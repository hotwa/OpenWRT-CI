# OpenWrt uv Runtime Integration Design

**Date:** 2026-03-25

**Status:** Approved design, pending implementation planning

## Goal

Integrate `uv` into this OpenWrt build repository so supported firmware images boot with:

- a directly executable `uv` command in the default shell `PATH`
- full system `python3` instead of `python3-light`
- precreated `uv` runtime directories with environment variables for cache and managed Python storage
- preloaded CPython 3.10, 3.11, 3.12, and 3.13 assets for supported architectures, avoiding network downloads at first use whenever possible

## Background

This repository builds customized ImmortalWrt/OpenWrt firmware images and already supports root filesystem overlays via the repository-level `files/` directory. The workflow copies `./files/.` into `./wrt/files/` during CI, which makes rootfs preloading a good fit for `uv`.

Relevant current behavior:

- `Config/GENERAL.txt` currently enables `CONFIG_PACKAGE_python3-light=y`
- `.github/workflows/WRT-CORE.yml` copies `files/` into `wrt/files/`
- `Scripts/Handles.sh` already performs pre-build downloads into `files/`

## Scope

### In Scope

- Replace `python3-light` with full `python3`
- Preload the `uv` musl binary into the image for supported architectures
- Precreate `uv` storage directories under `/opt/uv`
- Export `UV_CACHE_DIR`, `UV_PYTHON_INSTALL_DIR`, and `UV_PYTHON_CACHE_DIR` via shell profile
- Attempt to preload managed CPython 3.10 through 3.13 into `uv`'s managed Python directory layout
- Fall back safely when preloading some Python versions is not possible
- Add smoke-test level CI checks that confirm the expected rootfs artifacts are present

### Out of Scope

- Building `uv` from source inside OpenWrt
- Supporting every OpenWrt architecture on day one
- Implementing a LuCI frontend in the same change
- Guaranteeing offline installation of every future CPython patch release
- Replacing OpenWrt's package manager with `uv`

## Supported Architectures

Phase 1 support is limited to architectures with a verified `uv` musl binary path and a realistic chance of managed CPython preloading:

- `aarch64`
- `x86_64`

All other architectures remain buildable, but the `uv` preload workflow is skipped for them.

## User-Facing Behavior

On supported firmware images:

- `uv --version` works immediately after login
- `python3 --version` uses the system-provided OpenWrt Python package
- `uv venv --python 3.10`, `3.11`, `3.12`, and `3.13` should avoid network downloads when the preload step succeeds
- `uv` cache and managed Python storage live under `/opt/uv`, not under user-home hidden directories

On unsupported firmware images:

- the image still builds
- `python3` remains available
- `uv` and preloaded managed CPython are omitted

## Design Overview

The integration is split into three layers:

1. **System Python layer**
   OpenWrt provides a stable, complete `python3` package for baseline compatibility.

2. **uv binary layer**
   CI downloads the correct official `uv` musl binary for the target architecture and places it in `/usr/bin/uv`.

3. **Managed Python preload layer**
   CI prepares `/opt/uv/python`, `/opt/uv/python-cache`, `/opt/uv/python-mirror`, and `/opt/uv/cache`, then downloads the managed CPython 3.10-3.13 source archives into a local mirror layout that `uv` can consume without external network access.

## Repository Changes

### Configuration Changes

Modify `Config/GENERAL.txt`:

- remove `CONFIG_PACKAGE_python3-light=y`
- enable full `python3`

The Phase 1 target configuration is explicitly:

- remove `CONFIG_PACKAGE_python3-light=y`
- add `CONFIG_PACKAGE_python3=y`

The implementation plan must begin by inspecting the checked-out OpenWrt package metadata for Python package splits and then pin any additional package names only if required to make `python3 -m venv` succeed on the target source tree. The planned runtime acceptance check for this requirement is:

- `python3 -m venv /tmp/uv-smoke-venv`

