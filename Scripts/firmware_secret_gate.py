#!/usr/bin/env python3
"""Fail early on incomplete build credentials; report names only."""
import argparse
import json
import os
import sys
from cnb_re_profile_preflight import PROFILES, profile_expectations

SENSITIVE = (
    "SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY", "MULTICA_TOKEN",
    "MULTICA_SERVER_URL", "MULTICA_APP_URL", "MULTICA_WORKSPACE_ID",
    "NIKKI_SUBSCRIPTION_URL", "OPENWRT_DROPBEAR_AUTHORIZED_KEYS",
    "OPENWRT_WAN_PPPOE_USERNAME", "OPENWRT_WAN_PPPOE_PASSWORD",
    "COMMANDCODE_API_KEY", "CLIPROXYAPI_API_KEY", "CLIPROXYAPI_BASE_URL",
)

def clean_optional(value):
    """Treat documented optional placeholders as absent, never embed them."""
    value = value or ""
    stripped = value.strip().strip("\"'")
    if stripped.startswith("<") and stripped.endswith(">"):
        return ""
    if "${{" in stripped:
        return ""
    return value


def missing_required(base, profile):
    return sorted(key for key in profile_expectations(profile)["required_secrets"]
                  if not clean_optional(base.get(key, "")))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=sorted(PROFILES))
    args = parser.parse_args()
    required = missing_required(os.environ, PROFILES[args.profile])
    report = {"profile": args.profile, "missing_required_names": required,
              "missing_optional_names": sorted(key for key in SENSITIVE
                    if key not in profile_expectations(PROFILES[args.profile])["required_secrets"]
                    and not clean_optional(os.environ.get(key, "")))}
    print(json.dumps(report, sort_keys=True))
    return 1 if required else 0

if __name__ == "__main__":
    raise SystemExit(main())
