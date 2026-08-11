data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "amazon_linux_2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# CloudFront's origin-facing IP ranges, maintained by AWS. Used by the security
# group below so the containers on this host are reachable only through the
# distributions that front them.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  default_subnet_id = sort(data.aws_subnets.default.ids)[0]
  exposed_tcp_ports = length(var.allowed_ingress_cidrs) == 0 ? [] : toset(var.allowed_tcp_ports)
}

resource "aws_iam_role" "shared_ec2" {
  name = "${var.instance_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "shared_ec2_ssm" {
  role       = aws_iam_role.shared_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_caller_identity" "current" {}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# Lets on-host bootstrap scripts (e.g. navigation-service's docker login)
# read SecureString parameters the SSM default key encrypts. Parameters
# themselves are created out-of-band (aws ssm put-parameter), not by
# Terraform, so tokens never land in state.
resource "aws_iam_role_policy" "shared_ec2_ssm_parameters" {
  name = "${var.instance_name}-ssm-parameters"
  role = aws_iam_role.shared_ec2.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/navigation-service-ghcr-pat"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "shared_ec2" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.shared_ec2.name
}

resource "aws_security_group" "shared_ec2" {
  name        = "${var.instance_name}-sg"
  description = "Shared EC2 host for Docker workloads"
  vpc_id      = data.aws_vpc.default.id

  # The only standing ingress: CloudFront. The spacetraders stack fronts the
  # navigation/agent/fleet/automation services running on this host with a
  # CloudFront distribution, so the host must not be reachable directly — an
  # attacker who knows the Elastic IP would otherwise bypass CloudFront and hit
  # the backends unfiltered.
  #
  # This rule was created by hand in the console and existed only there. Because
  # the block below produced no ingress blocks when `allowed_tcp_ports` is empty,
  # the provider treated ingress as unmanaged and the rule stayed invisible to
  # code — one variable change away from being replaced by plain CIDR rules.
  # Encoding it here makes it reviewable and enforced. The port range spans the
  # service ports assigned by the sibling backend stacks.
  ingress {
    description     = "Allow navigation/agent/fleet-service traffic from CloudFront only."
    from_port       = 80
    to_port         = 8080
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  }

  # Optional extra exposure for ad-hoc/debug work, off by default. Anything added
  # here is reachable from the public internet, so prefer SSM Session Manager
  # (the instance profile already allows it) over opening a port.
  dynamic "ingress" {
    for_each = local.exposed_tcp_ports

    content {
      description = "Container TCP ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "shared_ec2" {
  ami                         = data.aws_ssm_parameter.amazon_linux_2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = local.default_subnet_id
  vpc_security_group_ids      = [aws_security_group.shared_ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.shared_ec2.name
  associate_public_ip_address = true
  user_data                   = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOF

  # The AMI data source above tracks the *latest* Amazon Linux 2023 image, so it
  # changes whenever AWS publishes a new one — and `ami` forces replacement. Left
  # unignored, a routine `terraform apply` (including one dispatched from the
  # Actions tab) would destroy this host and every container on it, taking the
  # spacetraders backends down with it.
  #
  # Ignoring it pins the instance to the AMI it was built with. OS upgrades are a
  # deliberate act: patch in place with `dnf update`, or to move to a new image,
  # `terraform apply -replace=aws_instance.shared_ec2` at a chosen moment, after
  # confirming the workloads on the host can be restored.
  lifecycle {
    ignore_changes = [ami]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.root_volume_size_gib
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = var.instance_name
  }
}

resource "aws_eip" "shared_ec2" {
  domain   = "vpc"
  instance = aws_instance.shared_ec2.id

  tags = {
    Name = "${var.instance_name}-eip"
  }
}

resource "aws_sns_topic" "alerts" {
  name = "${var.instance_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "shared_ec2_status_check" {
  alarm_name          = "${var.instance_name}-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Shared EC2 host failed an instance/system status check."
  dimensions = {
    InstanceId = aws_instance.shared_ec2.id
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
