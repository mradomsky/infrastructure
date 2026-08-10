output "website_bucket_name" {
  description = "Name of the S3 bucket hosting the website"
  value       = aws_s3_bucket.website.id
}

output "cloudfront_distribution_id" {
  description = "The ID of the CloudFront distribution"
  value       = aws_cloudfront_distribution.website_distribution.id
}

output "cloudfront_domain_name" {
  description = "The domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.website_distribution.domain_name
}

output "dev_zone_id" {
  description = "Route 53 hosted zone ID for radomsky.dev"
  value       = aws_route53_zone.dev.zone_id
}

output "dev_zone_nameservers" {
  description = "Nameservers for radomsky.dev (delegate the registrar here)"
  value       = aws_route53_zone.dev.name_servers
}

output "site_certificate_arn" {
  description = "Validated ACM certificate ARN for the CloudFront distribution"
  value       = aws_acm_certificate_validation.site.certificate_arn
}
