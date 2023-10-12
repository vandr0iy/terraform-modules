locals {
  name = "${var.cs_data_bucket}-${var.region}"
}

resource "aws_s3_bucket" "cs_data_bucket" {
  bucket = local.name
  force_destroy = false

  tags = {
    Name = local.name
  }
}

resource "aws_s3_bucket_acl" "cs_data_bucket_acl" {
  bucket = aws_s3_bucket.cs_data_bucket.id
  acl = "private"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cs_data_bucket_encryption" {
  bucket = aws_s3_bucket.cs_data_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.cs_data_bucket_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "cs_data_bucket_versioning" {
  bucket = aws_s3_bucket.cs_data_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
  
}

resource "aws_s3_bucket_lifecycle_configuration" "cs_data_bucket_lifecycle" {
  bucket = aws_s3_bucket.cs_data_bucket.id

  rule {
    status  = "Enabled"
    id      = "cleanup_after_30_days"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 31
    }
  }
}

resource "aws_sqs_queue" "cs_s3_bucket_sqs" {
  count = var.sqs_queue ? 1 : 0

  name                       = "s3-sqs-${local.name}"
  max_message_size           = 2048
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 600

  tags = {
    Bucket = local.name
  }
}

# Wait for sqs queue to come up before attaching policy
resource "time_sleep" "wait_1_minute" {
  depends_on = [aws_sqs_queue.cs_s3_bucket_sqs]

  create_duration = "60s"
}

resource "aws_sqs_queue_policy" "cs_s3_bucket_sqs" {
  count = var.sqs_queue ? 1 : 0
  depends_on = [time_sleep.wait_1_minute]

  queue_url = aws_sqs_queue.cs_s3_bucket_sqs[0].id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.cs_s3_bucket_sqs[0].arn}",
      "Condition": {
        "ArnEquals": { "aws:SourceArn": "${aws_s3_bucket.cs_data_bucket.arn}" }
      }
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [ "${aws_iam_role.cs_logging_server_side_role.arn}" ]
      },
      "Action": "sqs:*",
      "Resource": "${aws_sqs_queue.cs_s3_bucket_sqs[0].arn}"
    }
  ]
}
POLICY
}

resource "aws_s3_bucket_notification" "cs_data_bucket_notification" {
  count = var.sqs_queue ? 1 : 0
  depends_on = [aws_sqs_queue_policy.cs_s3_bucket_sqs[0]]

  bucket = aws_s3_bucket.cs_data_bucket.id

  queue {
    queue_arn = aws_sqs_queue.cs_s3_bucket_sqs[0].arn
    events    = ["s3:ObjectCreated:*"]
  }
}

resource "aws_kms_key" "cs_data_bucket_key" {
  description             = "This key is used to encrypt ${local.name}"
  deletion_window_in_days = 10
}

resource "aws_kms_alias" "cs_data_bucket_key" {
  name          = "alias/cs_${local.name}"
  target_key_id = aws_kms_key.cs_data_bucket_key.key_id
}


##
## IAM Role + Policy
##

resource "aws_iam_role" "cs_logging_server_side_role" {
  name = "cs_logs_${var.cs_external_id}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "AWS": [
            "arn:aws:iam::268357474475:root",
            "arn:aws:iam::291240392334:root",
            "arn:aws:iam::515570774723:root",
            "arn:aws:iam::079363773741:root"
        ]
      },
      "Effect": "Allow",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "${var.cs_external_id}"
        }
      }
    }
  ]
}
EOF
}

resource "aws_iam_policy" "cs_logging_server_side_role_policy" {
  name = "cs_logs_${var.cs_external_id}"

  #aws:userid
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AccessSQSObservabilityIngest",
            "Action": [
                "sqs:DeleteMessage",
                "sqs:DeleteMessageBatch",
                "sqs:ReceiveMessage",
                "sqs:GetQueueUrl",
                "sqs:GetQueueAttributes"
            ],
            "Resource": [
                "arn:aws:sqs:*:${var.aws_account_number}:*"
            ],
            "Effect": "Allow"
        },
        {
            "Sid": "AccessKMSNeedMimimumForRequiredBuckets",
            "Action": [
                "kms:*"
            ],
            "Resource": "*",
            "Effect": "Allow"
        },
        {
            "Sid": "ReadAccessDataBuckets",
            "Action": [
                "s3:GetObject",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging",
                "s3:GetBucketLocation",
                "s3:GetBucketTagging",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${var.data_bucket_name}",
                "arn:aws:s3:::${var.data_bucket_name}/*"
            ],
            "Effect": "Allow"
        },
        {
          "Sid": "ListAllBucketsS3UIPermission",
          "Action": [
            "s3:ListAllMyBuckets"
          ],
          "Resource": [
            "arn:aws:s3:::*"
          ],
          "Effect": "Allow"
        },
        {
            "Sid": "WriteAccessIndexedMetadataBucket",
            "Action": [
                "s3:GetObjectTagging",
                "s3:PutObjectTagging",
                "s3:ListBucket",
                "s3:CreateBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::cs-${var.cs_external_id}",
                "arn:aws:s3:::cs-${var.cs_external_id}/*"
            ],
            "Effect": "Allow"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "cs_logging_server_side_role_policy_attach" {
  role       = aws_iam_role.cs_logging_server_side_role.name
  policy_arn = aws_iam_policy.cs_logging_server_side_role_policy.arn
}
