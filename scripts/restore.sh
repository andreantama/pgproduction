#!/bin/bash
# ============================================================
# pgBackRest Restore / PITR Script
# Supports: Full Restore or Point-in-Time Recovery
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_DIR}/logs/restore.log"
STANZA="${PGBACKREST_STANZA:-main}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================
# Helper Functions
# ============================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

info()    { log "INFO " "$@"; echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { log "WARN " "$@"; echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { log "ERROR" "$@"; echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}========================================${NC}\n"; }

ensure_log_dir() {
    mkdir -p "$(dirname "${LOG_FILE}")"
}

validate_timestamp() {
    local ts="$1"
    if ! date -d "${ts}" "+%Y-%m-%d %H:%M:%S" > /dev/null 2>&1; then
        error "Invalid timestamp format: '${ts}'. Expected: YYYY-MM-DD HH:MM:SS"
        return 1
    fi
    return 0
}

check_dependencies() {
    local missing=()
    for cmd in docker docker-compose; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_containers_running() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    if ! docker-compose -f "${compose_file}" ps --services --filter "status=running" | grep -q "patroni-primary"; then
        warn "Some containers may not be running. Proceeding anyway..."
    fi
}

stop_postgres_containers() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    info "Stopping PostgreSQL and pgBackRest containers..."
    docker-compose -f "${compose_file}" stop \
        patroni-primary patroni-replica-1 patroni-replica-2 \
        pgbackrest-primary pgbackrest-replica-1 pgbackrest-replica-2 \
        2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "PostgreSQL and pgBackRest containers stopped"
}

start_postgres_containers() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    info "Starting PostgreSQL containers..."
    docker-compose -f "${compose_file}" start patroni-primary patroni-replica-1 patroni-replica-2 2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "PostgreSQL containers started"
}

wait_for_postgres() {
    local max_attempts=30
    local attempt=1
    info "Waiting for PostgreSQL to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T patroni-primary \
            pg_isready -U postgres -h localhost > /dev/null 2>&1; then
            info "PostgreSQL is ready!"
            return 0
        fi
        echo -n "."
        sleep 5
        attempt=$((attempt + 1))
    done
    error "PostgreSQL did not become ready after $((max_attempts * 5)) seconds"
    return 1
}

verify_connection() {
    info "Verifying database connection..."
    if docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T patroni-primary \
        psql -U postgres -d postgres -c "SELECT version();" > /dev/null 2>&1; then
        info "✅ Database connection verified successfully!"
        return 0
    else
        error "❌ Database connection verification failed"
        return 1
    fi
}

# Clear stale Patroni cluster state from etcd so nodes can re-elect cleanly
# after the data directory has been replaced by a restore.
# The Patroni namespace/scope is read from patroni-primary.yml:
#   namespace: /db/   scope: postgres-cluster  → keys live under /db/postgres-cluster/
# The stale "status" key records replication optimes from BEFORE the restore;
# Patroni refuses to become leader if it appears to lag by more than
# maximum_lag_on_failover bytes.  Deleting all keys forces a fresh bootstrap.
clear_dcs_state() {
    info "Clearing stale Patroni cluster state from etcd (namespace: /db/postgres-cluster)..."
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T etcd \
        etcdctl --endpoints=http://localhost:2379 del /db/postgres-cluster --prefix \
        2>&1 | tee -a "${LOG_FILE}" || true
    log "INFO " "etcd cluster state cleared"
}

start_patroni_primary() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    info "Starting patroni-primary container..."
    docker-compose -f "${compose_file}" start patroni-primary 2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "patroni-primary container started"
}

# Poll Patroni's HTTP API until the primary is elected leader.
# For PITR this may take several minutes while PostgreSQL replays WAL archives.
wait_for_primary_leader() {
    local max_attempts=120
    local attempt=1
    info "Waiting for patroni-primary to become cluster leader (max $((max_attempts * 5))s)..."
    while [ $attempt -le $max_attempts ]; do
        if curl -sf http://localhost:8008/primary > /dev/null 2>&1; then
            echo ""
            info "✅ patroni-primary is now the cluster leader!"
            return 0
        fi
        echo -n "."
        sleep 5
        attempt=$((attempt + 1))
    done
    echo ""
    error "patroni-primary did not become leader after $((max_attempts * 5)) seconds"
    error "Check logs with: docker compose logs patroni-primary"
    return 1
}

