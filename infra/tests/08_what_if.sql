\set ON_ERROR_STOP 1
\echo '== 08 what_if'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

select calc.refresh_all(null, '2026-02-10');
create temp table before_counts as
  select (select count(*) from calc.cash_projection) as proj, (select count(*) from knowledge.proposed_matches) as matches,
         (select generated_at from calc.briefing) as gen;

-- A one-off expense before payday.
create temp table r1 as select calc.what_if('{"type": "one_off_expense", "account_key": "chk", "amount": 600, "on": "2026-02-11", "label": "Car repair"}', '2026-02-10') as r;
select pg_temp.check((select (a -> 'baseline' ->> 'lowest')::numeric = 440.00 and (a -> 'scenario' ->> 'lowest')::numeric = -160.00
                             and a -> 'scenario' ->> 'first_below_zero_on' = '2026-02-11' and a -> 'baseline' ->> 'first_below_zero_on' is null
                             and (a ->> 'lowest_change')::numeric = -600.00
                        from r1, jsonb_array_elements(r -> 'accounts') a where a ->> 'account_key' = 'chk'),
  'a one-off expense shows the new low point and the day it goes below zero');
select pg_temp.check((select (a ->> 'lowest_change')::numeric = 0 from r1, jsonb_array_elements(r -> 'accounts') a where a ->> 'account_key' = 'sav'),
  'other accounts don''t move');

-- Skipping a bill.
select pg_temp.check((select (a ->> 'end_change')::numeric = 600.00
                        from jsonb_array_elements(calc.what_if('[{"type": "skip_bill", "bill_key": "rent", "due_month": "2026-02-01"}]', '2026-02-10') -> 'accounts') a
                       where a ->> 'account_key' = 'chk'), 'skipping February rent leaves 600 more at the end');

-- An income change.
select pg_temp.check((select (a ->> 'end_change')::numeric = -2000.00
                        from jsonb_array_elements(calc.what_if('{"type": "income_change", "income_key": "pay", "amount": 500, "from": "2026-02-14"}', '2026-02-10') -> 'accounts') a
                       where a ->> 'account_key' = 'chk'), 'a pay cut from Feb 14 removes 500 from each of the four later paychecks (Feb 27 to Apr 10)');

-- An extra payment moves the payoff date.
create temp table r2 as select calc.what_if('{"type": "extra_payment", "debt_key": "card", "amount": 500, "on": "2026-02-20", "account_key": "chk"}', '2026-02-10') as r;
select pg_temp.check((select (p ->> 'scenario_payoff')::date < (p ->> 'baseline_payoff')::date from r2, jsonb_array_elements(r -> 'payoffs') p
                       where p ->> 'debt_key' = 'card'), 'an extra 500 on the card pays it off sooner');
select pg_temp.check((select (a ->> 'end_change')::numeric = -500.00 from r2, jsonb_array_elements(r -> 'accounts') a where a ->> 'account_key' = 'chk'),
  'and the 500 comes out of checking');
select pg_temp.check((select (p ->> 'scenario_payoff')::date < (r2p ->> 'scenario_payoff')::date
                        from r2, jsonb_array_elements(r2.r -> 'payoffs') r2p,
                             jsonb_array_elements(calc.what_if('{"type": "extra_payment", "debt_key": "card", "amount": 100, "on": "2026-02-20", "account_key": "chk", "monthly": true}', '2026-02-10') -> 'payoffs') p),
  'a monthly 100 beats a single 500');
select pg_temp.check((select r -> 'notes' @> '["Payoff dates assume the minimum payment stays the same and payments start next month. They are estimates."]' from r2),
  'it says the payoff dates are estimates');

-- Several changes at once, and an empty list.
select pg_temp.check((select (a ->> 'end_change')::numeric = 0
                        from jsonb_array_elements(calc.what_if('[{"type": "one_off_expense", "account_key": "chk", "amount": 100, "on": "2026-02-11"},
                                                                {"type": "skip_bill", "bill_key": "power", "due_month": "2026-03-01"}]', '2026-02-10') -> 'accounts') a
                       where a ->> 'account_key' = 'chk'), 'two changes combine');
select pg_temp.check((select (a ->> 'lowest_change')::numeric = 0 from jsonb_array_elements(calc.what_if('[]', '2026-02-10') -> 'accounts') a
                       where a ->> 'account_key' = 'chk'), 'no changes, no difference');

-- Refused by name, never ignored.
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "lottery_win", "amount": 1}')$$, '%doesn''t know the change "lottery_win"%', 'an unknown change is refused by name');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "one_off_expense", "account_key": "chk", "amount": 5, "on": "2026-02-11", "colour": "red"}')$$,
  '%doesn''t take: colour%', 'an unknown field is refused by name');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "one_off_expense", "account_key": "chk", "amount": 5}')$$, '%needs: on%', 'a missing field is named');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "one_off_expense", "account_key": "nope", "amount": 5, "on": "2026-02-11"}')$$,
  '%no account "nope"%', 'an unknown account is refused');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "skip_bill", "bill_key": "nope", "due_month": "2026-02-01"}')$$, '%no bill "nope"%', 'an unknown bill is refused');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "one_off_expense", "account_key": "chk", "amount": "lots", "on": "2026-02-11"}')$$,
  '%wrong type%', 'a non-number amount is refused');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "one_off_expense", "account_key": "chk", "amount": -5, "on": "2026-02-11"}')$$,
  '%above 0%', 'a negative amount is refused');
select pg_temp.expect_error(null, $$select calc.what_if('"spend 100"')$$, '%takes a change or a list%', 'text instead of a change is refused');

-- It writes nothing, and assistant_read can run it.
select pg_temp.check((select proj = (select count(*) from calc.cash_projection) and matches = (select count(*) from knowledge.proposed_matches)
                             and gen = (select generated_at from calc.briefing) from before_counts), 'what_if changed nothing');
select pg_temp.check((select provolatile = 's' from pg_proc where oid = 'calc.what_if(jsonb, date)'::regprocedure),
  'what_if is STABLE, so Postgres refuses any write inside it');
select pg_temp.check(pg_temp.as_role('assistant_read', $$select calc.what_if('[]', '2026-02-10') ->> 'today'$$) = '2026-02-10',
  'assistant_read can run what_if');
select pg_temp.expect_error('assistant_act', $$select calc.what_if('[]')$$, '%permission denied%', 'assistant_act can''t');
rollback;
