# stagehopper infra — notes for AI sessions

## CloudFront strips headers you don't explicitly whitelist

`aws_cloudfront_distribution.website_distribution`'s `/api/*` cache behavior uses the legacy
`forwarded_values` block. It only forwards the headers listed in `forwarded_values.headers` to
the API Gateway origin — everything else is silently dropped, `Authorization` included.

This is invisible from the app or Lambda side: a stripped `Authorization` header just makes the
request arrive at API Gateway's JWT authorizer with no credential, which 401s exactly like a
real auth bug. Nothing logs "CloudFront ate your header." The Lambda's own CloudWatch logs stay
empty too — a rejected-at-the-authorizer request never reaches the Lambda at all.

**Incident:** PR #97 on the app repo moved the API credential from the request body to an
`Authorization` header (a JWT authorizer can only read headers). Nobody updated this file's
header whitelist to match, so every authenticated request through the real
`stagehopper.radomskyi.com` domain silently lost its token from the moment that shipped —
while curling the API Gateway's `execute-api` endpoint directly worked fine, because that
bypasses CloudFront entirely. That mismatch (CloudFront-fronted domain fails, direct
`execute-api` succeeds, same request) is the fastest way to confirm this class of bug.

**Rule:** any time a stagehopper route starts depending on a new request header — a new auth
scheme, an idempotency key, a custom header, anything — check the `/api/*`
`ordered_cache_behavior` here and add it to `forwarded_values.headers`, or it will be stripped
with no error anywhere in the stack.

## The deploy invokes the Lambda directly, with no route in front of it

`aws_iam_role_policy.stagehopper_github_actions` grants `lambda:InvokeFunction` (Sid
`LambdaRepublish`) on top of the usual `UpdateFunctionCode`. The app's `deploy.yml` uses it
to call the function with `{"republish":"festivals-manifest"}` right after shipping new code.

That exists because `data/festivals/index.json` — everything a signed-out visitor reads — is
*derived* from the festivals table by the Lambda, but is otherwise only rewritten when an
admin saves a festival. A release that adds a field to that file therefore leaves the old
shape live indefinitely, until some unrelated edit happens to rebuild it. The festival page's
`description` was missing in production for a full release exactly this way, with correct code
deployed the whole time.

Two things follow. **Don't remove the statement** as an over-broad permission: it is scoped to
the one function, and the handler takes the maintenance path only for an event carrying no
`routeKey` — which every API Gateway event does — so it is unreachable from the internet and
adds no route here. And **when a public field looks missing, read the published file before
reading any code**; present in DynamoDB and absent from `data/festivals/index.json` localizes
the bug to the publisher immediately.

## Where things live

- App code (SvelteKit + Lambda handler): `stagehopper` repo, separate clone.
- Everything AWS (this file's directory): Terraform here, in `infrastructure/projects/stagehopper`.
- Clerk's own instance config (social connections, sessions, etc., as opposed to the AWS-side
  JWT authorizer wiring here): a third repo, `clerk-config`.

A fix that looks like an app bug can be a CloudFront/API Gateway config gap instead (as above) —
check here, not just the app repo, when auth or routing misbehaves only in production.
