# query

*Reads.* Runs one SELECT against the database and returns the rows as JSON.

**Takes** `sql` (one `SELECT` or `WITH ... SELECT`), and optionally `limit` (1 to 500, default 500).

**Returns** `row_count`, `truncated` (true when there were more rows than the limit) and `rows`.

**When** for detail the briefing doesn't show: transactions, balances, bills, matches, life events, open questions. Also for any sum of more than two numbers or any date math ([rule 2](../constitution.md)). What each table means is in [data/schema.md](../data/schema.md). Always schema-qualify names (`raw.era_transactions`, `ref.current_bills`).

**Guards**
- Runs as `assistant_read`, which can read `raw`, `ref`, `ledger`, `knowledge` and `calc` and write nothing.
- Runs inside a read-only transaction with a 5-second limit.
- Exactly one statement, and it must be a SELECT. The text runs inside `mcp.run_query`, where Postgres refuses any attempt to switch role.
