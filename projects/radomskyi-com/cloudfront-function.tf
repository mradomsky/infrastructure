# Viewer-request function, two jobs:
#   1. 301 the legacy domain, www, and the CloudFront default host to the
#      canonical https://radomsky.dev (path + query preserved);
#   2. on the canonical host, rewrite extensionless URIs to the flat .html files
#      the static build emits, since S3 behind OAC has no index-document behaviour.
resource "aws_cloudfront_function" "redirect" {
  name    = "redirect-to-canonical"
  runtime = "cloudfront-js-1.0"
  comment = "301 legacy/www/default hosts to https://${var.dev_domain_name}; rewrite extensionless URIs to .html"
  publish = true
  code    = templatefile("${path.module}/redirect.js.tftpl", { canonical = var.dev_domain_name })
}
