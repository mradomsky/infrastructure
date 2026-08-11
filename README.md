# infrastructure

Terraform for personal AWS infrastructure (`543292785457`, `eu-central-1`).

How access, network exposure and secrets are handled — including the gaps that
are known and not yet closed — is written up in [docs/security-model.md](docs/security-model.md).

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
- SSM-managed instance profile (Session Manager for admin access — no open SSH)
- Security group for the host (kept non-authoritative over ingress; the single
  CloudFront rule — 443 from the origin-facing prefix list — is a standalone rule
  owned by `V-M-Pioneer-Trading/infrastructure`'s navigation-service stack)
- Stable public Elastic IP output
- Outputs for sibling repos: `ec2_instance_ip`, `ec2_security_group_id`

The instance ignores changes to `ami` so a routine apply cannot replace the host
(and the containers on it) when AWS publishes a new Amazon Linux image. Move to a
new image deliberately with `terraform apply -replace=aws_instance.shared_ec2`.

`V-M-Pioneer-Trading/infrastructure` can read those outputs from S3 key
`personal/terraform.tfstate` via `terraform_remote_state`.

## State and CI

- State bucket: `radomskyi-tfstate`, created by `bootstrap/`
- Shared stack key: `personal/terraform.tfstate`
- Other stacks keep per-stack keys such as `radomskyi-com/terraform.tfstate`
- PR CI runs `terraform fmt -check -recursive`, `terraform init`, `terraform validate`, and
  `terraform plan -lock=false` for `bootstrap/`, `shared/`, `projects/radomskyi-com`,
  `projects/stagehopper`, and `projects/spacetraders`
- OIDC trust on the bootstrap plan role is scoped to `mradomsky/infrastructure:pull_request`
  only. (`V-M-Pioneer-Trading/infrastructure` was removed: its CI validates without a backend
  and never assumes an AWS role.)
- The website deploy role `github-website-deployment-worker` is managed in `bootstrap/`,
  with trust scoped to stagehopper release tags and radomskyi.com main pushes

## Apply

```bash
cd shared
terraform init
terraform plan
terraform apply
```
