# 💾 Full Backup

A **full backup** copies every file in the PostgreSQL data directory to
MinIO. Subsequent incremental backups depend on at least one full backup
existing in the repository.

---

## When to run a full backup

| Trigger | Recommendation |
|---------|---------------|
| After major PostgreSQL upgrade | Always |
| Weekly maintenance window | Recommended |
| Before a risky schema migration | Recommended |
| Nightly cron (automated) | Configured by default |

The `pgbackrest-primary` sidecar already schedules a full backup every
night at **02:00** via supercronic.  The commands below let you trigger
one on demand.

---

## Prerequisites

All six service layers must be running. Verify with:

```bash
bash scripts/check-health.sh
```

---

## Method 1 — Helper script (recommended)

```bash
bash scripts/backup.sh full
```

The script:
1. Auto-detects which Patroni node is currently the primary.
2. Runs `pgbackrest backup --type=full` on the matching pgBackRest
   sidecar.
3. Streams output to stdout **and** appends it to `logs/backup.log`.
4. Prints a final `pgbackrest info` summary.

Sample output:

```
========================================
 pgBackRest Manual Backup
========================================

[INFO]  Backup type: full
[INFO]  Stanza: main
[INFO]  Started at: 2025-01-15 02:00:00
[INFO]  Using pgBackRest sidecar: pgbackrest-primary
...
[INFO]  ✅ Backup completed successfully!
```

---

## Method 2 — Direct Docker Compose command

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main --type=full --log-level-console=info backup
```

---

## Verify the backup

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main info
```

Expected output (trimmed):

```
stanza: main
    status: ok
    cipher: none

    db (current)
        wal archive min/max (15): 000000010000000000000001/000000010000000000000005

        full backup: 20250115-020000F
            timestamp start/stop: 2025-01-15 02:00:00+00 / 2025-01-15 02:03:42+00
            wal start/stop: 000000010000000000000001 / 000000010000000000000002
            database size: 23.8MB, database backup size: 23.8MB
            repo1: backup set size: 3.1MB, backup size: 3.1MB
```

---

## View backup logs

```bash
# Script log
tail -f logs/backup.log

# Container log
docker compose -f services/04-pgbackrest/docker-compose.yml \
  logs -f pgbackrest-primary
```

---

## Retention policy

The default retention is **7 full backups** (configurable in
`config/pgbackrest/pgbackrest.conf`):

```ini
repo1-retention-full=7
```

pgBackRest automatically expires older full backups (and their
associated incrementals) each time a new full backup completes.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `No primary found` | Cluster not healthy | `bash scripts/check-health.sh` |
| `could not connect to server` | pgBackRest sidecar can't reach socket | Check `pg-patroni-primary-socket` volume is shared |
| `archive_mode` errors | WAL archiving disabled | Check Patroni config `archive_mode: on` |
| MinIO connection refused | MinIO not running | `docker compose -f services/02-minio/docker-compose.yml ps` |
