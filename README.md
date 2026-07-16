# infrastructure

Terraform for personal AWS infrastructure (`543292785457`, `eu-central-1`).

## Layout

```text
bootstrap/                 State bucket + GitHub Actions OIDC role. Local state only.
shared/                    Shared EC2 host for Docker workloads. Remote state key: personal/terraform.tfstate.
projects/
  radomskyi-com/           Static site.
  stagehopper/             Static site + Lambda/API Gateway backend.
  spacetraders/            Static site + CloudFront routing to the SpaceTraders backend stacks
                           (V-M-Pioneer-Trading/infrastructure's navigation-service, agent-service,
                           fleet-service, each read via cross-repo terraform_remote_state).
  budgeter/                Placeholder.
```

## Shared EC2 stack

`shared/` provisions one reusable Amazon Linux 2023 EC2 instance with:

- Docker installed by `user_data`
- SSM-managed instance profile
- Closed-by-default security group
- Stable public Elastic IP output
- Outputs for sibling repos: `ec2_instance_ip`, `ec2_security_group_id`

`V-M-Pioneer-Trading/infrastructure` can read those outputs from S3 key
`personal/terraform.tfstate` via `terraform_remote_state`.

## State and CI

- State bucket: `radomskyi-tfstate`, created by `bootstrap/`
- Shared stack key: `personal/terraform.tfstate`
- Other stacks keep per-stack keys such as `radomskyi-com/terraform.tfstate`
- PR CI runs `terraform fmt -check -recursive`, `terraform init`, `terraform validate`, and
  `terraform plan -lock=false` for `bootstrap/`, `shared/`, `projects/radomskyi-com`,
  `projects/stagehopper`, and `projects/spacetraders`
- OIDC trust on bootstrap plan role allows both `mradomsky/infrastructure` and
  `V-M-Pioneer-Trading/infrastructure`

## Apply

```bash
cd shared
terraform init
terraform plan
terraform apply
```
