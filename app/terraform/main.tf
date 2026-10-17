terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

# --------------------------------------------------
# AWS PROVIDER
# --------------------------------------------------

provider "aws" {
  region = "ap-south-1"
}

# --------------------------------------------------
# VARIABLES
# --------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type; verify account eligibility and pricing first."
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name in ap-south-1."
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "Your public IPv4 address followed by /32."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "Provide a valid IPv4 CIDR, preferably your public IP followed by /32."
  }
}

# --------------------------------------------------
# UBUNTU 24.04 AMI
# --------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --------------------------------------------------
# DEFAULT VPC AND SUBNET
# --------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# --------------------------------------------------
# SECURITY GROUP
# --------------------------------------------------

resource "aws_security_group" "monitoring" {
  name        = "linux-monitoring-sg"
  description = "Restricted SSH and HTTP access for monitoring project"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from my public IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP dashboard"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound connectivity"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "linux-monitoring-sg"
    Project   = "LinuxServerMonitoring"
    ManagedBy = "Terraform"
  }
}

# --------------------------------------------------
# CLOUDWATCH LOG GROUP
# --------------------------------------------------

resource "aws_cloudwatch_log_group" "monitoring" {
  name              = "/linux-server-monitoring/system"
  retention_in_days = 7

  tags = {
    Project   = "LinuxServerMonitoring"
    ManagedBy = "Terraform"
  }
}

# --------------------------------------------------
# EC2 IAM ROLE
# --------------------------------------------------

resource "aws_iam_role" "monitoring" {
  name = "linux-monitoring-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "ec2.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = "LinuxServerMonitoring"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role = aws_iam_role.monitoring.name

  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "linux-monitoring-instance-profile"
  role = aws_iam_role.monitoring.name
}

# --------------------------------------------------
# EC2 INSTANCE
# --------------------------------------------------

resource "aws_instance" "monitoring" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  subnet_id = data.aws_subnets.default.ids[0]

  associate_public_ip_address = true

  vpc_security_group_ids = [
    aws_security_group.monitoring.id
  ]

  key_name = var.key_pair_name

  iam_instance_profile = aws_iam_instance_profile.monitoring.name

  user_data_replace_on_change = true

  user_data = <<-USERDATA
    #!/bin/bash
    set -eux

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y nginx python3 python3-venv git curl wget

    systemctl enable nginx
    systemctl start nginx

    # Install the official Amazon CloudWatch Agent package.
    wget -q \
      https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
      -O /tmp/amazon-cloudwatch-agent.deb

    dpkg -i /tmp/amazon-cloudwatch-agent.deb

    # Configure system and Nginx log collection.
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
    {
      "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
      },
      "metrics": {
        "namespace": "LinuxServerMonitoring",
        "append_dimensions": {
          "InstanceId": "$${aws:InstanceId}"
        },
        "metrics_collected": {
          "mem": {
            "measurement": ["mem_used_percent"],
            "metrics_collection_interval": 60
          },
          "disk": {
            "measurement": ["used_percent"],
            "resources": ["/"],
            "metrics_collection_interval": 60
          }
        }
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/syslog",
                "log_group_name": "/linux-server-monitoring/system",
                "log_stream_name": "{instance_id}/syslog"
              },
              {
                "file_path": "/var/log/nginx/access.log",
                "log_group_name": "/linux-server-monitoring/system",
                "log_stream_name": "{instance_id}/nginx-access"
              },
              {
                "file_path": "/var/log/nginx/error.log",
                "log_group_name": "/linux-server-monitoring/system",
                "log_stream_name": "{instance_id}/nginx-error"
              }
            ]
          }
        }
      }
    }
    CWCONFIG

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
      -s
  USERDATA

  tags = {
    Name      = "linux-server-monitoring"
    Project   = "LinuxServerMonitoring"
    ManagedBy = "Terraform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_cloudwatch_log_group.monitoring
  ]
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.monitoring.id
}

output "public_ip" {
  description = "Public IPv4 address"
  value       = aws_instance.monitoring.public_ip
}

output "dashboard_url" {
  description = "HTTP endpoint; application deployment is still required"
  value       = "http://${aws_instance.monitoring.public_ip}"
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group"
  value       = aws_cloudwatch_log_group.monitoring.name
}

