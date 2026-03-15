# linux-backup

Daily backup of a Debian Linux box to S3. Backs up config files, custom daemon
binaries, and MariaDB databases, then uploads a compressed archive to S3.
Runs as a systemd timer. Includes a restore script for rebuilding from scratch.

## What gets backed up

- Asterisk / FreePBX config (`/etc/asterisk`, `/var/lib/asterisk`, `/var/spool/asterisk`)
- MariaDB databases (via `mysqldump` — FreePBX stores its config here)
- Mosquitto MQTT broker (`/etc/mosquitto`, including TLS certs)
- Custom daemon configs and binaries
- HAProxy, Apache, Postfix, NUT (UPS), firewall rules
- Phone provisioning config files
- Systemd unit files, cron jobs

Large re-downloadable data is excluded: Asterisk sound files, phone firmware.

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
`BACKUP_PATHS` and `MARIADB_DATABASES` for your setup.

### 3. Deploy to the target machine

```bash
scp backup.sh restore.sh install.sh backup.conf user@hostname:/tmp/
ssh user@hostname
sudo bash /tmp/install.sh
```

`install.sh` installs `awscli` and `mariadb-client`, copies the scripts to
`/opt/linux-backup`, and sets up a systemd timer (daily by default).

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

The restore script also re-imports MariaDB dumps if present in the archive.
After restoring run `systemctl daemon-reload` and restart affected services.

## Backup schedule and retention

Default: daily at a randomised time around midnight, keeping 30 backups (~1 month).

To change the schedule, edit `/etc/systemd/system/linux-backup.timer` on the
target machine and run `sudo systemctl daemon-reload`.
