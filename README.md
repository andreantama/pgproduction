# pgproduction 🐘

Production-grade **PostgreSQL ecosystem** — fully containerized with Docker Compose.  
Features: High Availability (Patroni), Point-in-Time Recovery (pgBackRest + MinIO), Connection Pooling (pgBouncer), and Load Balancing (HAProxy).

---

## 🏗️ Architecture Overview

```
                        ┌─────────────────────────────────────────────────┐
                        │              Docker Compose Stack                │
                        │                                                  │
   Write (port 5000) ──▶│  ┌──────────┐     ┌─────────────────────────┐  │
                        │  │          │     │    patroni-primary       │  │
   Read  (port 5001) ──▶│  │ HAProxy  │────▶│    PostgreSQL 15 R/W    │  │
                        │  │  (LB)    │  │  │    Patroni + pgBackRest │  │
   Pool  (port 6432) ──▶│  │          │  │  └─────────────────────────┘  │
                        │  └──────────┘  │                               │
                        │       ▲        │  ┌─────────────────────────┐  │
                        │       │        │  │   patroni-replica-1     │  │
                        │  ┌────┴─────┐  └─▶│   PostgreSQL 15 RO      │  │
                        │  │pgBouncer │  │  │   Patroni + pgBackRest  │  │
                        │  └──────────┘  │  └─────────────────────────┘  │
                        │                │                               │
                        │  ┌──────────┐  │  ┌─────────────────────────┐  │
                        │  │   etcd   │  └─▶│   patroni-replica-2     │  │
                        │  │ (DCS/HA) │     │   PostgreSQL 15 RO      │  │
                        │  └──────────┘     │   Patroni + pgBackRest  │  │
                        │                   └─────────────────────────┘  │
                        │  ┌──────────────────────────────────────────┐  │
                        │  │  MinIO (S3) ← WAL Archive + Full Backups │  │
                        │  └──────────────────────────────────────────┘  │
                        └─────────────────────────────────────────────────┘
```

### Component Summary

| Component | Role | Port(s) |
|-----------|------|---------|
| **HAProxy** | Load balancer: routes write→primary, read→replicas | 5000 (write), 5001 (read), 7000 (stats) |
| **pgBouncer** | Connection pooler | 6432 |
| **patroni-primary** | PostgreSQL 15 (Read/Write) + HA leader | 8008 (API) |
| **patroni-replica-1** | PostgreSQL 15 (Read Only) | 8009 (API) |
| **patroni-replica-2** | PostgreSQL 15 (Read Only) | 8010 (API) |
| **etcd** | Distributed config store for Patroni | 2379 |
| **pgBackRest (×3)** | Backup sidecar — WAL archive + scheduled full backup | — |
| **MinIO** | S3-compatible backup storage | 9000 (API), 9001 (Console) |

---

## 📋 Prerequisites

- **Docker** ≥ 20.10
- **Docker Compose** ≥ 2.0 (v2 CLI)
- **curl**, **nc** (for health check script)
- Minimum 4 GB RAM recommended

---

## 🚀 Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/andreantama/pgproduction.git
cd pgproduction

# Copy and review environment variables
cp .env.example .env
# Edit .env to set your passwords (recommended for production)
```

### 2. Build and start the stack

```bash
docker-compose up -d --build
```

### 3. Wait for the cluster to be ready (~60 seconds)

```bash
# Watch container status
docker-compose ps

# Watch Patroni logs
docker-compose logs -f patroni-primary
```

### 4. Verify the cluster is healthy

```bash
bash scripts/check-health.sh
```

---

## ✅ Verification

### Check Patroni cluster status

```bash
# Primary
curl -s http://localhost:8008 | python3 -m json.tool

# Replica 1
curl -s http://localhost:8009 | python3 -m json.tool

