\set ON_ERROR_STOP 1
\echo '== 26 payday plan and the low-balance warning window'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Pay dates in the fixture: Fri Feb 13, Feb 27, Mar 13, Mar 27 ...
select pg_temp.check(calc._warning_window_end('2026-02-10') = '2026-03-12',
  'warnings look through the next two paychecks: to the day before the third pay date');
select pg_temp.check(calc._warning_window_end('2026-02-13') = '2026-03-26',
  'on a pay date, the window starts from the pay dates after today');

-- Three days before payday: no plan in the briefing yet, the usual due-before-income line.
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'payday_plan')
                             and exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'due_before_income')
                        from calc.briefing),
  'three days out: no payday plan, due-before-income stays');

-- Two days before payday: the plan.
select calc.refresh_all(null, '2026-02-11');
select pg_temp.check((select p ->> 'pay_on' = '2026-02-13' and p ->> 'through' = '2026-02-26' and p ->> 'next_income_on' = '2026-02-27'
                        from calc.payday_plan('2026-02-11') p),
  'the plan covers the pay date through the day before the next income');
select pg_temp.check((select (p -> 'accounts' -> 0 ->> 'start')::numeric = 1500.00
                             and (p -> 'accounts' -> 0 ->> 'left')::numeric = 348.02
                             and (p -> 'incomes' -> 0 ->> 'amount')::numeric = 1000.00
                        from calc.payday_plan('2026-02-11') p),
  'starts from the balance plus the paycheck and ends with what''s left after every bill');
-- Late bills (January ended unpaid in the fixture) come first, then by due date; Feb 12 gym is
-- before payday but in the list; power (a match waits) and Feb 20 streams (proposals wait) are not.
select pg_temp.check((select (p -> 'bills' -> 0 ->> 'late')::boolean and p -> 'bills' -> 0 ->> 'bill_key' = 'insurance'
                             and p -> 'bills' -> -1 ->> 'bill_key' = 'gym' and p -> 'bills' -> -1 ->> 'due_on' = '2026-02-12'
                             and not (p -> 'bills' -> -1 ->> 'late')::boolean
                             and (p -> 'bills' -> -1 ->> 'balance_after')::numeric = 348.02
                             and (p -> 'totals' ->> 'bill_count')::int = jsonb_array_length(p -> 'bills')
                             and (p -> 'totals' ->> 'manual')::numeric + (p -> 'totals' ->> 'autopay')::numeric = (p -> 'totals' ->> 'bills')::numeric
                        from calc.payday_plan('2026-02-11') p),
  'late bills first, then by due date, each with the running balance');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(p -> 'bills') x
                                          where x ->> 'due_on' > '2026-02-26')
                        from calc.payday_plan('2026-02-11') p),
  'nothing due after the stretch is in the plan');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(items) e
                                      where e ->> 'kind' = 'payday_plan' and e ->> 'level' = 'GREEN'
                                        and e ->> 'text' like 'Payday plan for Fri Feb 13, through Thu Feb 26: Paycheck $1,000.00 in.%Left after everything: Joint checking $348.02.')
                             and not exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'due_before_income')
                        from calc.briefing),
  'two days out: the briefing has the plan, and the due-before-income line folds into it');

-- A previous-month bill past its due date this month is flagged, not called late (rule 4).
select calc.refresh_all(null, '2026-02-13');
select pg_temp.check((select bool_and(not (x ->> 'past_due_date')::boolean or not (x ->> 'late')::boolean)
                        from calc.payday_plan('2026-02-13') p, jsonb_array_elements(p -> 'bills') x),
  'past its due date and late are never both set');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(p -> 'bills') x
                                      where x ->> 'bill_key' = 'gym' and x ->> 'due_on' = '2026-02-12' and (x ->> 'past_due_date')::boolean)
                        from calc.payday_plan('2026-02-13') p),
  'on payday, a bill due yesterday is past its due date and still in the plan');

-- Overdraft warnings: a big bill on Mar 20 (outside the window that ends Mar 12) is left out...
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('big', 'Big bill', 5000.00, 'fixed', 20, 'chk', false, 'monthly', '2026-03-01');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select exists (select 1 from calc.cash_projection where account_key = 'chk' and day = '2026-03-20' and closing < 0)),
  'the projection still shows the far-off dip');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft') from calc.briefing),
  'a dip only past the next two paychecks is not warned about');
-- ...but the same bill on Feb 20, inside the window, is.
update ref.bills set valid_from = '2026-02-01' where bill_key = 'big';
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft' and e ->> 'level' = 'YELLOW') from calc.briefing),
  'a dip inside the next two paychecks is still warned about');
delete from ref.bills where bill_key = 'big';

-- A small dip inside the buffer counts only before the next pay date: gym on Feb 12 takes
-- checking to -$30 (inside $50) before Feb 13's pay, so it shows...
select actions.record_balance('james', 'chk', 30.00, '2026-02-10 09:00-05');
update ref.accounts set overdraft_buffer = 50 where account_key = 'chk' and valid_to is null;
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft'
                                        and e ->> 'text' like '%dips below $0 on Thu Feb 12, before the next income on Fri Feb 13.%no fee is expected.')
                        from calc.briefing),
  'inside the buffer before the next pay date: mentioned');
-- ...but with the balance high enough that the first dip is after payday, still inside the buffer, it doesn't.
select actions.record_balance('james', 'chk', 70.00, '2026-02-10 10:00-05');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from, valid_to)
values ('dip', 'Dip bill', 1330.00, 'fixed', 12, 'chk', false, 'monthly', '2026-03-01', '2026-04-01');   -- Mar 12 ends at -$20
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not exists (select 1 from calc.cash_projection where account_key = 'chk' and day < '2026-02-13' and closing < 0)
                             and exists (select 1 from calc.cash_projection where account_key = 'chk' and day <= '2026-03-12' and closing between -50 and -0.01)
                             and not exists (select 1 from calc.cash_projection where account_key = 'chk' and day <= '2026-03-12' and closing < -50)
                        from calc.briefing),
  'setup: the only dip in the window is after payday and inside the buffer');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft') from calc.briefing),
  'inside the buffer after the next pay date: not mentioned');
rollback;
