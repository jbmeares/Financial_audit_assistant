\set ON_ERROR_STOP 1
\echo '== 06 the pull''s write functions, run as ingest'
begin;
\ir _helpers.sql

-- Everything below runs as ingest, the role the era-pull function uses.
set local role ingest;

-- The lock.
select raw.start_pull('nightly', '2026-10-10', '2026-11-09') as run1 \gset
select pg_temp.check(:run1 is not null, 'start_pull opens a run');
reset role;
select pg_temp.expect_error('ingest', $$select raw.start_pull('manual')$$,
  '%another pull is already running%', 'a second run is refused while one is running');
set local role ingest;

-- Accounts and balances.
select pg_temp.check(raw.ingest_accounts(:run1, '[{"id":"t-chk","payload":{"name":"Test checking"}},{"id":"t-card","payload":{"name":"Test card"}}]') = 2,
  'ingest_accounts upserts accounts');
select pg_temp.check(raw.ingest_balances(:run1, '[{"account_id":"t-chk","current":10.5,"available":9,"as_of":"2026-11-09T12:00:00Z","payload":{}}]') = 1,
  'ingest_balances adds a balance row');

-- Transactions: two new, one of them pending, one from an account Era didn't list.
select pg_temp.check(raw.ingest_transactions(:run1, '[
  {"id":"t-1","account_id":"t-chk","amount":-12.34,"occurred_on":"2026-11-01","pending":false,"merchant":"TEST SHOP","payload":{"v":1}},
  {"id":"t-p","account_id":"t-chk","amount":-5,"occurred_on":"2026-11-08","pending":true,"merchant":"TEST CAFE","payload":{"v":1}},
  {"id":"t-x","account_id":"t-hidden","amount":3,"occurred_on":"2026-11-02","pending":false,"merchant":null,"payload":{"v":1}}
]') = '{"new":3,"changed":0,"unchanged":0}'::jsonb, 'ingest_transactions reports three new');
select pg_temp.check((select payload->>'unlisted' from raw.era_accounts where era_account_id = 't-hidden') = 'true',
  'an unlisted account gets a stub row');
select pg_temp.check((select amount from raw.era_transactions where era_transaction_id = 't-1') = -12.34,
  'amount is stored with its sign');
select pg_temp.check(raw.mark_removed(:run1, '2026-10-10', '2026-11-09', array['t-chk', 't-hidden']) = 0,
  'nothing is removed when everything was seen');
select pg_temp.check(raw.replace_recurring(:run1, '[{"id":"rec_a","account_id":null,"payload":{}},{"id":"rec_b","account_id":null,"payload":{}}]') = 2,
  'replace_recurring loads the snapshot');
select raw.finish_pull(:run1, 'ok', '{"transactions_seen":3}', null);
select pg_temp.check((select status from raw.pull_runs where id = :run1) = 'ok', 'finish_pull closes the run');

-- The next night: t-1 changed, t-p posted under a new id, t-x unchanged.
select raw.start_pull('nightly', '2026-10-11', '2026-11-10') as run2 \gset
select pg_temp.check(raw.ingest_transactions(:run2, '[
  {"id":"t-1","account_id":"t-chk","amount":-12.34,"occurred_on":"2026-11-01","pending":false,"merchant":"TEST SHOP INC","payload":{"v":2}},
  {"id":"t-p2","account_id":"t-chk","amount":-5.5,"occurred_on":"2026-11-09","pending":false,"merchant":"TEST CAFE","payload":{"v":1}},
  {"id":"t-x","account_id":"t-hidden","amount":3,"occurred_on":"2026-11-02","pending":false,"merchant":null,"payload":{"v":1}}
]') = '{"new":1,"changed":1,"unchanged":1}'::jsonb, 'the second night sees one new, one changed, one unchanged');
select pg_temp.check((select merchant from raw.era_transactions where era_transaction_id = 't-1') = 'TEST SHOP INC',
  'a changed transaction gets the new values');
select pg_temp.check(raw.mark_removed(:run2, '2026-10-11', '2026-11-10', array['t-chk', 't-hidden']) = 1,
  'the vanished pending transaction is marked removed');
select pg_temp.check((select removed_at is not null from raw.era_transactions where era_transaction_id = 't-p'),
  'removed_at is set, and the row is kept');
select pg_temp.check(raw.replace_recurring(:run2, '[{"id":"rec_c","account_id":null,"payload":{}}]') = 1,
  'replace_recurring loads the new snapshot');
select pg_temp.check((select count(*) from raw.era_recurring) = 1, 'recurring is replaced whole');
select raw.finish_pull(:run2, 'partial', '{}', 'no balance for: Test card');

-- A transaction that comes back clears removed_at.
select raw.start_pull('manual') as run3 \gset
select raw.ingest_transactions(:run3, '[{"id":"t-p","account_id":"t-chk","amount":-5,"occurred_on":"2026-11-08","pending":true,"merchant":"TEST CAFE","payload":{"v":1}}]');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 't-p'),
  'a transaction that reappears is no longer marked removed');
