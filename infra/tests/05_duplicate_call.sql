\set ON_ERROR_STOP 1
\echo '== 05 a duplicate call does not double-write'
begin;
\ir _helpers.sql
\ir _fixture.sql

create temp table t_first as select * from actions.record_balance('james', 'test-checking', 120.50, '2026-11-09 09:00-05');
create temp table t_second as select * from actions.record_balance('james', 'test-checking', 120.50, '2026-11-09 09:00-05');

select pg_temp.check((select count(*) = 1 from ledger.balance_statements), 'the same record_balance twice writes one row');
select pg_temp.check((select t_first.id = t_second.id from t_first, t_second), 'the second call returns the first result');

select actions.record_balance('james', 'test-checking', 99.00, '2026-11-09 10:00-05');
select pg_temp.check((select count(*) = 2 from ledger.balance_statements), 'a different call does write');

select actions.log_life_event('james', '2026-08-01', 'Test event', 100.00, 'life/test.md');
select actions.log_life_event('james', '2026-08-01', 'Test event', 100.00, 'life/test.md');
select pg_temp.check((select count(*) = 1 from knowledge.life_events), 'the same log_life_event twice writes one row');

select actions.update_bill('james', 'test-phone', '{"amount": 41}', current_date);
select actions.update_bill('james', 'test-phone', '{"amount": 41}', current_date);
select pg_temp.check((select count(*) = 2 from ref.bills where bill_key = 'test-phone'), 'the same update_bill twice adds one version');

-- Calls older than 10 minutes don't count as duplicates.
update knowledge.action_calls set called_at = now() - interval '11 minutes' where action = 'record_balance';
select actions.record_balance('james', 'test-checking', 99.00, '2026-11-09 10:00-05');
select pg_temp.check((select count(*) = 3 from ledger.balance_statements), 'the same call after 10 minutes writes again');

-- Other validation.
select pg_temp.expect_error(null, $$select actions.record_balance('james', 'nope', 1)$$,
  '%no account%', 'record_balance refuses an unknown account');
select pg_temp.expect_error(null, $$select actions.record_balance('james', 'test-checking', 1, now() + interval '2 days')$$,
  '%future%', 'record_balance refuses a future date');
select pg_temp.expect_error(null, $$select actions.log_life_event('james', '2026-08-01', 'x', null, 'notes/x.md')$$,
  '%under life/%', 'log_life_event refuses a story file outside life/');

-- Questions.
create temp table t_q as select * from actions.log_question('katelyn', 'Test question?', 'test', 'new_context');
select actions.answer_question('james', (select id from t_q), 'Test answer');
select pg_temp.check((select status = 'answered' and answered_by = 'james' from knowledge.open_questions where id = (select id from t_q)),
  'answer_question answers');
select pg_temp.expect_error(null, $$select actions.answer_question('james', (select id from t_q), 'Another')$$,
  '%already answered%', 'a question cannot be answered twice');
select pg_temp.expect_error(null, $$select actions.log_question('james', 'q', null, 'gossip')$$,
  '%kind must be%', 'log_question refuses an unknown kind');
rollback;