# Replica 2
curl -s http://localhost:8010 | python3 -m json.tool
```

### Test write connection (port 5000 via HAProxy)

```bash
PGPASSWORD=postgres123 psql -h localhost -p 5000 -U postgres -d mydb -c "CREATE TABLE test (id serial, val text);"
PGPASSWORD=postgres123 psql -h localhost -p 5000 -U postgres -d mydb -c "INSERT INTO test(val) VALUES ('hello world');"
```

### Test read connection (port 5001 via HAProxy)

```bash
PGPASSWORD=postgres123 psql -h localhost -p 5001 -U postgres -d mydb -c "SELECT * FROM test;"
```

### Test via pgBouncer (port 6432)

```bash
PGPASSWORD=postgres123 psql -h localhost -p 6432 -U postgres -d mydb -c "SELECT current_database(), inet_server_addr();"
```

### Check replication

```bash
PGPASSWORD=postgres123 psql -h localhost -p 5000 -U postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```

---

## 💾 Backup

### Manual backup (full)

```bash
bash scripts/backup.sh full
```

### Manual backup (incremental)

```bash
bash scripts/backup.sh incr
```

### Check backup status

```bash
docker-compose exec pgbackrest-primary pgbackrest --stanza=main info
```

### View pgBackRest logs

```bash
docker-compose logs pgbackrest-primary
```

---

## 🔄 Point-in-Time Recovery (PITR)

### Step-by-step PITR

1. **Note the timestamp** you want to restore to (e.g., just before a bad operation):
   ```
   2024-01-15 14:30:00
   ```

2. **Run the restore script** (interactive):
   ```bash
   bash scripts/restore.sh
   ```
   Select option `2) PITR` and enter the target timestamp.

3. **The script will automatically**:
   - Show available backups
   - Stop the PostgreSQL containers
   - Run `pgbackrest restore` with `--type=time --target=<timestamp>`
   - Start the containers
   - Verify the connection

### Manual PITR (advanced)

```bash
# Stop containers
docker-compose stop patroni-primary patroni-replica-1 patroni-replica-2

# Run PITR restore
docker-compose exec pgbackrest-primary \
  pgbackrest --stanza=main \
    --delta \
    --type=time \
    --target="2024-01-15 14:30:00" \
    --target-action=promote \
    restore

# Restart containers
docker-compose start patroni-primary patroni-replica-1 patroni-replica-2
```

---

## 📊 Monitoring

### HAProxy Stats

Open in browser: **http://localhost:7000/stats**

Shows real-time status of:
- Active/backup servers per backend
- Connection counts
- Health check results

### MinIO Console

Open in browser: **http://localhost:9001**

- Username: `minioadmin`
- Password: `minioadmin123`

View backup files stored in the `pg-backups` bucket.

### Patroni REST API

```bash
# Get cluster overview
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Check primary
curl -s http://localhost:8008/primary   # 200 = is primary

# Check replica
curl -s http://localhost:8009/replica   # 200 = is replica

# Get config
curl -s http://localhost:8008/config | python3 -m json.tool
```

---

## 🔁 Failover Testing

### Simulate primary failure

```bash
# Stop the primary container
docker-compose stop patroni-primary

# Watch Patroni elect a new primary (~30 seconds)
docker-compose logs -f patroni-replica-1 patroni-replica-2

# Check which node is now primary
curl -s http://localhost:8009/primary  # 200 = is primary now
curl -s http://localhost:8010/primary  # 200 = is primary now

