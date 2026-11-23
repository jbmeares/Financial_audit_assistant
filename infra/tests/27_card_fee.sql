\set ON_ERROR_STOP 1
\echo '== 27 card fee counts with its bill'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Power comes with a card fee: the fixture's 112.40 charge on Feb 9, plus 3.37 the same day.
update ref.bills set card_fee = true where bill_key = 'power';
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-power-fee', 'era-chk', '{}', 'h', -3.37, '2026-02-09', false, 'CITY POWER'),
  -- Same day and merchant but too big to be a fee (over 10% of the bill): left alone.
  ('tx-power-big', 'era-chk', '{}', 'h', -40.00, '2026-02-09', false, 'CITY POWER');

select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select status = 'pending' and reason like '%plus card fee $3.37 (2026-02-09), recorded with it%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-power' and bill_key = 'power'),
  'the bill''s charge is proposed, and the proposal names the fee that came with it');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-power-fee'),
  'the fee is not proposed on its own');

select pg_temp.check((select (actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-power'))).amount = 112.40),
  'confirm_match returns the bill''s payment');
select pg_temp.check((select count(*) = 2 and sum(amount) = 115.77 from ledger.payments_effective where bill_key = 'power' and due_month = '2026-02-01'),
  'and records the fee as a second payment for the same cycle');
select pg_temp.check((select note = 'Card fee that came with this bill.' from ledger.payments where era_transaction_id = 'tx-power-fee'),
  'the fee''s payment says what it is');
select pg_temp.check(not exists (select 1 from ledger.payments where era_transaction_id = 'tx-power-big'),
  'a same-day charge too big to be a fee is not recorded with the bill');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'power' and due_month = '2026-02-01'),
  'the bill is paid');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id = 'tx-power-fee'),
  'and the fee is not proposed after the refresh');

-- A fee still pending at the bank when the bill is confirmed: proposed for the same cycle once it's there.
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, card_fee, valid_from)
values ('water', 'Water', 60.00, 'variable', 18, 'chk', false, 'monthly', true, '2026-01-01');
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
                             and reason like 'card fee $1.66 (2026-02-08) that came with the Water payment of $55.10%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-water-fee'),
  'once the bill is in the ledger, the fee is proposed for the same cycle');
update raw.era_transactions set pending = false where era_transaction_id = 'tx-water-fee';
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-water-fee'));
select pg_temp.check((select count(*) = 2 and sum(amount) = 56.76 from ledger.payments_effective where bill_key = 'water' and due_month = '2026-02-01'),
  'and confirming it records it with the bill');

-- A bill without card_fee is unchanged: a small same-day charge from the same merchant isn't recorded with it.
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-phone-extra', 'era-chk', '{}', 'h', -2.00, '2026-02-05', false, 'ACME MOBILE');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check(not exists (select 1 from ledger.payments where era_transaction_id = 'tx-phone-extra'),
  'a bill without card_fee records no fee');

-- update_bill accepts card_fee and carries it into each new version; a new bill defaults to false.
select actions.update_bill('james', 'power', '{"amount": 110.00}', current_date);
select pg_temp.check((select card_fee from ref.bills where bill_key = 'power' and valid_to is null),
  'update_bill carries card_fee into the new version');
select actions.update_bill('james', 'power', '{"card_fee": false}', current_date + 1);
select pg_temp.check((select not card_fee from ref.bills where bill_key = 'power' and valid_to is null),
  'update_bill can turn card_fee off');
select actions.update_bill('james', 'trash', '{"name": "Trash", "amount": 20, "amount_kind": "fixed", "due_day": 3, "account_key": "chk", "autopay": true, "cadence": "monthly"}');
select pg_temp.check((select not card_fee from ref.bills where bill_key = 'trash'),
  'a new bill has no card fee unless one is set');

rollback;
