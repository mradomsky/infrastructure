# shared

Reusable personal shared infrastructure.

Creates one Docker-ready EC2 host in default VPC, plus IAM instance profile and security group.
State lives at S3 key `personal/terraform.tfstate` so sibling repos can read outputs via
`terraform_remote_state`.

Default ingress is closed. Open ports by setting both `allowed_ingress_cidrs` and
`allowed_tcp_ports`.
