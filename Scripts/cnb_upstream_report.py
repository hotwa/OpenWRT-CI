#!/usr/bin/env python3
"""Read-only, unauthenticated upstream drift evidence. Never updates source pins."""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
SHA = re.compile(r"[0-9a-f]{40}\Z")
SOURCE_REPO = "VIKINGYFY/immortalwrt"
WATCH_PATHS = (
    "package/qca-nss",                 # inline NSS driver/firmware/SSDK packaging
    "target/linux/qualcommax",         # target kernel, DTS and patches
    "include/kernel-version.mk",       # common kernel version/hash definitions
)
WORKFLOWS = {
    "RE-CS-07": ".github/workflows/RE-CS-07-BUILD.yml",
    "CPE-5G": ".github/workflows/CPE-5G.yml",
}
API = "https://api.github.com/repos/"


def source_pin(text):
    """Fail closed on absent, conflicting or movable production pins."""
    fields = {}
    for name in ("WRT_REPO", "WRT_BRANCH", "WRT_COMMIT"):
        values = re.findall(r"^\s*" + name + r":\s*([^\s#]+)", text, re.M)
        if not values or len(set(values)) != 1:
            raise ValueError(f"missing or conflicting {name}")
        fields[name] = values[0]
    if fields["WRT_REPO"] != f"https://github.com/{SOURCE_REPO}.git":
        raise ValueError("unexpected production source repository")
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", fields["WRT_BRANCH"]):
        raise ValueError("invalid production branch")
    pin = fields["WRT_COMMIT"].lower()
    if not SHA.fullmatch(pin):
        raise ValueError("production pin must be full 40-character SHA")
    return {"repository": SOURCE_REPO, "branch": fields["WRT_BRANCH"], "pin": pin}


def github_json(path):
    # No token, cookies or credentials are sent. Use no user-controlled URL.
    request = Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "openwrt-ci-read-only-upstream-drift",
    })
    try:
        with urlopen(request, timeout=20) as response:
            return json.load(response)
    except HTTPError as exc:
        raise RuntimeError(f"GitHub API returned HTTP {exc.code} for {path}; check reachability/rate limit") from exc
    except (URLError, TimeoutError) as exc:
        raise RuntimeError(f"GitHub API unavailable for {path}") from exc


def checked_sha(value):
    if not isinstance(value, str) or not SHA.fullmatch(value.lower()):
        raise ValueError("invalid SHA in upstream response")
    return value.lower()


def latest_path_commit(fetch, repo, ref, path):
    query = urlencode({"sha": ref, "path": path, "per_page": 1})
    commits = fetch(f"{repo}/commits?{query}")
    if not isinstance(commits, list):
        raise ValueError("invalid GitHub path history")
    return checked_sha(commits[0]["sha"]) if commits else None


def report(fetch=github_json, workflow_root=ROOT):
    pins = {
        name: source_pin((workflow_root / filename).read_text(encoding="utf-8"))
        for name, filename in WORKFLOWS.items()
    }
    branch = pins["RE-CS-07"]["branch"]
    if any(item["branch"] != branch for item in pins.values()):
        raise ValueError("production workflows have divergent source branches")
    head = checked_sha(fetch(f"{SOURCE_REPO}/commits/{quote(branch, safe='')}")["sha"])
    result = {
        "schema": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "mode": "read-only; candidate evidence only; no pin change, build, release or deployment",
        "production_source": SOURCE_REPO,
        "production_branch": branch,
        "production_head": head,
        "devices": {},
        "original_immortalwrt": {},
        "davidtall_candidate": {},
    }
    for name, item in pins.items():
        paths = {}
        for path in WATCH_PATHS:
            pinned = latest_path_commit(fetch, SOURCE_REPO, item["pin"], path)
            current = latest_path_commit(fetch, SOURCE_REPO, head, path)
            paths[path] = {
                "pinned_last_change": pinned,
                "head_last_change": current,
                "changed": pinned != current,
            }
        result["devices"][name] = {
            "pinned_source_sha": item["pin"],
            "source_advanced": item["pin"] != head,
            "paths": paths,
        }
    original = "immortalwrt/immortalwrt"
    original_branch = "master"
    original_head = checked_sha(fetch(f"{original}/commits/{original_branch}")["sha"])
    result["original_immortalwrt"] = {
        "branch": original_branch,
        "head": original_head,
        # No production fork ancestry is assumed; this is NOT a safe merge proposal.
        "qualcommax_last_change": latest_path_commit(fetch, original, original_head, "target/linux/qualcommax"),
        "kernel_metadata_last_change": latest_path_commit(fetch, original, original_head, "include/kernel-version.mk"),
    }
    candidate = "davidtall/immortalwrt"
    candidate_branch = "stable"
    candidate_head = checked_sha(fetch(f"{candidate}/commits/{candidate_branch}")["sha"])
    result["davidtall_candidate"] = {"branch": candidate_branch, "head": candidate_head}
    return result


if __name__ == "__main__":
    try:
        print(json.dumps(report(), ensure_ascii=False, indent=2, sort_keys=True))
    except (KeyError, ValueError, OSError, RuntimeError) as exc:
        print(f"upstream report failed closed: {exc}", file=sys.stderr)
        sys.exit(1)
