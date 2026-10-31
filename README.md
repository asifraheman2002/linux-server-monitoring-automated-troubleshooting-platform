# Linux Server Monitoring & Automated Troubleshooting Platform

**A Linux server monitoring and automation solution deployed on AWS EC2, combining Bash scripting, Python Flask, systemd, Nginx, Terraform, and Amazon CloudWatch.**

![Linux Server Monitoring Architecture](architecture/LinuxServerMonitoringAchitecture.png)

---

## 1. Project Overview

The **Linux Server Monitoring & Automated Troubleshooting Platform** is a cloud-hosted monitoring solution designed to observe Linux server health, track system resource utilization, automate health checks, identify service and connectivity issues, and present monitoring information through a web-based dashboard.

The application is deployed on an **AWS EC2 instance running Ubuntu Linux**. It combines Linux administration, shell scripting, Python-based application development, systemd automation, reverse proxy configuration, infrastructure as code, and centralized monitoring with Amazon CloudWatch.

Rather than relying entirely on manual server inspection, the project uses scheduled Bash health checks and a Python Flask backend to collect and expose monitoring information through REST API endpoints. A web dashboard provides a consolidated view of server metrics, service health, alerts, logs, and monitoring status.

The project was developed with a practical operations focus: understanding how a Linux server behaves, identifying failures, investigating their causes, and verifying corrective actions.

### Project Objectives

- Monitor Linux server resource utilization, including CPU, memory, disk usage, system load, and uptime.
- Automate recurring server health checks using Bash.
- Schedule health-check execution using systemd services and timers.
- Monitor application and web-server availability.
- Expose monitoring information through REST API endpoints.
- Display monitoring data through a web-based dashboard.
- Integrate AWS CloudWatch for centralized monitoring and logging.
- Provision supporting AWS infrastructure using Terraform.
- Apply IAM permissions to support monitoring operations.
- Investigate and troubleshoot application, service, networking, and permission-related issues.

---

## 2. Technology Stack

| Category | Technologies |
|---|---|
| Cloud Platform | Amazon Web Services (AWS) |
| Compute | Amazon EC2 |
| Operating System | Ubuntu Linux |
| Infrastructure as Code | Terraform |
| Backend | Python, Flask |
| Application Server | Gunicorn |
| Web Server / Reverse Proxy | Nginx |
| Automation | Bash Shell Scripting |
| Scheduling | systemd Services and Timers |
| Monitoring | Amazon CloudWatch |
| AWS SDK | Boto3 |
| Configuration | Environment Variables, python-dotenv |
| API | REST API, JSON |
| Version Control | Git and GitHub |

---

## 3. Architecture

The platform follows a modular architecture in which Linux monitoring scripts, the Python application, system services, the web server, and AWS monitoring services perform separate responsibilities.

### Architecture Workflow

1. **AWS EC2 and Ubuntu:** The application runs on an Ubuntu Linux server hosted on Amazon EC2.
2. **Bash Health Checks:** A shell script collects system health information and performs checks on relevant server components.
3. **systemd Automation:** A systemd timer triggers the health-check service on a recurring schedule.
4. **Health-Check Logs:** Execution results are written to the project's health-check log.
5. **Python Flask Backend:** The Flask application gathers monitoring information and exposes it through REST API endpoints.
6. **Gunicorn:** Serves the Flask application as the production application server.
7. **Nginx:** Acts as the reverse proxy and provides the web entry point to the application.
8. **Monitoring Dashboard:** Displays resource utilization, service status, alerts, logs, and monitoring information.
9. **Amazon CloudWatch:** Supports centralized AWS monitoring and log integration.

### Architecture Diagram

![Linux Server Monitoring Architecture](architecture/LinuxServerMonitoringArchitecture.png)

---

## 4. Key Features

### 4.1 Linux System Monitoring

The application provides monitoring information for important Linux server resources.

The monitoring metrics exposed by the dashboard API include:

