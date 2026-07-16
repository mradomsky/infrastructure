# spacetraders

Static site + CloudFront routing for the SpaceTraders mining POC's `command-interface` frontend.

- S3 (private, OAC) + CloudFront serves the Vite build, with SPA fallback (404/403 -> index.html).
- Three `ordered_cache_behavior`s (`/api/v1/*`, `/api/agent/*`, `/api/fleet/*`) route to the shared
  EC2 host's navigation-service, agent-service, and fleet-service ports respectively, each read via
  cross-repo `terraform_remote_state` from `V-M-Pioneer-Trading/infrastructure`'s corresponding
  stack (same `radomskyi-tfstate` bucket).
- ACM cert (us-east-1, DNS-validated) + Route53 alias for `spacetraders.radomskyi.com`.
- Dedicated `command-interface-deploy` IAM role, OIDC-trusted only for
  `V-M-Pioneer-Trading/command-interface`, scoped to this stack's own S3 bucket + CloudFront
  distribution.

## Apply order

This stack's `terraform plan` will fail with "Unable to find remote state" until
`V-M-Pioneer-Trading/infrastructure`'s `agent-service/` and `fleet-service/` stacks have been
applied at least once (their state must exist in S3 for this stack to read their port/IP outputs).
navigation-service's state already exists, so that remote-state read resolves today.
