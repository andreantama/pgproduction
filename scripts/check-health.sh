#!/bin/bash
# ============================================================
# Cluster Health Check Script
# Checks status of all PostgreSQL cluster components
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_DIR}/logs/health-check.log"

COMPOSE_PGBACKREST="${PROJECT_DIR}/services/04-pgbackrest/docker-compose.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "${LOG_FILE}"
}

ok()     { echo -e "  ${GREEN}✅ $*${NC}"; log "OK   " "$*"; }
fail()   { echo -e "  ${RED}❌ $*${NC}"; log "FAIL " "$*"; }
warn()   { echo -e "  ${YELLOW}⚠️  $*${NC}"; log "WARN " "$*"; }
header() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
section(){ echo -e "\n${CYAN}▶ $*${NC}"; }

ensure_log_dir() {
    mkdir -p "$(dirname "${LOG_FILE}")"
}

# Check if a container is running
check_container() {
    local name="$1"
    
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "$name"; then
        ok "Container ${name} is running"
        return 0
    else
        fail "Container ${name} is NOT running"
        return 1
    fi
}

# Check Patroni REST API
check_patroni_api() {
    local name="$1"
    local port="$2"
    local url="http://localhost:${port}"
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "${url}" 2>/dev/null || echo "000")
    
    if [ "${http_code}" != "000" ]; then
        local role
        role=$(curl -s "${url}" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role','unknown'))" 2>/dev/null || echo "unknown")
        ok "Patroni API ${name} (port ${port}): HTTP ${http_code}, role=${role}"
        return 0
    else
        fail "Patroni API ${name} (port ${port}): Not reachable"
        return 1
    fi
}

# Check PostgreSQL connection
check_postgres_connection() {
    local host="$1"
    local port="$2"
    local label="$3"
    
    if PGPASSWORD="${POSTGRES_PASSWORD:-postgres123}" psql -h localhost -p "${port}" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        ok "PostgreSQL ${label} (port ${port}): Connection OK"
        return 0
    else
        fail "PostgreSQL ${label} (port ${port}): Connection FAILED"
        return 1
    fi
}

# Check replication status
check_replication() {
    section "Replication Status"
    
    local result
    result=$(PGPASSWORD="${POSTGRES_PASSWORD:-postgres123}" psql -h localhost -p 5000 -U postgres -t -c \
        "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null || echo "")
    
    if [ -n "${result}" ]; then
        ok "Replication is active"
        echo -e "\n  Replication details:"
        echo "${result}" | while read -r line; do
            [ -n "${line}" ] && echo "    ${line}"
        done
    else
        warn "No active replication connections found (may be normal if connecting as non-primary)"
    fi
}

# Check HAProxy
check_haproxy() {
    section "HAProxy"
    
    local stats_code
    stats_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:7000/stats" 2>/dev/null || echo "000")
    
    if [ "${stats_code}" = "200" ]; then
        ok "HAProxy stats page accessible at http://localhost:7000/stats"
    else
        fail "HAProxy stats page not accessible (HTTP ${stats_code})"
    fi
    
    # Check write port
    if nc -z localhost 5000 2>/dev/null; then
        ok "HAProxy write port 5000 is open"
    else
        fail "HAProxy write port 5000 is NOT open"
    fi
    
    # Check read port
    if nc -z localhost 5001 2>/dev/null; then
        ok "HAProxy read port 5001 is open"
    else
        fail "HAProxy read port 5001 is NOT open"
    fi
}

# Check pgBouncer
check_pgbouncer() {
    section "pgBouncer"
    
    if nc -z localhost 6432 2>/dev/null; then
        ok "pgBouncer port 6432 is open"
    else
        fail "pgBouncer port 6432 is NOT open"
    fi
}

# Check MinIO
check_minio() {
    section "MinIO"
    
    local health_code
    health_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:9000/minio/health/live" 2>/dev/null || echo "000")
    
    if [ "${health_code}" = "200" ]; then
        ok "MinIO API (port 9000) is healthy"
    else
        fail "MinIO API (port 9000) not healthy (HTTP ${health_code})"
    fi
    
    local console_code
    console_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:9001" 2>/dev/null || echo "000")
    
    if [ "${console_code}" != "000" ]; then
        ok "MinIO Console (port 9001) is accessible"
    else
        fail "MinIO Console (port 9001) not accessible"
    fi
}

# Check pgBackRest
check_pgbackrest() {
    section "pgBackRest"
    
    local info_output
    info_output=$(docker-compose -f "${COMPOSE_PGBACKREST}" exec -T pgbackrest-primary \
        pgbackrest --stanza="${PGBACKREST_STANZA:-main}" info 2>/dev/null || echo "")
    
    if echo "${info_output}" | grep -q "status: ok"; then
        ok "pgBackRest stanza is OK"
        local backup_count
        backup_count=$(echo "${info_output}" | grep -c "backup:" || echo "0")
        ok "Available backups: ${backup_count}"
    elif echo "${info_output}" | grep -q "no valid backups"; then
        warn "pgBackRest stanza OK but no backups found yet"
    else
        fail "pgBackRest stanza check failed"
    fi
}

# Check etcd
check_etcd() {
    section "etcd"
    
    local health_output
    health_output=$(curl -s --connect-timeout 3 "http://localhost:2379/health" 2>/dev/null || echo "")
    
    if echo "${health_output}" | grep -q '"health":"true"'; then
        ok "etcd is healthy"
    else
        fail "etcd health check failed"
    fi
}

main() {
    ensure_log_dir
    
    header "🔍 PostgreSQL Cluster Health Check"
    echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO " "Health check started"
    
    section "Container Status"
    check_container "patroni-primary"
    check_container "patroni-replica-1"
    check_container "patroni-replica-2"
    check_container "etcd"
    check_container "haproxy"
    check_container "pgbouncer"
    check_container "minio"
    check_container "pgbackrest-primary"
    check_container "pgbackrest-replica-1"
    check_container "pgbackrest-replica-2"
    
    section "Patroni REST API"
    check_patroni_api "primary" "8008"
    check_patroni_api "replica-1" "8009"
    check_patroni_api "replica-2" "8010"
    
    check_haproxy
    check_pgbouncer
    check_minio
    check_etcd
    check_replication
    check_pgbackrest
    
    header "Health Check Complete"
    log "INFO " "Health check completed"
}

main "$@"
