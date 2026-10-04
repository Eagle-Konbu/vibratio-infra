locals {
  bff_function_name = "${var.project_name}-bff"

  bff_resolver_fields = {
    Query    = ["sources", "episodes", "episode"]
    Mutation = ["createSource", "updateSource", "deleteSource"]
  }

  bff_resolvers = merge([
    for type, fields in local.bff_resolver_fields : {
      for field in fields : "${type}.${field}" => { type = type, field = field }
    }
  ]...)
}

resource "aws_appsync_graphql_api" "cms" {
  name                = "${var.project_name}-cms"
  authentication_type = "AMAZON_COGNITO_USER_POOLS"
  schema              = file("${path.module}/graphql/schema.graphql")

  user_pool_config {
    user_pool_id   = aws_cognito_user_pool.cms.id
    aws_region     = var.aws_region
    default_action = "ALLOW"
  }

  log_config {
    cloudwatch_logs_role_arn = aws_iam_role.appsync.arn
    field_log_level          = "ERROR"
  }
}

resource "aws_cloudwatch_log_group" "appsync" {
  name              = "/aws/appsync/apis/${aws_appsync_graphql_api.cms.id}"
  retention_in_days = var.log_retention_days
}

resource "aws_appsync_datasource" "bff" {
  api_id           = aws_appsync_graphql_api.cms.id
  name             = "bff"
  type             = "AWS_LAMBDA"
  service_role_arn = aws_iam_role.appsync.arn

  lambda_config {
    function_arn = aws_lambda_function.bff.arn
  }
}

# Direct Lambda resolvers: no mapping templates, the BFF receives the full AppSync event.
resource "aws_appsync_resolver" "bff" {
  for_each = local.bff_resolvers

  api_id      = aws_appsync_graphql_api.cms.id
  type        = each.value.type
  field       = each.value.field
  data_source = aws_appsync_datasource.bff.name
  kind        = "UNIT"
}

resource "aws_iam_role" "appsync" {
  name               = "${var.project_name}-appsync"
  assume_role_policy = data.aws_iam_policy_document.appsync_assume_role.json
}

data "aws_iam_policy_document" "appsync_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["appsync.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role_policy" "appsync" {
  name   = "appsync"
  role   = aws_iam_role.appsync.id
  policy = data.aws_iam_policy_document.appsync.json
}

data "aws_iam_policy_document" "appsync" {
  statement {
    sid       = "InvokeBff"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.bff.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.appsync.arn}:*"]
  }
}

resource "aws_lambda_function" "bff" {
  function_name = local.bff_function_name
  role          = aws_iam_role.bff.arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      DATA_BUCKET_NAME = aws_s3_bucket.data.bucket
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.bff.name
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_cloudwatch_log_group" "bff" {
  name              = "/aws/lambda/${local.bff_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "bff" {
  name               = "${local.bff_function_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "bff" {
  name   = "bff"
  role   = aws_iam_role.bff.id
  policy = data.aws_iam_policy_document.bff.json
}

data "aws_iam_policy_document" "bff" {
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bff.arn}:*"]
  }

  statement {
    sid       = "ListData"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.data.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${local.data_prefixes.sources}*",
        "${local.data_prefixes.episodes}*",
      ]
    }
  }

  statement {
    sid       = "ManageSources"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.data.arn}/${local.data_prefixes.sources}*"]
  }

  # Audio read access is required to sign presigned URLs that the CMS uses for playback.
  statement {
    sid     = "ReadEpisodes"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.episodes}*",
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.articles}*",
      "${aws_s3_bucket.data.arn}/${local.data_prefixes.audio}*",
    ]
  }
}