select raw.finish_pull(:run3, 'ok', '{}', null);

-- The full load walks back a month at a time and stops after two empty months.
select pg_temp.check(raw.next_full_month() = date_trunc('month', now() at time zone 'America/New_York')::date,
  'the full load starts with the current month');
insert into raw.pull_runs (kind, status, finished_at, window_start, window_end, counts) values
  ('full', 'ok', now(), '2026-11-01', '2026-11-30', '{"transactions_seen":40}'),
  ('full', 'ok', now(), '2026-10-01', '2026-10-31', '{"transactions_seen":35}'),
  ('full', 'failed', now(), '2026-09-01', '2026-09-30', '{}');
select pg_temp.check(raw.next_full_month() = '2026-09-01', 'a failed month is tried again');
insert into raw.pull_runs (kind, status, finished_at, window_start, window_end, counts) values
  ('full', 'ok', now(), '2026-09-01', '2026-09-30', '{"transactions_seen":0}');
select pg_temp.check(raw.next_full_month() = '2026-08-01', 'one empty month is not the end');
select pg_temp.check(raw.next_full_month('2026-08-15') is null, 'the floor stops the walk');
insert into raw.pull_runs (kind, status, finished_at, window_start, window_end, counts) values
  ('full', 'ok', now(), '2026-08-01', '2026-08-31', '{"transactions_seen":0}');
select pg_temp.check(raw.next_full_month() is null, 'two empty months in a row end the load');
select pg_temp.check(raw.next_full_month(p_after := now() + interval '1 second') = date_trunc('month', now() at time zone 'America/New_York')::date,
  'a restart ignores earlier full runs and starts from the current month');

-- Midnight in New York, across daylight saving.
select pg_temp.check(raw.is_midnight_eastern('2026-07-01 04:30+00'), '04:30 UTC is midnight in summer');
select pg_temp.check(not raw.is_midnight_eastern('2026-07-01 05:30+00'), '05:30 UTC is not midnight in summer');
select pg_temp.check(raw.is_midnight_eastern('2026-12-01 05:30+00'), '05:30 UTC is midnight in winter');
select pg_temp.check(not raw.is_midnight_eastern('2026-12-01 04:30+00'), '04:30 UTC is not midnight in winter');

reset role;

-- A run cut off mid-way doesn't block the next one forever.
select raw.start_pull('nightly') as stuck \gset
update raw.pull_runs set started_at = now() - interval '1 hour' where id = :stuck;
select pg_temp.check(pg_temp.as_role('ingest', $$select raw.start_pull('nightly')$$) is not null,
  'a run stuck for over 30 minutes is closed as failed and a new one starts');
select pg_temp.check((select status = 'failed' and error like 'abandoned%' from raw.pull_runs where id = :stuck),
  'the stuck run says it was abandoned');

-- Other roles can't run the pull functions.
select pg_temp.expect_error('assistant_read', $$select raw.start_pull('manual')$$, '%permission denied%',
  'assistant_read cannot start a pull');
select pg_temp.expect_error('anon', $$select raw.next_full_month()$$, '%permission denied%',
  'anon cannot run the pull functions');

rollback;
