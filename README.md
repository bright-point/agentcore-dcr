# AWS BedrockAgentCore Dynamic Client Registration (DCR)

A complete OAuth 2.1 Dynamic Client Registration implementation for AWS BedrockAgentCore Gateway with Cognito.

## The Problem

AWS BedrockAgentCore Gateway supports OAuth authentication via `CUSTOM_JWT` authorizers, but:

1. **No documentation exists** for implementing Dynamic Client Registration (RFC 7591) with Cognito
2. **Cognito doesn't natively support DCR** - you need a custom implementation
3. **OAuth 2.1 clients expect auto-registration** - manual client creation doesn't work for modern flows
4. **Cognito quirks** (like client name character restrictions) cause silent failures
5. **Gateway AllowedClients** must be updated dynamically as new clients register

This repository provides a production-ready CloudFormation template that solves all these issues.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OAuth 2.1 Discovery Flow                             │
│                                                                              │
│  OAuth 2.1 Client (Claude Code, custom apps, etc.)                          │
│       │                                                                      │
│       │ 1. Discover protected resource                                      │
│       ▼                                                                      │
│  GET /.well-known/oauth-protected-resource (from Gateway)                   │
│       │                                                                      │
│       │ 2. Discover OAuth server                                             │
│       ▼                                                                      │
│  GET /.well-known/openid-configuration (from OAuth API)                     │
│       │                                                                      │
│       │ 3. Dynamic Client Registration                                       │
│       ▼                                                                      │
│  POST /register (DCR Lambda)                                                │
│       │  - Creates Cognito client                                            │
│       │  - Adds to Gateway AllowedClients                                    │
│       │  - Returns client_id + client_secret                                 │
│       │                                                                      │
│       │ 4. Authorization Code Flow with PKCE                                 │
│       ▼                                                                      │
│  Browser → Cognito Hosted UI → Callback                                     │
│       │                                                                      │
│       │ 5. Exchange code for tokens                                          │
│       ▼                                                                      │
│  POST /oauth2/token (Cognito)                                               │
│       │                                                                      │
│       │ 6. Access protected resources with JWT                               │
│       ▼                                                                      │
│  BedrockAgentCore Gateway → Lambda (your backend)                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Use Cases

This infrastructure enables OAuth 2.1 authentication for any BedrockAgentCore Gateway backend:

- **MCP Servers**: Claude Code CLI, custom MCP clients
- **REST APIs**: Any API requiring OAuth with BedrockAgentCore
- **Custom Applications**: Your own apps needing dynamic OAuth client registration
- **Multi-tenant Systems**: Each tenant automatically gets their own OAuth client

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate permissions
- SAM CLI installed
- An existing Cognito User Pool with a domain configured
- A Lambda function to protect with OAuth

### 1. Deploy the Stack

```bash
# Clone this repo
git clone https://github.com/stache-ai/agentcore-dcr.git
cd agentcore-dcr

# Deploy (you'll be prompted for parameters)
./scripts/deploy.sh
```

