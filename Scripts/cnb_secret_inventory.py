#!/usr/bin/env python3
"""Audit and template the build-domain secrets a CNB fallback needs.

Read-only by construction: this script only ever looks at secret *names* in the
GitHub workflows, in ``.cnb.yml`` and in the CNB profile requirements. It never
reads, prints, hashes or copies a value, and it never touches GitHub secrets, the
cloud-secret repository or any ACL.

Subcommands
-----------
--audit                 list the build-domain secret names with their callers
--check PATH            validate an existing unfilled template (exit 1 on drift)
--write PATH            regenerate the unfilled template (placeholders only)

The template holds placeholders, not values; ``<...>`` is documented as absent by
the CNB replay (``clean_optional``), so an unfilled optional key can never be
mistaken for a real credential.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))

import cnb_re_profile_preflight as preflight  # noqa: E402

WORKFLOW_DIR = ROOT / ".github" / "workflows"
TEMPLATE_PATH = ROOT / ".cnb/cloud-secret-env.build.template.yml"
SECRET_REF = re.compile(r"secrets\.([A-Z][A-Z0-9_]*)")
PLACEHOLDER = re.compile(r"^<FILL:[^<>]{1,120}>$")

# Reviewed ACL for the build credential file. The owner maintains the file; this
# template only records the values that were actually agreed for the migration
# branch, so nobody has to guess them.
ALLOW_SLUGS = ["b2233/openwrt-ci"]
ALLOW_EVENTS = ["web_trigger_re_private_build", "vscode"]
ALLOW_BRANCHES = ["main", "migration/cnb-shadow-20260926"]

# Referenced by the GitHub build callers but deliberately not used by the CNB
# replay: the CI debug hold is never replayed and the replay strips these keys
# from the builder environment.
CNB_IGNORED = ("HEADSCALE_CI_AUTHKEY", "HEADSCALE_URL")

# Deployment / release credentials: the build boundary must never receive them.
NEVER_IN_BUILD = (
    "FIRMWARE_CD_SSH_PRIVATE_KEY",
    "FIRMWARE_CD_KNOWN_HOSTS",
    "AGENT_RUNTIME_USIGN_SECRET_KEY",
    "GITHUB_TOKEN",
)

PURPOSE = {
    "SAMBA_DEFAULT_PASSWORD": "Samba build credential used by every firmware profile",
    "HEADSCALE_OPENWRT_AUTHKEY": "Headscale device preauth key embedded by CPE-5G and QCA builds",
    "OPENWRT_WAN_PPPOE_USERNAME": "only needed when a profile builds with WAN_PROTOCOL=pppoe",
    "OPENWRT_WAN_PPPOE_PASSWORD": "only needed when a profile builds with WAN_PROTOCOL=pppoe",
    "OPENWRT_DROPBEAR_AUTHORIZED_KEYS": "extra SSH keys injected into the overlay",
    "NIKKI_SUBSCRIPTION_URL": "Nikki subscription URL injected at build time",
    "COMMANDCODE_API_KEY": "Pi CommandCode provider configuration",
    "CLIPROXYAPI_API_KEY": "Pi CliProxyAPI provider configuration",
    "CLIPROXYAPI_BASE_URL": "Pi CliProxyAPI provider configuration",
    "MULTICA_TOKEN": "Multica enrollment token",
    "MULTICA_SERVER_URL": "Multica endpoint",
    "MULTICA_APP_URL": "Multica app endpoint",
    "MULTICA_WORKSPACE_ID": "Multica workspace identifier",
}


def workflow_secret_names():
    """Map every referenced secret name to the workflow files that reference it."""
    found = {}
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        # Comments may mention a placeholder such as secrets.<NAME>; only real
        # references count, so comments are stripped before scanning.
        text = "\n".join(line.split("#", 1)[0]
                          for line in workflow.read_text(encoding="utf-8").splitlines())
        for name in set(SECRET_REF.findall(text)):
            found.setdefault(name, []).append(workflow.name)
    return {name: sorted(files) for name, files in found.items()}


def profile_requirements():
    """Return required secret names per CNB profile and the union of them."""
    per_profile = {}
    for name, profile in preflight.PROFILES.items():
        required = tuple(preflight.profile_expectations(profile)["required_secrets"])
        per_profile[name] = required
    union = sorted({secret for required in per_profile.values() for secret in required})
    return per_profile, union


def classification():
    """Classify every referenced name for the build-domain template."""
    referenced = workflow_secret_names()
    per_profile, required_union = profile_requirements()
    required = []
    optional = []
    ignored = []
    for name in sorted(referenced):
        if name in NEVER_IN_BUILD:
            continue
        if name in CNB_IGNORED:
            ignored.append(name)
        elif name in required_union:
            required.append(name)
        else:
            optional.append(name)
    missing = [name for name in required_union if name not in referenced]
    if missing:
        raise SystemExit("profile requirement is absent from the GitHub workflows: "
                         + ", ".join(missing))
    return {"referenced": referenced, "per_profile": per_profile, "required_union": required_union,
            "required": required, "optional": optional, "ignored": sorted(ignored)}


def render_template():
    info = classification()
    lines = [
        "# Build-domain secrets for b2233/cloud-secret projects/openwrt-ci/env.build.yml",
        "# Unfilled template: values are placeholders, never real credentials.",
        "#",
        "# Generated by Scripts/cnb_secret_inventory.py --write; validated by",
        "# tests/test_cnb_secret_inventory.py. Fill the values by hand in the CNB",
        "# secret repository; never commit a filled copy here.",
        "#",
        "# Placeholder semantics: the CNB replay treats <...> as absent, so a",
        "# placeholder can never be used as a credential.",
        "#",
        "# Scope: build domain only. Deployment credentials are deliberately absent.",
        "",
        "# ACL the owner maintains on that file (keep as reviewed):",
        "allow_slugs:",
    ]
    lines += [f"  - {slug}" for slug in ALLOW_SLUGS]
    lines += ["allow_events:"]
    lines += [f"  - {event}" for event in ALLOW_EVENTS]
    lines += ["allow_branches:"]
    lines += [f"  - {branch}" for branch in ALLOW_BRANCHES]
    lines += [
        "",
        "# Required by CNB profiles: an empty or placeholder value fails the build",
        "# closed instead of producing a silently different firmware.",
    ]
    for name in info["required"]:
        profiles = ", ".join(sorted(p for p, req in info["per_profile"].items() if name in req))
        lines.append(f"# required by: {profiles}")
        lines.append(f"# {PURPOSE.get(name, 'build-time credential')}")
        lines.append(f'{name}: "<FILL:required>"')
        lines.append("")
    lines += [
        "# Optional: an empty value reproduces the GitHub caller's degradation path.",
    ]
    for name in info["optional"]:
        callers = ", ".join(info["referenced"].get(name, []))
        lines.append(f"# used by: {callers}")
        lines.append(f"# {PURPOSE.get(name, 'optional build-time credential')}")
        lines.append(f'{name}: "<FILL:optional>"')
        lines.append("")
    lines += [
        "# Not used by the CNB replay (kept out of the builder environment):",
    ]
    lines += [f"#   {name}" for name in info["ignored"]]
    lines += [
        "",
        "# Never add deployment or release credentials here:",
    ]
    lines += [f"#   {name}" for name in NEVER_IN_BUILD if name != "GITHUB_TOKEN"]
    lines.append("")
    return "\n".join(lines)


def validate_template(path):
    """Fail closed on any drift or on any value that is not a placeholder."""
    info = classification()
    if not path.is_file():
        return [f"template is missing: {path}"]
    text = path.read_text(encoding="utf-8")
    try:
        import yaml
        data = yaml.safe_load(text)
    except Exception as exc:  # pragma: no cover - defensive
        return [f"template is not valid YAML: {exc}"]
    problems = []
    if not isinstance(data, dict):
        return ["template must be a mapping"]
    if data.get("allow_slugs") != ALLOW_SLUGS:
        problems.append("allow_slugs drifted from the reviewed value")
    if data.get("allow_events") != ALLOW_EVENTS:
        problems.append("allow_events drifted from the reviewed value")
    if data.get("allow_branches") != ALLOW_BRANCHES:
        problems.append("allow_branches drifted from the reviewed value")
    names = [key for key in data if not key.startswith("allow_")]
    for name in info["required_union"]:
        if name not in names:
            problems.append(f"required secret missing from template: {name}")
    for name in names:
        if name in NEVER_IN_BUILD:
            problems.append(f"deployment/release credential must not be in the build template: {name}")
        if name not in info["referenced"]:
            problems.append(f"template lists a name no GitHub workflow references: {name}")
        value = data[name]
        if not isinstance(value, str) or not (PLACEHOLDER.match(value) or value == ""):
            problems.append(f"{name} is not an empty or <FILL:...> placeholder")
    return problems


def cmd_audit():
    info = classification()
    print("build-domain secret names (names only; no values are read or printed):")
    for name in info["required"]:
        profiles = ",".join(sorted(p for p, req in info["per_profile"].items() if name in req))
        print(f"  required  {name:34s} profiles={profiles}")
    for name in info["optional"]:
        print(f"  optional  {name:34s} callers={','.join(info['referenced'][name])}")
    for name in info["ignored"]:
        print(f"  unused    {name:34s} (GitHub-only; not used by the CNB replay)")
    for name in NEVER_IN_BUILD:
        if name != "GITHUB_TOKEN":
            print(f"  forbidden {name:34s} (deployment/release boundary)")
    print(f"required union: {','.join(info['required_union'])}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--audit", action="store_true", help="print the name inventory")
    parser.add_argument("--check", metavar="PATH", help="validate an unfilled template")
    parser.add_argument("--write", metavar="PATH", help="regenerate the unfilled template")
    args = parser.parse_args()
    if args.audit:
        return cmd_audit()
    if args.write:
        target = Path(args.write)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(render_template(), encoding="utf-8")
        print(f"wrote unfilled template: {target}")
        problems = validate_template(target)
        if problems:
            print("\n".join(f"ERROR: {problem}" for problem in problems), file=sys.stderr)
            return 1
        print("template validated: placeholders only, required names present")
        return 0
    if args.check:
        problems = validate_template(Path(args.check))
        if problems:
            print("\n".join(f"ERROR: {problem}" for problem in problems), file=sys.stderr)
            return 1
        print("secret template check passed (placeholders only, no values)")
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
