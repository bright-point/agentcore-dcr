# DCR Shim, Adapted for Your Knowledge Base

This is the `stache-ai/agentcore-dcr` template modified to work with your Bedrock Knowledge Base instead of a Lambda backend. Use `template-kb.yaml` in place of the original `template.yaml`.

## What this does

Creates a NEW AgentCore gateway that:
1. Points at your existing KB (`10SEIXTFFF`) as a Standard-retrieval target
2. Uses the shim's OAuth discovery endpoint (which advertises a registration endpoint), so Claude can auto-register (DCR)
3. Creates Cognito clients (via the DCR Lambda) that log in with **Google**, matching your Workspace federation

You will retire the hand-built `bp-client-transcripts-gateway` and use this new one instead. (Keep the old one until this is proven, then delete it.)

## What I changed from the original template

1. **Parameter swap:** removed `MCPLambdaArn`; added `KnowledgeBaseId` and `KnowledgeBaseArn`.
2. **Gateway IAM role:** changed from `lambda:InvokeFunction` to `bedrock:Retrieve` + `bedrock:RetrieveAndGenerate` on your KB ARN.
3. **Gateway target:** replaced `LambdaTargetConfiguration` with the KB connector target (`Mcp.Connector`, `ConnectorId: bedrock-knowledge-bases`, `Retrieve` configuration) and added the required `CredentialProviderConfigurations: GATEWAY_IAM_ROLE`.
4. **Identity provider:** changed both the InitialMCPClient AND the DCR Lambda's created clients from `SupportedIdentityProviders: [COGNITO]` to `[Google]`, so team members sign in with Google. Also added Claude's callback URL to the initial client.
5. **Scopes:** removed the custom `${prefix}/read` and `${prefix}/write` scopes everywhere (they require a resource server this template doesn't create and would cause client creation to fail). Left standard `openid email profile`.

## PREREQUISITES (confirm before deploying)

- **Google is configured as an IdP on your user pool** (`us-east-1_VwN22M4PX`). You already did this. The template's clients reference `Google` as an identity provider, so it must exist on the pool or deployment/registration will fail.
- **AWS CLI + SAM CLI available.** Easiest: use AWS CloudShell (both are pre-installed). Verify: `sam --version`.
- **Your KB ARN:** `arn:aws:bedrock:us-east-1:873315827816:knowledge-base/10SEIXTFFF`

## Deploy steps (from CloudShell or local)

1. Fork/clone the repo, then replace the template:
   ```bash
   git clone https://github.com/YOUR-ACCOUNT/agentcore-dcr.git
   cd agentcore-dcr
   # replace template.yaml with this adapted template-kb.yaml
   ```

2. Deploy with SAM (do NOT use their deploy.sh unprompted; run guided so you can pass the new params):
   ```bash
   sam deploy --guided \
     --template-file template-kb.yaml \
     --stack-name bp-dcr-kb \
     --capabilities CAPABILITY_NAMED_IAM
   ```

3. When prompted for parameters, provide:
   - `ResourcePrefix`: `bpkb` (keep it short/lowercase; it's used in resource names)
   - `CognitoUserPoolId`: `us-east-1_VwN22M4PX`
   - `CognitoUserPoolArn`: `arn:aws:cognito-idp:us-east-1:873315827816:userpool/us-east-1_VwN22M4PX`
   - `CognitoDomain`: `us-east-1vwn22m4px.auth.us-east-1.amazoncognito.com`
   - `KnowledgeBaseId`: `10SEIXTFFF`
   - `KnowledgeBaseArn`: `arn:aws:bedrock:us-east-1:873315827816:knowledge-base/10SEIXTFFF`

4. After deploy, note the stack Outputs, especially `GatewayUrl` (the new MCP endpoint).

## Test before connecting Claude

1. Verify the OIDC discovery doc now advertises a registration endpoint:
   ```bash
   curl https://<OAuthMetadataUrl>/.well-known/openid-configuration
   ```
   Confirm it includes a `registration_endpoint` field.

2. Verify DCR registration works:
   ```bash
   curl -X POST https://<OAuthMetadataUrl>/register \
     -H "Content-Type: application/json" \
     -d '{"client_name":"claude-test","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}'
   ```
   Should return a `client_id` and `client_secret`.

3. Confirm the created client uses Google: check in Cognito console that the new client's identity provider is Google (not Cognito directory).

## Connect Claude

1. Claude → Org settings → Connectors → Add custom connector
2. URL: the new `GatewayUrl` from the stack outputs
3. Leave Advanced settings' OAuth fields EMPTY, DCR auto-registers, that's the whole point
4. Connect → you should be sent to Google sign-in → done
5. Test a transcript query

## Known risks / things to watch

- **KB target CloudFormation syntax is newish.** The `Mcp.Connector` target structure is confirmed from AWS docs, but `AWS::BedrockAgentCore::GatewayTarget` is a preview resource. If CloudFormation rejects the `TargetConfiguration`, the fallback is to deploy the gateway WITHOUT the target via CFN, then add the KB target via the console's "Use with AgentCore Gateway" flow (which you've done successfully before) pointed at this new gateway.
- **Gateway `RoleArn` for KB targets:** the gateway role here trusts `bedrock.amazonaws.com`. If the gateway fails to assume it for KB retrieval, check the trust policy, KB connector targets may need `bedrock-agentcore.amazonaws.com` as an additional trusted principal.
- **The DCR-created client needs Claude's real callback.** The DCR Lambda sets `CallbackURLs=redirect_uris` from whatever Claude sends. Claude sends `https://claude.ai/api/mcp/auth_callback`, so this should be correct automatically, but if login redirect fails, confirm the created client's callback matches exactly.
- **This is still a preview AWS resource + community template.** Deploy to your account with eyes open; review the DCR Lambda code (it creates Cognito clients on demand).

## If CloudFormation fights you on the KB target

The single most likely failure point is step-3 target syntax, because it's a preview resource. If `sam deploy` errors on `MCPGatewayTarget`, comment out that whole resource, deploy just the gateway + DCR infrastructure, then attach your KB to the new gateway via the console (Bedrock KB → "Use with AgentCore Gateway" → "Add as target in existing Gateway", selecting this new DCR-enabled gateway). That gets you the DCR benefit without fighting preview CFN syntax.
