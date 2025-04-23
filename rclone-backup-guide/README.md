# Rclone Backup to Box for Cluster

This tutorial explains how to configure `rclone` on your cluster to back up `/mfs/io/groups/sterling/mfshome/$USER` to a Box directory named `cluster-backup`, with subfolders for `daily`, `archive`, and `logs`, and how to schedule it via cron. Users in the sterling group only need to run the commands in sections 2, 3, 4, and 6. The scripts are maintained centrally under `/mfs/io/groups/sterling/setup`.

---

## 1. Prerequisites

- **rclone** (v1.38 or later) installed on both the cluster and your desktop (with a browser)  
- Confirm **rclone versions** match:  
  ```bash
  /mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone version
  rclone version
  ```
- A Box Enterprise SSO account  
- Shell access to the cluster with `cron` available  

> **Tip:** Before running any live syncs, you can test with `--dry-run` to see what would transfer or delete without affecting Box.  
> ```bash
> /mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone sync \
>   /mfs/io/groups/sterling/mfshome/$USER box:cluster-backup/daily \
>   --dry-run --fast-list --checksum
> ```

---

## 2. Configure the Box remote with offline authorization

On the cluster, run rclone using its full path:

```bash
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone config
```

Press Enter to accept each default (shown in `<angle brackets>`):

```text
No remotes found, make a new one?
n/s/q> n

name> box
Storage> box
client_id> <leave blank>
client_secret> <leave blank>
box_config_file> <leave blank>
access_token> <leave blank>

box_sub_type>
  1 / user
  2 / enterprise
box_sub_type> 2

Edit advanced config?
y/n> n

Use web browser to automatically authenticate?
y/n> n
```

rclone will then **print** a command, e.g.:  
```
rclone authorize "box" "xxxxxxxxxxxxxxxx"
```

1. **Copy** that exact command, **switch to your local machine**, paste and run it. Complete the OAuth flow in your browser. It will print a **long token string**.  
2. **Back on the cluster**, paste **only** that token at:
   ```text
   config_token> xxxxxxxxxxxxxxxx...xxx
   ```
3. When asked:
   ```text
   Keep this "box" remote?
y) Yes
   ```
4. Verify:
   ```bash
   /mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone lsd box:
   ```

---

## 3. Create the Box folder hierarchy

Run once on the cluster using the full rclone path:

```bash
# Parent backup folder
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone mkdir box:cluster-backup

# Subfolders
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone mkdir box:cluster-backup/daily
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone mkdir box:cluster-backup/archive
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone mkdir box:cluster-backup/logs
```

Verify:
```bash
/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone lsd box:cluster-backup
```

---

## 4. Prepare the local environment

On the cluster, create a directory for logs:

```bash
mkdir -p ~/logs
```

---

## 5. Reference scripts

Sterling group members **do not** need to write or modify these; they live in `/mfs/io/groups/sterling/setup`.

### A) `backup.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

data_dir="/mfs/io/groups/sterling/mfshome/$USER"
remote_root="box:cluster-backup"
rclone_bin="/mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone"
date_str=$(date +%F)

# 1) Daily incremental
"$rclone_bin" sync \
  "$data_dir" \
  "${remote_root}/daily" \
  --fast-list --checksum \
  --log-file "$HOME/logs/backup-$date_str.log" --log-level INFO

# 2) Weekly snapshot (Sundays)
if [[ "$(date +%u)" == "7" ]]; then
  "$rclone_bin" sync \
    "$data_dir" \
    "${remote_root}/archive/$date_str" \
    --fast-list --checksum \
    --log-file "$HOME/logs/snapshot-$date_str.log" --log-level INFO
fi

# 3) Upload logs
"$rclone_bin" sync "$HOME/logs" "${remote_root}/logs" --fast-list --log-level INFO
```

Make it executable:
```bash
chmod +x /mfs/io/groups/sterling/setup/backup.sh
```

### B) `cronscript`
```cron
# /mfs/io/groups/sterling/setup/cronscript
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=$USER@utdallas.edu

# Run backup.sh daily at 02:00
0 2 * * * /mfs/io/groups/sterling/setup/backup.sh

# Rotate old snapshots (keep 4 weeks)
0 3 1 * * /mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone delete --min-age 28d box:cluster-backup/archive
```

---

## 6. Install the cron job

On the cluster, install the pre-written cron script:

```bash
crontab /mfs/io/groups/sterling/setup/cronscript
```

Verify:
```bash
crontab -l
```

---

## 7. Monitoring & Maintenance

- **View logs (live tail):**  
  ```bash
  tail -f ~/logs/backup-$(date +%F).log
  ```
- **Clean up local logs older than 30 days:**  
  ```bash
  find ~/logs -type f -mtime +30 -delete
  ```
- **Test restores:**  
  ```bash
  /mfs/io/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone copy \  
    box:cluster-backup/daily/path/to/file /tmp && diff /tmp/file /mfs/io/groups/sterling/mfshome/$USER/path/to/file
  ```
- **Error notifications:** Cron will email stderr/stdout to `$USER@yourdomain.com`. For advanced alerting, you can grep logs for `ERROR` and pipe to mail or integrate with Slack.

---

## 8. Additional Notes

- **Security & permissions:**  
  - Do **not** check `~/.config/rclone/rclone.conf` into any shared repositories—it contains tokens.  
  - For data encryption at rest, consider using an rclone `crypt` wrapper.

- **API rate limits (side note):**  
  Box enforces API quotas. Tweak `--transfers`, `--checkers`, or add `--tpslimit 3` if you hit rate‑limit errors.

- **Network/firewall (side note):**  
  Ensure outbound HTTPS (port 443) is open. If behind a proxy, set `HTTPS_PROXY` or use `--proxy`.

- **Monthly or quarterly snapshots:**  
  Extend the weekly logic with checks like:  
  ```bash
  if [[ "$(date +%d)" == "01" ]]; then
    … # monthly archive
  fi
  ```

- **Upstream docs:**  
  Official rclone Box backend documentation: https://rclone.org/box/

---

Your cluster home directory is now backed up incrementally to Box under `cluster-backup`, with `daily`, `archive`, and `logs` subfolders, plus monitoring and maintenance tips to keep it running smoothly.

---

## Summary

In this tutorial, you have:

- **Configured** the Box remote on a headless cluster node via offline authorization.
- **Created** a clear Box folder hierarchy (`cluster-backup/{daily,archive,logs}`) for organized storage.
- **Prepared** a local log directory and referenced centrally maintained backup and cron scripts.
- **Written** a robust `backup.sh` that performs daily incremental syncs, weekly snapshots, and log uploads.
- **Scheduled** the backup using a `crontab`, including log rotation and snapshot cleanup.
- **Implemented** monitoring, restore procedures, and maintenance routines (log pruning, error alerts).
- **Added** best‑practice notes on dry‑runs, version checks, security, API‑rate limits, and firewall considerations.

Great work! Your cluster’s home directory is now automatically and safely backed up to Box every night, with versioning, logs, and the tools for easy maintenance and recovery.


