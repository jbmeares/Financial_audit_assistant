# Payday

Income just landed, or is about to. The question is usually "what does this paycheck need to cover?"

## Calls

1. `get_briefing` for bills due before the next income and the projection.
2. If the deposit amount or date differs from what's on file, note it and log an open question ([rule 6](../constitution.md)). Income sources are changed in Claude Code for v1.
3. For "can we afford…" or "what if we pay extra…", run `what_if` ([rule 2](../constitution.md)). Check `strategy/` for the plan it should respect.

## Say first

- On a Lincoln payday: Food, Fuel and fun money start fresh. Say what each has for the next two weeks (budget item).

- What this income has to cover before the next one, as one plain line with its as-of date ([rule 8](../constitution.md)).
- If the projection still goes below $0 before the next income, that's RED ([rule 11](../constitution.md)).

## Avoid

- Doing the math in prose ([rule 2](../constitution.md)).
- Judging last period's spending. Forward only ([rule 9](../constitution.md)).

## End with

One next action ([rule 10](../constitution.md)), e.g. which bill to pay first from this deposit.
