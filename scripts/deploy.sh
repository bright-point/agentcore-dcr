#!/bin/bash
# Deploy Claude Code MCP OAuth infrastructure
#
# Prerequisites:
# - AWS CLI configured
# - SAM CLI installed
# - Existing Cognito User Pool with a domain configured
# - Existing MCP Lambda function
#
# Usage:
#   ./scripts/deploy.sh
#
# The script will prompt for required parameters or you can set environment variables:
#   COGNITO_USER_POOL_ID - Your Cognito User Pool ID
#   COGNITO_DOMAIN - Cognito domain (without https://)
#   MCP_LAMBDA_ARN - ARN of your MCP server Lambda
#   RESOURCE_PREFIX - Prefix for resources (default: mcp)
#   AWS_REGION - AWS region (default: us-east-1)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_info() { echo -e "${CYAN}$1${NC}"; }

# Check prerequisites
command -v aws >/dev/null 2>&1 || { print_error "AWS CLI is required"; exit 1; }
command -v sam >/dev/null 2>&1 || { print_error "SAM CLI is required"; exit 1; }

# Get parameters (from env or prompt)
AWS_REGION="${AWS_REGION:-us-east-1}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-mcp}"
STACK_NAME="${RESOURCE_PREFIX}-oauth"

if [[ -z "$COGNITO_USER_POOL_ID" ]]; then
    read -p "Cognito User Pool ID: " COGNITO_USER_POOL_ID
fi

if [[ -z "$COGNITO_DOMAIN" ]]; then
    read -p "Cognito Domain (without https://): " COGNITO_DOMAIN
fi

if [[ -z "$MCP_LAMBDA_ARN" ]]; then
    read -p "MCP Lambda ARN: " MCP_LAMBDA_ARN
fi

# Get User Pool ARN
COGNITO_USER_POOL_ARN="arn:aws:cognito-idp:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):userpool/${COGNITO_USER_POOL_ID}"

echo ""
print_info "=== Deploying Claude Code MCP OAuth ==="
echo ""
echo "  Stack:       $STACK_NAME"
echo "  Region:      $AWS_REGION"
echo "  User Pool:   $COGNITO_USER_POOL_ID"
echo "  Domain:      $COGNITO_DOMAIN"
echo "  Lambda:      $MCP_LAMBDA_ARN"
echo ""

# Build and deploy
cd "$PROJECT_ROOT"

print_info "Building..."
sam build --template-file template.yaml

print_info "Deploying..."
sam deploy \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ResourcePrefix="$RESOURCE_PREFIX" \
        CognitoUserPoolId="$COGNITO_USER_POOL_ID" \
        CognitoUserPoolArn="$COGNITO_USER_POOL_ARN" \
        CognitoDomain="$COGNITO_DOMAIN" \
        MCPLambdaArn="$MCP_LAMBDA_ARN" \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset

# Get outputs
echo ""
print_success "=== Deployment Complete ==="
echo ""

GATEWAY_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`GatewayUrl`].OutputValue' \
    --output text)

OAUTH_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`OAuthMetadataUrl`].OutputValue' \
    --output text)

echo "Gateway URL:  $GATEWAY_URL"
echo "OAuth URL:    $OAUTH_URL"
echo ""
print_info "Add to Claude Code:"
echo ""
echo "  claude mcp add --transport http my-server $GATEWAY_URL"
echo ""
echo "Then run '/mcp' and click Authenticate."
