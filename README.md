# infrastructure

Terraform for all personal projects (AWS account `543292785457`, region `eu-central-1`).

## Layout

```
bootstrap/                 State bucket + CI OIDC role. LOCAL state (chicken-and-egg) — see below.
shared/                    Cross-project resources (DNS zone, ACM certs). Currently empty — see TODO.
modules/
  ecs-service-with-efs/    Reusable module: ECS Fargate service + EFS persistent volume (SQLite).
projects/
  radomskyi-com/           Static site (S3 + CloudFront) + StageHopper backend (API GW + Lambda + DynamoDB).
  navigation-service/      Java Spring Boot service (ECS Fargate + EFS-backed SQLite). See its README.
  budgeter/                Placeholder — nothing deployed yet.
  spacetraders/            Placeholder — nothing deployed yet.
```

## State

- Backend: S3 bucket `radomskyi-tfstate` (versioned, encrypted), created by `bootstrap/`.
- One state key per stack: `<stack>/terraform.tfstate` (e.g. `radomskyi-com/terraform.tfstate`).
- Locking: Terraform >= 1.10 native S3 lockfile (`use_lockfile = true`). No DynamoDB.
- `bootstrap/` itself uses **local state** (it creates the state bucket). Its state file is
  gitignored; the stack is tiny and can be re-imported from the two resources if lost.

## Workflow

CI (GitHub Actions) runs `fmt -check`, `validate`, and `plan` on PRs via the read-only OIDC role
`github-actions-terraform-plan`. CI **plans with `-lock=false`** (read-only role cannot write the
lockfile) and **never applies**.

Apply is manual, from a trusted workstation:

```bash
cd projects/radomskyi-com
terraform init
terraform plan
terraform apply
```

## Lambda code-deploy contract (StageHopper)

Ownership split between this repo and the app repo:

| Concern                                            | Owner                                             |
| -------------------------------------------------- | ------------------------------------------------- |
| Lambda function, IAM role, env vars, runtime, arch | this repo (`projects/radomskyi-com/`)             |
| Lambda **code**                                    | app repo (`radomskyi.com`), via its CI            |

- Terraform creates the function from a committed `lambda_seed.zip` placeholder and sets
  `ignore_changes = [filename, source_code_hash]` — it never redeploys code.
- The app repo's deploy workflow runs `aws lambda update-function-code --function-name stagehopper`
  whenever `src/lib/stagehopper/lambda/**` changes.
- Changing env vars, memory, runtime, routes etc. still happens here via Terraform.

## TODO (deferred, deliberate)

- **Import ACM cert + DNS into `shared/`**: the CloudFront cert
  (`arn:aws:acm:...19d0ecff...`, us-east-1) and the domain's DNS are not Terraform-managed yet.
  Plan: `shared/` stack with `import` blocks for the cert (and Route53 zone if applicable);
  project stacks then consume them via `terraform_remote_state` or data sources instead of the
  hardcoded `acm_certificate_arn` variable in `projects/radomskyi-com/variables.tf`.
