# 🔁 Failover Guide

This document covers both **automatic failover** (handled by Patroni)
and **manual failover / switchover** procedures.

---

## Architecture recap

```
                   ┌─────────────────────────────────────┐
                   │            pg-network                │
                   │                                      │
  clients ──▶ pgBouncer (6432)                           │
                   │                                      │
                   ▼                                      │
             HAProxy :5000 (write) / :5001 (read)        │
                   │                                      │
        ┌──────────┼──────────┐                          │
        ▼          ▼          ▼                          │
  patroni-   patroni-   patroni-                         │
  primary    replica-1  replica-2                        │
     ↕           ↕          ↕    (streaming replication) │
  pgbackrest- pgbackrest- pgbackrest-                    │
  primary     replica-1   replica-2                      │
                                                         │
  etcd (DCS) ←── Patroni leader election ───────────────┘
```

**Patroni** monitors the cluster and elects a new primary automatically
when the current primary becomes unavailable.

**HAProxy** health-checks each node's Patroni REST API:
* `/primary` → 200 only on the current write leader
* `/replica` → 200 on healthy standbys

---

## Automatic failover

When `patroni-primary` crashes or loses connectivity to etcd, Patroni
automatically promotes the most up-to-date replica to become the new
primary. HAProxy detects the change within `inter * fall` seconds
(default: 3 s × 3 = ~9 s) and reroutes traffic.

### Watch it happen

```bash
# Terminal 1 — tail Patroni logs
docker compose -f services/03-patroni/docker-compose.yml \
  logs -f patroni-primary patroni-replica-1 patroni-replica-2

# Terminal 2 — poll the cluster state
watch -n2 "curl -s http://localhost:8008 | python3 -m json.tool"

# Terminal 3 — simulate primary failure
docker compose -f services/03-patroni/docker-compose.yml \
  stop patroni-primary
```

Patroni will elect a new leader within `ttl` seconds (default 30 s).
HAProxy automatically redirects port 5000 to the new primary.

### Restore the old primary as a replica

```bash
docker compose -f services/03-patroni/docker-compose.yml \
  start patroni-primary
```

Patroni will detect it is no longer the leader, use `pg_rewind` to
sync its timeline with the new primary, and rejoin as a replica.

---

## Manual switchover (planned maintenance)

A **switchover** is a graceful, operator-initiated role transfer.
Transactions are drained before the switch.

```bash
# Install patronictl on your workstation, or run it inside the container
docker compose -f services/03-patroni/docker-compose.yml \
  exec patroni-primary \
  patronictl -c /etc/patroni/patroni.yml switchover postgres-cluster \
  --master patroni-primary \
  --candidate patroni-replica-1 \
  --scheduled now \
  --force
```

After the switchover, verify:

```bash
docker compose -f services/03-patroni/docker-compose.yml \
  exec patroni-replica-1 \
  patronictl -c /etc/patroni/patroni.yml list
```

---

## Manual failover (unplanned, emergency)

Use this only when automatic failover has not triggered and the primary
is unresponsive.

```bash
docker compose -f services/03-patroni/docker-compose.yml \
  exec patroni-replica-1 \
  patronictl -c /etc/patroni/patroni.yml failover postgres-cluster \
  --master patroni-primary \
  --candidate patroni-replica-1 \
  --force
```

---

## Post-failover checklist

1. **Verify new primary**

   ```bash
   curl -s http://localhost:8008 | python3 -m json.tool
   # "role": "master"
   ```

2. **Check replication is streaming**

   ```bash
   PGPASSWORD=<password> psql -h localhost -p 5000 -U postgres -c \
     "SELECT client_addr, state, replay_lsn FROM pg_stat_replication;"
   ```

3. **Restart HAProxy** to clear stale health-check state

   ```bash
   docker compose -f services/05-haproxy/docker-compose.yml \
     restart haproxy
   ```

4. **Restart pgBouncer** to flush stale server-side connections

   ```bash
   docker compose -f services/06-pgbouncer/docker-compose.yml \
     restart pgbouncer
   ```

5. **Confirm backup continuity**

   ```bash
   docker compose -f services/04-pgbackrest/docker-compose.yml \
     exec pgbackrest-primary \
     pgbackrest --stanza=main info
   ```

   WAL archiving should resume on the new primary within seconds.

6. **Run the health check script**

   ```bash
   bash scripts/check-health.sh
   ```

---

## Full restore after catastrophic failure

If all nodes are lost, follow the full restore procedure:

```bash
bash scripts/restore.sh
# Choose option 1 (Full Restore) or option 2 (PITR)
```

See the [full backup guide](./02-backup-full.md) and
[incremental backup guide](./03-backup-incremental.md) for details on
keeping the repository healthy before such an event.

---

## Tuning failover parameters

These values live in `config/patroni/patroni-primary.yml` (and are
synced to DCS on start-up):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ttl` | 30 s | How long the leader lock is valid |
| `loop_wait` | 10 s | Patroni heartbeat interval |
| `retry_timeout` | 10 s | Timeout for DCS operations |
| `maximum_lag_on_failover` | 1 MB | Maximum replica lag allowed to be a candidate |

Reduce `ttl` for faster failover at the cost of more DCS traffic.
