\set ON_ERROR_STOP 1
\echo '== 18 card payments from any account'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Two card minimums paid from checking: one on the fixture's test card, one on a second card.
insert into raw.era_accounts (era_account_id, payload, content_hash) values ('era-card2', '{}', 'h');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from)
values ('card2', 'era-card2', 'Second card', 'joint', 'card', null, '2026-01-01');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, pays_account_key, valid_from) values
  ('card-min', 'Test card minimum', 35.00, 'variable', 14, 'chk', false, 'monthly', 'card', '2026-01-01'),
  ('card2-min', 'Second card minimum', 25.00, 'fixed', 18, 'chk', false, 'monthly', 'card2', '2026-01-01');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  -- 50.00 from savings to the test card: more than the minimum, from an account that isn't the bill's.
  ('tx-card-out', 'era-sav', '{"description": "Card payment", "transferLink": {"linkedTransactionId": "tx-card-in", "counterpartAccountGroupKey": "era-card"}}',
   'h', -50.00, '2026-02-06', false, 'BANK'),
  ('tx-card-in', 'era-card', '{"description": "Payment", "category": "Transfers and card payments", "transferLink": {"linkedTransactionId": "tx-card-out", "counterpartAccountName": "Savings"}}',
   'h', 50.00, '2026-02-06', false, 'BANK'),
  -- A refund and a too-small payment on the same card: neither pays the minimum.
  ('tx-card-refund', 'era-card', '{"description": "Refund", "category": "Shopping"}', 'h', 60.00, '2026-02-07', false, 'BIGBUY'),
  ('tx-card-small', 'era-card', '{"description": "Payment Thank You"}', 'h', 10.00, '2026-02-08', false, 'BANK'),
  -- Exactly the second card's minimum from checking: both sides of the transfer would match.
  ('tx-card2-out', 'era-chk', '{"description": "Card payment", "transferLink": {"linkedTransactionId": "tx-card2-in", "counterpartAccountGroupKey": "era-card2"}}',
   'h', -25.00, '2026-02-08', false, 'BANK'),
  ('tx-card2-in', 'era-card2', '{"description": "Payment Thank You-Mobile", "transferLink": {"linkedTransactionId": "tx-card2-out"}}',
   'h', 25.00, '2026-02-08', false, 'BANK');

select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select status = 'pending' and due_month = '2026-02-01' and reason like 'card payment received on Test card from Savings%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-card-in' and bill_key = 'card-min'),
  'a payment received on the card is proposed for its minimum, from any account and above the minimum');
select pg_temp.check(not exists (select 1 from knowledge.proposed_matches where era_transaction_id in ('tx-card-out', 'tx-card-refund', 'tx-card-small')),
  'the savings side, a refund and a payment under the minimum are not proposed');
select pg_temp.check((select status = 'pending_match' from calc.bill_cycles where bill_key = 'card-min' and due_month = '2026-02-01'),
  'so the card bill shows as matched');

select pg_temp.check((select count(*) = 1 from knowledge.proposed_matches where bill_key = 'card2-min'),
  'when both sides of a transfer match, the cycle gets one proposal');
select pg_temp.check(exists (select 1 from knowledge.proposed_matches where bill_key = 'card2-min' and era_transaction_id = 'tx-card2-in'),
  'and it is the card side');

select pg_temp.check((select (actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-card-in'))).amount = 50.00),
  'confirm_match records money in on the card as the payment');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'card-min' and due_month = '2026-02-01'),
  'and the card bill is paid');

-- A proposal on the checking side of a transfer, open when the card side is confirmed, is closed.
insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
values ('tx-card2-out', 'phone', '2026-02-01', 70, 'test', 'pending');
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-card2-in'));
select pg_temp.check((select status = 'rejected' and decision_note like 'The other side of this transfer%'
                        from knowledge.proposed_matches where era_transaction_id = 'tx-card2-out'),
  'confirming the card side closes an open proposal on the other side of the transfer');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select count(*) = 1 from knowledge.proposed_matches where era_transaction_id = 'tx-card2-out'),
  'and the other side is not proposed again');

-- Money in still isn't a payment for a bill that doesn't pay down that account.
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-refund-chk', 'era-chk', '{}', 'h', 40.00, '2026-02-09', false, 'ACME MOBILE');
insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
values ('tx-refund-chk', 'gym', '2026-02-01', 70, 'test', 'pending');
select pg_temp.expect_error(null,
  $$select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-refund-chk'))$$,
  '%money in, not a payment%', 'confirm_match still refuses money in for other bills');

-- update_bill keeps and changes pays_account_key.
select actions.update_bill('james', 'card-min', '{"amount": 40.00}', current_date);
select pg_temp.check((select pays_account_key = 'card' from ref.bills where bill_key = 'card-min' and valid_to is null),
  'update_bill carries pays_account_key into the new version');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'card-min', '{"pays_account_key": "nope"}', current_date)$$,
  '%Unknown pays_account_key%', 'update_bill refuses an account that doesn''t exist');

rollback;
