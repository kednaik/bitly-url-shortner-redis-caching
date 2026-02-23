import json
import os
import boto3
import string
import random
import redis
from botocore.exceptions import ClientError

# Initialize DynamoDB resource outside the handler for connection reuse
dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('TABLE_NAME')
table = dynamodb.Table(table_name)

# Initialize Redis (ElastiCache Serverless uses TLS/SSL by default)
redis_client = redis.Redis(
    host=os.environ.get('REDIS_HOST'),
    port=int(os.environ.get('REDIS_PORT', 6379)),
    ssl=True,
    decode_responses=True
)

def generate_short_code(length=6):
    """Generates a random 6-character string"""
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for _ in range(length))

def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")
    route_key = event.get('routeKey')
    
    try:
        # ---------------------------------------------------------
        # POST /urls - Create a new Short URL
        # ---------------------------------------------------------
        if route_key == "POST /urls":
            body = json.loads(event.get('body', '{}'))
            original_url = body.get('long_url')
            custom_alias = body.get('custom_alias')
            expiration_date = body.get('expiration_date')
            
            if not original_url:
                return {"statusCode": 400, "body": json.dumps({"error": "long_url is required"})}

            # Base item structure
            item = {'long_url': original_url}
            if expiration_date:
                item['expiration_date'] = int(expiration_date)

            # SCENARIO A: User provided a custom alias
            if custom_alias:
                item['short_code'] = custom_alias
                try:
                    table.put_item(
                        Item=item,
                        ConditionExpression='attribute_not_exists(short_code)'
                    )
                except ClientError as e:
                    # If the condition fails, the custom alias is already taken
                    if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                         return {
                             "statusCode": 409, 
                             "body": json.dumps({"error": f"Custom alias '{custom_alias}' is already in use."})
                         }
                    raise # Re-throw any other unexpected errors
                
                final_short_code = custom_alias

            # SCENARIO B: We need to auto-generate a short code
            else:
                max_retries = 5
                attempts = 0
                success = False
                
                while attempts < max_retries:
                    generated_code = generate_short_code()
                    item['short_code'] = generated_code
                    
                    try:
                        table.put_item(
                            Item=item,
                            ConditionExpression='attribute_not_exists(short_code)'
                        )
                        success = True
                        final_short_code = generated_code
                        break # Successfully saved, break out of the retry loop
                    
                    except ClientError as e:
                        # Collision detected! The generated code already exists.
                        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                            print(f"Collision detected for {generated_code}. Retrying...")
                            attempts += 1
                            continue # Loop around and generate a new code
                        raise 
                        
                # If we loop 5 times and still hit collisions, fail gracefully
                if not success:
                    return {
                        "statusCode": 500, 
                        "body": json.dumps({"error": "System is busy, could not generate a unique short code. Please try again."})
                    }

            # Construct the final URL and return
            host = event.get('headers', {}).get('host', 'bit.ly')
            short_url = f"https://{host}/{final_short_code}"

            # WRITE-THROUGH CACHE: Proactively save to Redis with a 1-hour TTL
            try:
                redis_client.setex(final_short_code, 3600, original_url)
            except Exception as e:
                print(f"Redis write error (non-fatal): {str(e)}")

            return {
                "statusCode": 201,
                "body": json.dumps({"short_url": short_url, "short_code": final_short_code})
            }

        # ---------------------------------------------------------
        # GET /{short_code} - Redirect to Original URL
        # ---------------------------------------------------------
        elif route_key == "GET /{short_code}":
            path_params = event.get('pathParameters', {})
            short_code = path_params.get('short_code')

            # 1. CACHE-ASIDE: Check Redis First
            try:
                cached_url = redis_client.get(short_code)
                if cached_url:
                    return {
                        "statusCode": 302,
                        "headers": {
                            "Location": cached_url,
                            "Cache-Control": "public, max-age=300",
                            "X-Cache": "HIT-REDIS"
                        }
                    }
            except Exception as e:
                print(f"Redis read error (falling back to DB): {str(e)}")

            response = table.get_item(Key={'short_code': short_code})
            item = response.get('Item')

            if not item:
                return {"statusCode": 404, "body": json.dumps({"error": "URL not found"})}
            
            # 3. Save the DB result to Redis for the next user
            try:
                redis_client.setex(short_code, 3600, long_url)
            except Exception as e:
                pass

            return {
                "statusCode": 302,
                "headers": {
                    "Location": item['long_url'],
                    "Cache-Control": "public, max-age=300" 
                }
            }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal Server Error"})}
    
    return {"statusCode": 404, "body": json.dumps({"error": "Route not found"})}