# era-pull

The nightly Era pull (Block D). A Supabase Edge Function that reads Era's REST API with the
read key (`ERA_READ_KEY`) and writes the `raw` schema through the `raw.*` functions, as the
`ingest` role. Every run leaves a row in `raw.pull_runs`.

| File | What it does |
| --- | --- |
| `index.ts` | The entry point: modes, the database connection, the role switch |
| `pull.ts` | One run, step by step (D1), the nightly and full-load windows (D2) |
| `era.ts` | Era calls: 1.1 s apart, waits out 429s, retries 5xx, stops on 401 |
| `map.ts` | The only file that knows Era's field names. A missing field fails the run |
| `pull.test.ts` | Tests with Era and the database faked. Run `./test` (Node 22+) |

The SQL it calls is in `infra/migrations/20261109163152_pull_functions.sql`, tested by
`infra/tests/06_pull_functions.sql`. The schedule is `20261110140100_pull_schedule.sql`.

## Modes

POST a JSON body to the function:

- `{"mode": "nightly"}` from pg_cron at 04:00 and 05:00 UTC. Only the call in New York's
  midnight hour runs (D3). It re-reads the last 30 days, adds a balance row per account,
  replaces the recurring list, then runs `calc.refresh_all(run_id)`.
- `{"mode": "full"}` the history load. Walks back one month per run from the current month,
  as many months as fit in about 100 seconds, and stops after two empty months in a row.
  Call it again until it answers `"complete": true`. A failed month is retried next call.
- `{"mode": "manual"}` a nightly-style run now. Refused within 10 minutes of another run.
- `{"mode": "health"}` 200 when the last good nightly or manual pull is under 48 hours old,
  otherwise 503. The `pull-health` GitHub Action calls it daily (I1).

## What Era's API looks like (D0)

From Era's REST docs (era.app/docs/era-api, last updated Oct 8, 2026). The OpenAPI file at
`forge.era.app/api/openapi/public.json` could not be downloaded while this was built.

- Base `https://forge.era.app/api`, header `X-API-Key`. Reads need `banking:read`.
- `GET /banking/accounts` returns `{"accounts": [...]}`, keyed by `accountGroupKey`. No paging.
- `GET /banking/accounts/{accountGroupKey}/balance` returns `currentBalance`,
  `availableBalance`, `asOf`. A null balance means none reported, not zero.
- `GET /banking/transactions` with `fromDate`, `toDate`, `page`, `pageSize` (max 100),
  `includePending` (pending only for the last 7 days). Returns `{"transactions": [...],
  "pagination": {currentPage, pageSize, totalItems, totalPages}}`. All accounts unless
  `accountId` is given.
- `GET /banking/recurring` returns `{"items": [...]}` with `merchant`, `estimatedAmount`,
  `frequency`, `type`, `lastSeen`, `confidence`, and no id (the pull makes one).
- 429 carries `Retry-After` in seconds. 401 means no or bad key. Automate plan: 60 calls a minute.

The docs don't show the transaction object. `map.ts` reads the id from `groupKey` (the
`utgr_` key the docs use elsewhere), the account from `accountGroupKey`, the date from
`transactionDate`, `merchantName`, `isPending` and `amount`. Era's examples show money out as
negative, and `raw.era_transactions.amount` uses the same sign. Check these against the first
real load before trusting them (see the PR).

## Known gaps

- The function accepts any valid project JWT, including the public anon key the schedule uses.
  A trigger secret kept in Supabase Vault would be stronger. It needs a secret created in the
  dashboard, so it's left for James.
- Era has no "changed since" filter and no resync endpoint, so a stale bank connection shows
  only as an old balance `asOf`.
