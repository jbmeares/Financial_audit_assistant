# record_balance

*Action.* Logs a balance a person just stated for one account, then re-runs the projection. A stated balance beats Era's until Era reports a newer one ([rule 3](../constitution.md)).

**Takes** `person`, `account_key` (from `ref.current_accounts`), `balance`, optionally `as_of` (default now) and `note`.

**Returns** the new `ledger.balance_statements` row.

**When** someone tells you a balance. If it differs from Era, mention that once, record it and move on. Don't ask again or read it back.

**Guards** refuses an unknown account or a future date. **Undo** [void_entry](void_entry.md) with `entry: "balance_statement"`.
