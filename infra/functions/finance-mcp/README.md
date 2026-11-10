# finance-mcp

The finance MCP server (build spec, Block F): the only way Claude reaches the numbers, from claude.ai (connector "Household finance") and Claude Code (`.mcp.json`). What each tool does is in [tools/](../../../tools/README.md). This file is how it's built.

## Files

| File | What it holds |
| --- | --- |
| `index.ts` | HTTP, sign-in checks, JSON-RPC, the call log |
| `tools.ts` | The 14 tools: their schemas, descriptions and handlers |
| `db.ts` | Database access and turning errors into one sentence |
| `context.ts` | `read_context` (GitHub) |
| `era.ts` | `create_era_rule` (Era REST) |
| `tools.test.ts`, `test` | Tests against a scratch Postgres built from the migrations. GitHub and Era are faked |

## How the database is reached (F3)

The function uses the `SUPABASE_DB_URL` every Edge Function gets. Each tool call is its own transaction, and switches role before any of its SQL runs:

- **read tools**: `BEGIN READ ONLY`, `SET LOCAL ROLE assistant_read`, 5-second limit;
- **action tools**: `BEGIN`, `SET LOCAL ROLE assistant_act`, 30-second limit (actions re-run the calculations). `assistant_act` can only run the named functions in `actions`.

All SQL in the code is fixed, with arguments bound as parameters. The one tool that takes SQL, `query`, passes it to `mcp.run_query`, a security definer function owned by `assistant_read`. Postgres refuses `SET ROLE` and `set_config('role', …)` inside such a function, so the text can't climb back to the connection's own role. The read-only transaction also blocks `pg_net` (its request queue is a table insert), so a query can't reach the internet.

This differs from the build spec's F3, which planned a separate login and password for each role. Edge Function secrets are entered by James in the dashboard, and the function is given `SUPABASE_DB_URL` anyway, so separate passwords would add a manual step without taking any right away from the function. The role switch per call gives the same separation inside the database.

## How sign-in works

1. Claude calls the server with no token and gets a 401. The `WWW-Authenticate` header points to `/.well-known/oauth-protected-resource` on this function.
2. That metadata names the project's Supabase Auth (`/auth/v1`) as the sign-in server. Claude reads Supabase's discovery document and registers itself (dynamic client registration).
3. Supabase sends the browser to the consent page (`infra/consent/`, hosted on Vercel at the project's Site URL plus `/oauth/consent`). James signs in there and presses Allow.
4. Supabase gives Claude an access token and a refresh token. The server checks each token itself: signature against the project's public keys, issuer, audience, expiry, that it was issued to an OAuth client, and that the email is in `FINANCE_ALLOWED_EMAILS`.

It is deployed with `verify_jwt` off, because the platform check would answer with a bare 401 that Claude can't follow. The function does the check instead.

## Secrets it reads

| Secret | Used by | Set |
| --- | --- | --- |
| `FINANCE_ALLOWED_EMAILS` | sign-in | yes (F0) |
| `ERA_READ_KEY` | `create_era_rule` preview | yes (task 11) |
| `ERA_WRITE_KEY` | `create_era_rule` create, nothing else | yes (task 11) |
| `GITHUB_CONTEXT_TOKEN` | `read_context` | build spec A5 (James) |
| `FINANCE_CONTEXT_REPO`, `FINANCE_CONTEXT_REF` | `read_context`, optional | defaults `jbmeares/financial_audit_assistant`, `main` |

## Deploy

Through the Supabase MCP (`deploy_edge_function`, name `finance-mcp`, `verify_jwt: false`, every `.ts` file except the test plus `deno.json`, `import_map_path: deno.json`). URL: `https://lbhrkwjffgbfvmpyjuai.supabase.co/functions/v1/finance-mcp`.

## Test

```bash
ADMIN_URL=postgresql://supabase_admin@localhost:5432/postgres infra/functions/finance-mcp/test
```

It rebuilds the local `finance_test` database (and runs `infra/tests`), then runs every tool against it. The `finance-mcp-tests` GitHub Action runs the same on each pull request.

## Settings it needs (dashboard)

- **Authentication > URL Configuration**: Site URL is the consent page's host.
- **Authentication > OAuth Server**: on, Authorization Path `/oauth/consent`, dynamic client registration on.
- **Authentication > Sign In / Providers**: new sign-ups off. One user, created by hand.
- **Edge Functions > Secrets**: the table above.