start_patroni_replicas() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    info "Starting replica and pgBackRest sidecar containers..."
    docker-compose -f "${compose_file}" start \
        patroni-replica-1 patroni-replica-2 \
        pgbackrest-primary pgbackrest-replica-1 pgbackrest-replica-2 \
        2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "Replica and pgBackRest containers started"
}

restart_haproxy() {
    local compose_file="${PROJECT_DIR}/docker-compose.yml"
    info "Restarting HAProxy to clear stale health-check state..."
    docker-compose -f "${compose_file}" restart haproxy 2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "HAProxy restarted"
}

# Start PostgreSQL directly (bypassing Patroni) inside the patroni-primary container
# so it can replay WAL from the archive and promote at the recovery target.
# We poll for recovery.signal removal rather than relying on pg_ctl -w alone,
# because hot_standby=on makes pg_ctl -w return early (before promotion).
complete_pitr_recovery() {
    info "Starting PostgreSQL directly to replay WAL archive and promote (max ~12 min)..."
    local script
    script='
# standby.signal is created by Patroni when it demotes a node to replica.
# If present alongside recovery.signal, PostgreSQL 12+ honours recovery.signal
# for archive recovery but leaves standby.signal on disk after promotion —
# causing the NEXT startup to enter streaming-standby mode instead of primary.
# Remove it unconditionally before starting recovery.
echo "Removing standby.signal (if present) to ensure archive recovery runs cleanly..."
rm -f /var/lib/postgresql/data/standby.signal

echo "Starting PostgreSQL for WAL archive recovery..."
/usr/lib/postgresql/15/bin/pg_ctl \
    -D /var/lib/postgresql/data \
    -l /tmp/pg_recovery.log \
    -w -t 120 start || {
    echo "ERROR: Failed to start PostgreSQL within 120s. Startup log:"
    cat /tmp/pg_recovery.log
    exit 1
}
echo "PostgreSQL running. Polling for PITR promotion (max 600s)..."
attempt=0
while [ $attempt -lt 120 ]; do
    if [ ! -f /var/lib/postgresql/data/recovery.signal ]; then
        echo ""
        echo "Promotion complete after $((attempt * 5)) seconds."
        # Belt-and-suspenders: remove standby.signal again so Patroni starts
        # this node as primary, not as a streaming replica.
        rm -f /var/lib/postgresql/data/standby.signal
        break
    fi
    printf "."
    sleep 5
    attempt=$((attempt + 1))
done
if [ $attempt -ge 120 ]; then
    echo ""
    echo "ERROR: Timed out waiting for PITR promotion. Startup log:"
    cat /tmp/pg_recovery.log
    /usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data stop -m fast 2>/dev/null || true
    exit 1
fi
echo "Stopping PostgreSQL cleanly for Patroni handoff..."
/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data stop -m fast
echo "Done. Data directory is promoted and ready for Patroni."
'
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm --no-deps \
        -e PGHOST=/var/run/postgresql \
        -e PGPORT=5432 \
        --entrypoint /bin/bash \
        patroni-primary \
        -c "${script}" 2>&1 | tee -a "${LOG_FILE}"
}

# ============================================================
# Restore Functions
# ============================================================

show_backup_list() {
    info "Fetching available backups from MinIO..."
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" info 2>&1 | tee -a "${LOG_FILE}" || {
        warn "Could not fetch backup list. Please check pgBackRest configuration."
    }
}

