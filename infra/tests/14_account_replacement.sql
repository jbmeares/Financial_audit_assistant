\set ON_ERROR_STOP 1
\echo '== 14 a reconnected account: the old Era id hands over to the new one'
begin;
\ir _helpers.sql

-- Made-up accounts: 'old-chk' was replaced by 'new-chk' when the bank login was re-added.
-- The old account has posted rows through Nov 9; the new one sends the same days again.
insert into raw.era_accounts (era_account_id, payload, content_hash) values
  ('old-chk', '{"name": "Checking"}', 'h'), ('new-chk', '{"name": "Checking"}', 'h');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('o-1', 'old-chk', '{}', 'h', -10, '2026-11-08', false, 'SHOP'),
  ('o-2', 'old-chk', '{}', 'h', -20, '2026-11-09', false, 'SHOP');
insert into raw.era_account_replacements (old_era_account_id, new_era_account_id, cutover)
  values ('old-chk', 'new-chk', '2026-11-10');

set local role ingest;
select raw.start_pull('nightly', '2026-10-11', '2026-11-11') as run1 \gset
select pg_temp.check(raw.ingest_transactions(:run1, '[
  {"id":"n-1","account_id":"new-chk","amount":-10,"occurred_on":"2026-11-08","pending":false,"merchant":"SHOP","payload":{"v":1}},
  {"id":"n-2","account_id":"new-chk","amount":-20,"occurred_on":"2026-11-09","pending":false,"merchant":"SHOP","payload":{"v":1}},
  {"id":"n-3","account_id":"new-chk","amount":-30,"occurred_on":"2026-11-10","pending":false,"merchant":"SHOP","payload":{"v":1}}
]') = '{"new":3,"changed":0,"unchanged":0}'::jsonb, 'the new account''s rows are all stored');
select pg_temp.check((select count(*) from raw.era_transactions where era_account_id = 'new-chk' and removed_at is not null) = 2,
  'the new account''s rows before the cutover arrive removed');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'n-3'),
  'a row from the cutover on is kept');
select raw.finish_pull(:run1, 'ok', '{}', null);

-- The next night Era sends them again, one with a changed payload.
select raw.start_pull('nightly', '2026-10-12', '2026-11-12') as run2 \gset
select raw.ingest_transactions(:run2, '[
  {"id":"n-1","account_id":"new-chk","amount":-10,"occurred_on":"2026-11-08","pending":false,"merchant":"SHOP","payload":{"v":2}},
  {"id":"n-3","account_id":"new-chk","amount":-30,"occurred_on":"2026-11-10","pending":false,"merchant":"SHOP","payload":{"v":1}}
]');
select pg_temp.check((select removed_at is not null from raw.era_transactions where era_transaction_id = 'n-1'),
  'a covered row stays removed when Era sends it again');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'n-3'),
  'a row after the cutover stays kept');
select raw.finish_pull(:run2, 'ok', '{}', null);
reset role;

select pg_temp.check((select count(*) from raw.era_transactions where removed_at is null and occurred_on between '2026-11-08' and '2026-11-10') = 3,
  'each day counts once: old rows before the cutover, new rows from it');

-- An account with no replacement behaves as before: a removed row comes back when seen again.
update raw.era_transactions set removed_at = now() where era_transaction_id = 'o-1';
select raw.start_pull('manual', '2026-11-01', '2026-11-12') as run3 \gset
select raw.ingest_transactions(:run3, '[{"id":"o-1","account_id":"old-chk","amount":-10,"occurred_on":"2026-11-08","pending":false,"merchant":"SHOP","payload":{}}]');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'o-1'),
  'a row on an account nobody replaced comes back when Era sends it again');
select raw.finish_pull(:run3, 'ok', '{}', null);

rollback;
