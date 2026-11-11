\set ON_ERROR_STOP 1
\echo '== 15 a severed or replaced account keeps its history when Era sends nothing for it'
begin;
\ir _helpers.sql

insert into raw.era_accounts (era_account_id, payload, content_hash) values
  ('old-chk', '{"name": "Checking", "visibility": "connection_severed"}', 'h'),
  ('new-chk', '{"name": "Checking", "visibility": "visible"}', 'h'),
  ('cut-card', '{"name": "Card", "visibility": "connection_severed"}', 'h'),
  ('live-card', '{"name": "Card", "visibility": "visible"}', 'h'),
  ('repl-old', '{"name": "Old", "visibility": "visible"}', 'h');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('o-1', 'old-chk', '{}', 'h', -10, '2026-11-01', false, 'SHOP'),
  ('c-1', 'cut-card', '{}', 'h', -15, '2026-11-01', false, 'SHOP'),
  ('l-1', 'live-card', '{}', 'h', -20, '2026-11-01', false, 'SHOP'),
  ('r-1', 'repl-old', '{}', 'h', -25, '2026-11-01', false, 'SHOP');
insert into raw.era_account_replacements (old_era_account_id, new_era_account_id, cutover)
  values ('old-chk', 'new-chk', '2026-11-05'), ('repl-old', 'repl-new', '2026-11-05');

set local role ingest;
select raw.start_pull('nightly', '2026-10-12', '2026-11-11') as run1 \gset
-- Era sent nothing for any of them this run.
select pg_temp.check(raw.mark_removed(:run1, '2026-10-12', '2026-11-11',
  array['old-chk', 'new-chk', 'cut-card', 'live-card', 'repl-old']) = 1,
  'only the live, unreplaced account''s unseen row is marked removed');
select raw.finish_pull(:run1, 'ok', '{}', null);
reset role;

select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'o-1'),
  'a replaced, severed account keeps its row');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'c-1'),
  'a severed account with no replacement keeps its row');
select pg_temp.check((select removed_at is null from raw.era_transactions where era_transaction_id = 'r-1'),
  'a replaced account that still reads visible keeps its row');
select pg_temp.check((select removed_at is not null from raw.era_transactions where era_transaction_id = 'l-1'),
  'a live account''s row Era no longer sends is still marked removed');

rollback;
