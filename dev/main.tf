//region Kinesis

resource "aws_kinesis_stream" "kinesis_main" {
  name = "tf-kinesis-poc"
  shard_count = 1
  retention_period = 24
}

//endregion

//region Redshift

resource "aws_redshift_cluster" "redshift_main" {
  cluster_identifier = "tf-redshift-poc"
  node_type = "dc2.large"
  cluster_type = "single-node"
  number_of_nodes = 1

  database_name = var.rs_db_name
  master_username = var.rs_master_user
  master_password = var.rs_master_pwd

  publicly_accessible = true
  encrypted = true
  enhanced_vpc_routing = true
  iam_roles = [aws_iam_role.spectrum_role.arn]
}

//region Redshift backup
resource "aws_redshift_snapshot_schedule" "redshift_main" {
  identifier = "dwh-redshift-snapshot-schedule"
  definitions = [
    "cron(22 2 *)", # daily snapshots at 02:22AM UTC
  ]
}

resource "aws_redshift_snapshot_schedule_association" "redshift_main" {
  cluster_identifier  = aws_redshift_cluster.redshift_main.id
  schedule_identifier = aws_redshift_snapshot_schedule.redshift_main.id
}
//endregion

//region Redshift security & permissions
resource "aws_security_group" "redshift_main_sg1" {
  name = "tf-redshift-main-sg1"
  egress {
    from_port = 0
    to_port = 0
    protocol = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 5439
    to_port = 5439
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "spectrum_role" {
  name = "redshift-spectrum-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "redshift.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "spectrum_s3_glue_policy" {
  name        = "SpectrumS3GluePermissions"
  description = "Policy for Redshift Spectrum to access S3 as external tables"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "ListObjectsInBucket",
        Effect = "Allow",
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads"
        ],
        Resource = ["*"]
      },
      {
        Sid = "AllObjectActions",
        Effect = "Allow",
        Action = [
          "s3:*Object",
          "s3:ListMultipartUploadParts"
        ],
        Resource = ["*"]
      },
      {
        Sid = "AllGlueActions",
        Effect = "Allow",
        Action = [
          "glue:CreateDatabase",
          "glue:DeleteDatabase",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:UpdateDatabase",
          "glue:CreateTable",
          "glue:DeleteTable",
          "glue:BatchDeleteTable",
          "glue:UpdateTable",
          "glue:GetTable",
          "glue:GetTables",
          "glue:BatchCreatePartition",
          "glue:CreatePartition",
          "glue:DeletePartition",
          "glue:BatchDeletePartition",
          "glue:UpdatePartition",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition"
        ],
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_policy" "spectrum_kinesis_policy" {
  name        = "SpectrumKinesisPermissions"
  description = "Policy for Redshift Spectrum to access Kinesis as external schema"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "AllowReadKinesisStream",
        Effect = "Allow",
        Action = [
          "kinesis:DescribeStreamSummary",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:DescribeStream"
        ],
        Resource = "*"
      },
      {
        Sid = "AllowListKinesisStreams",
        Effect = "Allow",
        Action = [
          "kinesis:ListStreams",
          "kinesis:ListShards"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "spectrum_policy_attachments" {
  for_each = {
    "access_glue_s3": aws_iam_policy.spectrum_s3_glue_policy.arn,
    "access_kinesis": aws_iam_policy.spectrum_kinesis_policy.arn
  }

  role = aws_iam_role.spectrum_role.name
  policy_arn = each.value
}
//endregion

//endregion

//region ETL

resource "aws_redshiftdata_statement" "create_external_schema_from_kinesis" {
  cluster_identifier = aws_redshift_cluster.redshift_main.cluster_identifier
  database = aws_redshift_cluster.redshift_main.database_name
  db_user = var.rs_master_user
  sql = <<EOT
    CREATE EXTERNAL SCHEMA IF NOT EXISTS ext_kinesis_main FROM KINESIS
    IAM_ROLE '${aws_iam_role.spectrum_role.arn}';
  EOT
}

resource "aws_redshiftdata_statement" "drop_materialized_view_from_kinesis_stream1" {
  depends_on = [aws_redshiftdata_statement.create_external_schema_from_kinesis]
  cluster_identifier = aws_redshift_cluster.redshift_main.cluster_identifier
  database = aws_redshift_cluster.redshift_main.database_name
  db_user = var.rs_master_user
  sql = <<EOT
    DROP MATERIALIZED VIEW IF EXISTS mv_test_kinesis_source;
  EOT
}

resource "aws_redshiftdata_statement" "create_materialized_view_from_kinesis_stream1" {
  depends_on = [aws_redshiftdata_statement.drop_materialized_view_from_kinesis_stream1]
  cluster_identifier = aws_redshift_cluster.redshift_main.cluster_identifier
  database = aws_redshift_cluster.redshift_main.database_name
  db_user = var.rs_master_user
  sql = <<EOT
    CREATE MATERIALIZED VIEW mv_test_kinesis_source DISTKEY(5) sortkey(1) AS
    SELECT
      approximate_arrival_timestamp,
      partition_key,
      shard_id,
      sequence_number,
      refresh_time,
      json_parse(from_varbyte(kinesis_data, 'utf-8')) as payload,
      kinesis_data as _raw_data
    FROM ext_kinesis_main."${aws_kinesis_stream.kinesis_main.name}";
  EOT
}

resource "aws_redshiftdata_statement" "init_materialized_view_from_kinesis_stream1" {
  depends_on = [aws_redshiftdata_statement.create_materialized_view_from_kinesis_stream1]
  cluster_identifier = aws_redshift_cluster.redshift_main.cluster_identifier
  database = aws_redshift_cluster.redshift_main.database_name
  db_user = var.rs_master_user
  sql = <<EOT
    REFRESH MATERIALIZED VIEW mv_test_kinesis_source;
  EOT
}

//endregion
