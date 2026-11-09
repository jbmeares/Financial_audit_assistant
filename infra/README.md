# infra/

Code, kept apart from the words. Change it only in Claude Code, with James present (CLAUDE.md, "What lives where").

**Goes here**
- `migrations/`: SQL for the schema, roles and write functions. A migration that has been applied is never edited; a fix is a new migration.
- `tests/`: database tests.
- `functions/`: Supabase Edge Functions (`era-pull`, `finance-mcp`).
- `scripts/`: repo tooling, such as `check-map`.

**Doesn't go here**
- Keys, tokens or passwords. Those live in Supabase secrets or GitHub secrets, never in the repo.
- Household context. That goes in the word folders.

`read_context` never serves files from this folder.
