import os
import re
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, render_template

app = Flask(__name__)

PROJECT_DIR = Path("/home/asif/linux-server-monitoring")
LOG_DIR = PROJECT_DIR / "logs"

HEALTH_LOG = LOG_DIR / "health_check.log"
TROUBLESHOOT_LOG = LOG_DIR / "troubleshoot.log"

CPU_WARNING = 80.0
MEMORY_WARNING = 80.0
DISK_WARNING = 80.0

MAX_LOG_LINES = 100


def current_timestamp():
    return datetime.now(timezone.utc).isoformat()


def run_command(command, timeout=3):
    """Run a fixed system command without invoking a shell."""
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        return 1, "", str(exc)


def service_state(service_name):
    """Return the actual systemd service state."""
    code, output, _ = run_command(
        ["systemctl", "is-active", service_name]
    )

    if code == 0 and output == "active":
        return "RUNNING"

    if output in ("inactive", "failed", "activating", "deactivating"):
        return output.upper()

    return "UNKNOWN"


def get_cpu_percent():
    """Estimate CPU utilization from /proc/stat."""
    def read_cpu():
        with open("/proc/stat", "r", encoding="utf-8") as file:
            fields = file.readline().split()[1:]

        values = [int(value) for value in fields]
        idle = values[3] + (values[4] if len(values) > 4 else 0)

        return sum(values), idle

    try:
        total_before, idle_before = read_cpu()
        time.sleep(0.2)
        total_after, idle_after = read_cpu()

        total_delta = total_after - total_before
        idle_delta = idle_after - idle_before

        if total_delta <= 0:
            return None

        return round(
            100.0 * (total_delta - idle_delta) / total_delta, 1
        )
    except (OSError, ValueError, IndexError):
        return None


def get_memory():
    """Read memory information from /proc/meminfo."""
    values = {}

    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as file:
            for line in file:
                key, value = line.split(":", 1)
                values[key] = int(value.strip().split()[0])

        total = values["MemTotal"]
        available = values["MemAvailable"]
        used = total - available

        return {
            "memory_percent": round(used / total * 100, 1),
            "memory_used_mb": round(used / 1024, 1),
            "memory_total_mb": round(total / 1024, 1),
            "memory_avail_mb": round(available / 1024, 1),
        }
    except (OSError, ValueError, KeyError, ZeroDivisionError):
        return {
            "memory_percent": None,
            "memory_used_mb": None,
            "memory_total_mb": None,
            "memory_avail_mb": None,
        }


def get_disk():
    """Read capacity information for the root filesystem."""
    try:
        stats = os.statvfs("/")

        total_bytes = stats.f_blocks * stats.f_frsize
        free_bytes = stats.f_bavail * stats.f_frsize
        used_bytes = total_bytes - stats.f_bfree * stats.f_frsize

        # Use filesystem capacity and available space for the displayed
        # utilization, matching the usual df-style monitoring view.
        used_for_user = total_bytes - free_bytes
        percent = (
            used_for_user / total_bytes * 100
            if total_bytes
            else None
        )

        return {
            "disk_percent": round(percent, 1) if percent is not None else None,
            "disk_used_gb": round(used_for_user / (1024 ** 3), 2),
            "disk_total_gb": round(total_bytes / (1024 ** 3), 2),
            "disk_free_gb": round(free_bytes / (1024 ** 3), 2),
        }
    except OSError:
        return {
            "disk_percent": None,
            "disk_used_gb": None,
            "disk_total_gb": None,
            "disk_free_gb": None,
        }


def get_metrics():
    """Collect live host metrics."""
    metrics = {
        "hostname": socket.gethostname(),
        "timestamp": current_timestamp(),
        "cpu_percent": get_cpu_percent(),
    }

    metrics.update(get_memory())
    metrics.update(get_disk())

    try:
        with open("/proc/uptime", "r", encoding="utf-8") as file:
            metrics["uptime_seconds"] = int(float(file.readline().split()[0]))
    except (OSError, ValueError, IndexError):
        metrics["uptime_seconds"] = None

    try:
        with open("/proc/loadavg", "r", encoding="utf-8") as file:
            metrics["load_average"] = [
                float(value) for value in file.readline().split()[:3]
            ]
    except (OSError, ValueError, IndexError):
        metrics["load_average"] = []

    return metrics


def network_state():
    """Check basic DNS resolution without assuming internet is available."""
    try:
        socket.getaddrinfo("example.com", 443)
        return "CONNECTED"
    except socket.gaierror:
        return "UNKNOWN"


def read_log_file(path, component):
    """Read recent log lines and classify summary records correctly."""
    entries = []

    if not path.is_file():
        return entries

    try:
        lines = path.read_text(
            encoding="utf-8",
            errors="replace"
        ).splitlines()[-MAX_LOG_LINES:]
    except OSError:
        return entries

    for line in lines:
        upper = line.upper()

        # Summary lines describe counts; they are not alerts themselves.
        if re.search(r"\bCRITICAL\s+ISSUES?\s*:\s*0\b", upper):
            severity = "INFO"
        elif re.search(r"\bWARNINGS?\s*:\s*0\b", upper):
            severity = "INFO"
        elif re.search(r"\bOVERALL\s+STATUS\s*:\s*HEALTHY\b", upper):
            severity = "INFO"
        elif "CRITICAL" in upper or "FAILED" in upper or "ERROR" in upper:
            severity = "CRITICAL"
        elif "WARNING" in upper or "WARN" in upper:
            severity = "WARNING"
        else:
            severity = "INFO"

        entries.append({
            "timestamp": "",
            "severity": severity,
            "component": component,
            "message": line[:1000],
        })

    return entries

