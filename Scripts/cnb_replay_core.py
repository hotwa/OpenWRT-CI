#!/usr/bin/env python3
"""Compatibility entrypoint for existing CNB events; both hosts share firmware_build."""
import sys
import firmware_build

if __name__ == "__main__":
    firmware_build.main()
else:
    # Preserve imports and monkeypatch behavior of existing contract tests.
    sys.modules[__name__] = firmware_build
