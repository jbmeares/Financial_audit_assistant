# Payday

Income just landed, or lands in the next two days. On payday James sits down and pays every bill he can for the whole stretch to the next income, not only the ones due that day (James, 2026-11-19). So the answer is one plan in one place, not bits spread across the reply.

## Calls

1. `get_briefing`. From two days before a pay date through the pay date it has a `payday_plan` item. Any other day, `query` `select calc.payday_plan()` when someone asks for it.
2. If the deposit amount or date differs from what's on file, note it and log an open question ([rule 6](../constitution.md)). Income sources are changed in Claude Code for v1.
3. For "can we afford…" or "what if we pay extra…", run `what_if` ([rule 2](../constitution.md)) and lay out the tradeoffs ([rule 26](../constitution.md)). Check `strategy/` for the plan it should respect.

## Say first

Anything RED, then the payday plan as one block, in this order. Every number comes from the item's `data` ([rule 1](../constitution.md)); don't add or subtract in prose ([rule 2](../constitution.md)).

1. **Money in.** Each income (`incomes`), its amount and account.
2. **Moves.** Each transfer (`transfers`): amount, from, to.
3. **The bills, one list.** Every bill in `bills`, in the order given: late ones first, then any past their due date, then by due date. One table with due date, bill, amount, manual or autopay, account, and that account's balance after it (`balance_after`). Manual bills are the ones to pay now; autopay ones just say "comes out on its own". Use "late" only when `late` is true ([rule 4](../constitution.md)); `past_due_date` is "past its due date".
4. **Set aside.** The paycheck budget lines (`set_asides`), such as Food and Fuel, with the balance after.
5. **What's left.** Each account's `left`. Paying early doesn't change where the stretch ends, so this is also its low point. If it's below $0 but inside the account's `overdraft_buffer`, say no fee is expected. Name anything in `later` that moves money mid-stretch.

On a Lincoln payday, say once that Food, Fuel and fun money start fresh (budget item).

While the plan is in the briefing, the "due before the next income" line is folded into it. Don't repeat those bills elsewhere in the reply.

## Avoid

- Splitting the plan across "tomorrow", "rest of the stretch" and "housekeeping" sections.
- Doing the math in prose ([rule 2](../constitution.md)).
- Judging last period's spending. Forward only ([rule 9](../constitution.md)).
- Pushing promo or extra-payment choices. Mention a promo deadline in one line if the briefing has it; run a what-if only if asked ([rule 26](../constitution.md)).

## End with

One next action ([rule 10](../constitution.md)): usually the first manual bill on the list.
