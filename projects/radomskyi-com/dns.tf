# New canonical domain: Route 53 hosted zone (TF-managed).
resource "aws_route53_zone" "dev" {
  name = var.dev_domain_name

  tags = {
    Name = var.dev_domain_name
  }
}

# Legacy domain zone is managed outside this stack (it also parents the
# stagehopper/spacetraders subdomains). Reference it read-only so we can add
# the new certificate's validation records without adopting sibling records.
data "aws_route53_zone" "com" {
  name         = "${var.domain_name}."
  private_zone = false
}

# Delegate the Route 53-registered radomsky.dev to the new hosted zone.
# NOTE: import before first apply — `terraform import
# aws_route53domains_registered_domain.dev radomsky.dev`.
resource "aws_route53domains_registered_domain" "dev" {
  provider    = aws.us_east_1
  domain_name = var.dev_domain_name

  dynamic "name_server" {
    for_each = aws_route53_zone.dev.name_servers
    content {
      name = name_server.value
    }
  }

  auto_renew    = true
  transfer_lock = true

  tags = {
    Name = var.dev_domain_name
  }
}

# ALIAS records pointing the canonical apex + www (and legacy www) at the
# CloudFront distribution. The legacy apex (radomskyi.com) A ALIAS already
# exists in the .com zone and is left as-is; the redirect function 301s it.
locals {
  cf_alias_records = {
    "dev-apex-a"    = { zone = aws_route53_zone.dev.zone_id, name = var.dev_domain_name, type = "A" }
    "dev-apex-aaaa" = { zone = aws_route53_zone.dev.zone_id, name = var.dev_domain_name, type = "AAAA" }
    "dev-www-a"     = { zone = aws_route53_zone.dev.zone_id, name = "www.${var.dev_domain_name}", type = "A" }
    "dev-www-aaaa"  = { zone = aws_route53_zone.dev.zone_id, name = "www.${var.dev_domain_name}", type = "AAAA" }
    "com-www-a"     = { zone = data.aws_route53_zone.com.zone_id, name = "www.${var.domain_name}", type = "A" }
    "com-www-aaaa"  = { zone = data.aws_route53_zone.com.zone_id, name = "www.${var.domain_name}", type = "AAAA" }
  }
}

resource "aws_route53_record" "cf_alias" {
  for_each = local.cf_alias_records

  zone_id = each.value.zone
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.website_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.website_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}
