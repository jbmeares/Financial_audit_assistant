\set ON_ERROR_STOP 1
\echo '== 19 the paycheck plan and the debt payoff plan'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture (today is Tue 2026-02-10). Its paycheck 'pay' is
-- 1,000.00 biweekly into checking from Jan 30: Jan 30, Feb 13, Feb 27, Mar 13, Mar 27 (Feb 10 + 45 days).
--   Each paycheck: 200.00 from checking to bill pay, a 50.00 bill paid from bill pay, a 30.00
--   bill paid from checking, and a 100.00 Food line (150.00 from Mar 1). A monthly Shopping
--   line doesn't belong to a paycheck.
--   Debts: the fixture's card (1,200.00 at 24%, minimum 35, priority 1) and loan (6%,
--   minimum 100, priority 2, stated 2,000.00), a promo card (600.00 at 30%, minimum 25, promo
--   ends Apr 15) and a family loan kept outside the plan.
insert into raw.era_accounts (era_account_id, payload, content_hash) values ('era-bp', '{}', 'h'), ('era-promo', '{}', 'h');
insert into raw.era_balances (era_account_id, current, available, as_of, payload) values
  ('era-bp', 300.00, 300.00, '2026-02-09 12:00-05', '{}'),
  ('era-promo', 600.00, 400.00, '2026-02-09 12:00-05', '{}');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from) values
  ('bp', 'era-bp', 'Bill pay', 'joint', 'checking', 'pays bills', '2026-01-01'),
  ('promo', 'era-promo', 'Promo card', 'james', 'card', null, '2026-01-01'),
  ('family', null, 'Family loan', 'james', 'loan', null, '2026-01-01');
insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence, income_key, valid_from)
values ('pay-to-bp', 'Paycheck to bill pay', 'chk', 'bp', 200.00, 'per_paycheck', 'pay', '2026-01-01');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, income_key, valid_from) values
  ('auto', 'Auto loan', 50.00, 'fixed', null, 'bp', false, 'per_paycheck', null, 'pay', '2026-01-01'),
  ('daycare', 'Daycare', 30.00, 'fixed', null, 'chk', false, 'per_paycheck', null, 'pay', '2026-01-01');
insert into ref.budget_lines (line_key, name, amount, period, income_key, borrows_from, tracked, sort, valid_from, valid_to) values
  ('food', 'Food', 100.00, 'paycheck', 'pay', null, true, 1, '2026-01-01', '2026-03-01'),
  ('food', 'Food', 150.00, 'paycheck', 'pay', null, true, 1, '2026-03-01', null),
  ('shopping', 'Shopping', 200.00, 'month', null, null, true, 2, '2026-01-01', null),
  ('extra-debt', 'Extra debt payment', 100.00, 'month', null, null, false, 9, '2026-01-01', null);
insert into ref.debts (debt_key, account_key, apr, minimum_payment, promo_end_on, in_payoff_plan, valid_from) values
  ('promo', 'promo', 30.000, 25.00, '2026-04-15', true, '2026-01-01'),
  ('family', 'family', 0, 0, null, false, '2026-01-01');
insert into ledger.balance_statements (account_key, balance, as_of, entered_by) values
  ('loan', 2000.00, '2026-02-09 12:00-05', 'james'),
  ('family', 500.00, '2026-02-09 12:00-05', 'james');

select calc.refresh_all(null, '2026-02-10');

-- ---------------------------------------------------------------- paycheck plan

select pg_temp.check((select string_agg(pay_on::text, ',' order by pay_on) from calc.paycheck_plan('2026-02-10'))
                       = '2026-01-30,2026-02-13,2026-02-27,2026-03-13,2026-03-27',
  'the plan runs from the current paycheck through 45 days ahead');
select pg_temp.check((select is_current from calc.paycheck_plan('2026-02-10') where pay_on = '2026-01-30')
                     and not (select is_current from calc.paycheck_plan('2026-02-10') where pay_on = '2026-02-13'),
  'only the latest pay date on or before today is current');
select pg_temp.check((select income_amount = 1000 and transfers_out = 200 and bills_from_deposit = 30 and budget_lines = 100 and left_over = 670
                        from calc.paycheck_plan('2026-02-10') where pay_on = '2026-02-13'),
  'left over is the check less transfers, bills from the deposit account and paycheck lines');
select pg_temp.check((select jsonb_array_length(items) = 4
                             and items @> '[{"kind": "bill", "key": "auto", "counts": false, "account_key": "bp"}]'
                             and items @> '[{"kind": "bill", "key": "daycare", "counts": true, "status": "not_seen_yet"}]'
                             and items @> '[{"kind": "transfer", "key": "pay-to-bp", "counts": true}]'
                             and items @> '[{"kind": "budget_line", "key": "food", "amount": 100.00}]'
                             and not items @> '[{"key": "shopping"}]'
                        from calc.paycheck_plan('2026-02-10') where pay_on = '2026-02-13'),
  'a bill paid from bill pay is listed but not subtracted; monthly lines stay out');
select pg_temp.check((select budget_lines = 150 and left_over = 620 from calc.paycheck_plan('2026-02-10') where pay_on = '2026-03-13'),
  'a later paycheck uses the budget line in effect on its date');