- CPU utilization percentage.
- Memory utilization percentage.
- Total, used, and available memory.
- Disk utilization percentage.
- Total, used, and free disk space.
- System load average.
- Server uptime.
- Hostname.
- Metric collection timestamp.

These metrics help identify resource pressure and provide visibility into the server's operating condition.

### 4.2 Automated Bash Health Checks

A dedicated Bash script performs recurring health checks and records execution results.

**Script location:**

`scripts/health_check.sh`

The health-check automation is designed to reduce repetitive manual inspection and provide a consistent way to review server health.

The script can be inspected and executed using:

```bash
cd /opt/linux-server-monitoring

sudo bash scripts/health_check.sh
```

Execution results can be inspected using:

```bash
sudo tail -n 30 logs/health_check.log
```

### 4.3 systemd Service and Timer Automation

The project uses systemd to automate health-check execution.

**systemd components:**

| Component | Responsibility |
|---|---|
| `linux-health-check.service` | Executes the Bash health-check script |
| `linux-health-check.timer` | Schedules recurring health checks |
| `linux-server-monitoring.service` | Manages the monitoring application |

The health-check service is configured as a one-shot service. It executes the script and exits after completion. The timer is responsible for scheduling subsequent executions.

**Timer configuration:**

- Initial execution: One minute after boot.
- Recurring execution: Every five minutes.
- Service execution: One-shot.

Verify the timer:

```bash
systemctl is-active linux-health-check.timer

systemctl is-enabled linux-health-check.timer

systemctl list-timers --all | grep linux-health-check
```

Inspect the service:

```bash
sudo systemctl status linux-health-check.service --no-pager

sudo journalctl -u linux-health-check.service -n 30 --no-pager
```

**Important:** A one-shot service can show `inactive (dead)` after a successful execution. This is normal. The timer should remain active and enabled.

### 4.4 Python Flask REST API

The Flask backend collects monitoring information and provides API endpoints for the dashboard.

**Backend location:**

`app/app.py`

The API returns structured JSON responses, allowing the frontend to retrieve server metrics and monitoring information.

#### API Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | Application entry point |
| `GET /api/health` | Health information |
| `GET /api/metrics` | System resource metrics |
| `GET /api/status` | Overall monitoring and service status |
| `GET /api/services` | Service monitoring information |
| `GET /api/alerts` | Alert information |
| `GET /api/logs` | Log information |
| `GET /api/events` | Monitoring events |
| `GET /api/dashboard` | Consolidated dashboard data |
| `GET /api/cloudwatch/status` | CloudWatch integration status |

#### Test the Dashboard API

```bash
curl -sS -f http://127.0.0.1/api/dashboard | python3 -m json.tool
```

This verifies the dashboard API response through the local Nginx HTTP endpoint.

#### Inspect Registered API Routes

```bash
grep -nE '@app.route|@app.get|@app.post' app/app.py
```

### 4.5 Nginx Reverse Proxy

Nginx is configured as the web server and reverse proxy in front of the Flask application.

Its responsibilities include:

- Providing the HTTP entry point.
- Forwarding incoming application requests to the backend.
- Separating web-server responsibilities from application execution.
- Supporting communication between the browser and the Flask backend.

Verify Nginx:

```bash
sudo systemctl status nginx --no-pager

sudo nginx -t

curl -I http://localhost
```

The `nginx -t` command checks Nginx configuration syntax, while the HTTP request verifies the local web-server response.

### 4.6 Amazon CloudWatch Integration

Amazon CloudWatch is integrated to support centralized monitoring and log visibility.

The project uses AWS monitoring permissions through an IAM role and includes a CloudWatch read policy in the Terraform configuration.

**CloudWatch configuration:**

| Component | Configuration |
|---|---|
| CloudWatch Namespace | `LinuxServerMonitoring` |
| Log Group | `/linux-server-monitoring/system` |
| AWS SDK | Boto3 |
| IAM | EC2 monitoring role and CloudWatch permissions |

CloudWatch-related functionality can be checked through:

