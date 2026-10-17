#!/bin/bash

# Linux Server Monitoring, Hardening & Automated Troubleshooting Platform

LOG_FILE="$HOME/linux-server-monitoring/logs/troubleshoot.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=80

OVERALL_STATUS="HEALTHY"
WARNING_COUNT=0
CRITICAL_COUNT=0

# Record terminal output in the troubleshooting log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "       LINUX TROUBLESHOOTING REPORT"
echo "=============================================="
echo "Timestamp       : $TIMESTAMP"
echo "Hostname        : $HOSTNAME"
echo "=============================================="

# -----------------------------------------------
# 1. CPU DIAGNOSTICS
# -----------------------------------------------

echo
echo "--------------- CPU DIAGNOSTICS ---------------"

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
TOTAL1=$((user + nice + system + idle + iowait + irq + softirq + steal))
IDLE1=$((idle + iowait))

sleep 1

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
TOTAL2=$((user + nice + system + idle + iowait + irq + softirq + steal))
IDLE2=$((idle + iowait))

TOTAL_DIFF=$((TOTAL2 - TOTAL1))
IDLE_DIFF=$((IDLE2 - IDLE1))

if (( TOTAL_DIFF > 0 )); then
    CPU_USAGE=$((100 * (TOTAL_DIFF - IDLE_DIFF) / TOTAL_DIFF))
else
    CPU_USAGE=0
fi

echo "CPU Usage       : ${CPU_USAGE}%"

if (( CPU_USAGE >= CPU_THRESHOLD )); then
    echo "CPU Status      : HIGH"
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo "Top CPU-consuming processes:"
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6
    echo "Recommendation  : Investigate persistent CPU-intensive processes."
else
    echo "CPU Status      : NORMAL"
fi

# -----------------------------------------------
# 2. MEMORY DIAGNOSTICS
# -----------------------------------------------

echo
echo "------------- MEMORY DIAGNOSTICS --------------"

MEMORY_USAGE=$(free | awk '/^Mem:/ {
    if ($2 > 0) {
        printf "%.0f", ($2 - $7) / $2 * 100
    } else {
        print 0
    }
}')

echo "Memory Usage    : ${MEMORY_USAGE}%"

if (( MEMORY_USAGE >= MEMORY_THRESHOLD )); then
    echo "Memory Status   : HIGH"
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo "Top memory-consuming processes:"
    ps -eo pid,comm,%mem,rss --sort=-%mem | head -n 6
    echo "Recommendation  : Investigate memory-heavy processes and available memory."
else
    echo "Memory Status   : NORMAL"
fi

# -----------------------------------------------
# 3. DISK DIAGNOSTICS
# -----------------------------------------------

echo
echo "--------------- DISK DIAGNOSTICS --------------"

DISK_USAGE=$(df --output=pcent / | tail -n 1 | tr -d ' %')

echo "Root Disk Usage : ${DISK_USAGE}%"

if (( DISK_USAGE >= DISK_THRESHOLD )); then
    echo "Disk Status     : HIGH"
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo
    echo "Filesystem usage:"
    df -h
    echo
    echo "Largest directories under /var:"
    sudo du -xhd1 /var 2>/dev/null | sort -h | tail -n 5
    echo
    echo "Recommendation  : Investigate large directories and growing logs."
else
    echo "Disk Status     : NORMAL"
fi

# -----------------------------------------------
# 4. NETWORK DIAGNOSTICS
# -----------------------------------------------

echo
echo "-------------- NETWORK DIAGNOSTICS -------------"

INTERFACE=$(ip -o route show default | awk '{print $5; exit}')
GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')

echo "Interface       : ${INTERFACE:-NOT DETECTED}"
echo "Gateway         : ${GATEWAY:-NOT DETECTED}"

# Check network interface
if [[ -z "$INTERFACE" ]]; then
    echo "Interface Check : FAILED"
    echo "Finding         : No default route or interface detected."
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
elif ip link show "$INTERFACE" | grep -q "state UP"; then
    echo "Interface Check : PASSED"
else
    echo "Interface Check : FAILED"
    echo "Finding         : Interface $INTERFACE is not UP."
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
fi

# Check default gateway
if [[ -z "$GATEWAY" ]]; then
    echo "Gateway Check   : FAILED"
    echo "Finding         : No default gateway detected."
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
elif ping -c 3 -W 1 "$GATEWAY" >/dev/null 2>&1; then
    echo "Gateway Check   : PASSED"
