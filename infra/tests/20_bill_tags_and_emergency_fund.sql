\set ON_ERROR_STOP 1
\echo '== 19 bill tags and the emergency fund ladder'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- A per-paycheck bill, so the monthly figure follows its income's cadence (biweekly).
insert into ref.bills (bill_key, name, amount, amount_kind, account_key, autopay, cadence, income_key, valid_from)
values ('loanpay', 'Loan per paycheck', 100.00, 'fixed', 'chk', false, 'per_paycheck', 'pay', '2026-01-01');

insert into ref.budget_lines (line_key, name, amount, period, income_key, tracked, sort, valid_from) values
  ('food', 'Food', 100.00, 'paycheck', 'pay', true, 1, '2026-01-01'),
  ('animals', 'Animals', 50.00, 'month', null, true, 2, '2026-01-01'),
  ('shopping', 'Shopping', 500.00, 'month', null, true, 3, '2026-01-01');

insert into calc.account_balances (account_key, name, kind, balance, as_of, source, stale)
values ('emergency-fund', 'Emergency Fund', 'savings', 4000.00, now(), 'era', false);

-- Untagged: nothing counted, and the view says how many are missing.
select pg_temp.check((select untagged_bills = 8 and necessity_bills = 0 and necessity_lines = 266.67
                        from calc.emergency_fund_status),
  'untagged bills are counted as missing, never as necessities; Food and Animals lines count, Shopping does not');

-- Monthly figures by cadence.
select pg_temp.check((select monthly_amount = 100.00 from calc.bill_monthly where bill_key = 'insurance'),
  'a quarterly bill is a third of its amount a month');
select pg_temp.check((select monthly_amount = 216.67 from calc.bill_monthly where bill_key = 'loanpay'),
  'a per-paycheck bill follows its biweekly income: 26 a year');

-- Tag them the way the live data migration does: on every version.
update ref.bills set category = 'housing', basic_necessity = true where bill_key = 'rent';
update ref.bills set category = 'utilities', basic_necessity = true where bill_key = 'power';
update ref.bills set category = 'insurance', basic_necessity = true where bill_key = 'insurance';
update ref.bills set category = 'debt', basic_necessity = true where bill_key = 'loanpay';
update ref.bills set category = 'subscriptions', basic_necessity = false where bill_key in ('gym', 'stream-a', 'stream-b', 'phone');

select pg_temp.check((select untagged_bills = 0 and necessity_bills = 1016.67 and monthly_necessities = 1283.34
                             and target_3_months = 3850.02 and months_covered = 3.12 and rung_reached = 3
                        from calc.emergency_fund_status),
  'tagged necessities plus Food and Animals make the month; 4000 covers 3 months, not 6');

select pg_temp.check(pg_temp.as_role('assistant_read', 'select rung_reached from calc.emergency_fund_status') = '3',
  'assistant_read can read the ladder');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from calc.bill_monthly') = '8',
  'assistant_read can read the monthly figures');

-- update_bill carries the tags and can change them.
select actions.update_bill('james', 'rent', '{"amount": 650.00}', current_date);
select pg_temp.check((select category = 'housing' and basic_necessity from ref.bills where bill_key = 'rent' and valid_to is null),
  'update_bill carries category and basic_necessity into the new version');
select actions.update_bill('james', 'phone', '{"category": "utilities", "basic_necessity": true}', current_date);
select pg_temp.check((select category = 'utilities' and basic_necessity from ref.bills where bill_key = 'phone' and valid_to is null),
  'update_bill changes the tags as a new version');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'gym', '{"category": "Fun Stuff!"}', current_date)$$,
  '%category is one or more lowercase words%', 'update_bill refuses a category that isn''t lowercase words');

rollback;