```text
/api/cloudwatch/status
```

The CloudWatch integration provides an additional monitoring layer beyond the local Linux dashboard.

### 4.7 Infrastructure as Code with Terraform

Terraform is used to define and manage the supporting AWS infrastructure.

**Terraform configuration location:**

`app/terraform/main.tf`

The configuration includes AWS infrastructure and IAM permissions required by the monitoring deployment.

The project also includes a CloudWatch dashboard-read IAM policy with permissions such as:

- `cloudwatch:ListMetrics`
- `cloudwatch:DescribeAlarms`
- `cloudwatch:GetMetricStatistics`

These permissions support monitoring data retrieval.

Terraform workflow:

```bash
terraform init

terraform validate

terraform plan

terraform apply
```

Review the execution plan before applying infrastructure changes. AWS resources may incur charges depending on the services, configuration, and usage.

---

## 5. Troubleshooting and Problem-Solving

An important part of this project was investigating real deployment and operational issues instead of treating successful installation as the end of the work.

The following areas were addressed during implementation and troubleshooting.

### 5.1 Nginx and Flask Integration

**Problem area:** Ensuring the web server and Python backend communicate correctly.

**Investigation:**

- Checked Nginx service status.
- Validated Nginx configuration.
- Inspected the application service.
- Tested the local HTTP endpoint.
- Investigated the 502 Bad Gateway condition.

**Verification commands:**

```bash
sudo nginx -t

sudo systemctl status nginx --no-pager

sudo systemctl status linux-server-monitoring.service --no-pager

curl -I http://localhost
```

### 5.2 systemd Service and Timer Troubleshooting

**Problem area:** Understanding scheduled execution and the difference between a one-shot service and a recurring timer.

**Investigation:**

- Inspected the systemd service configuration.
- Checked timer activation and enablement.
- Verified the next scheduled execution.
- Reviewed service logs through journalctl.
- Checked the health-check output.

**Verification commands:**

```bash
systemctl status linux-health-check.timer --no-pager

systemctl list-timers --all | grep linux-health-check

sudo journalctl -u linux-health-check.service -n 30 --no-pager
```

### 5.3 Bash Script Execution

**Problem area:** Ensuring the health-check script executes correctly and produces useful output.

**Investigation:**

- Inspected the script.
- Verified executable permissions.
- Executed the script.
- Reviewed the generated health-check log.

```bash
chmod +x scripts/health_check.sh

sudo bash scripts/health_check.sh

sudo tail -n 30 logs/health_check.log
```

### 5.4 API and Dashboard Troubleshooting

**Problem area:** Ensuring the dashboard receives the expected information from the backend.

**Investigation:**

- Inspected registered API routes.
- Verified the dashboard endpoint.
- Reviewed JSON response structure.
- Checked the relationship between backend response fields and dashboard display elements.

```bash
curl -sS -f http://127.0.0.1/api/dashboard | python3 -m json.tool
```

### 5.5 AWS IAM and CloudWatch Permissions

**Problem area:** Monitoring functionality depends on correctly configured AWS permissions.

**Investigation:**

- Reviewed the EC2 IAM role.
- Examined CloudWatch permissions.
- Added a dedicated CloudWatch read policy to the Terraform configuration.
- Verified the application's CloudWatch integration endpoint.

This demonstrates the importance of understanding the relationship between IAM roles, policies, AWS services, and application-level monitoring.

---

## 6. Repository Structure

The repository is organized to separate application code, infrastructure configuration, automation scripts, architecture documentation, and deployment evidence.

