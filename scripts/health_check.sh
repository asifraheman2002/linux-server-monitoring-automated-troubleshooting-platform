#!/bin/bash

exec > >(tee -a ~/linux-server-monitoring/logs/health_check.log)

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

DISK_THRESHOLD=80
MEMORY_THRESHOLD=80
CPU_THRESHOLD=80

HOSTNAME=$(hostname)
UPTIME=$(uptime -p)
LOAD=$(awk '{print $1 ", " $2 ", " $3}' /proc/loadavg)

DISK_USAGE=$(df --output=pcent / | tail -n 1 | tr -d ' %')
MEMORY_USAGE=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
TOTAL1=$((user+nice+system+idle+iowait+irq+softirq+steal))
IDLE1=$((idle+iowait))

sleep 1

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
TOTAL2=$((user+nice+system+idle+iowait+irq+softirq+steal))
IDLE2=$((idle+iowait))

TOTAL_DIFF=$((TOTAL2-TOTAL1))
IDLE_DIFF=$((IDLE2-IDLE1))

CPU_USAGE=$((100 * (TOTAL_DIFF-IDLE_DIFF) / TOTAL_DIFF))

if (( DISK_USAGE >= DISK_THRESHOLD )); then
    DISK_STATUS="CRITICAL"
else
    DISK_STATUS="OK"
fi

if (( MEMORY_USAGE >= MEMORY_THRESHOLD )); then
    MEMORY_STATUS="CRITICAL"
else
    MEMORY_STATUS="OK"
fi

if (( CPU_USAGE >= CPU_THRESHOLD )); then
    CPU_STATUS="CRITICAL"
else
    CPU_STATUS="OK"
fi

GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')

if ip link show ens33 | grep -q "state UP" &&
   ping -c 3 -W 1 "$GATEWAY" >/dev/null 2>&1 &&
   ping -c 3 -W 1 8.8.8.8 >/dev/null 2>&1
then
    NETWORK_STATUS="OK"
else
    NETWORK_STATUS="CRITICAL"
fi

if systemctl is-active --quiet nginx; then
    NGINX_STATUS="RUNNING"
else
    NGINX_STATUS="DOWN"
fi

OVERALL_STATUS="HEALTHY"

if [[ "$DISK_STATUS" == "CRITICAL" ||
      "$MEMORY_STATUS" == "CRITICAL" ||
      "$CPU_STATUS" == "CRITICAL" ||
      "$NETWORK_STATUS" == "CRITICAL" ||
      "$NGINX_STATUS" == "DOWN" ]]
then
    OVERALL_STATUS="CRITICAL"
fi
if [[ "$OVERALL_STATUS" == "CRITICAL" ]]; then
    logger -p user.crit -t linux-server-monitoring \
        "CRITICAL: Server health check detected a problem on $(hostname)"
fi

echo "========================================"
echo "       LINUX SERVER HEALTH CHECK"
echo "========================================"
echo "Timestamp      : $TIMESTAMP"
echo "Hostname       : $HOSTNAME"
echo "Uptime         : $UPTIME"
echo "Load Average   : $LOAD"
echo "CPU Usage      : $CPU_USAGE% ($CPU_STATUS)"
echo "Memory Usage   : $MEMORY_USAGE% ($MEMORY_STATUS)"
echo "Disk Usage     : $DISK_USAGE% ($DISK_STATUS)"
echo "Network        : $NETWORK_STATUS"
echo "Nginx          : $NGINX_STATUS"
echo "Overall Status : $OVERALL_STATUS"
echo "========================================"

if [[ "$OVERALL_STATUS" == "HEALTHY" ]]; then
    exit 0
else
    exit 1
fi


