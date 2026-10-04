locals {
  batch_function_name = "${var.project_name}-batch"
}

resource "aws_lambda_function" "batch" {
  function_name = local.batch_function_name
  role          = aws_iam_role.batch.arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"
  timeout       = var.batch_timeout_seconds
  memory_size   = var.batch_memory_size_mb

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      AUDIO_BASE_URL         = local.audio_base_url
      CONFIG_TABLE_NAME      = aws_dynamodb_table.config.name
      DATA_BUCKET_NAME       = aws_s3_bucket.data.bucket
      SECRETS_PARAMETER_PATH = local.batch_secrets_path
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.batch.name
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/lambda/${local.batch_function_name}"
  retention_in_days = var.log_retention_days
}

# A failed run is re-executed manually instead of automatically,
# because retries would call the paid LLM and TTS APIs again.
resource "aws_lambda_function_event_invoke_config" "batch" {
  function_name          = aws_lambda_function.batch.function_name
  maximum_retry_attempts = 0
}

resource "aws_iam_role" "batch" {
  name               = "${local.batch_function_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "batch" {
  name   = "batch"
  role   = aws_iam_role.batch.id
  policy = data.aws_iam_policy_document.batch.json
}

data "aws_iam_policy_document" "batch" {
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.batch.arn}:*"]
  }

  statement {
    sid       = "ListData"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.data.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${local.data_prefixes.articles}*",
        "${local.data_prefixes.episodes}*",
      ]
    }
  }

  statement {
    sid       = "ReadConfig"
    actions   = ["dynamodb:Query", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.config.arn]
  }

  statement {
    sid     = "ReadWriteGeneratedData"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.articles}*",
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.episodes}*",
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.audio}*",
    ]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.batch_secrets_path}*"]
  }
}

resource "aws_scheduler_schedule" "batch" {
  name                         = "${local.batch_function_name}-daily"
  schedule_expression          = var.batch_schedule_expression
  schedule_expression_timezone = var.batch_schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.batch.arn
    role_arn = aws_iam_role.batch_scheduler.arn
  }
}

resource "aws_iam_role" "batch_scheduler" {
  name               = "${local.batch_function_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
}

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role_policy" "batch_scheduler" {
  name   = "invoke-batch"
  role   = aws_iam_role.batch_scheduler.id
  policy = data.aws_iam_policy_document.batch_scheduler.json
}

data "aws_iam_policy_document" "batch_scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.batch.arn]
  }
}
