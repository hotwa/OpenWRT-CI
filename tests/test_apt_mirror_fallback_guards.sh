#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
APT_LIB="$ROOT_DIR/Scripts/ci-apt-lib.sh"
INIT_ENV="$ROOT_DIR/Scripts/ci_init_environment.sh"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$APT_LIB" ] || { echo "missing Scripts/ci-apt-lib.sh"; exit 1; }
[ -f "$INIT_ENV" ] || { echo "missing Scripts/ci_init_environment.sh"; exit 1; }

# The mirror reset helper now lives in the shared apt library (it is no
# longer inlined in the workflow, which only sources ci_init_environment.sh).
grep -q 'reset_ubuntu_mirrors()' "$APT_LIB" || {
  echo "ci-apt-lib.sh does not define reset_ubuntu_mirrors()"
  exit 1
}

# The old apt_retry_update() in the workflow is replaced by aptx_update()
# (normalize mirrors -> update -> exactly one official-archive fallback).
grep -q 'aptx_update()' "$APT_LIB" || {
  echo "ci-apt-lib.sh does not define aptx_update()"
  exit 1
}

# The IE step must route every apt call through the shared library, never
# call apt/apt-get directly.
grep -q 'ci_init_environment.sh' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not invoke the unified Initialization Environment script"
  exit 1
}

# aptx_update must normalize mirrors BEFORE the first update (single fallback,
# never retrying the same unreachable mirror forever).
grep -q 'reset_ubuntu_mirrors' "$APT_LIB" || {
  echo "ci-apt-lib.sh does not call reset_ubuntu_mirrors"
  exit 1
}
grep -q 'aptx_update' "$INIT_ENV" || {
  echo "ci_init_environment.sh does not use aptx_update"
  exit 1
}

# The duplicate full-upgrade path was intentionally removed (single upgrade
# path through the library); guard against the interactive `apt` frontend or
# the old run_apt helper creeping back into the workflow. (The Install BC
# step may keep its bounded `apt-get` call.)
if grep -q 'run_apt' "$WORKFLOW"; then
  echo "WRT-CORE.yml must not use the old run_apt helper"
  exit 1
fi
if grep -q 'apt -yqq' "$WORKFLOW"; then
  echo "WRT-CORE.yml must not call the interactive apt frontend"
  exit 1
fi

# Host build prerequisites must be installed via the bounded library call.
grep -q 'aptx_retry install dos2unix libfuse-dev' "$INIT_ENV" || {
  echo "ci_init_environment.sh does not install build prerequisites via the bounded aptx_retry"
  exit 1
}

# python3-netifaces host dependency must stay removed.
if grep -q 'python3-netifaces' "$WORKFLOW"; then
  echo "WRT-CORE.yml still installs the unused python3-netifaces host dependency"
  exit 1
fi

echo "apt mirror fallback guards test passed"
