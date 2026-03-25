# pgproduction 🐘

Production-grade **PostgreSQL ecosystem** — fully containerized with Docker Compose.  
Features: High Availability (Patroni), Point-in-Time Recovery (pgBackRest + MinIO), Connection Pooling (pgBouncer), and Load Balancing (HAProxy).

> **New in this branch:** each service is isolated in its own
> `services/<NN>-<name>/docker-compose.yml` file so you can start, stop,
> update, or scale each layer independently.  
> See [`docs/`](./docs/) for detailed how-to guides.

---

## 🏗️ Architecture Overview

```
                        ┌─────────────────────────────────────────────────┐
                        │              pg-network (shared)                 │
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

| Layer | Component | Role | Port(s) |
|-------|-----------|------|---------|
| 1 | **etcd** | Distributed config store for Patroni | 2379 |
| 2 | **MinIO** | S3-compatible backup storage | 9000 (API), 9001 (Console) |
| 3 | **Patroni/PostgreSQL** | 1 primary (R/W) + 2 replicas (RO) | 8008–8010 (API) |
| 4 | **pgBackRest (×3)** | WAL archive + scheduled/on-demand backups | — |
| 5 | **HAProxy** | Load balancer: write→primary, read→replicas | 5000, 5001, 7000 |
| 6 | **pgBouncer** | Connection pooler | 6432 |

---

## 📋 Prerequisites

- **Docker** ≥ 24.x
- **Docker Compose** ≥ 2.20 (plugin) **or** `docker-compose` v1.29+
- **curl**, **nc** (for health check script)
- Minimum 4 GB RAM recommended

---

## 🚀 Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/andreantama/pgproduction.git
cd pgproduction

# Copy and edit environment variables
cp .env.example .env
# Fill in all <changeme> values with strong passwords
```

### 2. Start layers in order

```bash
docker compose -f services/01-etcd/docker-compose.yml       up -d
docker compose -f services/02-minio/docker-compose.yml      up -d
docker compose -f services/03-patroni/docker-compose.yml    up -d --build
docker compose -f services/04-pgbackrest/docker-compose.yml up -d --build
docker compose -f services/05-haproxy/docker-compose.yml    up -d
docker compose -f services/06-pgbouncer/docker-compose.yml  up -d
```

> See **[docs/01-installation.md](./docs/01-installation.md)** for a
> detailed step-by-step guide with verification commands.

### 3. Verify everything is healthy

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

See **[docs/02-backup-full.md](./docs/02-backup-full.md)** and  
**[docs/03-backup-incremental.md](./docs/03-backup-incremental.md)**  
for detailed guides.

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
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary pgbackrest --stanza=main info
```

### View pgBackRest logs

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml logs pgbackrest-primary
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
docker compose -f services/03-patroni/docker-compose.yml \
  stop patroni-primary patroni-replica-1 patroni-replica-2

# Run PITR restore
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main \
    --delta \
    --type=time \
    --target="2024-01-15 14:30:00" \
    --target-action=promote \
    restore

# Restart containers
docker compose -f services/03-patroni/docker-compose.yml \
  start patroni-primary patroni-replica-1 patroni-replica-2
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
- Password: from your `.env`

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

See **[docs/04-failover.md](./docs/04-failover.md)** for the complete guide.

### Simulate primary failure

```bash
# Stop the primary container
docker compose -f services/03-patroni/docker-compose.yml stop patroni-primary

# Watch Patroni elect a new primary (~30 seconds)
docker compose -f services/03-patroni/docker-compose.yml \
  logs -f patroni-replica-1 patroni-replica-2

# Check which node is now primary
curl -s http://localhost:8009/primary  # 200 = is primary now
curl -s http://localhost:8010/primary  # 200 = is primary now

# Restart old primary (will rejoin as replica)
docker compose -f services/03-patroni/docker-compose.yml start patroni-primary
```

---

## 🛠️ Scripts Reference

| Script | Description |
|--------|-------------|
| `scripts/restore.sh` | Interactive restore — full or PITR. Logs to `logs/restore.log`. |
| `scripts/backup.sh` | Trigger manual backup (`full`, `diff`, `incr`). Logs to `logs/backup.log`. |
| `scripts/check-health.sh` | Comprehensive health check. Logs to `logs/health-check.log`. |
| `scripts/init-minio.sh` | MinIO bucket init (used by the `minio-init` container). |

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
docker compose -f services/01-etcd/docker-compose.yml     logs etcd
docker compose -f services/03-patroni/docker-compose.yml  logs patroni-primary
```

### Patroni won't initialize

```bash
# Check etcd is healthy
curl http://localhost:2379/health

# Check Patroni config
docker compose -f services/03-patroni/docker-compose.yml \
  exec patroni-primary cat /etc/patroni/patroni.yml
```

### pgBackRest can't connect to MinIO

```bash
# Check MinIO is healthy
curl http://localhost:9000/minio/health/live

# Test pgBackRest connection
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary pgbackrest --stanza=main stanza-check
```

### Reset the entire cluster (⚠️ destroys all data)

```bash
docker compose -f services/06-pgbouncer/docker-compose.yml   down -v
docker compose -f services/05-haproxy/docker-compose.yml     down -v
docker compose -f services/04-pgbackrest/docker-compose.yml  down -v
docker compose -f services/03-patroni/docker-compose.yml     down -v
docker compose -f services/02-minio/docker-compose.yml       down -v
docker compose -f services/01-etcd/docker-compose.yml        down -v
```

---

## 📁 File Structure

```
pgproduction/
├── .env.example                    # Example env file
├── .env                            # Your env (do not commit!)
├── README.md                       # This file
│
├── services/                       # One docker-compose.yml per service layer
│   ├── 01-etcd/
│   │   └── docker-compose.yml      # etcd — also creates pg-network
│   ├── 02-minio/
│   │   └── docker-compose.yml      # MinIO + bucket init
│   ├── 03-patroni/
│   │   └── docker-compose.yml      # PostgreSQL primary + 2 replicas
│   ├── 04-pgbackrest/
│   │   └── docker-compose.yml      # pgBackRest sidecars (×3)
│   ├── 05-haproxy/
│   │   └── docker-compose.yml      # HAProxy load balancer
│   └── 06-pgbouncer/
│       └── docker-compose.yml      # pgBouncer connection pooler
│
├── docs/                           # How-to guides
│   ├── 01-installation.md
│   ├── 02-backup-full.md
│   ├── 03-backup-incremental.md
│   └── 04-failover.md
│
├── config/
│   ├── patroni/                    # Patroni YAML configs per node
│   ├── pgbackrest/                 # pgBackRest config (MinIO/S3 target)
│   ├── haproxy/                    # HAProxy routing rules
│   ├── pgbouncer/                  # pgBouncer settings + user list
│   └── minio/certs/                # TLS certs for MinIO
│
├── docker/
│   ├── patroni/                    # PostgreSQL 15 + Patroni Dockerfile
│   ├── pgbackrest/                 # pgBackRest sidecar Dockerfile
│   └── minio-init/                 # MinIO bucket init Dockerfile
│
├── scripts/
│   ├── restore.sh                  # Interactive restore / PITR
│   ├── backup.sh                   # Manual backup trigger
│   ├── check-health.sh             # Cluster health check
│   └── init-minio.sh               # MinIO init (container use)
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

