#!/usr/bin/env bash

set -uo pipefail

# Resolve the project root from this script's location.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LOG_FILE="$LOG_DIR/health_check.log"

mkdir -p "$LOG_DIR" || {
    echo "ERROR: Cannot create log directory: $LOG_DIR" >&2
    exit 1
}

# Keep console output and append the same output to the log.
exec > >(tee -a "$LOG_FILE") 2>&1

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
HOSTNAME="$(hostname)"
UPTIME="$(uptime -p 2>/dev/null || uptime)"
LOAD="$(awk '{print $1 ", " $2 ", " $3}' /proc/loadavg)"

CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"
DISK_THRESHOLD="${DISK_THRESHOLD:-80}"

# Read a percentage safely; return UNKNOWN if measurement fails.
DISK_USAGE="$(df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
MEMORY_USAGE="$(awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { available=$2 }
    END {
        if (total > 0) printf "%.0f", (total-available)*100/total;
        else print "UNKNOWN"
    }
' /proc/meminfo)"

CPU_USAGE="UNKNOWN"
read -r _ USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ STEAL _ < /proc/stat
TOTAL1=$((USER + NICE + SYSTEM + IDLE + IOWAIT + IRQ + SOFTIRQ + STEAL))
IDLE1=$((IDLE + IOWAIT))

sleep 1

read -r _ USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ STEAL _ < /proc/stat
TOTAL2=$((USER + NICE + SYSTEM + IDLE + IOWAIT + IRQ + SOFTIRQ + STEAL))
IDLE2=$((IDLE + IOWAIT))

TOTAL_DIFF=$((TOTAL2 - TOTAL1))
IDLE_DIFF=$((IDLE2 - IDLE1))

if (( TOTAL_DIFF > 0 )); then
    CPU_USAGE=$((100 * (TOTAL_DIFF - IDLE_DIFF) / TOTAL_DIFF))
fi

check_threshold() {
    local value="$1"
    local threshold="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "UNKNOWN"
    elif (( value >= threshold )); then
        echo "WARNING"
    else
        echo "OK"
    fi
}

DISK_STATUS="$(check_threshold "$DISK_USAGE" "$DISK_THRESHOLD")"
MEMORY_STATUS="$(check_threshold "$MEMORY_USAGE" "$MEMORY_THRESHOLD")"
CPU_STATUS="$(check_threshold "$CPU_USAGE" "$CPU_THRESHOLD")"

# Detect the default-route interface dynamically; do not assume ens33.
INTERFACE="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $5}')"
GATEWAY="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $3}')"

NETWORK_STATUS="CRITICAL"

if [[ -n "$INTERFACE" && -n "$GATEWAY" ]] &&
   ip link show "$INTERFACE" >/dev/null 2>&1 &&
   ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
    NETWORK_STATUS="OK"
fi

# External ICMP may be blocked, so DNS is checked separately.
DNS_STATUS="CRITICAL"
if getent hosts example.com >/dev/null 2>&1; then
    DNS_STATUS="OK"
fi

if systemctl is-active --quiet nginx; then
    NGINX_STATUS="RUNNING"
else
    NGINX_STATUS="DOWN"
fi

OVERALL_STATUS="HEALTHY"

if [[ "$DISK_STATUS" == "WARNING" ||
      "$MEMORY_STATUS" == "WARNING" ||
      "$CPU_STATUS" == "WARNING" ||
      "$DISK_STATUS" == "UNKNOWN" ||
      "$MEMORY_STATUS" == "UNKNOWN" ||
      "$CPU_STATUS" == "UNKNOWN" ||
      "$NETWORK_STATUS" != "OK" ||
      "$DNS_STATUS" != "OK" ||
      "$NGINX_STATUS" != "RUNNING" ]]; then
    OVERALL_STATUS="WARNING"
fi

if [[ "$DISK_STATUS" == "UNKNOWN" ||
      "$MEMORY_STATUS" == "UNKNOWN" ||
      "$CPU_STATUS" == "UNKNOWN" ]]; then
    OVERALL_STATUS="CRITICAL"
fi

if [[ "$OVERALL_STATUS" != "HEALTHY" ]]; then
    logger -p user.warning -t linux-server-monitoring \
        "Health check status=$OVERALL_STATUS host=$HOSTNAME" 2>/dev/null || true
fi

echo "========================================"
echo "       LINUX SERVER HEALTH CHECK"
echo "========================================"
echo "Timestamp      : $TIMESTAMP"
echo "Hostname       : $HOSTNAME"
echo "Uptime         : $UPTIME"
echo "Load Average   : $LOAD"
echo "CPU Usage      : ${CPU_USAGE}% ($CPU_STATUS)"
echo "Memory Usage   : ${MEMORY_USAGE}% ($MEMORY_STATUS)"
echo "Disk Usage     : ${DISK_USAGE}% ($DISK_STATUS)"
echo "Network IF     : ${INTERFACE:-UNKNOWN}"
echo "Gateway        : ${GATEWAY:-UNKNOWN}"
echo "Network        : $NETWORK_STATUS"
echo "DNS            : $DNS_STATUS"
echo "Nginx          : $NGINX_STATUS"
echo "Overall Status : $OVERALL_STATUS"
echo "Log File       : $LOG_FILE"
echo "========================================"

if [[ "$OVERALL_STATUS" == "HEALTHY" ]]; then
    exit 0
else
    exit 1
fi
