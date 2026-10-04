data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Function code is deployed by the backend repository's CI.
# Terraform only creates the functions with this placeholder and ignores later code changes.
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.build/lambda_placeholder.zip"

  source {
    filename = "bootstrap"
    content  = <<-EOT
      #!/bin/sh
      echo "placeholder: deploy the function code from vibratio-backend" >&2
      exit 1
    EOT
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
