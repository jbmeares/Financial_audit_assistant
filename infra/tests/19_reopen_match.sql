\set ON_ERROR_STOP 1
\echo '== 19 reopen_match takes back a mistaken rejection'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

select calc.refresh_all(null, '2026-02-10');
select actions.reject_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-phone' and status in ('pending', 'ambiguous') order by id limit 1), 'misread');

select pg_temp.expect_error(null,
  $$select actions.reopen_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-phone' and decided_by = 'james' and decision_note = 'misread'), ' ')$$,
  '%needs a reason%', 'reopening needs a reason');

select pg_temp.check((select (actions.reopen_match('james',
                        (select id from knowledge.proposed_matches where era_transaction_id = 'tx-phone' and decision_note = 'misread'),
                        'James meant yes')).status = 'pending'),
  'a rejected match goes back to pending');
select pg_temp.check((select decision_note like 'Reopened by james on %: James meant yes. Was rejected by james on % (misread).'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-phone' and decision_note like 'Reopened%'),
  'the note keeps the rejection on record');
select pg_temp.check(exists (select 1 from knowledge.action_calls where action = 'reject_match') and exists (select 1 from knowledge.action_calls where action = 'reopen_match'),
  'and both calls are in the call log');
select pg_temp.check((select (actions.confirm_match('james', (select id from knowledge.proposed_matches where decision_note like 'Reopened%'))).amount = 40.00),
  'the reopened match confirms');

-- A match whose transaction is now open for another bill can't come back alongside it.
select actions.reject_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-stream' and status = 'ambiguous' order by id limit 1), 'wrong one');
select pg_temp.expect_error(null,
  $$select actions.reopen_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-stream' and decision_note = 'wrong one'), 'x')$$,
  '%already matched or paid%', 'it won''t reopen while the transaction is open for another bill');

select pg_temp.expect_error(null,
  $$select actions.reopen_match('james', (select id from knowledge.proposed_matches where status = 'confirmed' limit 1), 'x')$$,
  '%not rejected by a person%', 'a confirmed match can''t be reopened');

-- A withdrawn proposal (rejected by nobody) isn't the person's rejection.
update knowledge.proposed_matches set status = 'rejected', decided_by = null, decided_at = now()
 where id = (select id from knowledge.proposed_matches where status = 'pending' limit 1);
select pg_temp.expect_error(null,
  $$select actions.reopen_match('james', (select id from knowledge.proposed_matches where status = 'rejected' and decided_by is null limit 1), 'x')$$,
  '%withdrawn by a build%', 'a withdrawn proposal isn''t reopened by hand');

rollback;
