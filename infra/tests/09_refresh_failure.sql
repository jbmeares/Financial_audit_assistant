\set ON_ERROR_STOP 1
\echo '== 09 a failed refresh keeps yesterday''s numbers'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

select calc.refresh_all(null, '2026-02-10');
create temp table good as
  select (select closing from calc.cash_projection where account_key = 'chk' and day = '2026-02-28') as feb28,
         (select count(*) from knowledge.proposed_matches) as matches,
         (select count(*) from calc.bill_cycles) as cycles,
         (select items from calc.briefing) as items;

-- Tonight's pull is running. Something changes, then the debt step fails.
insert into raw.pull_runs (kind, status, started_at) values ('nightly', 'running', now());
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-gym', 'era-chk', '{}', 'h', -60.00, '2026-02-10', false, 'GYM');
update ref.bills set amount = 700.00 where bill_key = 'rent';
set local calc.fail_step = 'debt_snapshot';
create temp table result as
  select calc.refresh_all((select id from raw.pull_runs where status = 'running'), '2026-02-10') as r;

select pg_temp.check((select r ->> 'ok' = 'false' and r ->> 'step' = 'debt_snapshot' from result), 'the refresh reports the failed step');
select pg_temp.check((select closing = good.feb28 from calc.cash_projection, good where account_key = 'chk' and day = '2026-02-28'),
  'the projection keeps yesterday''s numbers');
select pg_temp.check((select count(*) from knowledge.proposed_matches) = (select matches from good), 'the matcher''s new proposals were rolled back');
select pg_temp.check((select count(*) from calc.bill_cycles) = (select cycles from good), 'bill cycles were left alone');
select pg_temp.check((select level = 'YELLOW' and items -> 0 ->> 'kind' = 'refresh_failed' and items -> 0 ->> 'text' like '%these numbers are from%'
                        from calc.briefing), 'the briefing says its numbers are from the last good refresh');
select pg_temp.check((select error like '%calc refresh failed in debt_snapshot%' from raw.pull_runs where status = 'running'),
  'the error is recorded on the night''s pull_runs row');
select pg_temp.check((select ok = false and error like 'debt_snapshot:%' from calc.refresh_runs order by id desc limit 1),
  'and in calc.refresh_runs');

-- Failing twice doesn't stack notices.
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select count(*) = 1 from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'refresh_failed'),
  'a second failure leaves one notice, not two');

-- The next good refresh clears it and picks up the changes.
set local calc.fail_step = '';
select pg_temp.check((calc.refresh_all((select id from raw.pull_runs where status = 'running'), '2026-02-10') ->> 'ok')::boolean, 'the next refresh succeeds');
select pg_temp.check(not exists (select 1 from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'refresh_failed'),
  'the notice is gone');
select pg_temp.check((select money_out = 700.00 from calc.cash_projection where account_key = 'chk' and day = '2026-02-28'), 'the new rent amount is in');
select pg_temp.check((select counts ? 'calc' from raw.pull_runs where status = 'running'), 'the pull row gets the refresh counts');

-- A failure in a named action's refresh doesn't undo the action.
set local calc.fail_step = 'briefing';
select actions.log_question('james', 'Test question?');
select actions.record_balance('james', 'sav', 900.00, '2026-02-10 10:00-05');
select pg_temp.check(exists (select 1 from ledger.balance_statements where account_key = 'sav' and balance = 900.00),
  'record_balance still writes when the refresh after it fails');

-- The very first refresh failing still leaves a briefing that says so.
delete from calc.briefing;
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select level = 'YELLOW' and items -> 0 ->> 'kind' = 'refresh_failed' and items -> 0 ->> 'text' like '%no earlier refresh%' from calc.briefing),
  'with no earlier numbers, the briefing says there are none');
rollback;
