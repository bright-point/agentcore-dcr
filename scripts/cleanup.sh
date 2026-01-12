#!/bin/bash
# Clean up Claude Code MCP OAuth infrastructure
#
# This script:
# 1. Deletes the CloudFormation stack
# 2. Waits for deletion to complete
# 3. Cleans up any orphaned Cognito clients created via DCR
#
# Usage:
#   ./scripts/cleanup.sh [stack-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${1:-mcp-oauth}"

echo ""
print_warning "=== Cleaning up Claude Code MCP OAuth ==="
echo ""
echo "  Stack:  $STACK_NAME"
echo "  Region: $AWS_REGION"
echo ""

read -p "Are you sure you want to delete this stack? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Check if stack exists
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    print_error "Stack '$STACK_NAME' not found"
    exit 1
fi

# Get gateway ID before deletion (may need to manually clean up if delete fails)
GATEWAY_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`GatewayId`].OutputValue' \
    --output text 2>/dev/null || echo "")

echo "Deleting stack..."
aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION"

echo "Waiting for deletion to complete..."
if aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" 2>/dev/null; then
    print_success "Stack deleted successfully"
else
    print_error "Stack deletion may have failed or timed out"
    echo ""
    echo "If the stack is stuck, you may need to manually delete:"
    echo "  1. Gateway target: aws bedrock-agentcore-control delete-gateway-target ..."
    echo "  2. Gateway: aws bedrock-agentcore-control delete-gateway --gateway-identifier $GATEWAY_ID"
    echo "  3. Retry stack deletion"
    exit 1
fi

# Optionally clean up DCR-created clients
echo ""
read -p "Clean up DCR-created Cognito clients? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Cognito User Pool ID: " USER_POOL_ID

    echo "Finding DCR clients..."
    DCR_CLIENTS=$(aws cognito-idp list-user-pool-clients \
        --user-pool-id "$USER_POOL_ID" \
        --region "$AWS_REGION" \
        --query "UserPoolClients[?contains(ClientName, 'Claude-Code') || contains(ClientName, 'dcr-client')].{Name:ClientName,Id:ClientId}" \
        --output json)

    if [[ "$DCR_CLIENTS" == "[]" ]]; then
        echo "No DCR clients found"
    else
        echo "Found DCR clients:"
        echo "$DCR_CLIENTS" | jq -r '.[] | "  \(.Name) (\(.Id))"'
        echo ""
        read -p "Delete these clients? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$DCR_CLIENTS" | jq -r '.[].Id' | while read -r client_id; do
                echo "Deleting $client_id..."
                aws cognito-idp delete-user-pool-client \
                    --user-pool-id "$USER_POOL_ID" \
                    --client-id "$client_id" \
                    --region "$AWS_REGION"
            done
            print_success "DCR clients deleted"
        fi
    fi
fi

echo ""
print_success "Cleanup complete"
