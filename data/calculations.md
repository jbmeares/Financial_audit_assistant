# How the numbers are made

The `calc` tables are rebuilt by SQL, never edited and never worked out in prose (constitution rule 2). This file says what each step does and which defaults it uses. The SQL is in `infra/migrations/2026110917*`, with later changes in the migrations after them. Defaults marked *(proposed default)* come from the build spec and are safe to tune, because the matcher only ever proposes.

"Today" is the date in New York.

## The refresh

`calc.refresh_all()` runs after every nightly pull and after every named action. It runs these steps in order:

1. bill cycles
2. matcher
3. cash projection
4. debt snapshot
5. briefing

All five run as one unit. If any step fails, the whole unit is rolled back, so the numbers from the last good refresh stay exactly as they were. The failure is recorded in three places: `calc.refresh_runs`, the night's `raw.pull_runs` row, and a YELLOW item at the top of the briefing that says how old the numbers are. A failed refresh never undoes the action that called it.

## Bill cycles (`calc.bill_cycles`)

- **Rows.** There is one row for each bill on each due date, from the bill's first version to the end of the month two months ahead.
    - Monthly bills: one row a month.
    - Every-other-month, quarterly, semiannual and annual bills: one row in each month they fall in, counted from their known due date.
    - Weekly, biweekly and every-N-weeks bills: one row every 7, 14 or 7 × N days from their known due date (every 6 weeks is every 42 days).
    - Per-paycheck bills: one row on each pay date of their income source, after the pay date moves off a weekend or holiday.
- **Due dates.** A due day past the end of a short month moves to the month's last day, so the 31st becomes Feb 28.
- **Which version.** Each due date uses the version of the bill in effect on that date. If a due-day change leaves no version covering its own due date that month, the newest version is used, so the month doesn't vanish. A bill that ended has no cycles after it ends.
- **Status.**
  - `paid`: a ledger payment exists, for the same month (month-based bills) or the same due date (week-based and per-paycheck bills). Month-based bills pair by month so a later change of due day doesn't unpay a month.
  - `pending_match`: a proposal is waiting.
  - `late`: the due month ended with neither a payment nor a proposal. This holds for every cadence (rule 4).
  - `not_seen_yet`: everything else.
- **Pending beats late.** A waiting proposal ranks above late, because the bill may already be paid and only need a yes.

## Matcher (`knowledge.proposed_matches`)

The matcher looks at money-out transactions from the last 45 days that aren't paired yet. It scores each current bill against each transaction, out of 100 *(proposed default)*:

| Points | When |
| --- | --- |
| 30 | It came from the bill's account |
| 40 | The amount is within tolerance: the bill's own, else $0.01 for fixed and 15% for variable |
| 20 | It falls in the cycle's window: 7 days before to 7 days after the due month; for week-based and per-paycheck bills, the cycle's share of the days around its due date (weekly: 3 days either side; biweekly and per paycheck: 6 before to 7 after; every 6 weeks: 20 before to 21 after) |
| 10 | The merchant or Era's description contains an alias, or Era tagged it `bill:<key or name>` |

- **Never a bill payment.** A transfer to another of the household's checking or savings accounts, a fee (the word "fee" in the description) and an interest charge are skipped. A card payment is a transfer to a card, so it is still matched.
- **What can be proposed.** All three must hold:
  - It falls inside the window of an unpaid cycle. For month-based bills it must also be nearer that cycle's due date than the bill's previous one: a payment closer to the previous due date paid that one, so it is left alone even when the previous month isn't tracked. Week-based and per-paycheck windows don't overlap, so they need no such check.
  - It names the bill (alias or tag), or it is the exact amount from the bill's own account. Near the amount with no name is not enough.
  - If it names any bill, only the bills it names are considered. A Netflix charge is never proposed for another bill at the same price.
