# The claude.ai skill

On claude.ai the connector alone doesn't start the routine: a plain "hi" got no tool calls (test 1, 2026-11-14). A small claude.ai skill, `household-finance`, starts it. Open a chat with a money phrase such as "finance check-in" so the skill loads.

The skill lives in James's claude.ai skills. This is its text, kept here so it isn't lost:

```markdown
---
name: household-finance
description: Use for any conversation about James and Katelyn's household money: bills, balances, debts, budget, paydays, or a check-in. Starts the Household finance connector routine.
---

# Household finance

James and Katelyn share this Claude account. Both may see all household numbers and advice.

All the rules and context live behind the Household finance connector. This skill only starts it.

## Start, before anything else

1. Ask who you're talking to (James or Katelyn), unless they've said. The sign-in is always James's account, so `whoami` doesn't tell you who's typing.
2. Call the Household finance connector:
   - `read_context("CLAUDE.md")`
   - `read_context("constitution.md")`
   - `read_context("people/<name>.md")`
   - `get_briefing`
3. Open with anything RED, then one line on what's due before the next income.

After that, follow CLAUDE.md and the constitution. Every number comes from a tool result or from what a person said.

If the connector isn't available in this chat, say so and stop. Never answer money questions from memory.
```

Change the skill on claude.ai and here together.
