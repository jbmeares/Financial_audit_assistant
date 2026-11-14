\set ON_ERROR_STOP 1
\echo '== 17 proposals on dropped and still-pending bank charges'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- The gym bill (60.00, due the 12th) shows up first as a pending charge.
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-gym-pending', 'era-chk', '{}', 'h', -60.00, '2026-02-09', true, 'GYMCO');

select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'pending' from knowledge.proposed_matches where era_transaction_id = 'tx-gym-pending' and bill_key = 'gym'),
  'a pending charge is still proposed');
select pg_temp.check((select status = 'pending_match' from calc.bill_cycles where bill_key = 'gym' and due_month = '2026-02-01'),
  'so the bill shows as matched, not due');
select pg_temp.check((select (m ->> 'still_pending')::boolean
                        from calc.briefing, jsonb_array_elements(items) i, jsonb_array_elements(i -> 'data' -> 'matches') m
                       where i ->> 'kind' = 'pending_matches' and m ->> 'bill_key' = 'gym'),
  'the briefing marks it still pending at the bank');
select pg_temp.check((select i ->> 'text' like '% waiting for a yes or no. 1 more is still pending at the bank and can be confirmed once posted.'
                        from calc.briefing, jsonb_array_elements(items) i where i ->> 'kind' = 'pending_matches'),
  'the briefing counts the pending one apart from the ones ready for a yes or no');

select pg_temp.expect_error(null,
  $$select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-gym-pending'))$$,
  '%still pending at the bank%', 'confirm_match refuses a charge that is still pending');
select pg_temp.check(not exists (select 1 from ledger.payments where era_transaction_id = 'tx-gym-pending'), 'and writes no payment');

-- Era drops the pending copy and sends the posted one under a new id.
update raw.era_transactions set removed_at = now() where era_transaction_id = 'tx-gym-pending';
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-gym-posted', 'era-chk', '{}', 'h', -60.00, '2026-02-09', false, 'GYMCO');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'rejected' and decided_by is null and decision_note like 'Withdrawn%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-gym-pending'),
  'the proposal on the dropped copy is withdrawn, not rejected by a person');
select pg_temp.check((select status = 'pending' from knowledge.proposed_matches where era_transaction_id = 'tx-gym-posted' and bill_key = 'gym'),
  'the posted copy is proposed instead');
select pg_temp.check((select count(*) = 1 from knowledge.proposed_matches where bill_key = 'gym' and status in ('pending', 'ambiguous')),
  'only one open proposal for the gym bill');
select pg_temp.check(not exists (select 1 from calc.briefing, jsonb_array_elements(items) i where i ->> 'text' like '%still pending at the bank%'),
  'the briefing no longer mentions a pending charge');

select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-gym-posted'));
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'gym' and due_month = '2026-02-01'),
  'confirming the posted copy pays the bill');

-- A pending charge that posts under the same id becomes confirmable.
update raw.era_transactions set pending = true where era_transaction_id = 'tx-power';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.expect_error(null,
  $$select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-power'))$$,
  '%still pending%', 'the power charge can''t be confirmed while pending');
update raw.era_transactions set pending = false where era_transaction_id = 'tx-power';
select pg_temp.check((select (actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-power'))).bill_key = 'power'),
  'once it posts under the same id, the same proposal confirms');

-- A person's no stays a person's no when Era later drops the transaction.
update raw.era_transactions set removed_at = now() where era_transaction_id = 'tx-rejected';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select decided_by = 'james' and decision_note is null from knowledge.proposed_matches where era_transaction_id = 'tx-rejected'),
  'a rejection by a person is left as it was');

rollback;
