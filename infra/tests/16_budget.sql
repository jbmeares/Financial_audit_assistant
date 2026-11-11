\set ON_ERROR_STOP 1
\echo '== 16 the budget: lines, rules, status and the briefing item'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture. Its paycheck 'pay' is biweekly from Jan 30, so
-- pay periods run Jan 30-Feb 12 and Feb 13-26.
insert into raw.era_accounts (era_account_id, payload, content_hash) values ('era-bp', '{}', 'h');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, valid_from) values
  ('bp', 'era-bp', 'Bills account', 'joint', 'checking', '2026-01-01');

insert into ref.budget_lines (line_key, name, amount, period, income_key, borrows_from, tracked, sort, valid_from) values
  ('food', 'Food', 100.00, 'paycheck', 'pay', 'shopping', true, 1, '2026-01-01'),
  ('shopping', 'Shopping', 200.00, 'month', null, null, true, 2, '2026-01-01'),
  ('extra-debt', 'Extra debt payment', 50.00, 'month', null, null, false, 9, '2026-01-01');
insert into ref.budget_rules (line_key, era_category, merchant, account_key, priority, valid_from) values
  ('food', 'Groceries', null, null, 100, '2026-01-01'),
  ('shopping', 'Shopping and gear', null, null, 100, '2026-01-01'),
  ('food', null, 'big club', null, 50, '2026-01-01'),
  (null, null, null, 'bp', 1, '2026-01-01');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('b-groc', 'era-chk', '{"category": "Groceries"}', 'h', -80.00, '2026-02-14', false, 'FOOD MART'),
  ('b-groc-card', 'era-card', '{"category": "Groceries"}', 'h', -50.00, '2026-02-15', false, 'FOOD MART'),
  ('b-club', 'era-chk', '{"category": "Shopping and gear"}', 'h', -20.00, '2026-02-16', false, 'BIG CLUB #12'),
  ('b-store', 'era-chk', '{"category": "Shopping and gear"}', 'h', -45.00, '2026-02-05', false, 'STORE'),
  ('b-billpay', 'era-bp', '{"category": "Groceries"}', 'h', -500.00, '2026-02-17', false, 'FOOD MART'),
  ('b-transfer', 'era-chk', '{"category": "Groceries", "transferLink": {"status": "auto_detected"}}', 'h', -70.00, '2026-02-17', false, 'FOOD MART'),
  ('b-cardpay', 'era-chk', '{"category": "Transfers and card payments"}', 'h', -300.00, '2026-02-17', false, 'BANK'),
  ('b-early', 'era-chk', '{"category": "Groceries"}', 'h', -30.00, '2026-02-10', false, 'FOOD MART'),
  ('b-maybe-bill', 'era-chk', '{"category": "Groceries"}', 'h', -25.00, '2026-02-18', false, 'FOOD MART');
insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason)
values ('b-maybe-bill', 'phone', '2026-02-01', 60, 'test');

-- Rules.
select pg_temp.check((select line_key from calc.budget_spending('2026-02-01', '2026-02-28') where era_transaction_id = 'b-club') = 'food',
  'a merchant rule beats a category rule when its priority number is lower');
select pg_temp.check((select line_key is null from calc.budget_spending('2026-02-01', '2026-02-28') where era_transaction_id = 'b-billpay'),
  'a rule with no line makes the bills account count against nothing');
select pg_temp.check(not exists (select 1 from calc.budget_spending('2026-02-01', '2026-02-28')
                                  where era_transaction_id in ('b-transfer', 'b-cardpay', 'b-maybe-bill', 'tx-pay')),
  'transfers, card payments, possible bill payments and money in don''t count');

-- Status on Feb 20.
select pg_temp.check((select period_start = '2026-02-13' and period_end = '2026-02-26' and spent = 150 and "left" = -50
                        from calc.budget_status('2026-02-20') where line_key = 'food'),
  'a paycheck line counts only its own pay period (Feb 10 belongs to the one before)');
select pg_temp.check((select period_start = '2026-02-01' and period_end = '2026-02-28' and spent = 45 and borrowed = 50 and left_after_borrowing = 105
                        from calc.budget_status('2026-02-20') where line_key = 'shopping'),
  'Shopping covers what Food ran over by');
select pg_temp.check((select spent is null and "left" is null and amount = 50 from calc.budget_status('2026-02-20') where line_key = 'extra-debt'),
  'an amount-only line tracks no spending');
select pg_temp.check((select borrowed = 50 from calc.budget_status('2026-02-27') where line_key = 'shopping'),
  'an overage stays charged after the next payday in the same month');
select pg_temp.check((select borrowed = 0 from calc.budget_status('2026-03-02') where line_key = 'shopping'),
  'a new month starts with nothing borrowed');

-- The briefing.
select calc.refresh_all(null, '2026-02-20');
select pg_temp.check((select e ->> 'level' = 'GREEN'
                             and e ->> 'text' = 'Budget: Food $0 left of $100 through Feb 26. Shopping $105 left of $200 this month.'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'budget'),
  'the briefing says what each line has left');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('b-big', 'era-card', '{"category": "Shopping and gear"}', 'h', -150.00, '2026-02-18', false, 'STORE');
select calc.refresh_all(null, '2026-02-20');
select pg_temp.check((select e ->> 'level' = 'YELLOW' and e ->> 'text' like 'Budget: Over budget: Shopping is empty after covering other lines.%'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'budget'),
  'the item turns YELLOW once Shopping is used up');
select pg_temp.check((select level <> 'GREEN' from calc.briefing), 'an empty Shopping line lifts a GREEN day to YELLOW');

-- Access.
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from calc.budget_status(''2026-02-20'')') = '3',
  'the assistant can read the budget status');
select pg_temp.expect_error('assistant_read', 'insert into ref.budget_lines (line_key, name, amount, period) values (''x'', ''X'', 1, ''month'')',
  '%permission denied%', 'the assistant can''t write budget lines');

rollback;
