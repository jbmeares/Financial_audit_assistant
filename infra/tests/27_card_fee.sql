\set ON_ERROR_STOP 1
\echo '== 27 smaller charges from the same merchant count with the bill (card fees, split payments)'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Power comes with a card fee: the fixture's 112.40 charge on Feb 9, plus 3.37 the same day.
-- Since 20261124170000 every bill does this; card_fee isn't needed.
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-power-fee', 'era-chk', '{}', 'h', -3.37, '2026-02-09', false, 'CITY POWER'),
  -- Same day and merchant, bigger than a fee, and the bill adds up without it: its own purchase
  -- (since 20261124180000).
  ('tx-power-big', 'era-chk', '{}', 'h', -40.00, '2026-02-09', false, 'CITY POWER');

select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select status = 'pending' and reason like '%plus $3.37 (2026-02-09) from the same merchant within 2 days, recorded with it'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-power' and bill_key = 'power'),
  'the bill''s charge is proposed, and the proposal names the fee that came with it');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id in ('tx-power-fee', 'tx-power-big')),
  'the smaller charges are not proposed on their own');
select pg_temp.check(calc._is_companion('tx-power-fee', '2026-02-10') and not calc._is_companion('tx-power-big', '2026-02-10'),
  'the fee goes with the bill; the bigger charge doesn''t');

select pg_temp.check((select (actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-power'))).amount = 112.40),
  'confirm_match returns the bill''s payment');
select pg_temp.check((select count(*) = 2 and sum(amount) = 115.77 from ledger.payments_effective where bill_key = 'power' and due_month = '2026-02-01'),
  'and records the fee as a payment for the same cycle');
select pg_temp.check((select note = 'Card fee that came with this bill.' from ledger.payments where era_transaction_id = 'tx-power-fee'),
  'the fee''s payment says what it is');
select pg_temp.check(not exists (select 1 from ledger.payments where era_transaction_id = 'tx-power-big'),
  'a bigger charge the bill doesn''t need is not recorded with it');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'power' and due_month = '2026-02-01'),
  'the bill is paid');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id in ('tx-power-fee', 'tx-power-big')),
  'and neither is proposed after the refresh');

-- A fee still pending at the bank when the bill is confirmed: proposed for the same cycle once it's there.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('water', 'Water', 60.00, 'variable', 18, 'chk', false, 'monthly', '2026-01-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('water', 'town water', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-water', 'era-chk', '{}', 'h', -55.10, '2026-02-08', false, 'TOWN WATER'),
  ('tx-water-fee', 'era-chk', '{}', 'h', -1.66, '2026-02-08', true, 'TOWN WATER');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-water-fee'),
  'a pending fee is not proposed while its bill is unconfirmed');
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-water'));
select pg_temp.check((select count(*) = 1 from ledger.payments_effective where bill_key = 'water'),
  'a fee still pending at the bank is not recorded with the bill');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'pending' and bill_key = 'water' and due_month = '2026-02-01' and score = 100
                             and reason like '$1.66 (2026-02-08) from the same merchant within 2 days of the Water payment of $55.10%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-water-fee'),
  'once the bill is in the ledger, the fee is proposed for the same cycle');
update raw.era_transactions set pending = false where era_transaction_id = 'tx-water-fee';
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-water-fee'));
select pg_temp.check((select count(*) = 2 and sum(amount) = 56.76 from ledger.payments_effective where bill_key = 'water' and due_month = '2026-02-01'),
  'and confirming it records it with the bill');

-- A split payment: a $60 bill paid as $35 and $25 two days apart. Neither fits alone; together they do.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('lawn', 'Lawn care', 60.00, 'fixed', 20, 'chk', false, 'monthly', '2026-01-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('lawn', 'green lawns', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-lawn-1', 'era-chk', '{}', 'h', -35.00, '2026-02-07', false, 'GREEN LAWNS'),
  ('tx-lawn-2', 'era-chk', '{}', 'h', -25.00, '2026-02-09', false, 'GREEN LAWNS');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'pending' and reason like '%plus $25.00 (2026-02-09) from the same merchant%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-lawn-1' and bill_key = 'lawn'),
  'a bill paid in two parts is proposed on the bigger part, naming the other');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-lawn-2'),
  'and the smaller part isn''t proposed on its own');
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-lawn-1'));
select pg_temp.check((select count(*) = 2 and sum(amount) = 60 from ledger.payments_effective where bill_key = 'lawn'),
  'confirming it records both parts');
select pg_temp.check((select note = 'Part of this bill, paid as a separate charge.' from ledger.payments where era_transaction_id = 'tx-lawn-2'),
  'the other part says what it is');

-- The second part of a split still pending at the bank when the first is confirmed: proposed once it posts.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('tutor', 'Tutor', 80.00, 'fixed', 9, 'chk', false, 'monthly', '2026-01-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('tutor', 'bright tutors', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-tutor-1', 'era-chk', '{}', 'h', -50.00, '2026-02-08', false, 'BRIGHT TUTORS'),
  ('tx-tutor-2', 'era-chk', '{}', 'h', -30.00, '2026-02-09', true, 'BRIGHT TUTORS');
select calc.refresh_all(null, '2026-02-10');
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-tutor-1'));
update raw.era_transactions set pending = false where era_transaction_id = 'tx-tutor-2';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select status = 'pending' and bill_key = 'tutor' from knowledge.proposed_matches where era_transaction_id = 'tx-tutor-2'),
  'the late second part of a split is proposed for the same cycle');

-- A separate purchase at the same store two days after a fixed bill (Apple, Nov 2026): not part of the bill.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('app-sub', 'App subscription', 14.82, 'fixed', 6, 'chk', true, 'monthly', '2026-01-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('app-sub', 'app store', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-app', 'era-chk', '{}', 'h', -14.82, '2026-02-06', false, 'APP STORE');
select calc.refresh_all(null, '2026-02-10');
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-app'));
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-app-2', 'era-chk', '{}', 'h', -4.31, '2026-02-08', false, 'APP STORE');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-app-2'),
  'a later purchase that isn''t fee-sized isn''t proposed for a bill that''s already paid in full');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-app-big', 'era-chk', '{}', 'h', -30.00, '2026-02-20', false, 'APP STORE'),
  ('tx-app-small', 'era-chk', '{}', 'h', -1.99, '2026-02-20', false, 'APP STORE');
select pg_temp.check(not calc._is_companion('tx-app-small', '2026-02-21'),
  'a small charge beside a purchase that pays no bill stays its own charge');

-- Two equal charges are two payments, not one bill with an extra.
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-phone-twin', 'era-chk', '{}', 'h', -40.00, '2026-02-05', false, 'ACME MOBILE 123');
select pg_temp.check(not calc._is_companion('tx-phone-twin', '2026-02-10') and not calc._is_companion('tx-phone', '2026-02-10'),
  'an equal charge from the same merchant doesn''t go with the other');

rollback;
