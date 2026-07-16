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

output "acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1) used by CloudFront"
  value       = aws_acm_certificate.spacetraders.arn
}

output "command_interface_deploy_role_arn" {
  description = "IAM role ARN command-interface's CI assumes to deploy the frontend"
  value       = aws_iam_role.command_interface_deploy.arn
}