This keeps the desired end behavior precise while allowing the plan to discover exact package names from the upstream tree instead of guessing them in advance.

### New Runtime Fetch Script

Add a dedicated script:

- `Scripts/fetch_uv_runtime.sh`

Responsibilities:

- map `WRT_ARCH` to a supported `uv` musl target
- fetch the latest `uv` release metadata from GitHub API, with a repository-defined fallback version
- download the matching `uv` tarball
- extract the `uv` executable into `files/usr/bin/uv`
- create `files/opt/uv/python`
- create `files/opt/uv/python-cache`
- create `files/opt/uv/python-mirror`
- create `files/opt/uv/cache`
- download CPython 3.10, 3.11, 3.12, and 3.13 archives into a local mirror structure compatible with `UV_PYTHON_INSTALL_MIRROR`
- optionally pre-expand managed interpreters into `UV_PYTHON_INSTALL_DIR` only if the layout can be verified without relying on undocumented `uv` internals
- log warnings for partial Python preload failures without failing the build

### Rootfs Overlay Additions

Add:

- `files/etc/profile.d/uv.sh`

Contents should export:

- `UV_CACHE_DIR=/opt/uv/cache`
- `UV_PYTHON_INSTALL_DIR=/opt/uv/python`
- `UV_PYTHON_CACHE_DIR=/opt/uv/python-cache`
- `UV_PYTHON_INSTALL_MIRROR=file:///opt/uv/python-mirror`

This keeps future runtime path changes configurable via environment variables, which is explicitly desired.

### Workflow Integration

Update the workflow path that currently prepares custom packages and rootfs files so it also runs the new fetch script before `files/` is copied into `wrt/files/`.

Preferred integration point:

- inside the existing `Custom Packages` step in `.github/workflows/WRT-CORE.yml`

This keeps all image-preload behavior in one place.

## Architecture Mapping

The implementation must use an explicit allowlist, not best-effort guessing.

Initial mapping:

- `aarch64` -> `uv-aarch64-unknown-linux-musl`
- `x86_64` -> `uv-x86_64-unknown-linux-musl`

Any other architecture:

- skip `uv` preload
- emit a clear warning in CI logs
- continue the build

## Managed CPython Preload Strategy

### Primary Strategy

For supported architectures, download prebuilt managed CPython distributions for:

- 3.10
- 3.11
- 3.12
- 3.13

Stage the official `python-build-standalone` archives into a local mirror directory consumed through `UV_PYTHON_INSTALL_MIRROR`, rather than depending on `uv`'s private installed-layout conventions.

The mirror layout must follow the documented replacement behavior of `UV_PYTHON_INSTALL_MIRROR`, which substitutes for:

- `https://github.com/astral-sh/python-build-standalone/releases/download`

Therefore the staged rootfs should expose paths of the form:

- `/opt/uv/python-mirror/<build-id>/<artifact-name>`

Example shape:

- `/opt/uv/python-mirror/20240713/cpython-3.12.4+20240713-aarch64-unknown-linux-musl-install_only.tar.gz`

The exact `<build-id>` and `<artifact-name>` values should come from the release metadata for the selected CPython version and target architecture.

### Why Not Use Home-Directory Defaults

Using `/opt/uv` is preferred over `~/.local/share/uv` because:

- firmware rootfs should not depend on a specific login user
- root-owned system storage is clearer for preloaded assets
- later path changes can be handled entirely with environment variables

### Acceptable Fallback

If direct pre-expansion into `UV_PYTHON_INSTALL_DIR` proves unstable for some versions or upstream artifact formats, the implementation may stop at local-mirror preloading, provided that:

- the `uv` binary still works immediately
- the system `python3` remains usable
- the CI output clearly reports which versions were fully pre-expanded versus mirror-only
- creating a managed interpreter no longer requires network access for mirrored versions

### Non-Acceptable Fallback

Do not silently fall back to internet downloads while claiming the version is preloaded. Any preload miss must be visible in CI logs.

## Release and Download Resolution

### uv Binary