def get_logs():
    """Return recent entries from the existing monitoring log files."""
    entries = (
        read_log_file(HEALTH_LOG, "Health Check")
        + read_log_file(TROUBLESHOOT_LOG, "Troubleshooting")
    )

    return entries[-MAX_LOG_LINES:][::-1]


def get_services():
    """Inspect the services used by the existing project."""
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")

    nginx = service_state("nginx")
    timer = service_state("linux-health-check.timer")
    network = network_state()

    return [
        {
            "component": "Nginx Web Server",
            "status": nginx,
            "last_checked": now,
            "finding": f"systemd reports Nginx as {nginx}",
            "recommendation": (
                "Inspect Nginx service and logs"
                if nginx != "RUNNING"
                else "No action indicated by service state"
            ),
        },
        {
            "component": "Scheduled Health Timer",
            "status": timer,
            "last_checked": now,
            "finding": f"systemd reports timer as {timer}",
            "recommendation": (
                "Inspect linux-health-check.timer"
                if timer != "RUNNING"
                else "Timer is active"
            ),
        },
        {
            "component": "DNS Resolution",
            "status": network,
            "last_checked": now,
            "finding": f"DNS check result: {network}",
            "recommendation": (
                "Check DNS configuration and connectivity"
                if network != "CONNECTED"
                else "DNS resolution succeeded"
            ),
        },
    ]


def get_dashboard_data():
    metrics = get_metrics()
    services = get_services()
    logs = get_logs()

    warnings = []
    criticals = []

    for metric, label in (
        ("cpu_percent", "CPU utilization"),
        ("memory_percent", "Memory utilization"),
        ("disk_percent", "Disk utilization"),
    ):
        value = metrics.get(metric)

        if value is None:
            warnings.append(f"{label} could not be measured")
        elif value >= 90:
            criticals.append(f"{label} is {value}%")
        elif value >= (
            CPU_WARNING if metric == "cpu_percent"
            else MEMORY_WARNING if metric == "memory_percent"
            else DISK_WARNING
        ):
            warnings.append(f"{label} is {value}%")

    for service in services:
        if service["status"] not in ("RUNNING", "CONNECTED"):
            warnings.append(
                f'{service["component"]}: {service["status"]}'
            )

    # Include only recent log entries classified as warning/critical.
    for entry in logs:
        if entry["severity"] == "CRITICAL":
            criticals.append(
                f'{entry["component"]}: {entry["message"]}'
            )
        elif entry["severity"] == "WARNING":
            warnings.append(
                f'{entry["component"]}: {entry["message"]}'
            )

    if criticals:
        overall = "CRITICAL"
    elif warnings:
        overall = "WARNING"
    elif any(
        metrics.get(key) is None
        for key in ("cpu_percent", "memory_percent", "disk_percent")
    ):
        overall = "UNKNOWN"
    else:
        overall = "HEALTHY"

    alerts = []

    for message in criticals:
        alerts.append({
            "severity": "CRITICAL",
            "timestamp": current_timestamp(),
            "component": "Server Monitoring",
            "finding": message,
            "recommendation": "Investigate the underlying check or log",
            "verification": "Review metrics and relevant log entries",
        })

    for message in warnings:
        alerts.append({
            "severity": "WARNING",
            "timestamp": current_timestamp(),
            "component": "Server Monitoring",
            "finding": message,
            "recommendation": "Investigate the reported condition",
            "verification": "Review metrics and service state",
        })

    status = {
        "overall_health": overall,
        "nginx_status": service_state("nginx"),
        "network_status": network_state(),
        "timer_status": service_state("linux-health-check.timer"),
        "warning_count": len(warnings),
        "critical_count": len(criticals),
        "last_check": current_timestamp(),
    }

    return {
        "hostname": metrics["hostname"],
        "metrics": metrics,
        "status": status,
        "services": services,
        "alerts": alerts,
        "logs": logs,
    }


@app.get("/")
def dashboard():
    return render_template("dashboard.html")


@app.get("/api/health")
def api_health():
    return jsonify({
        "status": "ok",
        "application": "Linux Server Monitoring API",
        "timestamp": current_timestamp(),
    })


@app.get("/api/metrics")
def api_metrics():
    return jsonify(get_metrics())


@app.get("/api/status")
def api_status():
    return jsonify(get_dashboard_data()["status"])


@app.get("/api/services")
def api_services():
    return jsonify(get_services())


@app.get("/api/alerts")
def api_alerts():
    return jsonify(get_dashboard_data()["alerts"])


@app.get("/api/logs")
def api_logs():
    return jsonify(get_logs())


@app.get("/api/dashboard")
def api_dashboard():
    return jsonify(get_dashboard_data())


if __name__ == "__main__":
    # Local development only. Do not expose Flask's development server
    # directly to the public internet.
    app.run(host="127.0.0.1", port=5000, debug=False)
