resource "aws_s3_bucket" "cms" {
  bucket = "${var.project_name}-cms-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cms" {
  bucket = aws_s3_bucket.cms.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cms" {
  bucket = aws_s3_bucket.cms.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "cms" {
  bucket = aws_s3_bucket.cms.id
  policy = data.aws_iam_policy_document.cms_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.cms]
}

data "aws_iam_policy_document" "cms_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cms.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cms.arn]
    }
  }
}

resource "aws_cloudfront_origin_access_control" "cms" {
  name                              = "${var.project_name}-cms"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "cms" {
  enabled             = true
  comment             = "${var.project_name} CMS"
  default_root_object = "index.html"
  # PriceClass_200 is the cheapest class that includes edge locations in Japan.
  price_class     = "PriceClass_200"
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id                = "cms"
    domain_name              = aws_s3_bucket.cms.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.cms.id
  }

  default_cache_behavior {
    target_origin_id           = "cms"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # The CMS is a client-side routed SPA, so unknown paths must serve index.html.
  # S3 returns 403 (not 404) for missing keys when ListBucket is not granted.
  dynamic "custom_error_response" {
    for_each = [403, 404]

    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