Required parameters:
- `COGNITO_USER_POOL_ID` - Your existing Cognito User Pool ID
- `COGNITO_DOMAIN` - Your Cognito domain (without https://)
- `MCP_LAMBDA_ARN` - ARN of your Lambda function (or any Lambda to protect)
- `RESOURCE_PREFIX` - Prefix for resources (default: `mcp`)
- `AWS_REGION` - AWS region (default: `us-east-1`)

### 2. Use with OAuth 2.1 Clients

#### Example: Claude Code MCP Server

```bash
claude mcp add --transport http my-server https://YOUR-GATEWAY-ID.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp
```

Then in Claude Code, run `/mcp` and click "Authenticate". The client will:
1. Discover OAuth endpoints automatically
2. Register itself via DCR
3. Open browser for Cognito authentication
4. Store tokens for future requests

#### Example: Custom Application

Any OAuth 2.1 client can use this infrastructure:

```python
# 1. Discover OAuth metadata
metadata = requests.get(f"{gateway_url}/.well-known/oauth-protected-resource").json()
auth_server = requests.get(metadata["authorization_servers"][0]).json()

# 2. Register client dynamically
registration = requests.post(auth_server["registration_endpoint"], json={
    "client_name": "My App",
    "redirect_uris": ["https://myapp.com/callback"],
    "grant_types": ["authorization_code"],
    "token_endpoint_auth_method": "client_secret_basic"
}).json()

# 3. Use standard OAuth 2.1 Authorization Code flow
# (client_id and client_secret from registration response)
```

## How It Works

### OAuth Discovery Chain

The infrastructure implements the full OAuth 2.1 protected resource discovery flow:

1. **Protected Resource Metadata**: Gateway serves `/.well-known/oauth-protected-resource` pointing to our OAuth API
2. **Authorization Server Metadata**: Our API serves `/.well-known/openid-configuration` with all OAuth endpoints
3. **Dynamic Client Registration**: The `/register` endpoint creates Cognito clients on-demand

### The DCR Lambda

The core innovation is a Lambda function that:

1. **Receives registration requests** conforming to RFC 7591
2. **Sanitizes client metadata** (Cognito has strict validation rules)
3. **Creates Cognito User Pool Client** with proper OAuth scopes and flows
4. **Automatically updates Gateway AllowedClients** (avoiding manual configuration)
5. **Returns RFC 7591 compliant credentials** (client_id, client_secret, etc.)

Key implementation details:

```python
# Cognito only allows [\w\s+=,.@-]+ in client names
# OAuth clients often send names with parentheses or other chars
client_name = re.sub(r'[^\w\s+=,.@-]', '-', requested_client_name)

# After creating client, dynamically update gateway
gateway_id = find_gateway_by_name(os.environ['GATEWAY_NAME'])
current_config = get_gateway(gateway_id)
current_config['allowedClients'].append(new_client_id)
update_gateway(gateway_id, current_config)
```

### Gateway Configuration

The BedrockAgentCore Gateway uses `CUSTOM_JWT` authorization with our OIDC endpoint as the discovery URL:

```yaml
AuthorizerConfiguration:
  CustomJWTAuthorizer:
    DiscoveryUrl: https://YOUR-API.execute-api.region.amazonaws.com/prod/.well-known/openid-configuration
    AllowedClients:
      - initial-client-id  # DCR adds more dynamically
```

## Key Files

| File | Purpose |
|------|---------|
| [template.yaml](template.yaml) | Complete CloudFormation/SAM template |
| [scripts/deploy.sh](scripts/deploy.sh) | One-command deployment script |
| [scripts/cleanup.sh](scripts/cleanup.sh) | Remove all resources |
| [docs/ARTICLE.md](docs/ARTICLE.md) | Deep-dive technical article |

## Gotchas We Discovered

### 1. Client Name Sanitization

**Problem**: OAuth clients send names like `My App (dev)`. Cognito rejects parentheses.

**Solution**: Server-side sanitization in DCR Lambda:
```python
client_name = re.sub(r'[^\w\s+=,.@-]', '-', raw_client_name)
```

### 2. Gateway AllowedClients Updates

**Problem**: DCR creates clients, but they can't authenticate because they're not in the gateway's AllowedClients.

**Solution**: DCR Lambda automatically updates the gateway configuration after creating each client.

### 3. iam:PassRole Permission

**Problem**: Updating a gateway fails with `AccessDeniedException: iam:PassRole`.

**Solution**: DCR Lambda role needs `iam:PassRole` for the gateway's execution role:
```yaml
- Effect: Allow
  Action: iam:PassRole
  Resource: !GetAtt AgentCoreGatewayRole.Arn
```

### 4. list_gateways API Response Format

**Problem**: Gateway lookup fails silently.

**Solution**: The API returns `items`, not `gateways`:
```python
# Wrong
for gw in page.get('gateways', []):

# Correct
for gw in page.get('items', []):
```

### 5. Circular CloudFormation Dependencies

**Problem**: DCR Lambda needs to reference the gateway, but gateway depends on the OAuth API that includes DCR.

**Solution**: Pass gateway name as environment variable, look it up at runtime:
```python
def find_gateway_by_name(name):
    paginator = agentcore.get_paginator('list_gateways')
    for page in paginator.paginate():
        for gw in page.get('items', []):
            if gw.get('name') == name:
                return gw.get('gatewayId')
```

## Customization

### Adding Custom OAuth Scopes

Edit the DCR Lambda and OIDC metadata to include your scopes:

```python
AllowedOAuthScopes=[
    'email', 'openid', 'profile',
    'your-resource/read', 'your-resource/write'
]
```

Update the OIDC configuration response:
```python
"scopes_supported": ["openid", "email", "profile", "your-resource/read"]
```

### Using with Different Backends

Replace the Lambda ARN in the gateway target configuration:

```yaml
MCPGatewayTarget:
  Properties:
    TargetConfiguration:
      LambdaTargetConfiguration:
        LambdaArn: !GetAtt YourBackendLambda.Arn
```

### Multi-Region Deployment

Deploy the stack in multiple regions and use Route53 for global endpoint:

```bash
AWS_REGION=us-west-2 ./scripts/deploy.sh
AWS_REGION=eu-west-1 ./scripts/deploy.sh
```

## Debugging

### Check DCR Lambda Logs

```bash
aws logs tail /aws/lambda/YOUR-PREFIX-dcr --follow
```

### Verify OAuth Discovery

```bash
# Gateway's protected resource metadata
curl https://YOUR-GATEWAY.gateway.bedrock-agentcore.region.amazonaws.com/.well-known/oauth-protected-resource

# Your OAuth server metadata
curl https://YOUR-API.execute-api.region.amazonaws.com/prod/.well-known/openid-configuration
```

### List Registered Clients

```bash
aws cognito-idp list-user-pool-clients \
  --user-pool-id YOUR-POOL-ID \
  --query 'UserPoolClients[*].[ClientName,ClientId]' \
  --output table
```

### Check Gateway AllowedClients

```bash
aws bedrock-agentcore-control get-gateway \
  --gateway-identifier YOUR-GATEWAY-ID \
  --query 'authorizerConfiguration.customJWTAuthorizer.allowedClients'
```

## Security Notes

PKCE is required for all authorization code flows. Consider adding API Gateway throttling on `/register` to prevent abuse.

## License

MIT License - see [LICENSE](LICENSE)
