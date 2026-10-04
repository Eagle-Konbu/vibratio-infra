locals {
  resolver_dir = "${path.module}/graphql/resolvers"

  # One APPSYNC_JS resolver per file, named "<Type>.<field>.js".
  resolvers = {
    for file in fileset(local.resolver_dir, "*.js") : trimsuffix(file, ".js") => {
      type  = split(".", file)[0]
      field = split(".", file)[1]
      code  = file("${local.resolver_dir}/${file}")
    }
  }
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

resource "aws_appsync_datasource" "config" {
  api_id           = aws_appsync_graphql_api.cms.id
  name             = "config"
  type             = "AMAZON_DYNAMODB"
  service_role_arn = aws_iam_role.appsync.arn

  dynamodb_config {
    table_name = aws_dynamodb_table.config.name
    region     = var.aws_region
  }
}

resource "aws_appsync_resolver" "config" {
  for_each = local.resolvers

  api_id      = aws_appsync_graphql_api.cms.id
  type        = each.value.type
  field       = each.value.field
  data_source = aws_appsync_datasource.config.name
  kind        = "UNIT"
  code        = each.value.code

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
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
    sid = "ManageConfig"
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.config.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.appsync.arn}:*"]
  }
}

# The certificate is in us-east-1 while the domain is created in the API's region, as AppSync requires.
resource "aws_appsync_domain_name" "cms" {
  domain_name     = local.api_domain_name
  certificate_arn = aws_acm_certificate_validation.wildcard.certificate_arn
}

resource "aws_appsync_domain_name_api_association" "cms" {
  api_id      = aws_appsync_graphql_api.cms.id
  domain_name = aws_appsync_domain_name.cms.domain_name
}
