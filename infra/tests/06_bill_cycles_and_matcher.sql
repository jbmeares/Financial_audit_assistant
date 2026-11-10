\set ON_ERROR_STOP 1
\echo '== 06 bill cycles and the matcher'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

select pg_temp.check((calc.refresh_all(null, '2026-02-10') ->> 'ok')::boolean, 'the refresh succeeds');

-- Bill cycles: one row per bill per due month, from the start to two months ahead.
select pg_temp.check((select min(due_month) = '2026-01-01' and max(due_month) = '2026-04-01' from calc.bill_cycles where bill_key = 'phone'),
  'cycles run from the bill''s start to two months ahead');
select pg_temp.check((select count(*) = 4 from calc.bill_cycles where bill_key = 'phone'), 'one cycle per month');
select pg_temp.check((select due_on = '2026-02-28' from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-02-01'),
  'short month: a due day of 31 moves to Feb 28');
select pg_temp.check((select due_on = '2026-03-31' from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-03-01'),
  'a 31-day month keeps the 31st');
select pg_temp.check((select array_agg(due_month order by due_month) = array['2026-01-01', '2026-04-01']::date[]
                        from calc.bill_cycles where bill_key = 'insurance'), 'a quarterly bill falls due every third month from its anchor');

-- Status.
select pg_temp.check((select status = 'paid' and payment_id is not null from calc.bill_cycles where bill_key = 'phone' and due_month = '2026-01-01'),
  'paid: a ledger payment exists');
select pg_temp.check((select status = 'late' from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-01-01'),
  'late: January ended with no payment');
select pg_temp.check((select status = 'not_seen_yet' from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-02-01'),
  'not seen yet: the month isn''t over');
select pg_temp.check((select status = 'not_seen_yet' from calc.bill_cycles where bill_key = 'gym' and due_month = '2026-02-01'),
  'a bill due in two days is not seen yet');
select pg_temp.check((select status = 'pending_match' and proposed_match_id is not null from calc.bill_cycles where bill_key = 'phone' and due_month = '2026-02-01'),
  'pending match: a proposal from this refresh is waiting');

-- The matcher.
select pg_temp.check((select score = 100 and status = 'pending' and due_month = '2026-02-01'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-phone' and bill_key = 'phone'),
  'normal month: account, amount, date and alias give 100');
select pg_temp.check((select score = 100 and status = 'pending' from knowledge.proposed_matches where era_transaction_id = 'tx-power' and bill_key = 'power'),
  'variable bill: 112.40 is within 15% of 100');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id in ('tx-fee', 'tx-interest', 'tx-transfer')),
  'fees, interest charges and transfers between own accounts are never proposed');
select pg_temp.check(calc._not_a_bill_reason('{"description": "Capital One", "transferLink": {"counterpartAccountGroupKey": "era-card"}}', '2026-02-10') is null,
  'a payment to a card is still a bill payment');
select pg_temp.check(calc._not_a_bill_reason('{"description": "Hollywood Feed"}', '2026-02-10') is null
                     and calc._not_a_bill_reason('{"description": "Overdraft Fee"}', '2026-02-10') = 'fee',
  'fee means the word fee');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-near'),
  'near a variable bill''s amount with no name is not proposed');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-named-other'),
  'a charge that names one bill is never proposed for another');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-early'),
  'a payment outside every unpaid cycle''s window is not proposed');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-shop'),
  'a charge outside the tolerance is not proposed');
select pg_temp.check((select count(*) = 2 and bool_and(status = 'ambiguous') from knowledge.proposed_matches where era_transaction_id = 'tx-stream'),
  'a tie between two bills proposes both as ambiguous');
select pg_temp.check((select count(*) = 1 from knowledge.proposed_matches where era_transaction_id = 'tx-rejected'),
  'a rejected pairing never comes back, and nothing weaker replaces it');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id in ('tx-old', 'tx-pay', 'tx-phone-jan')),
  'older than 45 days, money in, and already-paid transactions are skipped');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where status = 'confirmed'),
  'nothing is confirmed automatically');