# Restart old primary (will rejoin as replica)
docker-compose start patroni-primary
```

---

## 🛠️ Scripts Reference

| Script | Description |
|--------|-------------|
| `scripts/restore.sh` | Interactive restore — full or PITR. Prompts for timestamp, stops containers, runs restore, restarts and verifies. Logs to `logs/restore.log`. |
| `scripts/backup.sh` | Trigger manual backup. Accepts type: `full`, `diff`, `incr`. Interactive if no argument. Logs to `logs/backup.log`. |
| `scripts/check-health.sh` | Comprehensive health check for all cluster components. Logs to `logs/health-check.log`. |
| `scripts/init-minio.sh` | Initialize MinIO bucket `pg-backups`. Used by the `minio-init` container. |

---

## 🔧 Configuration Files

| File | Description |
|------|-------------|
| `config/patroni/patroni-primary.yml` | Patroni config for primary node |
| `config/patroni/patroni-replica-1.yml` | Patroni config for replica-1 |
| `config/patroni/patroni-replica-2.yml` | Patroni config for replica-2 |
| `config/pgbackrest/pgbackrest.conf` | pgBackRest shared config (S3/MinIO target) |
| `config/haproxy/haproxy.cfg` | HAProxy routing rules and health checks |
| `config/pgbouncer/pgbouncer.ini` | pgBouncer connection pooler settings |
| `config/pgbouncer/userlist.txt` | pgBouncer user credentials |

---

## 🐛 Troubleshooting

### Containers won't start

```bash
# Check logs for errors
docker-compose logs etcd
docker-compose logs patroni-primary
```

### Patroni won't initialize

```bash
# Check etcd is healthy
curl http://localhost:2379/health

# Check Patroni config
docker-compose exec patroni-primary cat /etc/patroni/patroni.yml
```

### pgBackRest can't connect to MinIO

```bash
# Check MinIO is healthy
curl http://localhost:9000/minio/health/live

# Test pgBackRest connection
docker-compose exec pgbackrest-primary pgbackrest --stanza=main stanza-check
```

### Reset the entire cluster (⚠️ destroys all data)

```bash
docker-compose down -v
docker-compose up -d --build
```

---

## 📁 File Structure

```
pgproduction/
├── docker-compose.yml              # Main compose file
├── .env                            # Environment variables (do not commit!)
├── .env.example                    # Example env file
├── README.md                       # This file
│
├── config/
│   ├── patroni/
│   │   ├── patroni-primary.yml     # Patroni config for primary
│   │   ├── patroni-replica-1.yml   # Patroni config for replica-1
│   │   └── patroni-replica-2.yml   # Patroni config for replica-2
│   ├── pgbackrest/
│   │   └── pgbackrest.conf         # pgBackRest config (MinIO/S3 target)
│   ├── haproxy/
│   │   └── haproxy.cfg             # HAProxy load balancer config
│   └── pgbouncer/
│       ├── pgbouncer.ini           # pgBouncer pooler config
│       └── userlist.txt            # pgBouncer user auth
│
├── docker/
│   ├── patroni/
│   │   ├── Dockerfile              # PostgreSQL 15 + Patroni image
│   │   └── entrypoint.sh           # Container entrypoint
│   ├── pgbackrest/
│   │   ├── Dockerfile              # pgBackRest sidecar image
│   │   └── entrypoint.sh           # Sidecar entrypoint (WAL + cron)
│   └── minio-init/
│       ├── Dockerfile              # MinIO bucket init image
│       └── init-minio.sh           # Bucket creation script
│
├── scripts/
│   ├── restore.sh                  # Interactive restore / PITR script
│   ├── backup.sh                   # Manual backup trigger
│   ├── check-health.sh             # Cluster health check
│   └── init-minio.sh               # MinIO init (used in container)
│
└── logs/                           # Log files (auto-created)
    └── .gitkeep
```

---

## 🔒 Security Notes

- Change all default passwords in `.env` before deploying to production
- Never commit `.env` to version control (it is in `.gitignore`)
- Consider enabling TLS for etcd and MinIO in production
- pgBouncer `userlist.txt` passwords should use MD5 or SCRAM hashing in production

---

## 📦 Software Versions

| Software | Version |
|----------|---------|
| PostgreSQL | 15 |
| Patroni | latest (pip) |
| pgBackRest | 2.x (apt) |
| etcd | 3.5.9 |
| HAProxy | 2.8 (Alpine) |
| pgBouncer | latest |
| MinIO | latest |