- **Which cycle.** The nearest due date among the cycles that qualify. For week-based and per-paycheck bills, a cycle that already has a proposal waiting is picked last. Each proposal records the due date it would pay.
- **What gets proposed.** The best bill is proposed if it scores 70 or more. If two bills tie at the top, both are proposed as `ambiguous` (rule 5).
- **What never happens.**
  - A transaction with a proposal still waiting gets no new one.
  - A pairing a person rejected is never proposed again.
  - Nothing is confirmed automatically.
- **After a "no".** Once a proposal is rejected, the next-best bill can be proposed the following night.
- **Charges Era drops.** Each run first withdraws any open proposal whose transaction Era no longer sends (`removed_at` set), such as a pending charge that posted under a new id or a copy on a replaced account. The posted copy is then proposed on its own. Removed transactions are never proposed.
- **Charges still pending at the bank.** A pending charge is proposed like any other, so the bill shows as matched and isn't projected a second time. It can't be confirmed until it posts, because a pending charge can vanish and post under a new id. The briefing's pending matches item marks these with `still_pending` and counts them apart from the ones ready for a yes or no.
- **Withdrawn proposals.** A proposal set to `rejected` with no person in `decided_by` was withdrawn by a build, not refused by a person. The matcher may propose that pairing again under the current rules. The proposals from the first real run were withdrawn this way on 2026-11-10, because the old rules made them.

## Cash projection (`calc.cash_projection`, `calc.account_balances`)

The projection covers 60 days, starting today, for each checking and savings account that has a balance.

- **Starting balance.** It starts from the newer of Era's latest balance and a stated one. A stated balance wins when it is as new or newer (rule 3). Checking and savings use Era's "available" figure when there is one. Cards and loans use "current".
- **Money in.** Each income source's pay dates are counted from its known pay date. Only pay dates after the starting balance's date count.
- **Pay dates.** A pay date on a weekend or a bank holiday moves to the bank business day before. Bank holidays are the Federal Reserve's: a fixed-date holiday on a Sunday is kept the Monday after, and one on a Saturday isn't moved. This also moves the next income in the briefing, and per-paycheck bills and transfers.
- **Transfers.** Each planned transfer (`ref.transfers`) leaves its from-account and arrives in its to-account on its dates. Like income, each side counts only on days after that account's starting balance, so a transfer already inside a balance isn't counted twice. Transfers aren't income: the briefing's next income ignores them.
- **Money out.** Bills that are `not_seen_yet` come out on their due dates, from the account they're paid from. One already past due this month comes out today.
- **Left out.**
  - Pending matches, because that money has already left.
  - Late bills from earlier months, which the briefing names instead.
  - Accounts with no balance, also named in the briefing.
- **Each day.** Every day records what moved (`detail`), so the briefing can say "goes below $0 Thursday when the phone bill comes out".

## Debt snapshot (`calc.debt_snapshot`)

Each debt shows the following:

- **Balance:** owed, as a positive number, using the same starting-balance rule as above.
- **From `ref.debts`:** the APR and minimum payment.
- **Estimated monthly interest:** balance × APR ÷ 12.
- **Also:** the promo end date and the payoff priority.

A debt with no balance is named in the briefing, never guessed.

## Briefing (`calc.briefing`)

The briefing is one row. It records the date it was built (`today`), when the last good pull finished (`numbers_as_of`), the next income date, an overall level, and a list of items, with RED items first. The levels follow rule 11.

| Item | Level |
| --- | --- |
| Overdraft before the next income | RED |
| Overdraft later in the 60 days, or with no income on file | YELLOW |
| Key expired / expiring within 30 days | RED / YELLOW |
| Last pull failed on the key (auth) / failed otherwise, partial, stuck, or no pull today | RED / YELLOW |
| Balances older than 3 days, accounts or debts with no balance | YELLOW |
| Late bills, pending matches, promo rate ending within 30 days | YELLOW |
| No income on file ("projection incomplete") | YELLOW |
| Next income, bills due before it (or in the next 14 days with no income), open questions | GREEN |

## What-if (`calc.what_if`)