select pg_temp.check((select count(*) = 3 from calc.paycheck_plan('2026-02-10', 30)), 'the window can be shortened');

-- ---------------------------------------------------------------- debt payoff plan
-- Expected numbers worked out independently (monthly steps from March, extra 100):
--   promo paid Jul 2026 (5 months, 17.45 interest; none charged through April),
--   card Mar 2027 (13 months, 219.35), loan Jun 2027 (16 months, 101.68).

select pg_temp.check((select string_agg(debt_key, ',' order by plan_order) from calc.debt_payoff_plan('2026-02-10') where in_plan) = 'promo,card,loan',
  'promo balances go first, then the highest APR');
select pg_temp.check((select monthly_amount = 260 and extra = 100 from calc.debt_payoff_plan('2026-02-10') limit 1),
  'the monthly amount is every in-plan minimum plus the extra debt line');
select pg_temp.check((select payoff_month = '2026-07-31' and months_to_payoff = 5 and total_interest = 17.45 and is_target and promo_at_risk
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'promo'),
  'the promo card is the target, charged no interest during the promo, and flagged when it outlasts the promo');
select pg_temp.check((select payoff_month = '2027-03-31' and months_to_payoff = 13 and total_interest = 219.35 and not is_target and promo_at_risk is null
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'card'),
  'the next debt picks up the freed payment');
select pg_temp.check((select payoff_month = '2027-06-30' and months_to_payoff = 16 and total_interest = 101.68
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'loan'),
  'the last debt is paid off once everything rolls into it');
select pg_temp.check((select notes @> array['payoff_priority on file is 1; the written plan puts it at 2.']
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'card'),
  'a payoff priority that disagrees with the written plan is flagged');
select pg_temp.check((select plan_order is null and not in_plan and payoff_month is null
                             and notes = array['Outside the payoff plan (strategy/debt-plan.md).']
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'family'),
  'a debt outside the plan is listed but gets no money');
select pg_temp.check((select monthly_amount = 160 and payoff_month > '2027-06-30' from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'with no extra the plan runs on minimums alone, and takes longer');
select pg_temp.expect_error(null, 'select * from calc.debt_payoff_plan(''2026-02-10'', -5)', '%can''t be negative%',
  'a negative extra is refused');

update ref.debts set promo_end_on = '2026-08-31' where debt_key = 'promo';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not promo_at_risk from calc.debt_payoff_plan('2026-02-10') where debt_key = 'promo'),
  'a promo balance paid off in time isn''t flagged');

-- No balance on file: listed with a note, no money.
insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from)
values ('nobal', null, 'Unknown loan', 'james', 'loan', null, '2026-01-01');
insert into ref.debts (debt_key, account_key, apr, minimum_payment, valid_from) values ('nobal', 'nobal', 10, 20, '2026-01-01');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select plan_order is null and notes @> array['No balance on file, so it can''t be planned.']
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'nobal'),
  'a debt with no balance is named, never guessed');

-- Several promos on part of a balance (James's CareCredit, 2026-11-14), and promos that ended.
-- The promo card (600.00) gets a 100.00 promo ending Mar 15 and a 200.00 one ending May 15;
-- the other 300.00 is at its APR from the start.
insert into ref.debt_promos (debt_key, amount, ends_on, valid_from) values
  ('promo', 100.00, '2026-03-15', '2026-01-01'),
  ('promo', 200.00, '2026-05-15', '2026-01-01');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not promo_at_risk and promo_end_on = '2026-03-15'
                             and notes @> array['On promo: $100.00 by Mar 15, 2026, $200.00 by May 15, 2026. The rest is at the full APR.']
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'promo'),
  'promo parts paid off in time aren''t flagged; the note lists each one');
select pg_temp.check((select total_interest > 17.45 from calc.debt_payoff_plan('2026-02-10') where debt_key = 'promo'),
  'the part not on promo is charged interest during the promos');
select pg_temp.check((select promo_at_risk from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'promo'),
  'on minimums alone the promo parts can''t clear in time');
update ref.debts set apr = 10.000 where debt_key = 'promo';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select string_agg(debt_key, ',' order by plan_order) from calc.debt_payoff_plan('2026-02-10') where in_plan) = 'promo,card,loan',
  'a debt with an active promo goes first even at a low APR');
select pg_temp.check((select promo_end_on = '2026-05-15' from calc.debt_payoff_plan('2026-04-01') where debt_key = 'promo'),
  'after the first promo ends, the next one is shown');
select pg_temp.check((select string_agg(debt_key, ',' order by plan_order) from calc.debt_payoff_plan('2026-06-01') where in_plan) = 'card,promo,loan'
                     and (select promo_at_risk is null and promo_end_on is null from calc.debt_payoff_plan('2026-06-01') where debt_key = 'promo'),
  'once every promo has ended the debt takes its APR place');

-- ---------------------------------------------------------------- access

select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from calc.paycheck_plan(''2026-02-10'')') = '5',
  'the assistant can read the paycheck plan');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from calc.debt_payoff_plan(''2026-02-10'')') = '5',
  'the assistant can read the payoff plan');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from ref.current_debt_promos') = '2',
  'the assistant can read the promos');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from ref.current_debts where not in_payoff_plan') = '1',
  'the assistant can see which debts are outside the plan');

rollback;
