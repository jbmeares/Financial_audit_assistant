\set ON_ERROR_STOP 1
\echo '== 22 a paused debt payment'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture (today is Tue 2026-02-10; paycheck 'pay' is biweekly).
-- As in test 21, the loan (6%, minimum 100, 2,000.00) is paid 60.00 every paycheck by 'loanpay'
-- (130.00 a month). Here the bill is paused: its version ends 2026-03-01 and a new one starts
-- 2026-05-01, so March and April get nothing.
insert into ledger.balance_statements (account_key, balance, as_of, entered_by)
values ('loan', 2000.00, '2026-02-09 12:00-05', 'james');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, income_key, valid_from)
values ('loanpay', 'Loan payment', 60.00, 'fixed', null, 'chk', false, 'per_paycheck', null, 'pay', '2026-01-01');
update ref.debts set payment_bill_key = 'loanpay' where debt_key = 'loan';
select calc.refresh_all(null, '2026-02-10');
create temp table unpaused as select * from calc.debt_payoff_plan('2026-02-10', 0);

update ref.bills set valid_to = '2026-03-01' where bill_key = 'loanpay';
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, income_key, valid_from)
values ('loanpay', 'Loan payment', 60.00, 'fixed', null, 'chk', false, 'per_paycheck', null, 'pay', '2026-05-01');
select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select count(*) = 0 from calc.bill_cycles
                       where bill_key = 'loanpay' and due_on >= '2026-03-01' and due_on < '2026-05-01'),
  'no payments are scheduled while the bill is paused');
select pg_temp.check((select monthly_amount from calc.debt_payoff_plan('2026-02-10', 0) limit 1)
                     = (select monthly_amount from unpaused limit 1),
  'the plan still uses the scheduled 130.00, from the newest version');
select pg_temp.check((select notes @> array['Payments paused: nothing planned for Mar 2026, Apr 2026 (the bill "Loan payment" has no version then). Interest still builds.']
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'a note names the paused months');
-- Worked out independently (monthly steps from March, no extra): two months with no loan
-- payment and interest still building push the loan from Jul 2027 to Sep 2027 (19 months).
-- The card's own payments don't change in those months, and once the loan is gone its 130.00
-- rolls over two months later, so the card moves from Jan 2028 to Feb 2028.
select pg_temp.check((select payoff_month = '2027-09-30' and months_to_payoff = 19
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'the pause pushes the loan back two months');
select pg_temp.check((select a.payoff_month >= b.payoff_month
                        from calc.debt_payoff_plan('2026-02-10', 0) a join unpaused b using (debt_key)
                       where debt_key = 'card'),
  'the paused money is not spent on the card');
select pg_temp.check((select a.total_interest > b.total_interest
                        from calc.debt_payoff_plan('2026-02-10', 0) a join unpaused b using (debt_key)
                       where debt_key = 'loan'),
  'the loan costs more interest');

-- A part-month gap is a normal month (the bill is in effect for part of it).
update ref.bills set valid_from = '2026-04-15' where bill_key = 'loanpay' and valid_to is null;
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select notes @> array['Payments paused: nothing planned for Mar 2026 (the bill "Loan payment" has no version then). Interest still builds.']
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'only whole months count as paused');

-- With the pause over (no gap), nothing changes from test 21.
delete from ref.bills where bill_key = 'loanpay' and valid_to is null;
update ref.bills set valid_to = null where bill_key = 'loanpay';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select bool_and(a.payoff_month = b.payoff_month and a.total_interest = b.total_interest)
                        from calc.debt_payoff_plan('2026-02-10', 0) a join unpaused b using (debt_key)),
  'without a gap the plan is as before');

rollback;