`calc.what_if` is read-only. Postgres marks it STABLE, so it refuses any write. It takes one change or a list of changes:

- `extra_payment`: `debt_key`, `amount`, `on`, `account_key`, and optionally `monthly`.
- `skip_bill`: `bill_key`, `due_month`, and optionally `due_on` to skip one date of a bill due more than once a month.
- `one_off_expense`: `account_key`, `amount`, `on`, and optionally `label`.
- `income_change`: `income_key`, the new `amount` (0 means it stops), `from`.

It returns the following for each account, before and after the changes:

- the lowest balance and its date
- the first day below $0
- the end balance

It also returns payoff dates for any debt an extra payment touches. An `income_change` doesn't stop a per-paycheck transfer, and the notes say so. Payoff dates assume the minimum payment stays the same and that payments start next month, so they are estimates. A change, field or key it doesn't recognize is refused by name.

## Paycheck plan (`calc.paycheck_plan(today, days)`)

A function, not a table, so it is always worked out fresh from `ref` and the last refresh's bill cycles. One row per pay date, from each income source's latest pay date on or before today (`is_current`) through today + `days` (default 45).

- **What a paycheck funds** (`items`, in this order):
  - per-paycheck transfers on that income source (`ref.transfers`);
  - per-paycheck bills on that income source, with their status from `calc.bill_cycles`;
  - budget lines that reset on that income source's pay dates.
- **Left over.** The check, less transfers out of the deposit account, bills paid from the deposit account, and the paycheck budget lines. A bill paid from another account (Bill Pay) is listed with `counts: false` and isn't subtracted, because a transfer already funds that account.
- **Which version.** Pay dates come from the current income source, as in `budget_status`. Transfers and budget lines use the version in effect on the pay date, or today's for a pay date already past, so the current paycheck shows today's plan.
- **Left out.** Monthly budget lines (Shopping and the others), because nothing in the data ties them to one income source. [budget.md](../strategy/budget.md) says in words that VA funds them.

## Debt payoff plan (`calc.debt_payoff_plan(today, extra)`)

The debt plan as it stands ([debt-plan.md](../strategy/debt-plan.md)), worked out from `calc.debt_snapshot`. One row per current debt.

- **Plan order.** Debts with a promo end date first, soonest first. Then the highest APR. Ties go to the smaller balance, then the key *(proposed default)*. If a debt's `payoff_priority` disagrees with this order, the row's notes say so, and the written plan wins.
- **The monthly amount.** Every in-plan minimum plus the extra debt budget line (`extra-debt`), or `extra` when given. It never shrinks, so each paid-off minimum rolls into the next target.
- **Each month, from next month on** (this month's payments count as already planned, as in `what_if`):
  1. Interest is added: balance × APR ÷ 12. None is charged while a promo runs, through the promo end month *(assumption: deferred interest charged back at the end isn't modelled)*.
  2. Every debt gets its minimum.
  3. What's left goes to the first unpaid debt in plan order, then the next.
- **Each row** gives the payoff month, months to payoff, and total interest until then. `is_target` marks the current target. `promo_at_risk` means the payoff month ends after the promo end date. The steps are monthly, so a payoff in the promo's own month counts as at risk.
- **Listed but given no money**, with a note: a debt marked outside the plan (`ref.debts.in_payoff_plan` false, such as the loan from Katelyn's mom), a debt with no balance on file (never guessed), and a debt with nothing owed. Other notes: a stale balance, a $0 minimum, and a payoff past 50 years (reported as no date).
- **What it doesn't know.** It uses each debt's minimum from `ref.debts`, not a bill that pays more (for example a per-paycheck loan payment), and it doesn't check the cash floor. Payoff dates are estimates.

## Who can run what

- `ingest` runs `refresh_all()`.
- `assistant_read` runs `what_if()`, `budget_status()`, `paycheck_plan()` and `debt_payoff_plan()`, and reads every `calc` table.
- The inner steps are open to no role.
