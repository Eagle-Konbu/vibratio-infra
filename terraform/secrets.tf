locals {
  batch_secrets_path = "/${var.project_name}/batch/"
}

# Values are set out of band (see README) so that real credentials never enter the Terraform state.
resource "aws_ssm_parameter" "batch_secret" {
  for_each = var.batch_secret_names

  name  = "${local.batch_secrets_path}${each.key}"
  type  = "SecureString"
  value = "placeholder"

  lifecycle {
    ignore_changes = [value]
  }
}
