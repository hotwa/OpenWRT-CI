#!/bin/bash
# tests/lib/workflow-discovery.sh
# Dynamically discover device-build workflows that call WRT-CORE.yml.
#
# Usage in tests:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow-discovery.sh"
#   for wf in $(discover_device_workflows); do
#       ...
#   done
#
# Rationale: tests must not hardcode workflow file lists.  Every time a
# workflow is added or removed the hardcoded lists rot and cause false
# failures (e.g. the QCA-6.12 deletion broke 8 tests).  Dynamic discovery
# by content ("does this file call WRT-CORE.yml?") keeps tests in sync
# automatically.
#
# A "device build workflow" is any .yml file under .github/workflows/ that
# contains the reusable-workflow call `uses: ./.github/workflows/WRT-CORE.yml`.
# WRT-CORE.yml itself is excluded (it is the callee, not a caller).

set -u

# Echo the absolute paths of all caller workflows, one per line.
discover_device_workflows() {
	local root="${WORKFLOW_DISCOVERY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	local wf
	for wf in "$root"/.github/workflows/*.yml; do
		[ -f "$wf" ] || continue
		# Skip the core itself
		[ "$(basename "$wf")" = "WRT-CORE.yml" ] && continue
		# Match the reusable-workflow call.  Use grep -F for literal match.
		grep -Fq 'uses: ./.github/workflows/WRT-CORE.yml' "$wf" 2>/dev/null || continue
		echo "$wf"
	done
}

# Echo just the basenames, one per line.
discover_device_workflow_names() {
	discover_device_workflows | while read -r p; do basename "$p"; done
}

# Return success if the given workflow path (or basename) is a known
# device-build workflow.  Usage:
#   if workflow_is_device_build "$path"; then ...
workflow_is_device_build() {
	local target="$1"
	local wf
	for wf in $(discover_device_workflows); do
		if [ "$wf" = "$target" ] || [ "$(basename "$wf")" = "$target" ]; then
			return 0
		fi
	done
	return 1
}
