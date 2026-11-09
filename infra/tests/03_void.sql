\set ON_ERROR_STOP 1
\echo '== 03 confirming and voiding'
begin;
\ir _helpers.sql
\ir _fixture.sql

create temp table t_pay as
  select * from actions.confirm_match('james',
    (select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-1'), 'TEST PHONE CO');

select pg_temp.check((select amount = 40.00 and paid_on = '2026-11-03' and bill_key = 'test-phone' and entered_by = 'james' from t_pay),
  'confirm_match writes a payment from the transaction');
select pg_temp.check((select status = 'confirmed' from knowledge.proposed_matches where era_transaction_id = 'test-tx-1'),
  'the proposal is confirmed');
select pg_temp.check(exists (select 1 from ref.bill_aliases where bill_key = 'test-phone' and alias = 'TEST PHONE CO'),
  'the merchant name became an alias');

select pg_temp.expect_error(null, $$select actions.void_entry('james', 'payment', (select id from t_pay), '  ')$$,
  '%needs a reason%', 'a void without a reason is refused');

create temp table t_void as
  select * from actions.void_entry('james', 'payment', (select id from t_pay), 'Wrong bill');

select pg_temp.check((select count(*) = 1 from ledger.voids), 'a void adds a row');
select pg_temp.check((select count(*) = 1 from ledger.payments), 'the original payment is still there');
select pg_temp.check((select count(*) = 0 from ledger.payments_effective), 'the voided payment no longer counts');
select pg_temp.check((select status = 'rejected' from knowledge.proposed_matches where era_transaction_id = 'test-tx-1'),
  'voiding a confirmation rejects the pairing');
select pg_temp.expect_error(null, $$select actions.void_entry('james', 'payment', (select id from t_pay), 'Again')$$,
  '%already voided%', 'a row cannot be voided twice');

-- An ambiguous pair: confirming one closes the other.
select actions.confirm_match('katelyn',
  (select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-2' and bill_key = 'test-stream'));
select pg_temp.check((select status = 'rejected' from knowledge.proposed_matches where era_transaction_id = 'test-tx-2' and bill_key = 'test-other'),
  'confirming one of an ambiguous pair rejects the other');

-- A rejected pairing can never come back.
select pg_temp.expect_error(null,
  $$insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason) values ('test-tx-1', 'test-phone', '2026-11-01', 99, 'again')$$,
  '%duplicate key%', 'a rejected pairing cannot be proposed again');

-- Money in is never a payment.
select pg_temp.expect_error(null,
  $$select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-in'))$$,
  '%money in%', 'a deposit cannot be confirmed as a payment');

-- reject_match
select actions.reject_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-in'), 'Payroll');
select pg_temp.check((select status = 'rejected' and decided_by = 'james' from knowledge.proposed_matches where era_transaction_id = 'test-tx-in'),
  'reject_match rejects');
select pg_temp.expect_error(null,
  $$select actions.reject_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-in'))$$,
  '%already rejected%', 'a decided match cannot be rejected again');
rollback;
