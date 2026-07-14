# State Migration Guide

These commands move existing AWS resources from `radomskyi-com` Terraform state into `stagehopper`
without destroying or recreating them. Run them in order.

## 1. Import existing resources into stagehopper state

```bash
cd projects/stagehopper
terraform init

terraform import aws_dynamodb_table.stagehopper_selections stagehopper-selections

terraform import aws_iam_role.stagehopper_lambda stagehopper-lambda-role

terraform import aws_iam_role_policy.stagehopper_lambda stagehopper-lambda-role:stagehopper-lambda-policy

terraform import aws_lambda_function.stagehopper stagehopper

# API Gateway — get API ID:
#   aws apigatewayv2 get-apis --query 'Items[?Name==`stagehopper-api`].ApiId' --output text
terraform import aws_apigatewayv2_api.stagehopper API_ID

terraform import aws_apigatewayv2_integration.stagehopper API_ID/INTEGRATION_ID

terraform import aws_apigatewayv2_stage.stagehopper_default API_ID/$default

# Route IDs: aws apigatewayv2 get-routes --api-id API_ID
terraform import aws_apigatewayv2_route.create_room API_ID/ROUTE_ID_POST_rooms
terraform import aws_apigatewayv2_route.get_selections API_ID/ROUTE_ID_GET_selections
terraform import aws_apigatewayv2_route.put_selections API_ID/ROUTE_ID_PUT_selections_userId
terraform import aws_apigatewayv2_route.put_selections_self API_ID/ROUTE_ID_PUT_selections

# Lambda permission (statement ID is AllowAPIGatewayInvoke)
terraform import aws_lambda_permission.stagehopper_apigw stagehopper/AllowAPIGatewayInvoke

# S3 bucket
terraform import aws_s3_bucket.website stagehopper-radomskyi-com

# CloudFront OAC — get OAC ID:
#   aws cloudfront list-origin-access-controls --query 'OriginAccessControlList.Items[?Name==`stagehopper-oac`].Id' --output text
terraform import aws_cloudfront_origin_access_control.oac OAC_ID

# CloudFront distribution — get distribution ID from AWS console or:
#   aws cloudfront list-distributions --query 'DistributionList.Items[?Aliases.Items[0]==`stagehopper.radomskyi.com`].Id' --output text
terraform import aws_cloudfront_distribution.website_distribution DISTRIBUTION_ID

# ACM certificate in us-east-1 (if it already exists)
#   aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[?DomainName==`stagehopper.radomskyi.com`].CertificateArn' --output text
terraform import aws_acm_certificate.stagehopper arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID

# Route53 A record for stagehopper.radomskyi.com
# Get hosted zone ID: aws route53 list-hosted-zones-by-name --dns-name radomskyi.com
terraform import aws_route53_record.stagehopper ZONE_ID_stagehopper.radomskyi.com_A

# IAM role policy for GitHub Actions
terraform import aws_iam_role_policy.stagehopper_github_actions github-website-deployment-worker:stagehopper-github-actions-policy
```

## 2. Remove resources from radomskyi-com state

```bash
cd projects/radomskyi-com

terraform state rm aws_dynamodb_table.stagehopper_selections
terraform state rm aws_iam_role.stagehopper_lambda
terraform state rm aws_iam_role_policy.stagehopper_lambda
terraform state rm aws_lambda_function.stagehopper
terraform state rm aws_lambda_permission.stagehopper_apigw
terraform state rm aws_apigatewayv2_api.stagehopper
terraform state rm aws_apigatewayv2_integration.stagehopper
terraform state rm aws_apigatewayv2_route.create_room
terraform state rm aws_apigatewayv2_route.get_selections
terraform state rm aws_apigatewayv2_route.put_selections
terraform state rm aws_apigatewayv2_route.put_selections_self
terraform state rm aws_apigatewayv2_stage.stagehopper_default
terraform state rm data.aws_iam_role.github_actions
terraform state rm aws_iam_role_policy.github_actions_terraform
```

## 3. Verify

```bash
# Confirm radomskyi-com plan shows no stagehopper resources
cd projects/radomskyi-com
terraform plan

# Confirm stagehopper plan shows no destructive changes
cd projects/stagehopper
terraform plan
```

## Notes

- **ACM certificate bootstrap:** The ACM cert for `stagehopper.radomskyi.com` must exist and be
  validated before `terraform apply` can complete (CloudFront requires a valid cert). If the cert
  doesn't exist yet, do a targeted apply first:
  ```bash
  terraform apply -target=aws_acm_certificate.stagehopper -target=aws_route53_record.stagehopper_cert_validation
  # Wait for DNS validation (~5 min), then:
  terraform apply
  ```
- The `github_actions_terraform` policy in radomskyi-com covered all stagehopper permissions.
  After migration, stagehopper CI uses `stagehopper_github_actions` policy managed here.
