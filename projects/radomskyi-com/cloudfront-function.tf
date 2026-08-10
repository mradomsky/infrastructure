# Viewer-request function: 301 the legacy domain, www, and the CloudFront
# default host to the canonical https://radomsky.dev (path + query preserved).
resource "aws_cloudfront_function" "redirect" {
  name    = "redirect-to-canonical"
  runtime = "cloudfront-js-1.0"
  comment = "301 legacy/www/default hosts to https://${var.dev_domain_name}"
  publish = true
  code    = templatefile("${path.module}/redirect.js.tftpl", { canonical = var.dev_domain_name })
}
