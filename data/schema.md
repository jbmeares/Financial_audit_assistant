# Database guide

A plain-English map of the Supabase database. It describes structure only, never amounts (CLAUDE.md, "What lives where"). The SQL is in `infra/migrations/`.

## The layers

Each layer reads only from the layers above it, so a bad night of Era data can be thrown away and pulled again without touching anything a person confirmed.

| Schema | Holds | Written by |
| --- | --- | --- |
| `raw` | Exactly what Era sent | The nightly pull (`ingest`) |
| `ref` | What James or Katelyn told us is true | The interview, in Claude Code, and `update_bill` |
| `ledger` | Payments, stated balances, adjustments. Append-only | Named actions only |
| `knowledge` | Proposed matches, open questions, life events | The matcher proposes, actions decide |
| `calc` | Bill cycles, cash projection, debts, the briefing | SQL functions (Block E). Never edited |
| `actions` | The named write functions. No tables | Migrations only |
| `mcp` | `run_query`, which the MCP's `query` tool uses. No tables | Migrations only |

## raw

- **`pull_runs`**: one row per pull, with its kind (full, nightly, manual), status (running, ok, partial, failed), date window, counts and error. Only one pull can be running at a time. A missing or failed night shows up in the briefing.
- **`era_accounts`**, **`era_recurring`**: Era's records, kept as the full JSON Era sent. The recurring list is replaced whole on each pull.
- **`era_transactions`**: one row per Era transaction id, with the full JSON plus `amount` (negative is money out), `occurred_on`, `pending` and `merchant`. When Era stops returning a transaction, `removed_at` is set. Nothing is deleted.
- **`era_balances`**: a new row each pull (`current`, `available`, `as_of`), so history is kept.

