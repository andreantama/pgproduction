#!/bin/bash
set -e

NODE_NAME=${NODE_NAME:-primary}
PGBACKREST_STANZA=${PGBACKREST_STANZA:-main}

echo "Starting pgBackRest sidecar for node: $NODE_NAME"

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be available..."
until pg_isready -h "${PGHOST:-localhost}" -p 5432 -U postgres 2>/dev/null; do
    echo "PostgreSQL not ready, waiting 5 seconds..."
    sleep 5
done

echo "PostgreSQL is ready. Initializing pgBackRest stanza..."

# Try to create the stanza (idempotent - won't fail if already exists)
pgbackrest --stanza="${PGBACKREST_STANZA}" stanza-create --log-level-console=info 2>/dev/null || true

# Check if we're primary for initial backup
if [ "${IS_PRIMARY:-false}" = "true" ]; then
    echo "Node is primary. Checking if initial backup is needed..."
    # Wait a bit for cluster to be fully ready
    sleep 30
    
    if ! pgbackrest --stanza="${PGBACKREST_STANZA}" info 2>/dev/null | grep -q "status: ok"; then
        echo "No backup found. Creating initial full backup..."
        pgbackrest --stanza="${PGBACKREST_STANZA}" --type=full backup --log-level-console=info || true
    fi
fi

# Setup cron for scheduled backups
if [ "${IS_PRIMARY:-false}" = "true" ]; then
    echo "Setting up scheduled backups..."
    (crontab -l 2>/dev/null; echo "0 2 * * * pgbackrest --stanza=${PGBACKREST_STANZA} --type=full backup --log-level-console=info >> /var/log/pgbackrest/cron.log 2>&1") | crontab -
    
    # Start cron
    cron -f &
fi

echo "pgBackRest sidecar ready. Monitoring..."

# Keep container running
tail -f /dev/null
