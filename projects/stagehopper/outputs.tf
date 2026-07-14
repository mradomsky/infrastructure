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

output "stagehopper_api_endpoint" {
  description = "API Gateway endpoint for StageHopper"
  value       = aws_apigatewayv2_api.stagehopper.api_endpoint
}

output "stagehopper_dynamodb_table" {
  description = "DynamoDB table name for StageHopper selections"
  value       = aws_dynamodb_table.stagehopper_selections.name
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1) used by CloudFront"
  value       = aws_acm_certificate.stagehopper.arn
}
