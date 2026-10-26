# linux-backup

Daily backup of a Debian Linux box to S3. Archives the paths you list, MariaDB
databases, and anything your pre-backup hooks dump, optionally encrypts the
archive with GPG, and uploads it to S3. Runs as a systemd timer. Includes a
restore script for rebuilding from scratch.

This repo is the generic tool. What a particular host backs up (its
`backup.conf`, hooks and restore runbook) belongs in that host's own repo,
which installs a pinned release of this one. `backup.conf` is gitignored here.

## What it does

Each run, as root:

1. Dumps each database in `MARIADB_DATABASES` with `mariadb-dump` (or
   `mysqldump` on older systems).
2. Runs the [pre-backup hooks](#pre-backup-hooks) in `PRE_BACKUP_HOOKS_DIR`.
3. Archives `BACKUP_PATHS` (minus `EXCLUDE_PATHS`) plus the dumps and hook
   output into one `.tar.gz`. Missing paths are skipped with a warning.
4. Encrypts it for `GPG_RECIPIENT`, if set.
5. Uploads it to `s3://S3_BUCKET/S3_PREFIX/HOSTNAME/` and deletes the oldest
   beyond `RETENTION_COUNT`.
6. Publishes [MQTT events](#mqtt-events) as it goes.

Staging files are created under `umask 077`, as dumps may hold secrets.

## Setup

### 1. Create an S3 bucket and scoped credentials

Install [s3-credentials](https://github.com/simonw/s3-credentials):

```bash
pipx install s3-credentials
```

Set your AWS admin credentials in the environment, then run:

```bash
s3-credentials create your-bucket-name \
  -c \
  --bucket-region eu-west-2 \
  --endpoint-url https://s3.eu-west-2.amazonaws.com \
  --username your-hostname-backup \
  --prefix linux-backup/ \
  -f ini
```

This creates the bucket, an IAM user scoped to `linux-backup/*` in that bucket,
and prints credentials in ini format. Save the output — you'll need it in step 3.

> Note: the `--endpoint-url` flag is needed to create the bucket outside `us-east-1`.
> Once the bucket exists, omit it if you need to re-run (it interferes with IAM calls).

### 2. Configure the backup

```bash
cp backup.conf.example backup.conf
```

Edit `backup.conf` — at minimum set `S3_BUCKET` and `AWS_REGION`. Review
`BACKUP_PATHS`, `MARIADB_DATABASES` and `PRE_BACKUP_HOOKS_DIR` for your setup.

### 3. Deploy to the target machine

```bash
scp backup.sh restore.sh install.sh backup.conf user@hostname:/tmp/
ssh user@hostname
sudo bash /tmp/install.sh
```

`install.sh` installs `awscli` and `mariadb-client`, copies the scripts to
`/opt/linux-backup`, and sets up a systemd timer (daily by default). It
installs the `backup.conf` next to it, or `backup.conf.example` if there is
none, and never overwrites an existing `/opt/linux-backup/backup.conf`.

Put the S3 credentials from step 1 on the machine:

```bash
sudo mkdir -p /root/.aws
sudo tee /root/.aws/credentials > /dev/null <<'EOF'
[default]
aws_access_key_id=...
aws_secret_access_key=...
EOF
sudo chmod 600 /root/.aws/credentials

sudo tee /root/.aws/config > /dev/null <<'EOF'
[default]
region = eu-west-2
output = json
EOF
```

### 4. Test

```bash
sudo bash /opt/linux-backup/backup.sh
systemctl list-timers linux-backup.timer
```

## Pre-backup hooks

For data that must be dumped rather than copied while live (SQLite in WAL
mode, InfluxDB, MariaDB grants, ...), point `PRE_BACKUP_HOOKS_DIR` at a
directory of executables. Each run:

- Hooks run as root, in filename order (`10-sqlite`, `20-influx`, ...).
  Non-executable files are skipped with a warning; subdirectories are ignored.
- Each hook gets these environment variables:

  | Variable | Value |
  |---|---|
  | `BACKUP_HOOK_OUTPUT_DIR` | An empty directory for this hook: `STAGING_DIR/hooks/<hook-name>` |
  | `BACKUP_HOSTNAME` | Short hostname, as in the archive name |
  | `BACKUP_TIMESTAMP` | UTC timestamp, as in the archive name |

- Whatever a hook writes to `BACKUP_HOOK_OUTPUT_DIR` goes into the archive at
  that path, so it restores to `STAGING_DIR/hooks/<hook-name>/`.
- stdin is `/dev/null`. stdout and stderr go to the log, each line prefixed
  `[hook-name]`.
- Exit 0 means success. Any other exit, or running longer than `HOOK_TIMEOUT`
  seconds (default 600), counts as a failure. Later hooks still run and the
  archive is still uploaded, so one broken dump doesn't cost you the rest of
  the backup. But the run then ends with a `failed` MQTT event at stage
  `hook:<first-failed-hook>`, not `completed`, and `backup.sh` exits 1, so
  the systemd unit shows failed.
- If `PRE_BACKUP_HOOKS_DIR` is set but missing, that is a failure too
  (stage `hook:PRE_BACKUP_HOOKS_DIR`).

The hooks directory and the hooks in it must be owned by root and writable
only by root: they run as root.

A hook might look like this:

```bash
#!/usr/bin/env bash
set -euo pipefail
sqlite3 /var/lib/myapp/app.db ".backup '$BACKUP_HOOK_OUTPUT_DIR/app.db'"
```

## Restore

List available backups:

```bash
sudo bash /opt/linux-backup/restore.sh
```

Restore the latest:

```bash
sudo bash /opt/linux-backup/restore.sh latest
```

Restore a specific backup:

```bash
sudo bash /opt/linux-backup/restore.sh garibaldi_2026-03-15_111145.tar.gz
```

Restore to a different root (e.g. for inspection without overwriting):

```bash
sudo bash /opt/linux-backup/restore.sh latest --dest /mnt/restore
```

Restore from a different hostname (e.g. replacing dead hardware):

```bash
sudo bash /opt/linux-backup/restore.sh latest --host old-hostname
```

Other options: `--config FILE` uses another config (or set `CONFIG=FILE`), and
`--yes` skips the confirmation prompt.

When restoring to `/`, the script also re-imports MariaDB dumps if present in
the archive. Hook output is restored to `STAGING_DIR/hooks/<hook-name>/` and
left for you, or your host's runbook, to load. After restoring run
`systemctl daemon-reload` and restart affected services.

## MQTT events

If `MQTT_BROKER` is set in `backup.conf`, the script publishes events to
`backups/<hostname>` at the start and end of each backup run.

**started**
```json
{"state":"started","host":"garibaldi","timestamp":"2026-03-15T11:52:51Z"}
```

**completed**
```json
{
  "state": "completed",
  "host": "garibaldi",
  "timestamp": "2026-03-15T11:53:15Z",
  "duration_seconds": 24,
  "archive_size": "155M",
  "s3_uri": "s3://bucket/linux-backup/garibaldi/garibaldi_2026-03-15_115251.tar.gz",
  "backups_retained": 4
}
```

**failed**
```json
{"state":"failed","host":"garibaldi","timestamp":"...","stage":"upload","error":"S3 upload failed"}
```

Stages: `init`, `mariadb_dump`, `archive`, `upload`, `prune`, and
`hook:<name>`. A run with hook failures is the one failure that still uploads,
so its event also carries the completed fields:

```json
{
  "state": "failed",
  "host": "garibaldi",
  "timestamp": "2026-10-27T00:20:41Z",
  "stage": "hook:20-influxdb",
  "error": "1 hook(s) failed",
  "hooks_failed": ["20-influxdb"],
  "duration_seconds": 31,
  "archive_size": "160M",
  "s3_uri": "s3://bucket/linux-backup/garibaldi/garibaldi_2026-10-27_002010.tar.gz",
  "backups_retained": 30
}
```

## Deploying updates

After changing scripts locally, push them to a host that already ran
`install.sh`:

```bash
./deploy.sh user@192.168.1.10
```

Only the scripts are pushed; the host's `backup.conf` and hooks are left alone.
A host with its own repo should deploy a tagged release from there instead.

## Tests

```bash
test/run_tests.sh
```

The tests run `backup.sh` and `restore.sh` end to end against stub commands
(`aws`, `tar`, `mosquitto_pub`, ...), so they need only bash. One test checks a
real archive and runs only where GNU tar is installed (`brew install gnu-tar`
on macOS). CI runs them plus `shellcheck -S style`.

## Backup schedule and retention

Default: daily at a randomised time around midnight, keeping 30 backups (~1 month).

To change the schedule, edit `/etc/systemd/system/linux-backup.timer` on the
target machine and run `sudo systemctl daemon-reload`.
