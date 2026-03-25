#!/bin/bash
set -e

PATRONI_CONFIG=${PATRONI_CONFIG:-/etc/patroni/patroni.yml}

echo "Starting Patroni with config: $PATRONI_CONFIG"

# Ensure data directory has correct permissions
if [ "$(id -un)" = "postgres" ]; then
    mkdir -p /var/lib/postgresql/data
    chmod 700 /var/lib/postgresql/data
fi

# Write passwords to a runtime file so post_bootstrap.sh can read them.
# Patroni v4 runs post_bootstrap with a sanitised environment (no PATRONI_*
# or custom vars), so we cannot rely on env var passing to the subprocess.
mkdir -p /run/patroni-bootstrap
printf '%s' "${PATRONI_SUPERUSER_PASSWORD}"  > /run/patroni-bootstrap/super_pass
printf '%s' "${PATRONI_REPLICATION_PASSWORD}" > /run/patroni-bootstrap/repl_pass
chmod 600 /run/patroni-bootstrap/super_pass /run/patroni-bootstrap/repl_pass

exec patroni "$PATRONI_CONFIG"
