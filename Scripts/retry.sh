#!/bin/bash
#
# retry.sh - tiny command retry helper.
#
# Usage:
#   . "$(dirname "$(realpath "$0")")/retry.sh"
#   retry_cmd <max_attempts> <delay_seconds> <command> [args...]
#
# Examples:
#   retry_cmd 5 15 git clone --depth=1 https://example.com/repo.git
#   retry_cmd 3 5 curl -fsSL https://example.com/file -o file
#
# Returns 0 on the first successful attempt, otherwise the exit code of the
# last attempt after all retries are exhausted. Safe to source from scripts
# running under `set -euo pipefail`: a failed attempt does not abort the
# caller because the command runs inside an `if` conditional. This library
# intentionally does not toggle shell options (e.g. `set -u`) so it cannot
# change the caller's environment.

retry_cmd() {
	local max_attempts="$1"
	local sleep_seconds="$2"
	local attempt=1
	local exit_code=0
	shift 2

	while [ "$attempt" -le "$max_attempts" ]; do
		if "$@"; then
			return 0
		else
			exit_code=$?
		fi
		if [ "$attempt" -ge "$max_attempts" ]; then
			echo "ERROR: command failed after $attempt attempts: $*" >&2
			return "$exit_code"
		fi
		echo "WARN: command failed (attempt $attempt/$max_attempts): $*" >&2
		echo "WARN: retrying in ${sleep_seconds}s..." >&2
		sleep "$sleep_seconds"
		attempt=$((attempt + 1))
	done

	return "$exit_code"
}
