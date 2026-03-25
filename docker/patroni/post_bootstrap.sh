#!/bin/bash
# ============================================================
# post_bootstrap.sh — Patroni v4 post-bootstrap hook
#
# Sets passwords for the postgres superuser and creates the
# replicator user.  Called by Patroni after cluster initdb.
#
# Patroni v4 removed bootstrap.users and sanitises PATRONI_*
# environment variables before running this subprocess, so the
# passwords are passed via the non-prefixed PG_SUPER_PASS /
# PG_REPL_PASS env vars set in docker-compose.yml.
# ============================================================
set -e

if [ -z "$PG_SUPER_PASS" ] || [ -z "$PG_REPL_PASS" ]; then
    echo "ERROR: PG_SUPER_PASS and PG_REPL_PASS must be set" >&2
    exit 1
fi

# Connect via Unix socket (pg_hba: local all all trust)
psql -U postgres \
    --set="superpass=$PG_SUPER_PASS" \
    --set="replpass=$PG_REPL_PASS" \
    -c "ALTER USER postgres WITH PASSWORD :'superpass';" \
    -c "CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD :'replpass';"
