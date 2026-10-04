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

locals {
  cms_domain_name   = "cms.${var.domain_name}"
  audio_domain_name = "audio.${var.domain_name}"
  api_domain_name   = "api.${var.domain_name}"

  audio_base_url = "https://${local.audio_domain_name}"
}

# Custom domains reference the certificate through this resource so that they are
# only configured once the certificate is issued. Validation itself happens through
# the Cloudflare records; without them, apply would wait until it times out.
resource "aws_acm_certificate_validation" "wildcard" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.wildcard.arn
}
