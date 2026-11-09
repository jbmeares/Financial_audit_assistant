# finance-mcp

The finance MCP server (build spec, Block F). Right now it is the F0 spike: one `whoami` tool behind Supabase Auth's OAuth 2.1 server, to prove that claude.ai and Claude Code can sign in. It reads no finance data.

## How sign-in works

1. Claude calls the server with no token and gets a 401. The `WWW-Authenticate` header points to `/.well-known/oauth-protected-resource` on this function.
2. That metadata names the project's Supabase Auth (`/auth/v1`) as the sign-in server. Claude reads Supabase's discovery document and registers itself (dynamic client registration).
3. Supabase sends the browser to the consent page (`infra/consent/`, hosted on Vercel at the project's Site URL plus `/oauth/consent`). James signs in there and presses Allow.
4. Supabase gives Claude an access token and a refresh token. The server checks each token itself: signature against the project's public keys, issuer, audience, expiry, that it was issued to an OAuth client, and that the email is in `FINANCE_ALLOWED_EMAILS`.

It is deployed with `verify_jwt` off, because the platform check would answer with a bare 401 that Claude can't follow. The function does the check instead.

## Deploy

Deployed through the Supabase MCP (`deploy_edge_function`, name `finance-mcp`, `verify_jwt: false`). URL: `https://lbhrkwjffgbfvmpyjuai.supabase.co/functions/v1/finance-mcp`.

## Settings it needs (dashboard)

- **Authentication > URL Configuration**: Site URL is the consent page's host.
- **Authentication > OAuth Server**: on, Authorization Path `/oauth/consent`, dynamic client registration on.
- **Authentication > Sign In / Providers**: new sign-ups off. One user, created by hand.
- **Edge Functions > Secrets**: `FINANCE_ALLOWED_EMAILS`, comma-separated. Empty means nobody gets in.
