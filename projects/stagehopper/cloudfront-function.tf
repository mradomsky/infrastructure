# Viewer-request function that maps SPA deep links onto /index.html on the site behaviour.
# It replaces the two distribution-wide `custom_error_response` blocks (403/404 -> 200
# index.html) that also swallowed every /api/* error as `200 text/html`
# (mradomsky/stagehopper#181, the app's CLAUDE.md trap 1). See spa-fallback.js for the rule.
#
# Not a template: the code has no variables, so `file()` keeps it plain JavaScript.
resource "aws_cloudfront_function" "spa_fallback" {
  name    = "stagehopper-spa-fallback"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite extensionless URIs to /index.html on the site behaviour; /api/* keeps real status codes"
  publish = true
  code    = file("${path.module}/spa-fallback.js")
}
