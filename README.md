
# AWS Serverless URL Shortener with Redis Cache



A production-ready, highly scalable URL shortener (Bit.ly clone) deployed to AWS via Terraform. Built with Python, API Gateway, Lambda, DynamoDB, and Amazon ElastiCache (Redis). This project leverages a serverless architecture and VPC networking to deliver low-latency URL redirection with robust internal caching.

## Architecture Overview

* **API Routing:** Amazon API Gateway (HTTP API, Payload v2.0) routes REST requests.
* **Compute:** AWS Lambda (Python 3.11) processes the URL generation, validation, and redirection logic.
* **Cache Layer (Reads/Writes):** Amazon ElastiCache Serverless (Redis) sits inside a Virtual Private Cloud (VPC). It uses a *Write-Through* pattern for new URLs and a *Cache-Aside* pattern to serve immediate redirects, protecting the database from high read volumes.
* **Database:** Amazon DynamoDB acts as the persistent system of record. It provides single-digit millisecond lookups and uses native Time-To-Live (TTL) to automatically expire and delete old records.
* **Networking:** A custom VPC with private subnets, security groups, and a VPC Gateway Endpoint ensures Lambda can securely reach both Redis (in the VPC) and DynamoDB (on the AWS public network).

## Prerequisites

* [Terraform](https://developer.hashicorp.com/terraform/downloads) installed (v1.0+).
* [AWS CLI](https://aws.amazon.com/cli/) installed and configured (`aws configure` or `aws sso login`).
* Python 3.11 and `pip` installed locally (for fetching Lambda dependencies).

## Project Structure

```text
.
├── main.tf                 # Infrastructure as Code (Terraform)
├── lambda_src/             # Directory for Lambda code and dependencies
│   ├── lambda_function.py  # Core Python logic
│   └── ...                 # Installed pip packages (e.g., redis)
└── README.md               # Project documentation

```

## Deployment Instructions

1. **Prepare the Lambda Code & Dependencies:**
Because AWS Lambda does not natively include the `redis` library, you must install it into the `lambda_src/` folder so Terraform can package it. Also place your lambda_function.py file in this folder.
```bash
mkdir -p lambda_src
pip install redis -t lambda_src/

```


2. **Authenticate with AWS:**
Ensure your terminal session has active AWS credentials.
```bash
export AWS_PROFILE="your-profile-name" # If using SSO/Profiles

```


3. **Initialize Terraform:**
Downloads the necessary AWS provider plugins.
```bash
terraform init

```


4. **Deploy the Infrastructure:**
Review the plan and type `yes` to provision the resources. *(Note: Provisioning the VPC and ElastiCache Serverless can take ~5-10 minutes).*
```bash
terraform apply -auto-approve

```


5. **Get your API Endpoint:**
After a successful deployment, Terraform will output your API Gateway URL.
```text
Outputs:
api_url = "https://<YOUR_API_ID>.execute-api.us-east-1.amazonaws.com"

```



## API Usage & Examples

*Replace `<YOUR_API_URL>` with the actual URL from your Terraform output.*

### 1. Create a Short URL (Auto-Generated)

Creates a new short URL and instantly writes it to both DynamoDB and Redis.

```bash
curl -X POST <YOUR_API_URL>/urls \
  -H "Content-Type: application/json" \
  -d '{"long_url": "[https://www.hellointerview.com](https://www.hellointerview.com)"}'

```

### 2. Create a Short URL with a Custom Alias

```bash
curl -X POST <YOUR_API_URL>/urls \
  -H "Content-Type: application/json" \
  -d '{
    "long_url": "[https://github.com](https://github.com)",
    "custom_alias": "my-repo"
  }'

```

### 3. Test the Redirect (Hits Redis)

Make a GET request to test the redirect. Because of our caching layer, the first request might pull from DynamoDB (or Redis if you just created it), but subsequent requests will fetch exclusively from ElastiCache!

```bash
curl -i <YOUR_API_URL>/my-repo

```

*Look for the `302 Found` status, the `Location:` header, and the custom `X-Cache: HIT-REDIS` header.*

## Cleanup

To avoid incurring future charges, destroy all AWS resources created by this project:

```bash
terraform destroy -auto-approve

```