do_full_restore() {
    local target_container="${1:-patroni-primary}"
    header "Full Restore"
    
    log "INFO " "Starting full restore on container: ${target_container}"
    warn "This will OVERWRITE the current database. All data after the last backup will be LOST."
    echo ""
    read -rp "Are you sure you want to proceed? (yes/no): " confirm
    
    if [ "${confirm}" != "yes" ]; then
        info "Restore cancelled by user."
        exit 0
    fi
    
    info "Step 1: Stopping PostgreSQL containers..."
    stop_postgres_containers
    
    info "Step 2: Running full restore..."
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm --no-deps \
        -e PGBACKREST_STANZA="${STANZA}" \
        pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" --delta restore 2>&1 | tee -a "${LOG_FILE}"

    info "Step 3: Completing WAL archive recovery and promoting (without Patroni)..."
    complete_pitr_recovery

    info "Step 4: Clearing stale etcd cluster state..."
    clear_dcs_state

    info "Step 5: Starting patroni-primary..."
    start_patroni_primary

    info "Step 6: Waiting for primary to become cluster leader..."
    wait_for_primary_leader

    info "Step 7: Starting replica and pgBackRest sidecar containers..."
    start_patroni_replicas

    info "Step 8: Restarting HAProxy to clear stale health-check state..."
    restart_haproxy

    info "Step 9: Verifying connection..."
    verify_connection

    info "✅ Full restore completed successfully!"
    log "INFO " "Full restore completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

do_pitr_restore() {
    header "Point-in-Time Recovery (PITR)"
    
    # Show available backups
    show_backup_list
    
    echo ""
    echo "Enter the target timestamp for PITR recovery."
    echo "Format: YYYY-MM-DD HH:MM:SS (e.g., 2024-01-15 14:30:00)"
    echo ""
    read -rp "Target timestamp: " target_time
    
    # Validate timestamp
    if ! validate_timestamp "${target_time}"; then
        exit 1
    fi
    
    log "INFO " "PITR target timestamp: ${target_time}"
    warn "This will OVERWRITE the current database and restore it to: ${target_time}"
    echo ""
    read -rp "Are you sure you want to proceed? (yes/no): " confirm
    
    if [ "${confirm}" != "yes" ]; then
        info "Restore cancelled by user."
        exit 0
    fi
    
    info "Step 1: Stopping PostgreSQL containers..."
    stop_postgres_containers
    
    info "Step 2: Running PITR restore to: ${target_time}..."
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm --no-deps \
        -e PGBACKREST_STANZA="${STANZA}" \
        pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" \
            --delta \
            --type=time \
            "--target=${target_time}" \
            --target-action=promote \
            restore 2>&1 | tee -a "${LOG_FILE}"

    info "Step 3: Completing WAL archive recovery to target time (without Patroni)..."
    complete_pitr_recovery

    info "Step 4: Clearing stale etcd cluster state..."
    clear_dcs_state

    info "Step 5: Starting patroni-primary..."
    start_patroni_primary

    info "Step 6: Waiting for primary to become cluster leader..."
    wait_for_primary_leader

    info "Step 7: Starting replica and pgBackRest sidecar containers..."
    start_patroni_replicas

    info "Step 8: Restarting HAProxy to clear stale health-check state..."
    restart_haproxy

    info "Step 9: Verifying connection..."
    verify_connection

    info "✅ PITR restore to '${target_time}' completed successfully!"
    log "INFO " "PITR restore to '${target_time}' completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

# ============================================================
# Main Menu
# ============================================================

main() {
    ensure_log_dir
    check_dependencies
    
    header "PostgreSQL Restore / PITR Tool"
    log "INFO " "Restore script started at $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Show current backup status
    check_containers_running
    
    echo ""
    echo "Select restore type:"
    echo "  1) Full Restore       - Restore to the latest backup"
    echo "  2) PITR               - Point-in-Time Recovery to a specific timestamp"
    echo "  3) Show backup list   - Display available backups"
    echo "  4) Exit"
    echo ""
    read -rp "Enter your choice [1-4]: " choice
    
    case "${choice}" in
        1)
            do_full_restore
            ;;
        2)
            do_pitr_restore
            ;;
        3)
            show_backup_list
            ;;
        4)
            info "Exiting. No changes made."
            exit 0
            ;;
        *)
            error "Invalid choice: ${choice}"
            exit 1
            ;;
    esac
}

main "$@"
