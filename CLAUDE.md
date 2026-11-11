# Household finance: start here

This repo explains the household's money. The numbers live in Supabase and are reached only through the finance MCP. The words live here. Read this file first, then only what the conversation needs.

## Start of every session

1. **Who's talking?** Unless it's already clear, ask. Then read `people/<name>.md`.
2. **Rules.** Read `constitution.md` once per session. It is short and always applies.
3. **Today's picture.** Call `get_briefing`. Open with anything RED, then one line on what's due before the next income, then one line on what the budget has left.
4. **Go deeper only when asked.** Pull the files below as the conversation needs them.

On claude.ai you can't open these files directly. Use `read_context("<path>")`, which returns the same file.

## Where to look

| When the conversation is about | Read or call |
| --- | --- |
| What's due, what's paid, cash right now | `get_briefing`, then `query` for detail |
| What's left to spend, the budget, a line running over | Budget item in `get_briefing`, `query` on `calc.budget_status()`, and `strategy/budget.md` |
| "Can we afford…", "what if we pay extra…" | `what_if`, then `strategy/` for the plan it should respect |
| A transaction that might be a bill | Pending matches in the briefing, then `confirm_match` or `reject_match` |
| A balance someone just told you | `record_balance` |
| A bill that changed or is new | `update_bill`, plus `playbooks/new-bill.md` |
| A hard time, a loss, a windfall | `life/`, and constitution Part 2 before typing |
| Debt plan, goals, what "on track" means | `strategy/` |
| A routine conversation (payday, weekly check-in, statement upload) | `playbooks/` |
| What a tool does or when to use it | `tools/` |
| What a table or column means | `data/schema.md` |
| A key expiring or rejected, or a backup to restore | `infra/runbooks/` (on claude.ai, give James the GitHub link in its README; `read_context` can't open `infra/`) |

## What lives where

- **Supabase**: amounts, dates, transactions, the ledger and projections. Never copy a number from the database into a repo file.
- **This repo**: who the people are, what happened and why, the plan, and how to talk about it.
- **Era**: bank connections and transaction cleanup (rules, tags). Reached by the nightly pull and the `create_era_rule` action.
- **`infra/`**: migrations, functions, and runbooks for swapping keys and restoring the backup (`infra/runbooks/`). Change these only in Claude Code, with James present.

## Editing this repo

- Change it in Claude Code only, and commit with a one-line message saying what changed and why.
- Keep each file to one subject. If a file grows past a screen or two, split it.
- Don't duplicate. If a fact is in another file, link to it.
- New life context goes in `life/`, with a matching `log_life_event` for the date and amount.

## When something doesn't fit

The folders below are a starting point, not a fence. When a new topic comes up:

1. **Try the existing folders first.** Read each folder's `README.md`, which states what belongs there and what doesn't. If the topic fits one, file it there.
2. **If nothing fits, use `inbox/`.** Write a dated file, e.g. `inbox/2026-11-06-kids-college.md`. Start it with one line on what it is and why it didn't fit anywhere. Never create a new top-level folder on your own.
3. **Propose a folder once a topic repeats.** When three or more inbox files share a topic, or James asks, propose a new folder. Give it a name, a one-line purpose and the files that would move. Create it only after he agrees.
4. **Register it, or it doesn't exist.** A new folder needs three things in the same commit:
    - a `README.md` (purpose, what goes in, what doesn't)
    - a row in "Where to look" above
    - a line in the folder list below

   A folder missing from this file is invisible to future sessions.
5. **Split from the inside.** When a file or folder outgrows a screen or two, split it into a subfolder with its own `README.md`, and update the links.
6. **Numbers aren't a folder.** If the new topic is mostly amounts or dates, it needs a database table instead. Log it as an open question for a build session.
7. **On claude.ai, park it.** The repo is read-only there. Log a new topic as an open question ("new context: …"), and file it in the next Claude Code session.

Clear out `inbox/` during the monthly review. Each file either gets filed, becomes a folder, or gets deleted with James's OK.

## Folders

```text
CLAUDE.md          this map
constitution.md    the rules
people/            one profile per person, built by interview
life/              what happened and why it mattered
strategy/          goals, the budget and the debt plan
playbooks/         repeatable conversations
tools/             MCP tool reference
data/schema.md     plain-English guide to the database
inbox/             anything that doesn't fit yet, dated, cleared monthly
infra/             migrations, era-pull, finance-mcp, runbooks
```

Every folder has a `README.md` stating its scope. Add new folders here when they're created (see "When something doesn't fit").
