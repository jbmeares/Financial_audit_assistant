# what_if

*Reads.* Re-runs the 60-day projection with changes and returns the difference from the normal projection: each account's lowest balance and its date, days below zero, and debt payoff dates that move.

**Takes** `changes`: one change or a list. Types:

| type | fields |
| --- | --- |
| `extra_payment` | `debt_key`, `amount`, `on`, `account_key`, optional `monthly` |
| `skip_bill` | `bill_key`, `due_month` (first of the month) |
| `one_off_expense` | `account_key`, `amount`, `on`, optional `label` |
| `income_change` | `income_key`, `amount`, `from` |

Keys come from the `ref.current_*` views (use `query`).

**When** "can we afford…", "what if we pay extra…". Then check the plan in `strategy/`.

**Guards** writes nothing. A change type or field it doesn't know is refused by name, never ignored. How it calculates: [data/calculations.md](../data/calculations.md).
