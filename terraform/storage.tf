locals {
  # Key layout shared with vibratio-backend. IAM policies are scoped by these prefixes.
  data_prefixes = {
    sources  = "sources/"
    articles = "articles/"
    episodes = "episodes/"
    audio    = "audio/"
    config   = "config/"
  }
}

resource "aws_s3_bucket" "data" {
  bucket = "${var.project_name}-data-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Without a database, this bucket is the only copy of Sources edited from the CMS,
# so versioning protects against accidental overwrites and deletes.
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}
