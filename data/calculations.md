# How the numbers are made

The `calc` tables are rebuilt by SQL, never edited and never worked out in prose (constitution rule 2). This file says what each step does and which defaults it uses. The SQL is in `infra/migrations/2026110917*` and `infra/migrations/2026111016*`. Defaults marked *(proposed default)* come from the build spec and are safe to tune, because the matcher only ever proposes.

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
| 10 | The merchant contains an alias, or Era tagged it `bill:<key or name>` |

- **Which cycle.** The nearest unpaid one, preferring one whose window holds the date. For week-based and per-paycheck bills, a cycle that already has a proposal waiting is picked last. Each proposal records the due date it would pay.
- **What gets proposed.** The best bill is proposed if it scores 70 or more. If two bills tie at the top, both are proposed as `ambiguous` (rule 5).
- **What never happens.**
  - A transaction with a proposal still waiting gets no new one.
  - A pairing that already exists, including a rejected one, is never proposed again.
  - Nothing is confirmed automatically.
- **After a "no".** Once a proposal is rejected, the next-best bill can be proposed the following night.

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

## Who can run what

- `ingest` runs `refresh_all()`.
- `assistant_read` runs `what_if()` and reads every `calc` table.
- The inner steps are open to no role.
