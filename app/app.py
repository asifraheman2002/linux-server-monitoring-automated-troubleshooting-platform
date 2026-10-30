import json
import os
import re
import socket
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from flask import Flask, jsonify, render_template

# Load existing .env configuration when python-dotenv is installed.
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass

app = Flask(__name__)

# Keep the existing project structure.
PROJECT_DIR = Path(__file__).resolve().parent.parent
LOG_DIR = PROJECT_DIR / "logs"

HEALTH_LOG = Path(
    os.getenv("HEALTH_LOG", str(LOG_DIR / "health_check.log"))
)
TROUBLESHOOT_LOG = Path(
    os.getenv("TROUBLESHOOT_LOG", str(LOG_DIR / "troubleshoot.log"))
)

CPU_WARNING = float(os.getenv("CPU_WARNING", "80"))
MEMORY_WARNING = float(os.getenv("MEMORY_WARNING", "80"))
DISK_WARNING = float(os.getenv("DISK_WARNING", "80"))
MAX_LOG_LINES = 100

AWS_REGION = os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "ap-south-1"))
CW_NAMESPACE = os.getenv("CW_NAMESPACE", "LinuxServerMonitoring")
CW_LOG_GROUP = os.getenv(
    "CW_LOG_GROUP", "/linux-server-monitoring/system"
)


def current_timestamp():
    return datetime.now(timezone.utc).isoformat()


def run_command(command, timeout=3):
    """Run a fixed command without invoking a shell."""
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

        return round(100 * (total_delta - idle_delta) / total_delta, 1)
    except (OSError, ValueError, IndexError):
        return None


