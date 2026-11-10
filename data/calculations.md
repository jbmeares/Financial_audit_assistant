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

- **Rows.** There is one row for each bill in each due month, from the bill's first version to two months ahead. Quarterly, semiannual and annual bills count forward from their known due date.
- **Due dates.** A due day past the end of a short month moves to the month's last day, so the 31st becomes Feb 28.
- **Which version.** Each month uses the version of the bill in effect on its due date. If a due-day change leaves no version covering its own due date that month, the newest version is used, so the month doesn't vanish. A bill that ended has no cycles after it ends.
- **Status.**
  - `paid`: a ledger payment exists.
  - `pending_match`: a proposal is waiting.
  - `late`: the due month ended with neither a payment nor a proposal.
  - `not_seen_yet`: everything else.
- **Pending beats late.** A waiting proposal ranks above late, because the bill may already be paid and only need a yes.

## Matcher (`knowledge.proposed_matches`)

The matcher looks at money-out transactions from the last 45 days that aren't paired yet. It scores each current bill against each transaction, out of 100 *(proposed default)*:

| Points | When |
| --- | --- |
| 30 | It came from the bill's account |
| 40 | The amount is within tolerance: the bill's own, else $0.01 for fixed and 15% for variable |
| 20 | It falls between 7 days before and 7 days after the due month |
| 10 | The merchant or Era's description contains an alias, or Era tagged it `bill:<key or name>` |

- **Never a bill payment.** A transfer to another of the household's checking or savings accounts, a fee (the word "fee" in the description) and an interest charge are skipped. A card payment is a transfer to a card, so it is still matched.
- **What can be proposed.** All three must hold:
  - It falls inside the window of an unpaid cycle, and nearer that cycle's due date than the bill's previous one. A payment closer to the previous due date paid that one, so it is left alone even when the previous month isn't tracked.
  - It names the bill (alias or tag), or it is the exact amount from the bill's own account. Near the amount with no name is not enough.
  - If it names any bill, only the bills it names are considered. A Netflix charge is never proposed for another bill at the same price.
- **What gets proposed.** The best bill is proposed if it scores 70 or more. If two bills tie at the top, both are proposed as `ambiguous` (rule 5).
- **What never happens.**
  - A transaction with a proposal still waiting gets no new one.
  - A pairing a person rejected is never proposed again.
  - Nothing is confirmed automatically.
- **After a "no".** Once a proposal is rejected, the next-best bill can be proposed the following night.
- **Withdrawn proposals.** A proposal set to `rejected` with no person in `decided_by` was withdrawn by a build, not refused by a person. The matcher may propose that pairing again under the current rules. The proposals from the first real run were withdrawn this way on 2026-11-10, because the old rules made them.

## Cash projection (`calc.cash_projection`, `calc.account_balances`)

The projection covers 60 days, starting today, for each checking and savings account that has a balance.

- **Starting balance.** It starts from the newer of Era's latest balance and a stated one. A stated balance wins when it is as new or newer (rule 3). Checking and savings use Era's "available" figure when there is one. Cards and loans use "current".
- **Money in.** Each income source's pay dates are counted from its known pay date. Only pay dates after the starting balance's date count.
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
- `skip_bill`: `bill_key`, `due_month`.
- `one_off_expense`: `account_key`, `amount`, `on`, and optionally `label`.
- `income_change`: `income_key`, the new `amount` (0 means it stops), `from`.

It returns the following for each account, before and after the changes:

- the lowest balance and its date
- the first day below $0
- the end balance

It also returns payoff dates for any debt an extra payment touches. Payoff dates assume the minimum payment stays the same and that payments start next month, so they are estimates. A change, field or key it doesn't recognize is refused by name.

## Who can run what

- `ingest` runs `refresh_all()`.
- `assistant_read` runs `what_if()` and reads every `calc` table.
- The inner steps are open to no role.
