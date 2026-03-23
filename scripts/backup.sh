#!/bin/bash
# ============================================================
# Manual Backup Trigger Script
# Triggers pgBackRest backup on the primary node
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_DIR}/logs/backup.log"
STANZA="${PGBACKREST_STANZA:-main}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

info()   { log "INFO " "$@"; echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { log "WARN " "$@"; echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { log "ERROR" "$@"; echo -e "${RED}[ERROR]${NC} $*"; }
header() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}========================================${NC}\n"; }

ensure_log_dir() {
    mkdir -p "$(dirname "${LOG_FILE}")"
}

check_dependencies() {
    for cmd in docker docker-compose; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Missing required command: $cmd"
            exit 1
        fi
    done
}

run_backup() {
    local backup_type="${1:-full}"
    
    header "pgBackRest Manual Backup"
    info "Backup type: ${backup_type}"
    info "Stanza: ${STANZA}"
    info "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    log "INFO " "Starting ${backup_type} backup..."
    
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" \
            --type="${backup_type}" \
            --log-level-console=info \
            backup 2>&1 | tee -a "${LOG_FILE}"
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        info "✅ Backup completed successfully!"
        log "INFO " "${backup_type} backup completed at $(date '+%Y-%m-%d %H:%M:%S')"
    else
        error "❌ Backup failed with exit code: ${exit_code}"
        log "ERROR" "Backup failed at $(date '+%Y-%m-%d %H:%M:%S') with exit code: ${exit_code}"
        exit $exit_code
    fi
    
    info "Backup info:"
    docker-compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T pgbackrest-primary \
        pgbackrest --stanza="${STANZA}" info 2>&1 | tee -a "${LOG_FILE}"
}

main() {
    ensure_log_dir
    check_dependencies
    
    local backup_type="${1:-}"
    
    if [ -z "${backup_type}" ]; then
        echo "Select backup type:"
        echo "  1) Full backup"
        echo "  2) Differential backup"
        echo "  3) Incremental backup"
        echo ""
        read -rp "Enter choice [1-3] (default: 1): " choice
        
        case "${choice}" in
            2) backup_type="diff" ;;
            3) backup_type="incr" ;;
            *) backup_type="full" ;;
        esac
    fi
    
    case "${backup_type}" in
        full|diff|incr)
            run_backup "${backup_type}"
            ;;
        *)
            error "Invalid backup type: ${backup_type}. Use: full, diff, or incr"
            exit 1
            ;;
    esac
}

main "$@"
