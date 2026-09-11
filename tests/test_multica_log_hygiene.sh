#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/multica-log-hygiene"

[ -x "$SCRIPT" ] || { echo "multica log hygiene helper is missing or not executable"; exit 1; }
sh -n "$SCRIPT"

grep -Fq 'MAX_BYTES=8388608' "$SCRIPT"
grep -Fq 'KEEP_ARCHIVES=7' "$SCRIPT"
grep -Fq 'RETENTION_DAYS=14' "$SCRIPT"
grep -Fq ': > "$log_file"' "$SCRIPT"
grep -Fq '/etc/init.d/multica restart' "$SCRIPT"

if grep -Eq 'mv .*(daemon\.log|\$DAEMON_LOG)' "$SCRIPT"; then
	echo "active daemon.log must never be rotated with mv"
	exit 1
fi
if grep -Fq 'config.json' "$SCRIPT"; then
	echo "log hygiene helper must never reference Multica config.json"
	exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
printf '0123456789' >"$WORK_DIR/daemon.log"

MULTICA_LOG_HYGIENE_LIBRARY_ONLY=1 . "$SCRIPT"
MAX_BYTES=4
archive_and_truncate "$WORK_DIR/daemon.log" "$WORK_DIR/daemon-test.log.gz"
[ "$(stat -c%s "$WORK_DIR/daemon.log")" -eq 0 ]
gzip -cd "$WORK_DIR/daemon-test.log.gz" | grep -Fq '0123456789'

DATA_DIR="$WORK_DIR"
for sequence in $(seq 1 9); do
	archive="$WORK_DIR/daemon-20260101T00000${sequence}Z.log.gz"
	printf '%s' "$sequence" | gzip -c >"$archive"
	touch -d "@$((1700000000 + sequence))" "$archive"
done
prune_archives
[ "$(find "$WORK_DIR" -maxdepth 1 -name 'daemon-*.log.gz' | wc -l)" -le 7 ] || {
	echo "archive count was not capped at seven"
	exit 1
}

old_archive="$WORK_DIR/daemon-20000101T000000Z.log.gz"
printf old | gzip -c >"$old_archive"
touch -d '20 days ago' "$old_archive"
prune_archives
[ ! -e "$old_archive" ] || { echo "archive older than retention window was not pruned"; exit 1; }

runtime_log="$WORK_DIR/agent-runtime.log"
printf '0123456789' >"$runtime_log"
truncate_if_oversize "$runtime_log"
[ "$(stat -c%s "$runtime_log")" -eq 0 ]

echo "multica log hygiene guards passed"
