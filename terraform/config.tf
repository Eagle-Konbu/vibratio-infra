# Settings edited from the CMS (Sources, ...). AppSync reads and writes this table directly,
# and the batch reads it at the start of each run.
#
# Items are grouped by partition key, e.g. pk = "SOURCE", sk = <source id>.
resource "aws_dynamodb_table" "config" {
  name         = "${var.project_name}-config"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  deletion_protection_enabled = true

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # This table is the only copy of the settings, so accidental writes and deletes can be rolled back.
  point_in_time_recovery {
    enabled = true
  }
}
