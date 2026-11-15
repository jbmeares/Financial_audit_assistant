\set ON_ERROR_STOP 1
\echo '== 21 a debt paid by a scheduled bill'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture (today is Tue 2026-02-10; paycheck 'pay' is biweekly).
-- Debts: the fixture's card (24%, minimum 35) and loan (6%, minimum 100, stated 2,000.00).
-- The loan is also paid 60.00 every paycheck by the bill 'loanpay': 60 x 26 / 12 = 130.00 a month.
insert into ledger.balance_statements (account_key, balance, as_of, entered_by)
values ('loan', 2000.00, '2026-02-09 12:00-05', 'james');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, income_key, valid_from)
values ('loanpay', 'Loan payment', 60.00, 'fixed', null, 'chk', false, 'per_paycheck', null, 'pay', '2026-01-01');
select calc.refresh_all(null, '2026-02-10');

create temp table before_link as select * from calc.debt_payoff_plan('2026-02-10', 0);

select pg_temp.expect_error(null, 'update ref.debts set payment_bill_key = ''nope'' where debt_key = ''loan''', '%Unknown payment_bill_key%',
  'the payment bill must be a current bill');

update ref.debts set payment_bill_key = 'loanpay' where debt_key = 'loan';
select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select monthly_amount from calc.debt_payoff_plan('2026-02-10', 0) limit 1)
                     = (select monthly_amount + 30 from before_link limit 1),
  'the monthly amount counts the scheduled 130.00, not the 100.00 minimum');
select pg_temp.check((select minimum_payment = 100 from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'minimum_payment still shows the required minimum');
select pg_temp.check((select a.payoff_month < b.payoff_month
                        from calc.debt_payoff_plan('2026-02-10', 0) a join before_link b using (debt_key)
                       where debt_key = 'loan'),
  'the loan is paid off sooner at the scheduled payment');
select pg_temp.check((select notes @> array['Planned at $130.00 a month from the bill "Loan payment" ($60.00 each paycheck), not the $100.00 minimum.']
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'a note says the bill sets the payment');
-- Worked out independently (monthly steps from March, no extra): the loan at 130.00 a month is
-- paid off in Jul 2027 (17 months, against 22 at the minimum); its 130.00 then rolls to the card,
-- paid off in Jan 2028 (23 months, against 29).
select pg_temp.check((select payoff_month = '2027-07-31' and months_to_payoff = 17
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'loan'),
  'the scheduled payment drives the payoff month');
select pg_temp.check((select payoff_month = '2028-01-31' and months_to_payoff = 23
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'card'),
  'once the debt is gone, its scheduled payment rolls to the next one');
select pg_temp.check((select months_to_payoff = 22 from before_link where debt_key = 'loan')
                     and (select months_to_payoff = 29 from before_link where debt_key = 'card'),
  'without the link the plan runs on the minimum, as before');

-- A scheduled bill smaller than the minimum changes nothing.
update ref.bills set amount = 40.00 where bill_key = 'loanpay';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select a.payoff_month = b.payoff_month and a.monthly_amount = b.monthly_amount
                             and not exists (select 1 from unnest(a.notes) n where n like 'Planned at%')
                        from calc.debt_payoff_plan('2026-02-10', 0) a join before_link b using (debt_key)
                       where debt_key = 'loan'),
  'a bill below the minimum leaves the minimum in charge');

select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(payment_bill_key) from ref.current_debts') = '1',
  'the assistant can read the link');

rollback;
