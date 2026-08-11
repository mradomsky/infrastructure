# Security model

How this account is meant to be reached, what is deliberately trusted, and the
gaps that are known but not yet closed.

## Access to AWS

There are no long-lived AWS keys in CI. Every workflow authenticates with GitHub
OIDC and assumes a role whose trust policy names the exact repository *and*
context allowed to assume it:

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `github-actions-terraform-plan` | `repo:mradomsky/infrastructure:pull_request` | `ReadOnlyAccess`, minus explicit denies on secret reads and application-data reads |
| `github-actions-terraform-apply` | `repo:mradomsky/infrastructure:ref:refs/heads/main` | `AdministratorAccess` |
| `github-website-deployment-worker` | stagehopper release tags and `main`, radomskyi.com `main` | S3 sync, CloudFront invalidation, `lambda:UpdateFunctionCode` |
| `command-interface-deploy` | `repo:V-M-Pioneer-Trading/command-interface:*` | S3 sync, CloudFront invalidation |

The `sub` claim is the trust boundary, so it is kept as narrow as the workflow
actually needs. A wildcard such as `repo:owner/*:*` grants every repo in the
account on every ref, which is why none of these use one. The one remaining
ref-level wildcard is `command-interface-deploy` (any context within that single
repo); narrowing it to the exact deploy contexts is tracked in
[#34](https://github.com/mradomsky/infrastructure/issues/34).

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
managed prefix list, so nothing that resolves the Elastic IP can connect to the
services directly. Note the limit of that rule: the prefix list covers *all* of
CloudFront, so any AWS customer's distribution — not just ours — can be pointed
at the host and reach the backend ports. Authenticating that requests came
through *our* distributions (a shared-secret origin header verified at the host)
is part of [#32](https://github.com/mradomsky/infrastructure/issues/32).
Administrative access is via SSM Session Manager (the instance profile grants
it); there is no open SSH port. IMDSv2 is required, which blunts
SSRF-to-credential-theft against anything on the host.

Every S3 bucket blocks public access and is served through CloudFront with an
Origin Access Control; the bucket policies grant `s3:GetObject` only to the
specific distribution ARN.

### Known gap: plaintext between CloudFront and the origin

The spacetraders backend origins use `origin_protocol_policy = "http-only"` and
forward the `Authorization` header, so bearer tokens travel unencrypted between
CloudFront and the EC2 host. Closing this (TLS termination on the host, plus the
origin-authentication header above) is tracked in
[#32](https://github.com/mradomsky/infrastructure/issues/32).

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

The same deny policy also blocks the plan role from reading application *data*:
DynamoDB item reads (`GetItem`, `Query`, `Scan`, …) on the `stagehopper-*`
tables, and `s3:GetObject` on the website buckets. `ReadOnlyAccess` would
otherwise allow both — it covers data-plane reads, not just resource
configuration — and a compromised plan run has no business reading user records
or bucket content. The `radomskyi-tfstate` bucket stays readable because `plan`
must read its own backend state.

### Lambda secrets and Terraform state

A value set as a Lambda environment variable is recorded in state on every
refresh, so it sits in plaintext in the state object and in each retained version
of it — `ignore_changes` suppresses the *diff*, not the *read*. The plan role
cannot simply be denied access to the state bucket either, because
`terraform plan` reads its own backend state. Keeping secrets out of state is
therefore the fix, not blocking the read.

Of the values the stagehopper functions consume, only the VAPID private key is a
credential. It now lives in SSM as a `SecureString` and the notifier resolves it
at runtime (`lambda/secrets.ts` in `mradomsky/stagehopper`), caching it for the
life of the execution environment; the function's environment carries only the
parameter *name*.

The rest stay plain environment variables on purpose:

| Value | Why it stays |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Public by design. OAuth client IDs ship to browsers; this app verifies ID tokens and uses no client secret. |
| `VAPID_PUBLIC_KEY` | Sent to the browser to subscribe (`VITE_VAPID_PUBLIC_KEY`). |
| `VAPID_SUBJECT` | A `mailto:` contact for the push service. |
| `ADMIN_EMAILS` | Not a credential — the admin gate requires a Google-verified token, so knowing an address does not pass it. Worth moving only if the allowlist ever holds addresses that are not already public. |

The VAPID keypair was rotated after the move to SSM, which retired the key that
older state versions had recorded. As a backstop, the state bucket now expires
noncurrent object versions after 7 days (`bootstrap/main.tf`), so any secret
that ever transits state ages out of the retained history instead of persisting
indefinitely.
