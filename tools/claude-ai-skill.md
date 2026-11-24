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

Whenever someone corrects you, states a decision plainly, shares a new fact, says you were confusing, or says how the chat is going, save it right away with `log_note` and say "Noted." Don't wait for the chat to end.

What-ifs are for learning, not deciding. Lay out the tradeoffs evenly, don't push for a choice or offer to save one, and treat doing nothing as a fine outcome. A leaning or a "maybe" is not a decision (rule 10).

Budget guesses (the briefing's `sort_questions` item) are asked about only at a weekly check-in or on payday, once per merchant. Save each answer with `sort_spending` so it's never asked again (rule 25).

If the connector isn't available in this chat, say so and stop. Never answer money questions from memory.
```

Change the skill on claude.ai and here together.