-- Era tags count toward the name score, under either key.
select pg_temp.check(calc._tx_tags('{"appliedTags": [{"name": "Bill:Phone"}], "tags": ["x"]}') = array['x', 'bill:phone'],
  'tags are read from tags and appliedTags, as strings or objects');

-- Running again proposes nothing new.
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select count(*) = 5 from knowledge.proposed_matches), 'a second refresh adds no duplicate proposals');

-- Confirming the phone match marks February paid. Rejecting one stream frees the other.
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-phone'));
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'phone' and due_month = '2026-02-01'),
  'after confirm_match the cycle is paid');
select actions.reject_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-stream' and bill_key = 'stream-b'));
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'not_seen_yet' from calc.bill_cycles where bill_key = 'stream-b' and due_month = '2026-02-01'),
  'after a rejection the cycle goes back to not seen yet');
select pg_temp.check((select status = 'pending_match' from calc.bill_cycles where bill_key = 'stream-a' and due_month = '2026-02-01'),
  'the other tied bill still waits for a yes');

-- A bill that changed mid-month uses the version in effect on its due date.
select actions.update_bill('james', 'rent', '{"amount": 650.00}', '2026-02-20');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select expected_amount = 650.00 from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-02-01'),
  'a change on Feb 20 applies to the Feb 28 due date');
select actions.update_bill('james', 'gym', '{"amount": 70.00}', '2026-02-13');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select expected_amount = 60.00 from calc.bill_cycles where bill_key = 'gym' and due_month = '2026-02-01'),
  'a change on Feb 13 doesn''t touch the Feb 12 due date');
select pg_temp.check((select expected_amount = 70.00 from calc.bill_cycles where bill_key = 'gym' and due_month = '2026-03-01'),
  'it applies from March');

-- Moving the due day keeps the month (the new version is used), and an ended bill stops.
select actions.update_bill('james', 'power', '{"due_day": 5}', '2026-02-10');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select due_on = '2026-02-05' from calc.bill_cycles where bill_key = 'power' and due_month = '2026-02-01'),
  'a due-day change doesn''t make the month disappear');
select actions.update_bill('james', 'insurance', '{}', '2026-03-01', true);
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check(not exists (select 1 from calc.bill_cycles where bill_key = 'insurance' and due_month = '2026-04-01'),
  'an ended bill has no cycles after it ends');

-- An alias in Era's description counts as the name, not only the merchant name.
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('gym', 'fitco', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-gym-desc', 'era-chk', '{"description": "FITCO GYM 42"}', 'h', -60.00, '2026-02-09', false, 'CARD PURCHASE');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select score = 100 and due_month = '2026-02-01' from knowledge.proposed_matches
                       where era_transaction_id = 'tx-gym-desc' and bill_key = 'gym'),
  'an alias in Era''s description counts as the name');

-- A bill tracked from February, due the 25th: a payment on Jan 26 is inside February's window but
-- paid January, so it is left alone. One on Feb 24 is proposed.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, valid_from)
values ('water', 'Water', 30.00, 'fixed', 25, 'chk', false, 'monthly', null, '2026-02-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('water', 'waterco', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-water-jan', 'era-chk', '{}', 'h', -30.00, '2026-01-26', false, 'WATERCO'),
       ('tx-water-feb', 'era-chk', '{}', 'h', -30.00, '2026-02-24', false, 'WATERCO');
select calc.refresh_all(null, '2026-02-26');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-water-jan'),
  'a payment nearer the previous due date isn''t proposed for this one');
select pg_temp.check(exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-water-feb' and due_month = '2026-02-01'),
  'the payment near this due date is');

-- A withdrawn proposal (rejected, no person) can be proposed again; a person's no can't.
update knowledge.proposed_matches set status = 'rejected', decided_at = now(), decision_note = 'withdrawn'
 where era_transaction_id = 'tx-water-feb';
select calc.refresh_all(null, '2026-02-26');
select pg_temp.check((select status = 'pending' and decided_at is null from knowledge.proposed_matches where era_transaction_id = 'tx-water-feb'),
  'a withdrawn pairing comes back under the current rules');
select pg_temp.check((select status = 'rejected' from knowledge.proposed_matches where era_transaction_id = 'tx-rejected'),
  'a pairing a person rejected stays rejected');
rollback;
