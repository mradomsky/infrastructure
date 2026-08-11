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

**The VAPID keypair must still be rotated.** The previous private key is present
in state versions that already exist, and removing it going forward does not
unpublish them. Rotating is what actually retires the exposed key.