```text
linux-server-monitoring-automated-troubleshooting-platform/
│
├── app/
│   ├── app.py
│   ├── requirements.txt
│   │
│   ├── templates/
│   │   └── dashboard.html
│   │
│   └── terraform/
│       ├── .terraform.lock.hcl
│       └── main.tf
│
├── architecture/
│   └── Linux Server Monitoring Architecture.png
│
├── Linux-Server-Monitoring-Evidence/
│   ├── 01-pre-deployment/
│   ├── 02-aws-account-and-region/
│   ├── 03-iam-and-security/
│   ├── 04-ec2-deployment/
│   ├── 05-application/
│   ├── 06-cloudwatch-monitoring/
│   ├── 07-troubleshooting/
│   ├── 08-terraform/
│   ├── 09-cleanup/
│   ├── 10-bash-health-check/
│   ├── 11-systemd-automation/
│   ├── 12-api-testing/
│   └── 13-live-dashboard/
│
├── scripts/
│   ├── health_check.sh
│   └── troubleshoot.sh
│
├── .gitignore
├── LICENSE
└── README.md
```

---

## 7. Deployment and Verification Evidence

The following screenshots document the project implementation in a structured sequence.

### 7.1 Pre-Deployment Linux Environment

Initial Linux environment and preparation.

![Linux Environment](Linux-Server-Monitoring-Evidence/01-pre-deployment/01-linux-environment.png)

### 7.2 AWS Account and CLI Configuration

AWS CLI installation and identity verification.

![AWS CLI Installation](Linux-Server-Monitoring-Evidence/02-aws-account-and-region/01-aws-cli-installed.png)

![AWS Identity Verification](Linux-Server-Monitoring-Evidence/02-aws-account-and-region/02-aws-identity-verified.png)

### 7.3 IAM and Security Configuration

Evidence of EC2 security group configuration and CloudWatch permissions.

![EC2 Security Group](Linux-Server-Monitoring-Evidence/03-iam-and-security/01-ec2-sg.png)

![CloudWatch Permissions](Linux-Server-Monitoring-Evidence/03-iam-and-security/02-cloudwatch-permissions.png)

### 7.4 EC2 Deployment

EC2 instance deployment and instance details.

![EC2 Instance Details](Linux-Server-Monitoring-Evidence/04-ec2-deployment/01-ec2-instance-details.png)

![EC2 Deployment](Linux-Server-Monitoring-Evidence/04-ec2-deployment/Ec2.png)

### 7.5 Application Deployment

Application files, Python dependencies, Flask startup, Nginx configuration, and HTTP verification.

![Nginx HTTP Response](Linux-Server-Monitoring-Evidence/05-application/01-nginx-http-response.png)

![EC2 Python and Nginx Setup](Linux-Server-Monitoring-Evidence/05-application/02-ec2-python-nginx-setup.png)

![Flask Files Copied](Linux-Server-Monitoring-Evidence/05-application/03-flask-files-copied.png)

![Flask Dependencies Installed](Linux-Server-Monitoring-Evidence/05-application/04-flask-dependencies-installed.png)

![Flask Startup](Linux-Server-Monitoring-Evidence/05-application/05-flask-startup.png)

![Nginx Reverse Proxy](Linux-Server-Monitoring-Evidence/05-application/06-nginx-reverse-proxy.png)

![Flask and Nginx Verification](Linux-Server-Monitoring-Evidence/05-application/07-flask-nginx-verified.png)

### 7.6 CloudWatch Monitoring

CloudWatch metric and log-stream evidence.

![CloudWatch Disk Metric](Linux-Server-Monitoring-Evidence/06-cloudwatch-monitoring/01-disk-metric.png)

![CloudWatch Log Streams](Linux-Server-Monitoring-Evidence/06-cloudwatch-monitoring/02-log-streams.png)

### 7.7 Troubleshooting Evidence

Evidence documenting service health checks and the investigation of a 502 Bad Gateway issue.

![Health Check and Services](Linux-Server-Monitoring-Evidence/07-troubleshooting/01-health-check-and-services.png)

![502 Bad Gateway Troubleshooting](Linux-Server-Monitoring-Evidence/07-troubleshooting/02-502-bad-gateway.png)

### 7.8 Terraform Infrastructure

Terraform plan, apply, and infrastructure state evidence.

![Terraform Plan](Linux-Server-Monitoring-Evidence/08-terraform/01-terraform-plan.png)