else
    echo "Gateway Check   : WARNING"
    echo "Finding         : Gateway $GATEWAY did not respond to ping."
    echo "Note            : ICMP filtering may cause a false alarm."
    WARNING_COUNT=$((WARNING_COUNT + 1))
fi

# Check external IP connectivity
if ping -c 3 -W 1 8.8.8.8 >/dev/null 2>&1; then
    echo "External IP     : PASSED"
else
    echo "External IP     : WARNING"
    echo "Finding         : External IP connectivity check failed."
    echo "Note            : ICMP filtering may cause a false alarm."
    WARNING_COUNT=$((WARNING_COUNT + 1))
fi

# Check DNS resolution
DNS_HOST="example.com"

if getent ahosts "$DNS_HOST" >/dev/null 2>&1; then
    echo "DNS Check       : PASSED"
    echo "DNS Host        : $DNS_HOST"
else
    echo "DNS Check       : FAILED"
    echo "Finding         : Could not resolve $DNS_HOST."
    echo "Recommendation  : Investigate DNS configuration and connectivity."
    WARNING_COUNT=$((WARNING_COUNT + 1))
fi

# Check HTTPS connectivity
HTTPS_URL="https://example.com"

HTTP_STATUS=$(curl -sS -L \
    --connect-timeout 5 \
    --max-time 10 \
    -o /dev/null \
    -w '%{http_code}' \
    "$HTTPS_URL" 2>/dev/null)
CURL_STATUS=$?

if (( CURL_STATUS == 0 )) &&
   [[ "$HTTP_STATUS" =~ ^[23][0-9][0-9]$ ]]; then
    echo "HTTPS Check     : PASSED ($HTTP_STATUS)"
else
    echo "HTTPS Check     : FAILED"
    echo "Finding         : HTTPS request to $HTTPS_URL failed."
    echo "HTTP Status     : ${HTTP_STATUS:-UNAVAILABLE}"
    echo "Recommendation  : Check DNS, routing, TLS certificates and outbound access."
    WARNING_COUNT=$((WARNING_COUNT + 1))
fi

# -----------------------------------------------
# 5. NGINX DIAGNOSTICS
# -----------------------------------------------

echo
echo "--------------- NGINX DIAGNOSTICS --------------"

if systemctl is-active --quiet nginx; then
    echo "Nginx Status    : RUNNING"

    if ss -ltn | grep -Eq '(^|[[:space:]])[^[:space:]]*:80[[:space:]]'; then
        echo "Port 80         : LISTENING"
    else
        echo "Port 80         : NOT LISTENING"
        CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        echo "Recommendation  : Check Nginx configuration and listening sockets."
    fi

    HTTP_CODE=$(curl -sS --max-time 3 \
        -o /dev/null \
        -w '%{http_code}' \
        http://localhost 2>/dev/null)
    CURL_STATUS=$?

    if (( CURL_STATUS == 0 )) &&
       [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        echo "HTTP Check      : PASSED ($HTTP_CODE)"
    else
        echo "HTTP Check      : FAILED (${HTTP_CODE:-UNAVAILABLE})"
        CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        echo "Recent Nginx error-log entries:"
        sudo tail -n 10 /var/log/nginx/error.log 2>/dev/null
    fi
else
    echo "Nginx Status    : DOWN"
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo "Recent Nginx service logs:"
    journalctl -u nginx -n 10 --no-pager 2>/dev/null
    echo "Recommendation  : Investigate the service failure and configuration."
fi

# -----------------------------------------------
# 6. FINAL REPORT
# -----------------------------------------------

if (( CRITICAL_COUNT > 0 )); then
    OVERALL_STATUS="CRITICAL"
elif (( WARNING_COUNT > 0 )); then
    OVERALL_STATUS="WARNING"
else
    OVERALL_STATUS="HEALTHY"
fi

echo
echo "=============================================="
echo "             FINAL REPORT"
echo "=============================================="
echo "Warnings        : $WARNING_COUNT"
echo "Critical Issues : $CRITICAL_COUNT"
echo "Overall Status  : $OVERALL_STATUS"
echo "Report saved to : $LOG_FILE"
echo "=============================================="

if [[ "$OVERALL_STATUS" == "HEALTHY" ]]; then
    exit 0
else
    exit 1
fi
