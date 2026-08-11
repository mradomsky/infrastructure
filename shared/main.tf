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

locals {
  default_subnet_id = sort(data.aws_subnets.default.ids)[0]
  exposed_tcp_ports = length(var.allowed_ingress_cidrs) == 0 ? [] : toset(var.allowed_tcp_ports)

  # One standalone ingress rule per (port, CIDR) pair for the optional debug
  # exposure. Empty by default, so no debug rules exist unless explicitly asked
  # for. Standalone rather than an inline `dynamic "ingress"` block on purpose —
  # see the security group below.
  debug_ingress_rules = {
    for pair in setproduct(tolist(local.exposed_tcp_ports), var.allowed_ingress_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }
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

# The hosted zone the on-host Caddy edge proxy issues its origin certificate in.
# CloudFront requires a publicly-trusted cert on the HTTPS origin, and the
# security group admits only CloudFront (no port 80 for ACME HTTP-01), so Caddy
# uses the ACME DNS-01 challenge against Route53. Credentials come from this
# instance profile — no static AWS keys on the host.
data "aws_route53_zone" "primary" {
  name = var.dns_zone_name
}

resource "aws_iam_role_policy" "shared_ec2_route53_dns01" {
  name = "${var.instance_name}-route53-dns01"
  role = aws_iam_role.shared_ec2.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Record changes are scoped to the single managed zone.
        Sid    = "ChangeRecordsInManagedZone"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = data.aws_route53_zone.primary.arn
      },
      {
        # These two actions do not support resource-level scoping.
        # GetChange polls an opaque change ID; ListHostedZonesByName is how the
        # caddy-dns/route53 module discovers the zone ID at runtime.
        Sid    = "DiscoverZoneAndPollChanges"
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ListHostedZonesByName",
        ]
        Resource = "*"
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

  # Ingress is deliberately NOT declared inline here. An aws_security_group with
  # any inline `ingress` block becomes authoritative over ingress and deletes
  # every rule it does not itself declare on the next apply. The standing
  # CloudFront rule (ports 80-8080 from the origin-facing prefix list) is owned
  # by the V-M-Pioneer-Trading/infrastructure navigation-service stack, as a
  # standalone aws_vpc_security_group_ingress_rule. Declaring it inline here too
  # meant two stacks fought over one rule — and an apply of this stack would try
  # to recreate a rule that already exists, or strip the one the other stack
  # created. Keeping this SG non-authoritative over ingress (only standalone
  # rules, below and cross-repo) lets both stacks coexist safely.
  #
  # Optional ad-hoc/debug exposure lives in aws_vpc_security_group_ingress_rule
  # ("debug") below, also standalone for the same reason.

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Optional extra exposure for ad-hoc/debug work, off by default (empty unless
# allowed_ingress_cidrs is set). Standalone so this SG never becomes ingress-
# authoritative — see the security group's ingress comment above. Anything opened
# here is reachable from the public internet, so prefer SSM Session Manager (the
# instance profile already allows it) over opening a port.
resource "aws_vpc_security_group_ingress_rule" "debug" {
  for_each = local.debug_ingress_rules

  security_group_id = aws_security_group.shared_ec2.id
  description       = "Container TCP ${each.value.port} (ad-hoc/debug)"
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value.cidr
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