The pull writes only through functions in `raw`: `start_pull` (takes the lock; a run stuck for 30 minutes is closed as failed), `ingest_accounts`, `ingest_balances`, `ingest_transactions` (upserts by Era id and counts new, changed and unchanged; an account Era didn't list gets a stub row with `{"unlisted": true}`), `mark_removed`, `replace_recurring` and `finish_pull` (merges its counts and error with anything the calc refresh wrote). `next_full_month` says which month the history load does next, and `is_midnight_eastern` decides which of the two nightly schedule times runs. The function is described in `infra/functions/era-pull/README.md`.

Claude's read role can read `raw` (to look up transactions and balances) but never write it.

## ref

Every row has `valid_from` and `valid_to`. A change closes the old row and adds a new one, so nothing is overwritten. Each thing has a short stable key (for example `phone`) shared by all its versions. The `current_*` views show the rows in effect today.

- **`people`**: `james`, `katelyn`.
- **`accounts`**: an Era account mapped to a name, an owner (a person or `joint`), a kind (checking, savings, card, loan, retirement, investment) and a role in words. `connection` says how it reaches us: `era` (it should come through Era; with no Era account yet, it's still to connect) or `manual` (tracked by hand: people tell us the balance). This is the running list of accounts that should be connected.
- **`bills`**: name, amount, fixed or variable, tolerance, the account it's paid from, autopay, and a schedule. A card bill also names the card it pays down (`pays_account_key`), so a payment into that card from any account can match it. The schedule is a cadence plus what that cadence needs:
    - `monthly`: a due day.
    - `every_other_month`, `quarterly`, `semiannual`, `annual`: a due day and one known due date.
    - `weekly`, `biweekly`: one known due date.
    - `every_n_weeks`: one known due date and how many weeks apart (`every_weeks`, for example 6).
    - `per_paycheck`: the income source (`income_key`) whose pay dates it falls on.

  Every other field except tolerance, note and `pays_account_key` is required. A field nobody knows becomes an open question, never a guess (rule 6).
- **`bill_aliases`**: names a bill shows up as in transactions.
- **`debts`**: the account, APR (percent), minimum payment, promo end date and payoff priority (1 goes first).
- **`income_sources`**: person, amount, cadence (monthly or biweekly), one known pay date to count from, and the deposit account. The known pay date is the scheduled one: a pay date on a weekend or bank holiday is paid the bank business day before.
- **`transfers`**: planned moves between the household's own accounts, such as Joint to Bill Pay each payday. Each has a from-account, a to-account, an amount and a schedule, with the same cadences as bills. They move money in the projection but are never bills and never matched.
- **`budget_lines`**: each spending line's name, amount, and period: `paycheck` (resets on each pay date of `income_key`) or `month` (resets on the 1st). `borrows_from` names the line it borrows from when it runs over (Shopping). `tracked` is false for an amount-only line, such as the extra debt payment. How the budget works: [strategy/budget.md](../strategy/budget.md).
- **`budget_rules`**: which transactions count against which line, by Era category, merchant (part of the name) and/or account. Every condition given must match, and the lowest `priority` number wins. A rule with no line means "counts against nothing" (used for Bill Pay).
- **`api_keys`**: each key's name, scope and expiry date. Never the key itself. `current_api_keys` adds `days_left`.

## ledger

Append-only. A trigger refuses every update, delete and truncate, even from the owner.

- **`payments`**: a bill is paid only when a row here says so (rule 4). Each has the bill, the month it covers, the due date it pays (`due_on`), amount, date, the Era transaction, and who confirmed it. Week-based and per-paycheck bills pair on the due date; the others pair on the month.
- **`balance_statements`**: a balance someone stated. It beats Era until Era reports a newer one (rule 3).
- **`adjustments`**: named in the design without detail. No action writes here yet.
- **`voids`**: cancels exactly one row above, with a reason. The original stays. The `*_effective` views leave voided rows out.

## knowledge

- **`proposed_matches`**: a transaction paired with a bill and a month, with a score and a reason. For a card bill the transaction can be the payment received on the card, so it matches whichever account sent it; only one side of a transfer is proposed. Status is pending, ambiguous (two bills tied), confirmed or rejected. A pairing can be proposed only once, so a rejected one never comes back.
- **`open_questions`**: a question for a person, or `new_context` parked from claude.ai to be filed in the repo later (rule 22).
- **`life_events`**: date, title, amount and the path of its story file in `life/`.
- **`action_calls`**: every named action and what it returned. It makes a repeated call harmless.
- **`tool_calls`**: every finance MCP tool call: the tool, the person, ok or error, and how long it took (F5).
- **`era_rule_previews`**: each `create_era_rule` preview: the exact rule, its summary, and whether it was sent, created or failed, with Era's answer. A preview expires after 30 minutes and can be sent once.

## calc

Rebuilt by `refresh_all()` after every pull and every named action. Never edited. How each number is made, and the defaults used, are in [calculations.md](calculations.md).

- **`bill_cycles`**: each bill on each due date, with its due month, cadence, expected amount and status (paid, pending match, not seen yet or late). Month-based bills have one a month; week-based and per-paycheck bills can have several.
- **`account_balances`**: the balance each account's numbers start from, whether it came from Era or a person, and whether it's older than 3 days.
- **`cash_projection`**: each checking and savings account for 60 days: opening, money in, money out, closing, below zero, and what moved that day.
- **`debt_snapshot`**: each debt's balance, APR, minimum, estimated monthly interest, promo end and payoff priority.
- **`briefing`**: one row: today's date, how old the numbers are, the next income, a level and a list of RED, YELLOW and GREEN items.
- **`connection_status`**: the connection list checked against what Era last sent. One row per current account, with a status: `ok` (data in the last 3 days), `stale` (Era lists it, but its data is older), `gone_from_era` (Era stopped listing it, or shows it disconnected or hidden), `to_connect`, `manual`, or `not_tracked` (Era has it, but `ref.accounts` doesn't). `era_archived` is Era's own flag: Era archives a connection after about 30 days with no new data, which takes it out of the main view in Era.
- **`budget_status(today)`** (a function): each budget line in the period that contains today, with spent, left, what other lines borrowed from it, and what's left after that. Default today is Eastern.
- **`budget_spending(from, to)`** (a function): each spending transaction between two dates and the budget line it counts against. Leaves out transfers, card and loan payments, money in, and anything that is or may be a bill payment.
- **`refresh_runs`**: every refresh, and whether it worked. A failed one keeps the previous numbers.

`what_if(changes)` is a read-only function on top of these.

## Named actions

The MCP's action tools call these and nothing else. Each one needs a person (`james` or `katelyn`), checks its input, writes in one transaction and returns the new row. Bad input is refused with a plain sentence and nothing is written. The same call again within 10 minutes returns the first result instead of writing twice.

| Action | What it does |
| --- | --- |
| `confirm_match` | Turns a proposed match into a payment, closes other proposals for that transaction, and can add the merchant name as an alias |
| `reject_match` | Dismisses a proposed match for good |
| `record_balance` | Logs a balance someone stated, then re-runs the numbers |
| `log_life_event` | Adds a dated event, with an optional amount and story file |
| `update_bill` | Changes a bill by closing the old row and adding a new one. Also creates a new bill, or ends one |
| `void_entry` | Voids a payment, balance statement or adjustment with a reason. Voiding a confirmed match also rejects that pairing |
| `log_question`, `answer_question` | Parks a question or new context, and answers it |
| `stage_era_rule`, `claim_era_rule`, `finish_era_rule` | The two steps of `create_era_rule`: store the previewed rule, claim it once for sending, record Era's answer |
| `log_tool_call` | Writes `knowledge.tool_calls` |

Changes to debts, income and key expiry dates are made in Claude Code for v1.

## Who can do what

| Role | Can | Used by |
| --- | --- | --- |
| `ingest` | Write `raw`, run `refresh_all()` | The nightly pull |
| `assistant_read` | Read `raw`, `ref`, `ledger`, `knowledge`, `calc`, run `what_if()` | Every conversation, through the MCP |
| `assistant_act` | Run the named actions, nothing else | The MCP's action tools |
| owner | Everything | Migrations, in Claude Code with James present |

Row security is on for every table. The public API roles get nothing. The three roles have no login. The finance MCP reaches them with `SET LOCAL ROLE` inside each tool's transaction (reads also run read-only). The MCP's `query` tool runs its SQL inside `mcp.run_query`, owned by `assistant_read`, where switching role is refused. Details: `infra/functions/finance-mcp/README.md`.

## Tests

`infra/tests/run` checks the rules above: the ledger refuses changes, each role can do only its job, a void adds a row, `update_bill` keeps the old row, and a duplicate call doesn't write twice. Files 06 to 09 check the calculations on made-up data: a normal month, a short month, a variable bill, a tie between two bills, a stated balance that beats Era, a month with no income, what-if, and a failed refresh. Every test rolls back, so it is safe to run against the live project. The `db-tests` GitHub Action runs them on every pull request that touches the migrations.
