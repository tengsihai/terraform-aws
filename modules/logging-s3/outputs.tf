output "bucket_id" {
  description = "Name of the log bucket."
  value       = aws_s3_bucket.logs.id
}

output "bucket_arn" {
  description = "ARN of the log bucket."
  value       = aws_s3_bucket.logs.arn
}

output "bucket_domain_name" {
  description = "Regional domain name of the log bucket."
  value       = aws_s3_bucket.logs.bucket_regional_domain_name
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the bucket."
  value       = aws_kms_key.logs.arn
}

output "kms_key_id" {
  description = "ID of the CMK encrypting the bucket."
  value       = aws_kms_key.logs.key_id
}