![Terraform Apply](Linux-Server-Monitoring-Evidence/08-terraform/02-terraform-apply.png)

![Terraform State List](Linux-Server-Monitoring-Evidence/08-terraform/03-terraform-state-list.png)

### 7.9 Terraform Cleanup Evidence

![Terraform Destroy Evidence](Linux-Server-Monitoring-Evidence/09-cleanup/01-terraform-destroy.png)

### 7.10 Bash Health-Check Automation

The following screenshots document the health-check script, its output, and execution.

![Health Check Results](Linux-Server-Monitoring-Evidence/10-bash-health-check/01-health-check-results.png)

![Health Check Script](Linux-Server-Monitoring-Evidence/10-bash-health-check/02-health-check-script.png)

![Health Check Execution](Linux-Server-Monitoring-Evidence/10-bash-health-check/03-health-check-execution.png)

### 7.11 systemd Automation

Evidence of the systemd service configuration and timer scheduling.

![systemd Service File](Linux-Server-Monitoring-Evidence/11-systemd-automation/01-systemd-service-file.png)

![Timer Active, Enabled and Next Scheduled Run](Linux-Server-Monitoring-Evidence/11-systemd-automation/02-timer-active-enabled%20%26%20next-scheduled-run.png)

### 7.12 API Testing

Evidence of registered API routes and the dashboard JSON response.

![API Routes](Linux-Server-Monitoring-Evidence/12-api-testing/01-api-routes.png)

![Dashboard API Response](Linux-Server-Monitoring-Evidence/12-api-testing/02-dashboard-api-response.png)

![API Testing](Linux-Server-Monitoring-Evidence/12-api-testing/api-testing.png)

### 7.13 Live Monitoring Dashboard

Dashboard screenshots showing the monitoring interface and its major sections.

![Dashboard Overview](Linux-Server-Monitoring-Evidence/13-live-dashboard/01-dashboard-overview.png)

![Resource Utilization](Linux-Server-Monitoring-Evidence/13-live-dashboard/02-resource-utilization.png)

![Service Health](Linux-Server-Monitoring-Evidence/13-live-dashboard/03-service-health.png)

![Live Logs](Linux-Server-Monitoring-Evidence/13-live-dashboard/04-live-logs.png)

---

## 8. Installation and Local Development

### Prerequisites

- Ubuntu Linux or another compatible Linux distribution.
- Python 3.
- pip.
- Git.
- Bash.
- AWS CLI for AWS operations.
- Terraform for infrastructure management.
- An AWS account and appropriately configured permissions for cloud deployment.

### Clone the Repository

```bash
git clone https://github.com/asifraheman2002/linux-server-monitoring.git

cd linux-server-monitoring
```

### Create a Python Virtual Environment

```bash
python3 -m venv .venv

source .venv/bin/activate
```

### Install Dependencies

```bash
pip install -r app/requirements.txt
```

### Inspect the Application

```bash
python3 -m py_compile app/app.py

sed -n '1,220p' scripts/health_check.sh
```

The first command checks Python syntax. The second displays the health-check script for inspection.

**Deployment note:** Production execution uses the configured Gunicorn, systemd, and Nginx setup. Follow the application's actual service configuration when deploying it to a new server. Environment variables and AWS permissions must be configured for the target environment.

---

## 9. Security and Operational Considerations

Security and operational reliability are important aspects of a cloud-hosted Linux monitoring solution.

The project incorporates the following practices:

- AWS IAM roles and policies for application-level AWS permissions.
- A dedicated CloudWatch read policy in Terraform.
- Environment-variable-based configuration support.
- `.gitignore` rules to exclude private keys, environment files, Terraform state, local variable files, logs, backups, and virtual environments.
- Separation of application code, infrastructure code, automation scripts, and runtime logs.
- Service management through systemd.
- Application delivery through an Nginx reverse proxy.

### Operational Improvements to Consider

