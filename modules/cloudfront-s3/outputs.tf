output "bucket_id" {
  description = "Name of the private site bucket."
  value       = aws_s3_bucket.site.id
}

output "bucket_arn" {
  description = "ARN of the private site bucket."
  value       = aws_s3_bucket.site.arn
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the site bucket."
  value       = aws_kms_key.site.arn
}

output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.site.id
}

output "distribution_arn" {
  description = "ARN of the CloudFront distribution."
  value       = aws_cloudfront_distribution.site.arn
}

output "distribution_domain_name" {
  description = "Public CloudFront hostname of the site."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront hosted zone ID, for alias records against the distribution."
  value       = aws_cloudfront_distribution.site.hosted_zone_id
}
