# `/data` rclone snapshot backup

`rclone-data-backup` is present but disabled by default. It is a deliberate,
one-way snapshot backup, not a filesystem mount or mirror. It always copies
`/data/smb`; other directories require an explicit line in
`/etc/rclone-data-backup/include.conf`. The manifest must never list
`/data/smb`, credentials, rclone configuration, globs, or relative paths.

Configure a pre-existing rclone remote on the device outside the firmware
image, then enable the UCI section. When the firmware build received
`WRTBAK_DEVICE_ALIAS`, that stable wrtbak alias is copied into
`device_alias`; preserve the same alias across sysupgrade. Otherwise set a
distinct alias explicitly. It is a device namespace, not a credential or a
hardware serial number:

```
uci set rclone-data-backup.main.remote='my-remote'
uci set rclone-data-backup.main.remote_path='router-backups'
uci set rclone-data-backup.main.device_alias='re-ss-01'
uci set rclone-data-backup.main.enabled='1'
uci commit rclone-data-backup
/etc/init.d/rclone-data-backup enable
/etc/init.d/rclone-data-backup start
```

The init service installs `0 3 * * *` cron only when enabled. Scheduled runs
add a cryptographic-random delay of 0–20 minutes. Manual invocations do not
jitter: `/usr/sbin/rclone-data-backup`.

Each snapshot lives at
`remote:remote_path/device_alias/snapshots/<UTC-id>/`. A `_SUCCESS` marker is
written only after every configured copy succeeds. Retention considers only
such markers and retains exactly the most recent three successful snapshots.
It uses `rclone purge` only for an exact, old, marker-verified snapshot path;
the upload path uses `rclone copy` and never calls `mount`, `sync`, or a
general remote delete.

Before upload, the script requires `/data` to be a real mount, takes an
exclusive local lock, and defers if a configured `list writer_lock` exists.
Set locks only for writers that hold the path for their complete transaction.
Result, error/deferred status, timestamp, remote, snapshot, and best-effort
`rclone about` quota output are atomically written as key/value text to
`/var/run/agent-data-backup.status` for human/role-card consumers. The same
details are retained at `/data/.rclone-data-backup/status`; compact Prometheus
text is in `metrics.prom`. Neither file contains credentials.

If the remote is full, unreachable, or times out, the status becomes `error`;
the job has the configured hard timeout and must not retry indefinitely. The
agent may report source size, quota text and failure reason, then ask whether
to keep three snapshots or explicitly change to one. It must not silently
change retention, the remote, included paths or scheduling frequency.

`timeout_seconds` is bounded to 60–86400, jitter to 0–20, and retention is
fixed at 3 as a safety contract. Keep rclone remotes and credentials in the
device's protected runtime configuration, never in this repository or the
include manifest.
