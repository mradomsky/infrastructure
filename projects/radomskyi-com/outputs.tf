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
