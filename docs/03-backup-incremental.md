# 🔄 Incremental Backup

An **incremental backup** copies only the files that have changed since
the **most recent** backup of any type (full, differential, or
incremental). This makes it much faster and uses far less storage than
a full backup.

> **Dependency chain**  
> `full → incr → incr → incr …`  
> An incremental backup cannot be taken unless at least one full backup
> already exists in the repository.

---

## Backup types at a glance

| Type | Copies | Size | Speed |
|------|--------|------|-------|
| `full` | All files | Largest | Slowest |
| `diff` | Changed since last *full* | Medium | Medium |
| `incr` | Changed since last backup (any) | Smallest | Fastest |

---

## Prerequisites

* At least one **full backup** must already exist.
* All six service layers must be running.

Verify:

```bash
# Check that a full backup exists
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main info

# Overall health
bash scripts/check-health.sh
```

---

## Method 1 — Helper script (recommended)

```bash
# Incremental backup
bash scripts/backup.sh incr

# Differential backup (relative to last full)
bash scripts/backup.sh diff
```

Or run the script interactively without arguments:

```bash
bash scripts/backup.sh
# Select backup type:
#   1) Full backup
#   2) Differential backup
#   3) Incremental backup
#
# Enter choice [1-3] (default: 1): 3
```

---

## Method 2 — Direct Docker Compose command

```bash
# Incremental
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main --type=incr --log-level-console=info backup

# Differential
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main --type=diff --log-level-console=info backup
```

---

## Verify the backup

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main info
```

A healthy repository with one full + two incrementals looks like this:

```
stanza: main
    status: ok

    db (current)
        full backup: 20250115-020000F
            timestamp start/stop: 2025-01-15 02:00:00 / 2025-01-15 02:03:42
            database size: 23.8MB, backup size: 23.8MB

        incr backup: 20250115-020000F_20250115-100000I
            timestamp start/stop: 2025-01-15 10:00:00 / 2025-01-15 10:00:14
            database size: 23.8MB, backup size: 256KB
            backup reference list: 20250115-020000F

        incr backup: 20250115-020000F_20250115-180000I
            timestamp start/stop: 2025-01-15 18:00:00 / 2025-01-15 18:00:11
            database size: 23.8MB, backup size: 128KB
            backup reference list: 20250115-020000F, 20250115-020000F_20250115-100000I
```

---

## Recommended automated schedule

Edit `docker/pgbackrest/entrypoint.sh` (or override it in your own
`docker-compose.override.yml`) to customise the cron schedule:

```bash
# Example: full at 02:00, incremental every 6 hours
echo "0 2    * * *  pgbackrest --stanza=main --type=full backup" >  /tmp/pgbackrest-crontab
echo "0 8,14,20 * * * pgbackrest --stanza=main --type=incr backup" >> /tmp/pgbackrest-crontab
supercronic /tmp/pgbackrest-crontab &
```

---

## View backup logs

```bash
tail -f logs/backup.log
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `no prior backup exists` | No full backup in repo | Run `bash scripts/backup.sh full` first |
| `archive_command failed` | WAL archiving broken | Check `pgbackrest-primary` container logs |
| Incremental is unexpectedly large | Many files changed or stale checksum | Normal after bulk-load; consider a `diff` instead |