def get_memory():
    """Read memory information from /proc/meminfo."""
    try:
        values = {}
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

        # Match the user-visible available-capacity perspective.
        used_for_user = total_bytes - free_bytes
        percent = used_for_user / total_bytes * 100 if total_bytes else None

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
    """Collect live metrics from the Linux host running this application."""
    metrics = {
        "hostname": socket.gethostname(),
        "cpu_count": os.cpu_count(),
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
    """Return DNS connectivity as a string for existing dashboard checks."""
    try:
        socket.getaddrinfo("amazon.com", 443)
        return "CONNECTED"
    except (socket.gaierror, OSError):
        return "FAILED"
def network_diagnostics():
    """Check local HTTP, DNS resolution, and external HTTPS connectivity."""
    import urllib.request
    import socket

    results = {}

    # Check local Nginx HTTP
    try:
        with urllib.request.urlopen("http://127.0.0.1/", timeout=3) as response:
            results["local_http"] = (
                "CONNECTED" if response.status < 500 else "FAILED"
            )
    except Exception:
        results["local_http"] = "FAILED"

    # Check DNS resolution
    try:
        socket.getaddrinfo("amazon.com", 443)
        results["dns"] = "CONNECTED"
    except (socket.gaierror, OSError):
        results["dns"] = "FAILED"

    # Check external HTTPS
    try:
        with urllib.request.urlopen("https://amazon.com", timeout=5) as response:
            results["external_https"] = (
                "CONNECTED" if response.status < 500 else "FAILED"
            )
    except Exception:
        results["external_https"] = "FAILED"

    return results

def classify_log_line(line):
    """Classify individual log lines without treating zero-count summaries as alerts."""
    upper = line.upper()

    if re.search(r"\bCRITICAL\s+ISSUES?\s*:\s*0\b", upper):
        return "INFO"
    if re.search(r"\bWARNINGS?\s*:\s*0\b", upper):
        return "INFO"
    if re.search(r"\bOVERALL\s+STATUS\s*:\s*HEALTHY\b", upper):
        return "INFO"

    if (
        "CRITICAL" in upper
        or "FAILED" in upper
        or "ERROR" in upper
    ):
        return "CRITICAL"

    if "WARNING" in upper or re.search(r"\bWARN\b", upper):
        return "WARNING"

    return "INFO"


def read_log_file(path, component):
    """Read recent records from a project log."""
    entries = []

    if not path.is_file():
        return entries

    try:
        lines = path.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()[-MAX_LOG_LINES:]
    except OSError:
        return entries

    for line in lines:
        entries.append({
            "timestamp": "",
            "severity": classify_log_line(line),
            "component": component,
            "message": line[:1000],
        })

    return entries


def get_logs():
    """Combine the existing health-check and troubleshooting logs."""
    entries = (
        read_log_file(HEALTH_LOG, "Health Check")
        + read_log_file(TROUBLESHOOT_LOG, "Troubleshooting")
    )
    return entries[-MAX_LOG_LINES:][::-1]


def get_services():
    """Inspect services relevant to this project."""
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")

    checks = [
        (
            "Nginx Web Server",
            service_state("nginx"),
            "Inspect Nginx service and logs",
        ),
        (
            "Scheduled Health Timer",
            service_state("linux-health-check.timer"),
            "Check the configured systemd timer",
        ),
        (
            "DNS Resolution",
            network_state(),
            "Check DNS configuration and connectivity",
        ),
    ]

    services = []
    for component, status, recommendation in checks:
        services.append({
            "component": component,
            "status": status,
            "last_checked": now,
            "finding": f"{component} check returned {status}",
            "recommendation": (
                "No action indicated by this check"
                if status in ("RUNNING", "CONNECTED")
                else recommendation
            ),
        })

    return services

def get_latest_health_check():
    """Read the latest overall health status from the health-check log."""
    log_path = (
        Path(__file__).resolve().parent.parent
        / "logs"
        / "health_check.log"
    )

    result = {
        "status": "UNKNOWN",
        "last_result": "No health-check result available",
    }

    try:
        if not log_path.is_file():
            return result

        lines = log_path.read_text(errors="replace").splitlines()

        for line in reversed(lines):
            match = re.search(
                r"Overall Status\s*:\s*(HEALTHY|WARNING|CRITICAL)",
                line,
                re.IGNORECASE,
            )
            if match:
                result["status"] = match.group(1).upper()
                result["last_result"] = line.strip()
                return result

    except OSError:
        result["last_result"] = "Health-check log could not be read"

    return result


def get_environment_status():
    """Return actual system checks for the dashboard."""
    logrotate_file = Path("/etc/logrotate.d/linux-server-monitoring")

    try:
        ufw_result = subprocess.run(
            ["sudo", "-n", "ufw", "status"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )

        ufw_output = ufw_result.stdout.strip().lower()

        if ufw_result.returncode == 0 and "status: active" in ufw_output:
            hardening = "UFW ACTIVE"
        elif ufw_result.returncode == 0 and "status: inactive" in ufw_output:
            hardening = "UFW INACTIVE"
        else:
            hardening = "UNKNOWN"
    except (OSError, subprocess.TimeoutExpired):
        hardening = "UNKNOWN"

    log_rotation = (
        "CONFIGURED" if logrotate_file.is_file() else "NOT CONFIGURED"
    )

    timer = service_state("linux-health-check.timer")

    return {
        "hardening": hardening,
        "log_rotation": log_rotation,
        "scheduled_timer": timer,
    }

def get_dashboard_data():
    metrics = get_metrics()
    services = get_services()
    environment = get_environment_status()
    logs = get_logs()
    health_check = get_latest_health_check()
    warnings = []
    criticals = []

    thresholds = {
        "cpu_percent": ("CPU utilization", CPU_WARNING),
        "memory_percent": ("Memory utilization", MEMORY_WARNING),
        "disk_percent": ("Disk utilization", DISK_WARNING),
    }

    for key, (label, threshold) in thresholds.items():
        value = metrics.get(key)

        if value is None:
            warnings.append(f"{label} could not be measured")
        elif value >= 90:
            criticals.append(f"{label} is {value}%")
        elif value >= threshold:
            warnings.append(f"{label} is {value}%")

    for service in services:
        if service["status"] not in ("RUNNING", "CONNECTED"):
            warnings.append(
                f'{service["component"]}: {service["status"]}'
            )

    # Historical log lines remain visible in Logs. They are not automatically
    # treated as current health incidents by this dashboard summary.
    if criticals:
        overall = "CRITICAL"
    elif warnings:
        overall = "WARNING"
    elif any(metrics.get(key) is None for key in thresholds):
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
            "recommendation": "Investigate the affected metric",
            "verification": "Recheck metrics after remediation",
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
        "network_diagnostics": network_diagnostics(),
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
        "events": logs,
        "environment": environment,
        "health_check": health_check,
    }

def get_cloudwatch_status():
    """Return CloudWatch integration, log delivery, and alarm status."""
    region = os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "ap-south-1"))
    namespace = os.getenv("CW_NAMESPACE", "LinuxServerMonitoring")
    log_group = os.getenv("CW_LOG_GROUP", "/linux-server-monitoring/system")
    instance_id = os.getenv("INSTANCE_ID")

    result = {
        "status": "UNAVAILABLE",
        "namespace": namespace,
        "log_group": log_group,
        "log_group_exists": False,
        "log_delivery": "UNKNOWN",
        "metrics_found": 0,
        "alarms_count": 0,
        "iam_role": "Unknown",
        "region": region,
        "instance_id": instance_id or "Not configured",
    }

    try:
        import boto3
        from botocore.config import Config

        config = Config(
            connect_timeout=2,
            read_timeout=3,
            retries={"max_attempts": 1},
        )
        cw = boto3.client("cloudwatch", region_name=region, config=config)
        logs_client = boto3.client("logs", region_name=region, config=config)
        ec2 = boto3.client("ec2", region_name=region, config=config)

        groups = logs_client.describe_log_groups(
            logGroupNamePrefix=log_group, limit=10
        ).get("logGroups", [])
        group = next(
            (g for g in groups if g["logGroupName"] == log_group), None
        )
        result["log_group_exists"] = group is not None

        streams = []
        if group:
            streams = logs_client.describe_log_streams(
                logGroupName=log_group,
                orderBy="LastEventTime",
                descending=True,
                limit=5,
            ).get("logStreams", [])

        import time
        cutoff_ms = int((time.time() - 900) * 1000)
        recent_logs = any(
            s.get("lastEventTimestamp", 0) >= cutoff_ms for s in streams
        )
        result["log_delivery"] = (
            "RECENT LOGS RECEIVED" if recent_logs
            else "NO RECENT LOG EVENTS" if group
            else "LOG GROUP MISSING"
        )

        dimensions = [{"Name": "InstanceId", "Value": instance_id}] if instance_id else []
        metric_response = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName="mem_used_percent",
            Dimensions=dimensions,
            StartTime=datetime.now(timezone.utc) - timedelta(minutes=15),
            EndTime=datetime.now(timezone.utc),
            Period=300,
            Statistics=["Average"],
        )

        datapoints = metric_response.get("Datapoints", [])
        result["metrics_found"] = len(datapoints)
        result["recent_metrics_received"] = bool(datapoints)

        alarms = cw.describe_alarms().get("MetricAlarms", [])
        result["alarms_count"] = len(alarms)

        if instance_id:
            response = ec2.describe_instances(InstanceIds=[instance_id])
            instances = [
                i for r in response.get("Reservations", [])
                for i in r.get("Instances", [])
            ]
            if instances:
                profile = instances[0].get("IamInstanceProfile", {}).get("Arn", "")
                result["iam_role"] = profile.rsplit("/", 1)[-1] if profile else "No instance profile"

        if result["log_group_exists"] and result["recent_metrics_received"]:
            result["status"] = "CONNECTED"
        elif result["log_group_exists"] or result["recent_metrics_received"]:
            result["status"] = "PARTIAL"
        else:
            result["status"] = "NO DATA"

    except Exception as exc:
        result["error"] = str(exc)

    return result
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


@app.get("/api/events")
def api_events():
    return jsonify(get_logs())


@app.get("/api/dashboard")
def api_dashboard():
    return jsonify(get_dashboard_data())


@app.get("/api/cloudwatch/status")
def api_cloudwatch_status():
    return jsonify(get_cloudwatch_status())


if __name__ == "__main__":
    # Local development only. Use the project's existing service in production.
    app.run(host="127.0.0.1", port=5000, debug=False)
