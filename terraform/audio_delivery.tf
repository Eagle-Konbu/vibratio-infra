# Public delivery of the audio files whose URLs the batch posts to Discord.
# Discord messages stay around, so the URLs must not expire, which rules out presigned URLs.
# Only audio/ is readable through CloudFront; the rest of the data bucket stays private.
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = data.aws_iam_policy_document.data_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.data]
}

data "aws_iam_policy_document" "data_bucket" {
  statement {
    sid       = "AllowCloudFrontReadAudio"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/${local.data_prefixes.audio}*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.audio.arn]
    }
  }
}

resource "aws_cloudfront_origin_access_control" "data" {
  name                              = "${var.project_name}-data"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "audio" {
  enabled = true
  comment = "${var.project_name} audio"
  # PriceClass_200 is the cheapest class that includes edge locations in Japan.
  price_class     = "PriceClass_200"
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id                = "data"
    domain_name              = aws_s3_bucket.data.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.data.id
  }

  default_cache_behavior {
    target_origin_id           = "data"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
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
