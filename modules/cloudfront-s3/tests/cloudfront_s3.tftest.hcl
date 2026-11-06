mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

}

variables {
  name          = "platform-dev"
  environment   = "dev"
  account_id    = "123456789012"
  bucket_name   = "platform-dev-site-123456789012-ap-northeast-1"
  log_bucket_id = "platform-dev-logs-123456789012-ap-northeast-1"
}

run "origin_bucket_is_private_encrypted_and_versioned" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.site.block_public_acls == true
    error_message = "the site bucket must block public ACLs."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.site.block_public_policy == true
    error_message = "the site bucket must block public policies."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.site.ignore_public_acls == true
    error_message = "the site bucket must ignore public ACLs."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.site.restrict_public_buckets == true
    error_message = "the site bucket must restrict public buckets."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.site.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "object ownership must be BucketOwnerEnforced."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.site.versioning_configuration).status == "Enabled"
    error_message = "versioning must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.site.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "the site bucket must use SSE-KMS with a CMK."
  }

  assert {
    condition     = aws_kms_key.site.enable_key_rotation == true
    error_message = "the CMK must rotate automatically."
  }

  assert {
    condition     = aws_s3_bucket.site.force_destroy == false
    error_message = "force_destroy must stay false so site content is not silently deleted."
  }
}

run "cloudfront_reads_through_oac_over_https" {
  command = plan

  assert {
    condition     = aws_cloudfront_origin_access_control.site.signing_behavior == "always"
    error_message = "OAC must always sign origin requests."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.site.origin_access_control_origin_type == "s3"
    error_message = "the OAC must target an S3 origin."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.default_cache_behavior).viewer_protocol_policy == "redirect-to-https"
    error_message = "viewers must be redirected to HTTPS."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.viewer_certificate).minimum_protocol_version == "TLSv1.2_2021"
    error_message = "the minimum TLS version must be TLSv1.2_2021."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.default_root_object == "index.html"
    error_message = "default_root_object must default to index.html."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site.origin) == 1
    error_message = "the distribution must have exactly one S3 origin."
  }

  assert {
    condition     = length(one(aws_cloudfront_distribution.site.origin).s3_origin_config) == 0
    error_message = "the distribution must not fall back to a legacy OAI s3_origin_config."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site.custom_error_response) == 0
    error_message = "custom error responses must stay off unless spa_mode is enabled."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.default_cache_behavior).compress == true
    error_message = "compression must be enabled."
  }
}

run "spa_mode_maps_missing_objects_to_index" {
  command = plan

  variables {
    spa_mode = true
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site.custom_error_response) == 2
    error_message = "spa_mode must map both 403 and 404 responses."
  }

  assert {
    condition     = alltrue([for r in aws_cloudfront_distribution.site.custom_error_response : r.response_page_path == "/index.html"])
    error_message = "SPA fallbacks must point at the default root object."
  }

  assert {
    condition     = alltrue([for r in aws_cloudfront_distribution.site.custom_error_response : r.response_code == 200])
    error_message = "SPA fallbacks must return HTTP 200."
  }
}
