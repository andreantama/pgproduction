#!/bin/bash
set -e

PATRONI_CONFIG=${PATRONI_CONFIG:-/etc/patroni/patroni.yml}

echo "Starting Patroni with config: $PATRONI_CONFIG"

# Ensure data directory has correct permissions
if [ "$(id -un)" = "postgres" ]; then
    mkdir -p /var/lib/postgresql/data
    chmod 700 /var/lib/postgresql/data
fi

exec patroni "$PATRONI_CONFIG"
