-- C2. raw: exactly what Era sent. Upserted by the nightly pull, never edited by hand.
-- Each table keeps the full Era payload. The typed columns (amount, dates) are filled by
-- the pull from that payload so later layers don't have to parse JSON.

create table raw.pull_runs (
  id            bigint generated always as identity primary key,
  kind          text not null check (kind in ('full', 'nightly', 'manual')),
  status        text not null default 'running' check (status in ('running', 'ok', 'partial', 'failed')),
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  window_start  date,
  window_end    date,
  counts        jsonb not null default '{}'::jsonb,
  error         text,
  check (window_end is null or window_start is null or window_end >= window_start),
  check ((status = 'running') = (finished_at is null))
);
comment on table raw.pull_runs is 'One row per pull. A missing or failed row shows up in the briefing.';

-- The lock: only one pull can be running at a time.
create unique index pull_runs_one_running on raw.pull_runs ((true)) where status = 'running';

create table raw.era_accounts (
  era_account_id  text primary key,
  payload         jsonb not null,
  content_hash    text not null,
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  last_pull_run_id bigint references raw.pull_runs (id)
);

create table raw.era_transactions (
  era_transaction_id text primary key,
  era_account_id     text not null references raw.era_accounts (era_account_id),
  payload            jsonb not null,
  content_hash       text not null,
  amount             numeric(12, 2),
  occurred_on        date,
  pending            boolean,
  merchant           text,
  first_seen_at      timestamptz not null default now(),
  last_seen_at       timestamptz not null default now(),
  removed_at         timestamptz,
  last_pull_run_id   bigint references raw.pull_runs (id)
);
comment on column raw.era_transactions.amount is 'Normalized by the pull: negative is money out, positive is money in.';
comment on column raw.era_transactions.removed_at is 'Set when Era stops returning a transaction (a pending one that posted under a new id). Rows are never deleted.';

create index era_transactions_account_date on raw.era_transactions (era_account_id, occurred_on);
create index era_transactions_date on raw.era_transactions (occurred_on);

create table raw.era_balances (
  id              bigint generated always as identity primary key,
  era_account_id  text not null references raw.era_accounts (era_account_id),
  current         numeric(12, 2),
  available       numeric(12, 2),
  as_of           timestamptz,
  pulled_at       timestamptz not null default now(),
  payload         jsonb not null,
  pull_run_id     bigint references raw.pull_runs (id)
);
comment on table raw.era_balances is 'A new row on every pull, so balance history is kept.';

create index era_balances_account_asof on raw.era_balances (era_account_id, as_of desc);

create table raw.era_recurring (
  era_recurring_id text primary key,
  era_account_id   text,
  payload          jsonb not null,
  pulled_at        timestamptz not null default now(),
  pull_run_id      bigint references raw.pull_runs (id)
);
comment on table raw.era_recurring is 'Era''s recurring list. Replaced as a whole snapshot on each pull.';