The monitoring application should be treated as an evolving operations project. Before production use, the following areas should be explicitly verified and hardened:

- UFW firewall configuration and SSH access restrictions.
- Log rotation and retention policies.
- HTTPS configuration and TLS certificate management.
- Least-privilege IAM permissions.
- CloudWatch alarms and notification delivery.
- Monitoring-data retention and alert thresholds.
- Backup and recovery procedures.
- Resource utilization under sustained workload.

These controls should only be marked as implemented after their configuration and operation have been verified.

---

## 10. Key Linux and Cloud Engineering Concepts Demonstrated

This project provides practical exposure to several concepts relevant to Linux administration, cloud support, cloud operations, and junior DevOps engineering.

| Area | Practical Concepts |
|---|---|
| Linux Administration | Processes, services, filesystem paths, permissions, logs |
| Bash Scripting | Automation, health checks, command execution, log output |
| systemd | Unit files, one-shot services, timers, service lifecycle |
| Python | Backend development, system metrics, API responses |
| Flask | REST endpoints, JSON responses, application routing |
| Gunicorn | Python application serving |
| Nginx | Reverse proxy, HTTP requests, service integration |
| AWS | EC2, IAM, CloudWatch |
| Terraform | Infrastructure as Code, plans, apply workflow, state inspection |
| Troubleshooting | Service failures, HTTP errors, log analysis, permission investigation |
| Git | Version control, repository organization, change management |

---

## 11. Future Improvements

Potential improvements to extend the platform include:

1. Configure and verify UFW firewall rules with restricted inbound access.
2. Implement log rotation using logrotate.
3. Add CloudWatch alarms for CPU, memory, and disk thresholds.
4. Integrate SNS notifications for critical alerts.
5. Add historical metric storage and visualization.
6. Implement authentication and role-based access for the dashboard.
7. Configure HTTPS using ACM or an appropriate TLS termination approach.
8. Add automated testing for API endpoints and Bash scripts.
9. Introduce CI/CD using GitHub Actions.
10. Add Docker-based deployment as an optional deployment method.
11. Improve alert severity classification and incident history.
12. Add automated backup and recovery validation.

These are proposed enhancements, not claims of completed functionality.

---

## 12. What I Learned

Building this project helped develop practical understanding of how different Linux and cloud components work together in a deployed environment.

Key learning outcomes include:

- Deploying and operating a Python application on an Ubuntu EC2 instance.
- Understanding the interaction between Flask, Gunicorn, and Nginx.
- Writing Bash scripts for recurring server health checks.
- Automating tasks through systemd services and timers.
- Investigating service failures using systemctl and journalctl.
- Testing REST APIs and examining JSON responses.
- Configuring AWS IAM permissions for monitoring integrations.
- Using CloudWatch for centralized monitoring and log visibility.
- Managing supporting AWS infrastructure using Terraform.
- Organizing deployment evidence and maintaining project documentation.
- Understanding the importance of verification rather than assuming that a successful command means a healthy deployment.

---

## 13. Project Evidence and Demonstration

The repository contains screenshots documenting the Linux environment, AWS configuration, application deployment, infrastructure provisioning, troubleshooting, health-check automation, systemd scheduling, API testing, and live dashboard.

The `Linux-Server-Monitoring-Evidence/` directory is organized into numbered folders to make the implementation process easier to review.

Architecture documentation is maintained separately in `architecture/`.

---

## 14. Author

**SK ASIF RAHEMAN**

MCA Graduate | AWS Cloud & Infrastructure | Linux | Terraform | Python

Interested in Cloud Support Engineering, Cloud Operations, Linux Administration, and Junior Cloud Engineering roles.

**GitHub:** [github.com/asifraheman2002](https://github.com/asifraheman2002)

**Project Repository:** [Linux Server Monitoring](https://github.com/asifraheman2002/linux-server-monitoring-automated-troubleshooting-platform)
---

## 15. License

This project is distributed under the license included in the repository. Refer to the `LICENSE` file for the applicable terms.
