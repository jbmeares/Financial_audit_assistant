\set ON_ERROR_STOP 1
\echo '== 02 each role can do only its job'
begin;
\ir _helpers.sql
\ir _fixture.sql

-- assistant_read can read, but not write.
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from ref.current_bills$$)::int = 3,
  'assistant_read reads ref views');
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from knowledge.proposed_matches$$)::int = 4,
  'assistant_read reads knowledge');
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from calc.briefing$$)::int = 0,
  'assistant_read reads calc');
select pg_temp.expect_error('assistant_read', $$insert into ledger.payments (bill_key, due_month, amount, paid_on, entered_by) values ('test-phone', '2026-11-01', 1, '2026-11-01', 'james')$$,
  '%permission denied%', 'assistant_read cannot insert into the ledger');
select pg_temp.expect_error('assistant_read', $$update ref.bills set amount = 1$$,
  '%permission denied%', 'assistant_read cannot update ref');
select pg_temp.expect_error('assistant_read', $$delete from knowledge.proposed_matches$$,
  '%permission denied%', 'assistant_read cannot delete from knowledge');
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from raw.era_transactions$$)::int = 3,
  'assistant_read reads raw transactions');
select pg_temp.expect_error('assistant_read', $$insert into raw.pull_runs (kind) values ('manual')$$,
  '%permission denied%', 'assistant_read cannot insert into raw');
select pg_temp.expect_error('assistant_read', $$update raw.era_transactions set amount = 0$$,
  '%permission denied%', 'assistant_read cannot update raw');
select pg_temp.expect_error('assistant_read', $$delete from raw.era_balances$$,
  '%permission denied%', 'assistant_read cannot delete from raw');
select pg_temp.expect_error('assistant_read', $$select actions.log_question('james', 'q')$$,
  '%permission denied%', 'assistant_read cannot run actions');

-- assistant_act can run actions, and nothing else.
select pg_temp.check(pg_temp.as_role('assistant_act', $$select (actions.log_question('james', 'Role test question')).id$$) is not null,
  'assistant_act runs an action');
select pg_temp.expect_error('assistant_act', $$select count(*) from ref.bills$$,
  '%permission denied%', 'assistant_act cannot read tables');
select pg_temp.expect_error('assistant_act', $$insert into knowledge.open_questions (question, asked_for) values ('x', 'james')$$,
  '%permission denied%', 'assistant_act cannot write tables directly');
select pg_temp.expect_error('assistant_act', $$select actions._log_call('x', 'james', '{}', '{}')$$,
  '%permission denied%', 'assistant_act cannot run the internal helpers');

-- ingest writes raw only.
select pg_temp.check(pg_temp.as_role('ingest', $$insert into raw.pull_runs (kind) values ('nightly') returning id$$) is not null,
  'ingest writes raw');
select pg_temp.expect_error('ingest', $$insert into raw.pull_runs (kind) values ('nightly')$$,
  '%pull_runs_one_running%', 'a second running pull is refused (the lock)');
select pg_temp.expect_error('ingest', $$select count(*) from ref.bills$$,
  '%permission denied%', 'ingest cannot read ref');
select pg_temp.expect_error('ingest', $$insert into ledger.payments (bill_key, due_month, amount, paid_on, entered_by) values ('test-phone', '2026-11-01', 1, '2026-11-01', 'james')$$,
  '%permission denied%', 'ingest cannot write the ledger');

-- The public API roles get nothing.
select pg_temp.expect_error('anon', $$select count(*) from calc.briefing$$,
  '%permission denied%', 'anon cannot read calc');
select pg_temp.expect_error('authenticated', $$select count(*) from ref.bills$$,
  '%permission denied%', 'authenticated cannot read ref');
select pg_temp.expect_error('authenticated', $$select actions.log_question('james', 'q')$$,
  '%permission denied%', 'authenticated cannot run actions');

-- Row security is on for every table.
select pg_temp.check(not exists (
  select 1 from pg_tables
  where schemaname in ('raw', 'ref', 'ledger', 'knowledge', 'calc') and not rowsecurity
), 'row security is on for every table');
rollback;
