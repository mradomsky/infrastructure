# Single ACM certificate (us-east-1, required by CloudFront) covering the new
# canonical domain plus the legacy redirect domain, apex + www for each.
resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = var.dev_domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "www.${var.dev_domain_name}",
    var.com_domain_name,
    "www.${var.com_domain_name}"
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Write each DNS validation record into whichever zone owns that name.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options :
    dvo.domain_name => dvo
  }

  zone_id = endswith(each.value.domain_name, var.dev_domain_name) ? aws_route53_zone.dev.zone_id : data.aws_route53_zone.com.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  # Ensure .dev is delegated to Route 53 before we wait on public resolution.
  depends_on = [aws_route53domains_registered_domain.dev]
}
