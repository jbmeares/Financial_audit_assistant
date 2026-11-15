\set ON_ERROR_STOP 1
\echo '== 24 debt parts: promos, reduced-APR plans and the rest at the APR'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on the calc fixture (today Tue 2026-02-10). The fixture's card owes 1,200.00 at
-- 24%, minimum 35. Its statement (Jan 20) splits it like James's CareCredit:
--   300.00 deferred interest to Mar 1 (back interest 20.00 so far)
--   200.00 deferred interest to Jun 15 (back interest 5.00 so far)
--   400.00 on a reduced-APR plan at 12%
-- so 300.00 is left at the full 24%.
insert into ref.debt_buckets (debt_key, kind, amount, apr, ends_on, deferred_interest, as_of, valid_from) values
  ('card', 'deferred_interest', 300.00, 24, '2026-03-01', 20.00, '2026-01-20', '2026-01-01'),
  ('card', 'deferred_interest', 200.00, 24, '2026-06-15', 5.00, '2026-01-20', '2026-01-01'),
  ('card', 'reduced_apr', 400.00, 12, null, null, '2026-01-20', '2026-01-01');
-- The loan (6%) has no parts; give it a stated balance.
insert into ledger.balance_statements (account_key, balance, as_of, entered_by)
values ('loan', 2000.00, '2026-02-09 12:00-05', 'james');
select calc.refresh_all(null, '2026-02-10');

select pg_temp.check((select promo_balance = 500 and reduced_apr_balance = 400 and full_apr_balance = 300
                             and deferred_interest_at_risk = 25 and promo_end_on = '2026-03-01'
                        from calc.debt_snapshot where debt_key = 'card'),
  'the snapshot splits the balance into promos, the reduced-APR plan and the rest');
select pg_temp.check((select est_monthly_interest = 10.00 from calc.debt_snapshot where debt_key = 'card'),
  'monthly interest is worked out per part: none on promos, 12% on the plan, 24% on the rest');
select pg_temp.check((select string_agg(kind || ':' || amount || '@' || rate_now, ',' order by part_order)
                        from calc.debt_parts where debt_key = 'card')
                       = 'deferred_interest:300.00@0,deferred_interest:200.00@0,reduced_apr:400.00@12.000,full_apr:300.00@24.000',
  'calc.debt_parts lists each part in order with the rate charged now');
select pg_temp.check((select parts_text like 'Test card owes $1,200.00: $300.00 on a deferred-interest promo: no interest if paid in full by Mar 1, 2026.%'
                             and parts_text like '%$400.00 on a reduced-APR plan at 12.00% until paid off. $300.00 at the full 24.00% APR. About $10.00 interest a month%'
                             and parts_text like '%from the Jan 20, 2026 statement%'
                        from calc.debt_snapshot where debt_key = 'card'),
  'the split is written out, ready to say');
select pg_temp.check((select est_monthly_interest = round(2000 * 6 / 1200.0, 2) and parts_text is null and full_apr_balance = 2000
                        from calc.debt_snapshot where debt_key = 'loan'),
  'a debt with no parts is all at its APR, as before');

-- Briefing: a promo ending within 30 days names its amount and back interest; the split is GREEN.
select pg_temp.check((select items @> '[{"level": "YELLOW", "kind": "promo_ending", "data": {"debt_key": "card", "amount": 300.00, "days_left": 19, "deferred_interest": 20.00}}]'
                             and not items @> '[{"kind": "promo_ending", "data": {"promo_end_on": "2026-06-15"}}]'
                        from calc.briefing),
  'the briefing names the promo ending within 30 days with its amount');
select pg_temp.check((select (e ->> 'text') like '$300.00 of Test card is on a deferred-interest promo that ends %, in 19 days.%($20.00 built up as of the Jan 20 statement, and growing).'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'promo_ending'),
  'the promo item says what it costs to miss');
select pg_temp.check((select count(*) = 1 from calc.briefing, jsonb_array_elements(items) e
                       where e ->> 'kind' = 'debt_parts' and e ->> 'level' = 'GREEN'
                         and e -> 'data' ->> 'full_apr_balance' = '300.00'),
  'the briefing carries the split as a GREEN item');

-- Payoff plan: the plan's rate, the note, and back interest when a promo is missed.
select pg_temp.check((select notes @> array['On promo: $300.00 by Mar 1, 2026, $200.00 by Jun 15, 2026. On a reduced-APR plan: $400.00 at 12.00%. The rest is at the full APR.']
                        from calc.debt_payoff_plan('2026-02-10') where debt_key = 'card'),
  'the payoff plan names the promos and the reduced-APR plan');
select pg_temp.check((select promo_at_risk and total_interest >= 20
                             and notes @> array['A promo misses its deadline at this pace, so its back interest is added (at least what the last statement showed).']
                        from calc.debt_payoff_plan('2026-02-10', 0) where debt_key = 'card'),
  'a missed promo adds its back interest');
select pg_temp.check((select a.total_interest < b.total_interest
                        from calc.debt_payoff_plan('2026-02-10', 2000) a, calc.debt_payoff_plan('2026-02-10', 0) b
                       where a.debt_key = 'card' and b.debt_key = 'card'),
  'paying more costs less interest');

-- A lower balance: parts are capped in order, and nothing is left at the full APR.
insert into ledger.balance_statements (account_key, balance, as_of, entered_by)
values ('card', 600.00, '2026-02-10 08:00-05', 'james');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select promo_balance = 500 and reduced_apr_balance = 100 and full_apr_balance = 0 and est_monthly_interest = 1.00
                        from calc.debt_snapshot where debt_key = 'card'),
  'parts never add up to more than the balance');

-- After the first promo ends, it is part of the full-APR rest.
select calc.refresh_all(null, '2026-03-02');
select pg_temp.check((select promo_balance = 200 and promo_end_on = '2026-06-15' and deferred_interest_at_risk = 5
                        from calc.debt_snapshot where debt_key = 'card'),
  'an ended promo drops out of the parts');

-- Checks on the table.
select pg_temp.expect_error(null,
  $$insert into ref.debt_buckets (debt_key, kind, amount, apr, ends_on, as_of) values ('card', 'deferred_interest', 10, 24, null, '2026-01-20')$$,
  '%check%', 'a promo needs an end date');
select pg_temp.expect_error(null,
  $$insert into ref.debt_buckets (debt_key, kind, amount, apr, ends_on, as_of) values ('card', 'reduced_apr', 10, 12, '2026-05-01', '2026-01-20')$$,
  '%check%', 'a reduced-APR plan has no end date');
select pg_temp.expect_error(null,
  $$insert into ref.debt_buckets (debt_key, kind, amount, apr, ends_on, as_of) values ('nope', 'reduced_apr', 10, 12, null, '2026-01-20')$$,
  '%Unknown debt_key%', 'a part must belong to a debt');

-- Access.
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from ref.current_debt_buckets') = '3',
  'the assistant can read the parts');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from calc.debt_parts where debt_key = ''card''') = '2',
  'the assistant can read calc.debt_parts (the 200.00 promo and the plan; nothing left at the full APR)');
select pg_temp.expect_error('assistant_read', $$select * from calc._debt_parts('card', 100, 24, '2026-02-10')$$,
  '%permission denied%', 'the inner step is open to no role');

rollback;
