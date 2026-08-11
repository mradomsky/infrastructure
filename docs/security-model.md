# Security model

How this account is meant to be reached, what is deliberately trusted, and the
gaps that are known but not yet closed.

## Access to AWS

There are no long-lived AWS keys in CI. Every workflow authenticates with GitHub
OIDC and assumes a role whose trust policy names the exact repository *and*
context allowed to assume it:

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `github-actions-terraform-plan` | `repo:mradomsky/infrastructure:pull_request` | `ReadOnlyAccess`, minus explicit denies on secret reads |
| `github-actions-terraform-apply` | `repo:mradomsky/infrastructure:ref:refs/heads/main` | `AdministratorAccess` |
| `github-website-deployment-worker` | stagehopper release tags and `main`, radomskyi.com `main` | S3 sync, CloudFront invalidation, `lambda:UpdateFunctionCode` |
| `command-interface-deploy` | `repo:V-M-Pioneer-Trading/command-interface:*` | S3 sync, CloudFront invalidation |

The `sub` claim is the trust boundary, so it is kept as narrow as the workflow
actually needs. A wildcard such as `repo:owner/*:*` grants every repo in the
account on every ref, which is why none of these use one.

Two further guards matter now that the repo is public:

- `plan.yml` refuses to run for forked pull requests. `terraform plan` executes
  provider and external-data code from the PR's own `.tf` files, so without that
  guard anyone could fork, open a PR, and run code inside a job holding
  account-wide read credentials.
- Actions are pinned to commit SHAs, and the repository requires SHA pinning.
  Tags are mutable; `apply.yml` assumes an administrator role, so a hijacked tag
  would be an account takeover. Dependabot keeps the pins current.

`bootstrap/` is applied from a workstation, never from CI, because it manages the
OIDC provider and the CI roles themselves — a bad run there could otherwise break
its own trust and lock everyone out.

## Network exposure

The shared EC2 host runs the spacetraders backends in Docker. Its security group
allows ingress only from AWS's `com.amazonaws.global.cloudfront.origin-facing`
managed prefix list, so the services are reachable through CloudFront and not by
anyone who resolves the Elastic IP. Administrative access is via SSM Session
Manager (the instance profile grants it); there is no open SSH port. IMDSv2 is
required, which blunts SSRF-to-credential-theft against anything on the host.

Every S3 bucket blocks public access and is served through CloudFront with an
Origin Access Control; the bucket policies grant `s3:GetObject` only to the
specific distribution ARN.

### Known gap: plaintext between CloudFront and the origin

The spacetraders backend origins use `origin_protocol_policy = "http-only"` and
forward the `Authorization` header, so bearer tokens travel unencrypted between
CloudFront and the EC2 host. The prefix-list rule keeps third parties from
reaching the origin, but does not encrypt that hop.

Closing it means terminating TLS on the host — a reverse proxy (Caddy or nginx)
with a certificate for `spacetraders-backend.radomskyi.com`, after which the
origins move to `https-only`. That work belongs to the container stacks in
`V-M-Pioneer-Trading`, not to this repo.

## Secrets

Secrets are never committed. `.gitignore` excludes every `*.tfvars` file, values
are passed as `TF_VAR_*` environment variables at apply time, and each secret
variable is marked `sensitive` so it does not surface in plan output. Secret
scanning and push protection are enabled on the repository.

The parameters the EC2 host consumes (for example the GHCR pull token) are
created out of band with `aws ssm put-parameter` as `SecureString` and read by
the host at runtime, so their values never enter Terraform state. The plan role
carries an explicit `Deny` on reading those parameters and on
`secretsmanager:GetSecretValue`, because an explicit deny overrides the allow in
`ReadOnlyAccess`.

### Known gap: Lambda secrets reach Terraform state

The stagehopper functions receive `GOOGLE_CLIENT_ID`, `ADMIN_EMAILS` and the
three `VAPID_*` values as Lambda environment variables. `ignore_changes`
suppresses *diffs*, not *refresh*: Terraform still records the live values, so
they sit in plaintext in the state object in `radomskyi-tfstate` and in its
retained versions. Anything that can read that object can read the Web Push
signing key.

The fix is for the functions to resolve their own secrets at runtime, exactly as
the EC2 host already does — the environment holds a parameter *name*, and the
value stays in SSM. That requires an application change first, so the order is:

1. Create the parameters as `SecureString` with `aws ssm put-parameter`.
2. In `mradomsky/stagehopper`, read them at cold start with `ssm:GetParameter`
   and cache them for the container's lifetime.
3. Here: grant each Lambda role `ssm:GetParameter` on its own parameters plus
   `kms:Decrypt` on `alias/aws/ssm`, add the parameter ARNs to the plan role's
   deny list, and delete the secret variables and environment entries.
4. Rotate the VAPID keypair and the Google client secret. Rotation is required
   regardless of the above: the current values are in state versions that
   already exist, and removing them going forward does not unpublish them.

Note that the plan role cannot simply be denied access to the state bucket —
`terraform plan` reads its own backend state, so keeping the secrets out of state
is the fix, not blocking the read.
