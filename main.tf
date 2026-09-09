terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

variable "localstack_host" {
  type        = string
  default     = "localstack"
  description = "Hostname do LocalStack (ex: localstack em container docker, localhost no host local)"
}

# Provider AWS apontando para o LocalStack
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock_access_key"
  secret_key                  = "mock_secret_key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3         = "http://${var.localstack_host}:4566"
    kinesis    = "http://${var.localstack_host}:4566"
    firehose   = "http://${var.localstack_host}:4566"
    lambda     = "http://${var.localstack_host}:4566"
    events     = "http://${var.localstack_host}:4566"
    iam        = "http://${var.localstack_host}:4566"
    cloudwatch = "http://${var.localstack_host}:4566"
    logs       = "http://${var.localstack_host}:4566"
  }
}

# ------------------------------------------------------------------------------
# 1. BUCKET S3 (DATA LAKE)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "telemetry_bucket" {
  bucket        = "telemetry-data-lake"
  force_destroy = true

  tags = {
    Environment = "Local"
    Project     = "IoT-Telemetry-Pipeline"
  }
}

# ------------------------------------------------------------------------------
# 2. AMAZON KINESIS DATA STREAM (STREAMING)
# ------------------------------------------------------------------------------
resource "aws_kinesis_stream" "telemetry_stream" {
  name             = "telemetry-stream"
  shard_count      = 1
  retention_period = 24

  tags = {
    Environment = "Local"
    Project     = "IoT-Telemetry-Pipeline"
  }
}

# ------------------------------------------------------------------------------
# 3. AWS LAMBDA COLETORA & EMPACOTAMENTO
# ------------------------------------------------------------------------------

# Empacotamento automático da função Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

# IAM Role para a Lambda
resource "aws_iam_role" "lambda_role" {
  name = "telemetry_lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy para a Lambda permitir gravação no Kinesis, Firehose e Logs
resource "aws_iam_role_policy" "lambda_policy" {
  name = "telemetry_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords",
          "kinesis:DescribeStream",
          "firehose:PutRecord",
          "firehose:PutRecordBatch"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# Função Lambda
resource "aws_lambda_function" "collector_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "telemetry-collector-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = 30
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      API_URL              = "http://fastapi-app:8001/telemetria"
      KINESIS_STREAM_NAME  = aws_kinesis_stream.telemetry_stream.name
      FIREHOSE_STREAM_NAME = aws_kinesis_firehose_delivery_stream.telemetry_firehose.name
      AWS_REGION           = "us-east-1"
    }
  }

  tags = {
    Environment = "Local"
    Project     = "IoT-Telemetry-Pipeline"
  }
}

# ------------------------------------------------------------------------------
# 4. AMAZON DATA FIREHOSE (DELIVERY STREAM DIRECTPUT -> S3)
# ------------------------------------------------------------------------------

# IAM Role para o Data Firehose
resource "aws_iam_role" "firehose_role" {
  name = "telemetry_firehose_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy para o Data Firehose acessar o Kinesis e o Bucket S3
resource "aws_iam_role_policy" "firehose_policy" {
  name = "telemetry_firehose_policy"
  role = aws_iam_role.firehose_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:*", "s3:*", "logs:*"]
        Resource = "*"
      }
    ]
  })
}

# Delivery Stream do Firehose (DirectPut)
resource "aws_kinesis_firehose_delivery_stream" "telemetry_firehose" {
  name        = "telemetry-firehose"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = aws_s3_bucket.telemetry_bucket.arn
    prefix              = "raw/"
    error_output_prefix = "errors/"
    buffering_size      = 1
    buffering_interval  = 60
    compression_format  = "UNCOMPRESSED"
  }

  depends_on = [
    aws_s3_bucket.telemetry_bucket,
    aws_iam_role_policy.firehose_policy
  ]

  tags = {
    Environment = "Local"
    Project     = "IoT-Telemetry-Pipeline"
  }
}

# ------------------------------------------------------------------------------
# 5. EVENTBRIDGE (AGENDAMENTO DE 1 MINUTO)
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "telemetry-collector-schedule"
  description         = "Dispara a Lambda Coletora a cada 1 minuto"
  schedule_expression = "rate(1 minute)"

  tags = {
    Environment = "Local"
    Project     = "IoT-Telemetry-Pipeline"
  }
}

resource "aws_cloudwatch_event_target" "trigger_lambda" {
  rule      = aws_cloudwatch_event_rule.every_minute.name
  target_id = "TelemetryLambdaTarget"
  arn       = aws_lambda_function.collector_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

# ------------------------------------------------------------------------------
# OUTPUTS DE REFERÊNCIA
# ------------------------------------------------------------------------------
output "fastapi_url_external" {
  description = "URL externa da API FastAPI no host"
  value       = "http://localhost:8001/telemetria"
}

output "fastapi_url_internal" {
  description = "URL interna da API na rede Docker"
  value       = "http://fastapi-app:8001/telemetria"
}

output "s3_bucket_name" {
  description = "Nome do Bucket S3 Data Lake"
  value       = aws_s3_bucket.telemetry_bucket.bucket
}

output "kinesis_stream_name" {
  description = "Nome do Kinesis Data Stream"
  value       = aws_kinesis_stream.telemetry_stream.name
}

output "firehose_delivery_stream_name" {
  description = "Nome do Amazon Data Firehose"
  value       = aws_kinesis_firehose_delivery_stream.telemetry_firehose.name
}

output "lambda_function_name" {
  description = "Nome da função Lambda Coletora"
  value       = aws_lambda_function.collector_lambda.function_name
}
