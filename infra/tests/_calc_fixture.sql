-- Made-up data for the calc tests. None of these values are real.
-- The tests pin "today" to Tue 2026-02-10, so February is a short month.
--
-- Income: 1,000.00 every other Friday into checking (Feb 13, Feb 27, Mar 13, ...).
-- Bills from checking: phone 40 fixed (5th), gym 60 fixed (12th), power 100 variable (15th),
-- two streaming services at 15.99 (20th), rent 600 fixed (31st, so Feb 28), and insurance
-- 300 quarterly (12th of Jan, Apr, Jul, Oct).

insert into raw.pull_runs (kind, status, started_at, finished_at)
values ('nightly', 'ok', '2026-02-10 00:01-05', '2026-02-10 00:04-05');

insert into raw.era_accounts (era_account_id, payload, content_hash) values
  ('era-chk', '{}', 'h'), ('era-sav', '{}', 'h'), ('era-card', '{}', 'h');

insert into raw.era_balances (era_account_id, current, available, as_of, payload) values
  ('era-chk', 520.00, 500.00, '2026-02-09 12:00-05', '{}'),
  ('era-sav', 1000.00, null, '2026-02-09 12:00-05', '{}'),
  ('era-card', 1200.00, 800.00, '2026-02-09 12:00-05', '{}');

insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from) values
  ('chk', 'era-chk', 'Joint checking', 'joint', 'checking', 'pays bills', '2026-01-01'),
  ('sav', 'era-sav', 'Savings', 'joint', 'savings', null, '2026-01-01'),
  ('card', 'era-card', 'Test card', 'james', 'card', null, '2026-01-01'),
  ('loan', null, 'Test loan', 'james', 'loan', null, '2026-01-01');

insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, valid_from) values
  ('phone', 'Phone', 40.00, 'fixed', 5, 'chk', true, 'monthly', null, '2026-01-01'),
  ('gym', 'Gym', 60.00, 'fixed', 12, 'chk', true, 'monthly', null, '2026-01-01'),
  ('power', 'Power', 100.00, 'variable', 15, 'chk', false, 'monthly', null, '2026-01-01'),
  ('stream-a', 'Stream A', 15.99, 'fixed', 20, 'chk', true, 'monthly', null, '2026-01-01'),
  ('stream-b', 'Stream B', 15.99, 'fixed', 20, 'chk', true, 'monthly', null, '2026-01-01'),
  ('rent', 'Rent', 600.00, 'fixed', 31, 'chk', false, 'monthly', null, '2026-01-01'),
  ('insurance', 'Insurance', 300.00, 'fixed', 12, 'chk', false, 'quarterly', '2026-01-12', '2026-01-01');

insert into ref.bill_aliases (bill_key, alias, valid_from) values
  ('phone', 'acme mobile', '2026-01-01'), ('power', 'city power', '2026-01-01');

insert into ref.income_sources (income_key, person, name, amount, cadence, anchor_pay_date, deposit_account_key, valid_from)
values ('pay', 'james', 'Paycheck', 1000.00, 'biweekly', '2026-01-30', 'chk', '2026-01-01');

insert into ref.debts (debt_key, account_key, apr, minimum_payment, payoff_priority, valid_from) values
  ('card', 'card', 24.000, 35.00, 1, '2026-01-01'),
  ('loan', 'loan', 6.000, 100.00, 2, '2026-01-01');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('tx-phone', 'era-chk', '{}', 'h', -40.00, '2026-02-04', false, 'ACME MOBILE 123'),
  ('tx-power', 'era-chk', '{}', 'h', -112.40, '2026-02-09', false, 'CITY POWER'),
  ('tx-shop', 'era-chk', '{}', 'h', -130.00, '2026-02-09', false, 'BIGBUY'),
  ('tx-stream', 'era-chk', '{}', 'h', -15.99, '2026-02-08', false, 'STREAMCO'),
  ('tx-rejected', 'era-chk', '{}', 'h', -40.00, '2026-02-03', false, 'SOMEONE'),
  ('tx-old', 'era-chk', '{}', 'h', -40.00, '2025-12-01', false, 'ACME MOBILE 999'),
  ('tx-pay', 'era-chk', '{}', 'h', 1000.00, '2026-01-30', false, 'PAYROLL'),
  ('tx-phone-jan', 'era-chk', '{}', 'h', -40.00, '2026-01-05', false, 'ACME MOBILE 123'),
  -- Not bill payments, though each would otherwise score: a fee, an interest charge and a
  -- transfer to the household's own savings.
  ('tx-fee', 'era-chk', '{"description": "Late Fee"}', 'h', -40.00, '2026-02-06', false, 'ACME MOBILE'),
  ('tx-interest', 'era-chk', '{"description": "Interest Charge"}', 'h', -15.99, '2026-02-07', false, 'BANK'),
  ('tx-transfer', 'era-chk', '{"description": "Online Transfer to Savings 0001", "transferLink": {"counterpartAccountGroupKey": "era-sav"}}', 'h', -60.00, '2026-02-07', false, 'BANK'),
  -- Close to a bill's amount with no name: not enough.
  ('tx-near', 'era-chk', '{}', 'h', -95.00, '2026-02-08', false, 'HARDWARE STORE'),
  -- Names the phone bill but is the streaming amount: never proposed for the streams.
  ('tx-named-other', 'era-chk', '{}', 'h', -15.99, '2026-02-08', false, 'ACME MOBILE ACCESSORIES'),
  -- The phone bill paid before February's window opened (Jan 25), with January already paid.
  ('tx-early', 'era-chk', '{}', 'h', -40.00, '2026-01-20', false, 'ACME MOBILE 123');

-- January's phone bill was confirmed. A wrong pairing was rejected earlier.
insert into ledger.payments (bill_key, due_month, amount, paid_on, era_transaction_id, entered_by)
values ('phone', '2026-01-01', 40.00, '2026-01-05', 'tx-phone-jan', 'james');
insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status, decided_at, decided_by)
values ('tx-rejected', 'phone', '2026-02-01', 90, 'test', 'rejected', now(), 'james');
