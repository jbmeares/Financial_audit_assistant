# Monthly review

The monthly clean-up. This is where percentages are fine ([rule 13](../constitution.md)).

## Steps

1. `get_briefing` for the month's bill statuses, open questions and key expiry dates.
2. Clear `inbox/`. Each file gets filed, becomes a folder with James's OK, or gets deleted with James's OK ([rule 24](../constitution.md), CLAUDE.md "When something doesn't fit").
3. Go through open questions. Answer what can be answered with `answer_question` ([rule 14](../constitution.md)).
4. Check key expiry dates. Anything within 30 days follows its key swap page in the runbooks (`infra/runbooks/`, which `read_context` can't open, so give James the link: https://github.com/jbmeares/financial_audit_assistant/tree/main/infra/runbooks).
5. Look at Era rules created this month (`create_era_rule` history).
6. Check for missing bills (below).
7. Pull Era's spending trends for context (below).
8. Any debt paid off this month gets celebrated: name it, the monthly room it frees, and the next target ([rule 12](../constitution.md)).

## Missing bills

Era spots charges that repeat. Some are bills or subscriptions we don't track yet.

1. Get Era's recurring list: `transactions__list_recurring_charges` on the Era Context connector. Without that connector, `query` `raw.era_recurring`, which is the same list as of the last nightly pull.
2. `query` the bill list (`ref.current_bills` and `ref.current_bill_aliases`).
3. Set aside every recurring charge that matches a bill or an alias. What's left is a candidate.
4. Skip any candidate a past review already settled. Check answered questions in `knowledge.open_questions` first ([rule 14](../constitution.md)).
5. Name the rest to James in one short list, by their names ([rule 13](../constitution.md)), and ask once which are bills. Era also flags everyday shopping that just happens to repeat, such as a grocery store or a restaurant. Say so, so nobody feels they have to explain each one.
6. For each one he calls a bill, follow [new-bill.md](new-bill.md). For each one he says isn't a bill, record that with `log_question` and `answer_question`, so the next review doesn't ask again. A new subscription he didn't know about is a YELLOW, said calmly ([rule 11](../constitution.md)).

Only James adds bills ([rule 20](../constitution.md)). With Katelyn, name the candidates and log them as an open question for James.

## Era spending trends

For context only. Era's numbers explain the month; they never decide anything.

- `insights__compare_spending_periods` for this month against last month, and `insights__analyze_spending` for where the money went.
- **Era counts card payments and transfers between our own accounts as spending.** Its totals run high. Say that every time you quote one, and prefer our own budget numbers (`calc.budget_status()`) when the two disagree ([rule 3](../constitution.md)).
- Describe changes by category and plan, never by person ([rule 19](../constitution.md)).

## Never use Era's forecast for warnings

Don't use `insights__forecast_spending` for any RED, YELLOW or "you'll run short" message. It is a run-rate guess with no balances, income or due dates, and it counts card payments and transfers as spending. Our own projection (`get_briefing`, `what_if`) decides every RED ([rule 11](../constitution.md)).

## Say first

- How the month went by category and plan, never by person ([rule 19](../constitution.md)).
- If the month was hard, check `life/` and life events first ([rule 23](../constitution.md)).

## End with

One next action for the coming month ([rule 10](../constitution.md)).
