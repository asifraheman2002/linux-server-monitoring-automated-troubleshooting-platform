
#!/usr/bin/env bash

set -uo pipefail

# Resolve the project directory from this script's location.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/troubleshoot.log"

mkdir -p "$LOG_DIR" || {
    printf 'ERROR: Cannot create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
}

# Log all output to both the terminal and the log file.
exec > >(tee -a "$LOG_FILE") 2>&1

START_TIME="$(date --iso-8601=seconds)"
ISSUES=0
WARNINGS=0

section() {
    printf '\n%s\n' "============================================================"
    printf '%s\n' "$1"
    printf '%s\n' "============================================================"
}

pass() {
    printf '[PASS] %s\n' "$1"
}

warn() {
    printf '[WARNING] %s\n' "$1"
    WARNINGS=$((WARNINGS + 1))
}

fail() {
    printf '[CRITICAL] %s\n' "$1"
    ISSUES=$((ISSUES + 1))
}

info() {
    printf '[INFO] %s\n' "$1"
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

section "LINUX SERVER TROUBLESHOOTING REPORT"
info "Start time: $START_TIME"
info "Hostname: $(hostname 2>/dev/null || printf 'unknown')"
info "Project directory: $PROJECT_DIR"
info "Log file: $LOG_FILE"

# 1. Essential commands
section "1. REQUIRED COMMANDS"

for cmd in awk df free getent hostname ip ping ss systemctl timeout; do
    if check_command "$cmd"; then
        pass "$cmd is available"
    else
        warn "$cmd is not installed or not in PATH"
    fi
done

# 2. CPU usage
section "2. CPU HEALTH"

if [[ -r /proc/stat ]]; then
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat

    IDLE_BEFORE=$((idle + iowait))
    TOTAL_BEFORE=$((user + nice + system + idle + iowait + irq + softirq + steal))

    sleep 1

    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat

    IDLE_AFTER=$((idle + iowait))
    TOTAL_AFTER=$((user + nice + system + idle + iowait + irq + softirq + steal))

    TOTAL_DIFF=$((TOTAL_AFTER - TOTAL_BEFORE))
    IDLE_DIFF=$((IDLE_AFTER - IDLE_BEFORE))

    if (( TOTAL_DIFF > 0 )); then
        CPU_USAGE=$(( (100 * (TOTAL_DIFF - IDLE_DIFF)) / TOTAL_DIFF ))
        info "CPU usage: ${CPU_USAGE}%"

        if (( CPU_USAGE >= ${CPU_THRESHOLD:-90} )); then
            warn "CPU usage is high"
        else
            pass "CPU usage is below the threshold"
        fi
    else
        warn "Unable to calculate CPU usage"
    fi
else
    warn "/proc/stat is unavailable"
fi

# 3. Memory
section "3. MEMORY HEALTH"

if check_command free; then
    MEMORY_INFO="$(free -b | awk '/^Mem:/ {print $2, $3, $7}')"

    read -r MEM_TOTAL MEM_USED MEM_AVAILABLE <<< "$MEMORY_INFO"

    if [[ "${MEM_TOTAL:-0}" =~ ^[0-9]+$ ]] &&
       [[ "$MEM_TOTAL" -gt 0 ]] &&
       [[ "${MEM_USED:-}" =~ ^[0-9]+$ ]]; then

        MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
        info "Memory used: ${MEM_PERCENT}%"
        info "Total memory: $((MEM_TOTAL / 1024 / 1024)) MiB"
        info "Available memory: $(( ${MEM_AVAILABLE:-0} / 1024 / 1024 )) MiB"

        if (( MEM_PERCENT >= ${MEMORY_THRESHOLD:-90} )); then
            warn "Memory usage is high"
        else
            pass "Memory usage is below the threshold"
        fi
    else
        warn "Unable to parse memory statistics"
    fi
else
    warn "The free command is unavailable"
fi

# 4. Disk
section "4. DISK SPACE"

if check_command df; then
    df -hP

    ROOT_USAGE="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"

    if [[ "${ROOT_USAGE:-}" =~ ^[0-9]+$ ]]; then
        info "Root filesystem usage: ${ROOT_USAGE}%"

        if (( ROOT_USAGE >= ${DISK_THRESHOLD:-90} )); then
            warn "Root filesystem usage is high"
        else
            pass "Root filesystem usage is below the threshold"
        fi
    else
        warn "Unable to determine root filesystem usage"
    fi
else
    warn "The df command is unavailable"
fi

# 5. Network interface and gateway
section "5. NETWORK CONNECTIVITY"

DEFAULT_ROUTE=""
NETWORK_INTERFACE=""
GATEWAY=""

if check_command ip; then
    DEFAULT_ROUTE="$(ip route show default 2>/dev/null | head -n 1 || true)"

    if [[ -n "$DEFAULT_ROUTE" ]]; then
        GATEWAY="$(awk '{for (i=1; i<=NF; i++) if ($i=="via") print $(i+1)}' <<< "$DEFAULT_ROUTE")"
        NETWORK_INTERFACE="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}' <<< "$DEFAULT_ROUTE")"

        info "Default route: $DEFAULT_ROUTE"
        info "Network interface: ${NETWORK_INTERFACE:-unknown}"
        info "Gateway: ${GATEWAY:-not specified}"

        if [[ -n "$NETWORK_INTERFACE" ]] &&
           ip link show "$NETWORK_INTERFACE" >/dev/null 2>&1; then
            pass "Network interface exists"
        else
            warn "Unable to verify the default network interface"
        fi
    else
        fail "No default network route was found"
    fi
else
    warn "The ip command is unavailable; network checks are limited"
fi

if [[ -n "$GATEWAY" ]] && check_command ping; then
    if timeout 5 ping -c 1 -W 3 "$GATEWAY" >/dev/null 2>&1; then
        pass "Default gateway responded to ping"
    else
        warn "Default gateway did not respond to ping; ICMP may be blocked"
    fi
fi

# 6. DNS resolution
section "6. DNS RESOLUTION"

if check_command getent; then
    if timeout 5 getent ahosts example.com >/dev/null 2>&1; then
        pass "DNS resolution succeeded for example.com"
    else
        warn "DNS resolution failed for example.com"
    fi
else
    warn "The getent command is unavailable"
fi

# 7. External HTTPS connectivity
section "7. EXTERNAL HTTPS"

if check_command curl; then
    if timeout 10 curl -fsSI --max-time 8 https://example.com >/dev/null 2>&1; then
        pass "External HTTPS request succeeded"
    else
        warn "External HTTPS request failed; check DNS, routing, firewall, and proxy settings"
    fi
else
    warn "curl is unavailable; external HTTPS could not be checked"
fi

# 8. Nginx
section "8. NGINX SERVICE"

if check_command systemctl; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
        pass "Nginx service is active"
    else
        fail "Nginx service is not active"
        info "Inspect with: systemctl status nginx --no-pager"
    fi
else
    warn "systemctl is unavailable; Nginx service state could not be checked"
fi

# 9. Web server port
section "9. HTTP PORT"

if check_command ss; then
    if ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -Eq '(^|:)80$|\]:80$'; then
        pass "A process is listening on TCP port 80"
    else
        warn "No listener was detected on TCP port 80"
    fi
else
    warn "The ss command is unavailable"
fi

# 10. Local HTTP response
section "10. LOCAL WEB RESPONSE"

if check_command curl; then
    HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 3 --max-time 5 http://127.0.0.1/ 2>/dev/null || true)"

    if [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] && [[ "$HTTP_CODE" != "000" ]]; then
        pass "Local HTTP endpoint responded with status $HTTP_CODE"

        if [[ "$HTTP_CODE" =~ ^[45] ]]; then
            warn "Local HTTP returned an error status"
        fi
    else
        warn "No valid HTTP response received from http://127.0.0.1/"
    fi
else
    warn "curl is unavailable; local HTTP could not be checked"
fi

# 11. Optional Flask API check
section "11. OPTIONAL DASHBOARD API"

if check_command curl; then
    API_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 --max-time 4 \
        http://127.0.0.1:5000/api/health 2>/dev/null || true)"

    if [[ "$API_CODE" =~ ^[0-9]{3}$ ]] && [[ "$API_CODE" != "000" ]]; then
        pass "Dashboard API responded with status $API_CODE"

        if [[ "$API_CODE" =~ ^[45] ]]; then
            warn "Dashboard API returned an error status"
        fi
    else
        info "No Flask API response on port 5000; this is informational if the dashboard is not running"
    fi
fi

# 12. Recent application logs
section "12. RECENT PROJECT LOGS"

for file in "$PROJECT_DIR/logs/health_check.log" "$PROJECT_DIR/logs/troubleshoot.log"; do
    if [[ -f "$file" ]]; then
        info "Last 5 lines of $(basename "$file"):"
        tail -n 5 "$file" 2>/dev/null || warn "Unable to read $file"
    else
        info "Log not created yet: $file"
    fi
done

# Final report
section "FINAL SUMMARY"

info "End time: $(date --iso-8601=seconds)"
info "Critical issues: $ISSUES"
info "Warnings: $WARNINGS"

if (( ISSUES > 0 )); then
    printf '%s\n' "OVERALL STATUS: CRITICAL"
    exit 1
elif (( WARNINGS > 0 )); then
    printf '%s\n' "OVERALL STATUS: WARNING"
    exit 0
else
    printf '%s\n' "OVERALL STATUS: HEALTHY"
    exit 0
fi
