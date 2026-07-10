# budgeter

Placeholder — no infrastructure deployed yet.

When the budgeter backend needs AWS resources, create the stack here following repo conventions
(see root README): S3 backend key `budgeter/terraform.tfstate`, `use_lockfile = true`, default
tags with `Project = "budgeter"`, then add the stack path to `.github/workflows/plan.yml`.
