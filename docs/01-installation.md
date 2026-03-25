# 📦 Installation Guide

This guide walks you through starting the PostgreSQL production stack
layer by layer using individual Docker Compose files.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Docker Engine | 24.x |
| Docker Compose (plugin) | 2.20+ **or** `docker-compose` v1.29+ |
| Git | any |
| Bash | 4.x |

> **macOS / Windows** — Docker Desktop bundles both Docker Engine and the
> Compose plugin. Linux users should install the Compose plugin via the
> [official docs](https://docs.docker.com/compose/install/).

---

## 1. Clone the repository

```bash
git clone https://github.com/andreantama/pgproduction.git
cd pgproduction
```

---

## 2. Configure environment variables

```bash
cp .env.example .env
```

Open `.env` and fill in **all** `changeme` values with strong passwords:

```dotenv
POSTGRES_DB=mydb
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<strong-password>

REPLICATION_USER=replicator
REPLICATION_PASSWORD=<strong-password>

PATRONI_SUPERUSER_PASSWORD=<strong-password>
PATRONI_REPLICATION_PASSWORD=<strong-password>

MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=<strong-password>

PGBACKREST_STANZA=main
```

> ⚠️ Never commit `.env` to version control.  
> Update `config/pgbouncer/userlist.txt` with the same postgres/replicator
> passwords in MD5 or SCRAM format if you change them.

---

## 3. Start each layer in order

Every service lives under `services/<NN>-<name>/docker-compose.yml`.  
All layers share the same Docker network (`pg-network`) and named volumes.

### Layer 1 — etcd (creates the shared network)

```bash
docker compose -f services/01-etcd/docker-compose.yml up -d
# Verify
docker compose -f services/01-etcd/docker-compose.yml ps
```

Wait until `etcd` shows **healthy** before continuing.

### Layer 2 — MinIO (object storage for backups)

```bash
docker compose -f services/02-minio/docker-compose.yml up -d
# Verify
docker compose -f services/02-minio/docker-compose.yml ps
```

`minio-init` (one-shot container) creates the `pg-backups` bucket
automatically and exits with code 0.

Open the MinIO console at <http://localhost:9001> to confirm the bucket
exists.

### Layer 3 — Patroni / PostgreSQL 15

```bash
docker compose -f services/03-patroni/docker-compose.yml up -d
# Verify
docker compose -f services/03-patroni/docker-compose.yml ps
```

Check the Patroni REST API endpoints:

```bash
# Primary (should show role=master)
curl -s http://localhost:8008 | python3 -m json.tool

# Replica 1
curl -s http://localhost:8009 | python3 -m json.tool

# Replica 2
curl -s http://localhost:8010 | python3 -m json.tool
```

Wait until `patronictl list` shows one `Leader` and two `Replica` nodes
before starting Layer 4.

### Layer 4 — pgBackRest (backup sidecars)

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml up -d
# Verify
docker compose -f services/04-pgbackrest/docker-compose.yml ps
```

The primary sidecar (`pgbackrest-primary`) automatically:
1. Runs `stanza-create` (idempotent).
2. Creates an **initial full backup** if none exists.
3. Starts a cron schedule for nightly full backups at 02:00.

Check backup status:

```bash
docker compose -f services/04-pgbackrest/docker-compose.yml \
  exec pgbackrest-primary \
  pgbackrest --stanza=main info
```

### Layer 5 — HAProxy (load balancer)

```bash
docker compose -f services/05-haproxy/docker-compose.yml up -d
# Verify
docker compose -f services/05-haproxy/docker-compose.yml ps
```

| Port | Purpose |
|------|---------|
| 5000 | Write endpoint (primary only) |
| 5001 | Read endpoint (replicas, round-robin) |
| 7000 | Stats UI (<http://localhost:7000/stats>) |

### Layer 6 — pgBouncer (connection pooler)

```bash
docker compose -f services/06-pgbouncer/docker-compose.yml up -d
# Verify
docker compose -f services/06-pgbouncer/docker-compose.yml ps
```

Connect through pgBouncer on port **6432**:

```bash
psql -h localhost -p 6432 -U postgres -d mydb
```

---

## 4. Run the health check

```bash
bash scripts/check-health.sh
```

All components should show ✅.

---

## Stopping all services

Stop layers in reverse order to avoid dependency warnings:

```bash
docker compose -f services/06-pgbouncer/docker-compose.yml   down
docker compose -f services/05-haproxy/docker-compose.yml     down
docker compose -f services/04-pgbackrest/docker-compose.yml  down
docker compose -f services/03-patroni/docker-compose.yml     down
docker compose -f services/02-minio/docker-compose.yml       down
docker compose -f services/01-etcd/docker-compose.yml        down
```

Add `-v` to also remove named volumes (⚠️ destroys all data):

```bash
docker compose -f services/01-etcd/docker-compose.yml down -v
# ...repeat for each layer...
```

---

## Rebuilding images after code changes

```bash
docker compose -f services/03-patroni/docker-compose.yml    build --no-cache
docker compose -f services/04-pgbackrest/docker-compose.yml build --no-cache
```
