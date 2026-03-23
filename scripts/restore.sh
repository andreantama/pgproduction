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
    info "Stopping PostgreSQL containers..."
    docker-compose -f "${compose_file}" stop patroni-primary patroni-replica-1 patroni-replica-2 2>&1 | tee -a "${LOG_FILE}"
    log "INFO " "PostgreSQL containers stopped"
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
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm \
        -e PGBACKREST_STANZA="${STANZA}" \
        pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" --delta restore 2>&1 | tee -a "${LOG_FILE}"
    
    info "Step 3: Starting PostgreSQL containers..."
    start_postgres_containers
    
    info "Step 4: Waiting for PostgreSQL to be ready..."
    wait_for_postgres
    
    info "Step 5: Verifying connection..."
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
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm \
        -e PGBACKREST_STANZA="${STANZA}" \
        pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" \
            --delta \
            --type=time \
            "--target=${target_time}" \
            --target-action=promote \
            restore 2>&1 | tee -a "${LOG_FILE}"
    
    info "Step 3: Starting PostgreSQL containers..."
    start_postgres_containers
    
    info "Step 4: Waiting for PostgreSQL to be ready..."
    wait_for_postgres
    
    info "Step 5: Verifying connection..."
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