Use GitHub API to detect the latest `uv` release at build time.

Fallback behavior:

- if API resolution fails, use a repository-owned fallback version constant
- if fallback version download fails, fail the build for supported architectures

Rationale:

- the firmware requirement explicitly expects `uv` to be present
- without the `uv` binary, the feature is not delivered

### Managed CPython

For each requested Python major.minor version:

- resolve the latest matching downloadable managed CPython artifact for the target architecture from the Astral `python-build-standalone` release path used by `uv`
- download and stage the archive into the local mirror tree
- if one version fails, keep processing the others
- report failures as warnings

The spec intentionally defines "preloaded" as:

- the archive required for that Python version exists in the local mirror path included in the firmware image

The spec intentionally defines "fully pre-expanded" as:

- the interpreter is already unpacked into `UV_PYTHON_INSTALL_DIR` in a form recognized by `uv`

Rationale:

- `uv` itself is mandatory
- internet-free access to selected interpreter versions is valuable but secondary

## Failure Handling

### Hard Failures

Fail the build when:

- target architecture is supported but the `uv` binary cannot be downloaded or extracted
- the fetch script cannot create the required rootfs output directories

### Soft Failures

Warn but continue when:

- a managed CPython version cannot be resolved
- a managed CPython version downloads but cannot be staged into the local mirror path
- a managed CPython version is mirrored but cannot be safely pre-expanded
- the target architecture is not in the allowlist

## Verification

### Pre-Build Verification

Add or extend repository tests to verify:

- `Config/GENERAL.txt` selects full `python3`, not `python3-light`
- `files/etc/profile.d/uv.sh` exists and exports the expected variables
- `files/usr/bin/uv` exists after the preload script runs for supported architectures
- `files/opt/uv/python`, `files/opt/uv/python-cache`, `files/opt/uv/python-mirror`, and `files/opt/uv/cache` exist

### Artifact-Level Verification

For supported architectures, the workflow should assert before image compilation that:

- `uv` is executable in the staged rootfs
- at least one requested managed CPython version was staged successfully into the local mirror
- the profile exports include `UV_PYTHON_INSTALL_MIRROR`

If all managed Python versions fail to preload, the workflow should still continue, but the warning must be prominent.

### Runtime Smoke Expectations

The implementation should add one explicit smoke test path for supported targets that validates:

- `python3 -m venv /tmp/uv-smoke-venv`

This is the acceptance check for the "full system Python" requirement.

### Runtime Expectations

This change is considered successful when a freshly flashed supported device can do all of the following without additional downloads for the happy path:

- run `uv --version`
- run `python3 --version`
- create a virtual environment with one of the mirrored Python versions without requiring external network access

## LuCI Follow-Up

`luci-app-uv` is intentionally deferred until the CLI path is proven stable. The later LuCI app should assume:

- `uv` lives at `/usr/bin/uv`
- storage lives under `/opt/uv`
- configuration can be represented as environment variables or a small UCI wrapper
- local Python asset mirroring lives under `/opt/uv/python-mirror`

This keeps the current work focused on a stable runtime foundation.

## Open Questions Resolved by This Design

- **Install only uv or both uv and pixi?**
  Install only `uv`.

- **Which Python versions should be preloaded?**
  Preload 3.10, 3.11, 3.12, and 3.13.

- **How should unsupported architectures behave?**
  Skip preloading and keep the build green.

- **Should cache and Python locations stay adjustable later?**
  Yes, via exported environment variables.

## Risks

- Preloading managed CPython may require adaptation if upstream asset naming or layout changes
- Full `python3` plus four managed CPython versions will noticeably increase image size
- Some OpenWrt targets may not have enough storage headroom for all four preloaded versions

## Risk Mitigations

- keep the architecture allowlist narrow at first
- separate mandatory `uv` failures from optional CPython preload failures
- expose storage paths via environment variables so later tuning does not require a redesign
- defer LuCI work until runtime behavior is validated on real devices
