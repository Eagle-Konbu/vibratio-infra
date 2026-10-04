output "data_bucket_name" {
  description = "S3 bucket that stores Sources, Articles, Episodes, Audio and Config."
  value       = aws_s3_bucket.data.bucket
}

output "batch_function_name" {
  description = "Lambda function deployed from vibratio-backend for the daily batch."
  value       = aws_lambda_function.batch.function_name
}

output "bff_function_name" {
  description = "Lambda function deployed from vibratio-backend that resolves the CMS GraphQL API."
  value       = aws_lambda_function.bff.function_name
}

output "batch_secret_parameter_names" {
  description = "SecureString parameters whose values must be set manually."
  value       = [for parameter in aws_ssm_parameter.batch_secret : parameter.name]
}

output "graphql_api_url" {
  description = "AppSync GraphQL endpoint used by the CMS."
  value       = aws_appsync_graphql_api.cms.uris["GRAPHQL"]
}

output "cognito_user_pool_id" {
  description = "Cognito user pool for CMS sign-in."
  value       = aws_cognito_user_pool.cms.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito app client used by the CMS."
  value       = aws_cognito_user_pool_client.cms.id
}

output "cms_bucket_name" {
  description = "S3 bucket that hosts the CMS build output."
  value       = aws_s3_bucket.cms.bucket
}

output "cms_distribution_id" {
  description = "CloudFront distribution to invalidate after deploying the CMS."
  value       = aws_cloudfront_distribution.cms.id
}

output "cms_url" {
  description = "URL of the CMS."
  value       = "https://${aws_cloudfront_distribution.cms.domain_name}"
}
