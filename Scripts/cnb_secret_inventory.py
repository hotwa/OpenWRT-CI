#!/usr/bin/env python3
"""Audit and template the build-domain secrets a CNB fallback needs.

Read-only by construction: this script only ever looks at secret *names* in the
GitHub workflows and at reviewed tables in this file. It never reads, prints,
hashes or copies a value, and it never touches GitHub secrets, the cloud-secret
repository, any ACL or the protected ``firmware-cd`` environment.

Subcommands
-----------
--audit                 print the name inventory, grouped by build impact
--check PATH            validate an unfilled template (exit 1 on drift)
--write PATH            regenerate the unfilled template (placeholders only)

``--check`` additionally cross-checks the embedded profile requirement table
against the CNB preflight module when that module is present (the CNB side); on
GitHub the module is absent and the embedded table is authoritative.

The template holds placeholders, not values. ``<...>`` is documented as absent by
the CNB replay (``clean_optional``), so an unfilled key can never be mistaken for
a real credential.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_DIR = ROOT / ".github" / "workflows"
TEMPLATE_PATH = ROOT / ".cnb/cloud-secret-env.build.template.yml"
SECRET_REF = re.compile(r"secrets\.([A-Z][A-Z0-9_]*)")
PLACEHOLDER = re.compile(r"^<FILL:[^<>]{1,120}>$")

# Reviewed ACL for the build credential file. The owner maintains the file; this
# template only records the values agreed for the migration branch.
ALLOW_SLUGS = ["b2233/openwrt-ci"]
ALLOW_EVENTS = ["web_trigger_re_private_build", "vscode"]
ALLOW_BRANCHES = ["main", "migration/cnb-shadow-20260926"]

# Reviewed per-profile requirement table (names only). It mirrors
# Scripts/cnb_re_profile_preflight.py on the CNB side; --check cross-checks both
# when that module is importable.
REVIEWED_PROFILE_REQUIREMENTS = {
    "re-cs-07": ("SAMBA_DEFAULT_PASSWORD",),
    "re-cs-02": ("SAMBA_DEFAULT_PASSWORD",),
    "re-ss-01": ("SAMBA_DEFAULT_PASSWORD",),
    "wlg-re-cs-07": ("SAMBA_DEFAULT_PASSWORD",),
    "cpe5g-a": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    "cpe5g-b": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    "cpe5g-b-configonly": ("SAMBA_DEFAULT_PASSWORD",),
    "qca-ipq60xx-wifi-no": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    "qca-ipq60xx-wifi-yes": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
}

# Referenced by the GitHub build callers but deliberately unused by the CNB
# replay: the CI debug hold is never replayed and the replay strips these keys
# from the builder environment.
OTHER_DOMAIN = {
    "HEADSCALE_CI_AUTHKEY": "GitHub CI debug hold only; not replayed by the CNB build",
    "HEADSCALE_URL": "GitHub CI debug hold only; stripped from the CNB builder environment",
    "GH_PAT": "GitHub API automation credential; not a build credential",
}

# Deployment, release and backup credentials: the build boundary must never
# receive them. ``firmware-cd`` environment secrets are listed here only by name;
# this repository never binds that environment.
NEVER_IN_BUILD = {
    "FIRMWARE_CD_SSH_PRIVATE_KEY": "firmware-cd environment (deployment)",
    "FIRMWARE_CD_KNOWN_HOSTS": "firmware-cd environment (deployment)",
    "AGENT_RUNTIME_USIGN_SECRET_KEY": "agent runtime signing/release",
    "WRTBAK_HOME_PROXY_URL": "device backup proxy",
    "WRTBAK_OFFICE_PROXY_URL": "device backup proxy",
    "WRTBAK_R2_ACCESS_KEY_ID": "device backup object storage",
    "WRTBAK_R2_SECRET_ACCESS_KEY": "device backup object storage",
    "WRTBAK_R2_BUCKET": "device backup object storage",
    "WRTBAK_R2_ENDPOINT": "device backup object storage",
    "WRTBAK_R2_PREFIX": "device backup object storage",
    "WRTBAK_R2_REGION": "device backup object storage",
    "GITHUB_TOKEN": "GitHub Actions built-in, not a transferable secret",
}

# Names the owner's GitHub secret inventory contains but no repository workflow
# references, and names workflows reference that the inventory did not list.
INVENTORY_NOT_REFERENCED = ("GH_PAT",) + tuple(
    name for name in NEVER_IN_BUILD if name.startswith("WRTBAK_"))
REFERENCED_NOT_IN_INVENTORY = (
    "OPENWRT_WAN_PPPOE_USERNAME", "OPENWRT_WAN_PPPOE_PASSWORD",
    "MULTICA_SERVER_URL", "MULTICA_APP_URL",
)
# Observed state (names only) from a read-only repository listing on 2026-09-27:
# the four names above are referenced by workflows but are not defined as
# repository secrets, so an empty value in the CNB file reproduces GitHub.
OBSERVED_UNSET = REFERENCED_NOT_IN_INVENTORY
OBSERVED_AT = "2026-09-27"


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
        if workflow.name == "CNB-Secret-Audit.yml":
            # The audit workflow references these names only for boolean presence
            # checks; it is not a build caller, so it must not appear as one.
            continue
        # Comments may mention a placeholder such as secrets.<NAME>; only real
        # references count, so comments are stripped before scanning.
        text = "\n".join(line.split("#", 1)[0]
                         for line in workflow.read_text(encoding="utf-8").splitlines())
        for name in set(SECRET_REF.findall(text)):
            found.setdefault(name, []).append(workflow.name)
    return {name: sorted(files) for name, files in found.items()}


def profile_requirements():
    """Required secret names per CNB profile and their union (names only)."""
    per_profile = {name: tuple(required)
                   for name, required in REVIEWED_PROFILE_REQUIREMENTS.items()}
    union = sorted({secret for required in per_profile.values() for secret in required})
    return per_profile, union


def cross_check_preflight():
    """Compare the embedded table with the CNB preflight when it is available."""
    preflight_path = ROOT / "Scripts/cnb_re_profile_preflight.py"
    if not preflight_path.is_file():
        return None
    sys.path.insert(0, str(ROOT / "Scripts"))
    import cnb_re_profile_preflight as preflight  # noqa: E402

    problems = []
    for name, profile in preflight.PROFILES.items():
        expected = tuple(preflight.profile_expectations(profile)["required_secrets"])
        if name not in REVIEWED_PROFILE_REQUIREMENTS:
            problems.append(f"profile missing from the reviewed table: {name}")
        elif tuple(REVIEWED_PROFILE_REQUIREMENTS[name]) != expected:
            problems.append(f"profile requirement drift: {name}")
    for name in REVIEWED_PROFILE_REQUIREMENTS:
        if name not in preflight.PROFILES:
            problems.append(f"reviewed table lists an unknown profile: {name}")
    return problems


def classification():
    """Group every known name by its impact on the CNB build."""
    referenced = workflow_secret_names()
    per_profile, required_union = profile_requirements()
    required, optional, other, forbidden = [], [], [], []
    for name in sorted(referenced):
        if name in NEVER_IN_BUILD:
            continue
        if name in OTHER_DOMAIN:
            other.append(name)
        elif name in required_union:
            required.append(name)
        else:
            optional.append(name)
    for name in sorted(OTHER_DOMAIN):
        if name not in other:
            other.append(name)
    for name in sorted(NEVER_IN_BUILD):
        forbidden.append(name)
    missing = [name for name in required_union if name not in referenced]
    if missing:
        raise SystemExit("profile requirement is absent from the GitHub workflows: "
                         + ", ".join(missing))
    return {"referenced": referenced, "per_profile": per_profile,
            "required_union": required_union, "required": required, "optional": optional,
            "other_domain": sorted(other), "forbidden": forbidden,
            "inventory_not_referenced": sorted(INVENTORY_NOT_REFERENCED),
            "referenced_not_in_inventory": sorted(REFERENCED_NOT_IN_INVENTORY)}


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
        "# Scope: build domain only. Deployment, release and backup credentials are",
        "# deliberately absent (see the comments at the end of this file).",
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
        "# Not used by the CNB build (names only; never add them here):",
    ]
    lines += [f"#   {name:32s} {OTHER_DOMAIN[name]}" for name in info["other_domain"]]
    lines += [
        "",
        "# Forbidden here (deployment/release/backup domain, names only):",
    ]
    lines += [f"#   {name:32s} {NEVER_IN_BUILD[name]}"
              for name in info["forbidden"] if name != "GITHUB_TOKEN"]
    lines += [
        "#   GITHUB_TOKEN                     GitHub Actions built-in, not transferable",
        "",
        "# Reconciliation notes (names only):",
        "#   present in the GitHub inventory but referenced by no workflow: "
        + ", ".join(info["inventory_not_referenced"]),
        "#   referenced by workflows but absent from the repository secret list: "
        + ", ".join(info["referenced_not_in_inventory"]),
        f"#   (observed unset at {OBSERVED_AT}; leave them empty to match GitHub)",
        "",
    ]
    return "\n".join(lines)


def validate_template(path):
    """Fail closed on drift or on any value that is not a placeholder."""
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
            problems.append(f"deployment/release/backup credential must not be a template key: {name}")
        if name in OTHER_DOMAIN:
            problems.append(f"other-domain credential must not be a template key: {name}")
        if name not in info["referenced"]:
            problems.append(f"template lists a name no GitHub workflow references: {name}")
        value = data[name]
        if not isinstance(value, str) or not (PLACEHOLDER.match(value) or value == ""):
            problems.append(f"{name} is not an empty or <FILL:...> placeholder")
    cross = cross_check_preflight()
    if cross:
        problems.extend(cross)
    return problems


def cmd_audit():
    info = classification()
    print("build-domain secret names (names only; no value is read or printed)")
    print("  [build-required]")
    for name in info["required"]:
        profiles = ",".join(sorted(p for p, req in info["per_profile"].items() if name in req))
        print(f"    {name:34s} profiles={profiles}")
    print("  [build-optional]")
    for name in info["optional"]:
        print(f"    {name:34s} callers={','.join(info['referenced'][name])}")
    print("  [github-only / other domain: not used by the CNB build]")
    for name in info["other_domain"]:
        print(f"    {name:34s} {OTHER_DOMAIN[name]}")
    print("  [forbidden in the build domain: deployment/release/backup]")
    for name in info["forbidden"]:
        print(f"    {name:34s} {NEVER_IN_BUILD[name]}")
    print("  [reconciliation]")
    print("    inventory but no workflow reference: "
          + ", ".join(info["inventory_not_referenced"]))
    print("    workflow reference but not in the inventory: "
          + ", ".join(info["referenced_not_in_inventory"]))
    print("    required union: " + ",".join(info["required_union"]))
    cross = cross_check_preflight()
    print("    preflight cross-check: "
          + ("not available (GitHub side)" if cross is None
             else ("passed" if not cross else "; ".join(cross))))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--audit", action="store_true", help="print the grouped name inventory")
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
