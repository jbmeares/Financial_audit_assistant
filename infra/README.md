# infra/

Code, kept apart from the words. Change it only in Claude Code, with James present (CLAUDE.md, "What lives where").

**Goes here**
- `migrations/`: SQL for the schema, roles and write functions. A migration that has been applied is never edited; a fix is a new migration.
- `tests/`: database tests. Run them with `infra/tests/run`.
- `functions/`: Supabase Edge Functions (`era-pull`, `finance-mcp`).
- `consent/`: the sign-in and consent page for the finance MCP, a static page hosted on Vercel (see `functions/finance-mcp/README.md`).
- `scripts/`: repo tooling, such as `check-map`.

**Doesn't go here**
- Keys, tokens or passwords. Those live in Supabase secrets or GitHub secrets, never in the repo.
- Household context. That goes in the word folders.

`read_context` never serves files from this folder.
