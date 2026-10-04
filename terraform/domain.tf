# One wildcard certificate covers every custom domain (cms, audio, api).
# DNS is hosted on Cloudflare, so the validation records are added there by hand
# from the acm_validation_records output.
resource "aws_acm_certificate" "wildcard" {
  provider = aws.us_east_1

  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
