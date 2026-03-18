terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ==========================================
# 1. DATABASE: DynamoDB Table
# ==========================================
resource "aws_dynamodb_table" "urls_table" {
  name           = "BitlyUrls"
  billing_mode   = "PAY_PER_REQUEST" # Auto-scales with traffic
  hash_key       = "short_code"

  attribute {
    name = "short_code"
    type = "S"
  }

  # Satisfies the requirement to expire shortened URLs
  ttl {
    attribute_name = "expiration_date"
    enabled        = true
  }
}

# ==========================================
# NETWORKING (VPC & Security Groups)
# ==========================================
resource "aws_vpc" "cache_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# ElastiCache Serverless requires at least 2 subnets
resource "aws_subnet" "subnet_a" {
  vpc_id            = aws_vpc.cache_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "subnet_b" {
  vpc_id            = aws_vpc.cache_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

# Allow traffic on Redis Port 6379 inside the VPC
resource "aws_security_group" "internal_vpc_sg" {
  name   = "internal_vpc_sg"
  vpc_id = aws_vpc.cache_vpc.id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.cache_vpc.cidr_block]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# CRITICAL: Lambda in a VPC loses internet access. 
# We need a VPC Gateway Endpoint so Lambda can still securely reach DynamoDB.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.cache_vpc.id
  service_name      = "com.amazonaws.us-east-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_vpc.cache_vpc.main_route_table_id]
}

# ==========================================
# ELASTICACHE SERVERLESS
# ==========================================
resource "aws_elasticache_serverless_cache" "redis" {
  engine             = "redis"
  name               = "bitly-cache"
  security_group_ids = [aws_security_group.internal_vpc_sg.id]
  subnet_ids         = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
}

# ==========================================
# 2. COMPUTE: IAM & AWS Lambda
# ==========================================
#  Give Lambda permission to attach to a VPC
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role" "lambda_exec" {
  name = "bitly_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Allow Lambda to write logs and access DynamoDB
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess" # Can be scoped down in production
}

# Zip the entire folder (including the redis library)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/lambda.zip"
}


resource "aws_lambda_function" "api_handler" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "bitly_core_api_python"
  role             = aws_iam_role.lambda_exec.arn
  
  # CHANGE 1: Python Runtime
  runtime          = "python3.11" 
  
  # CHANGE 2: Handler points to filename.function_name
  handler          = "lambda_function.lambda_handler"
  
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.urls_table.name
      REDIS_HOST = aws_elasticache_serverless_cache.redis.endpoint[0].address
      REDIS_PORT = aws_elasticache_serverless_cache.redis.endpoint[0].port
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
    security_group_ids = [aws_security_group.internal_vpc_sg.id]
  }
}

# ==========================================
# 3. API ROUTING: HTTP API Gateway
# ==========================================
resource "aws_apigatewayv2_api" "api" {
  name          = "bitly_api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_handler.invoke_arn

  payload_format_version = "2.0"
}

# Create URL mapping
resource "aws_apigatewayv2_route" "post_url" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /urls"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Redirect lookup
resource "aws_apigatewayv2_route" "get_url" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /{short_code}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

output "api_url" {
  description = "The base URL for your API Gateway"
  value       = aws_apigatewayv2_api.api.api_endpoint
}
