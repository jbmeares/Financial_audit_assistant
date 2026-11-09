\set ON_ERROR_STOP 1
\echo '== 07 cash projection, debts and the briefing'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

select calc.refresh_all(null, '2026-02-10');

-- Starting balances.
select pg_temp.check((select balance = 500.00 and source = 'era' from calc.account_balances where account_key = 'chk'),
  'checking starts from Era''s available figure');
select pg_temp.check((select balance = 1000.00 from calc.account_balances where account_key = 'sav'),
  'savings with no available figure uses current');
select pg_temp.check((select balance is null from calc.account_balances where account_key = 'loan'),
  'an account with no balance has none, not a guess');

-- Normal month in the projection.
select pg_temp.check((select count(*) = 60 from calc.cash_projection where account_key = 'chk'), '60 days per account');
select pg_temp.check(not exists (select 1 from calc.cash_projection where account_key in ('card', 'loan')),
  'cards, loans and accounts with no balance are left out');
select pg_temp.check((select opening = 500.00 and closing = 500.00 from calc.cash_projection where account_key = 'chk' and day = '2026-02-10'),
  'day one opens at the starting balance');
select pg_temp.check((select money_out = 60.00 and closing = 440.00 from calc.cash_projection where account_key = 'chk' and day = '2026-02-12'),
  'the gym bill comes out on its due date');
select pg_temp.check((select money_in = 1000.00 and closing = 1440.00 from calc.cash_projection where account_key = 'chk' and day = '2026-02-13'),
  'income arrives on its biweekly pay date');
select pg_temp.check((select money_out = 600.00 and closing = 1840.00 and detail @> '[{"key": "rent"}]'
                        from calc.cash_projection where account_key = 'chk' and day = '2026-02-28'),
  'short month: rent comes out Feb 28, and the day says what moved');
select pg_temp.check((select money_out = 0 from calc.cash_projection where account_key = 'chk' and day = '2026-02-15'),
  'a bill with a pending match isn''t taken out twice');
select pg_temp.check((select closing = 3968.02 from calc.cash_projection where account_key = 'chk' and day = '2026-04-10'),
  'the last day adds up');
select pg_temp.check(not exists (select 1 from calc.cash_projection where below_zero), 'no day goes below zero');

-- Debts.
select pg_temp.check((select balance = 1200.00 and est_monthly_interest = 24.00 and source_ok
                        from (select *, balance_source = 'era' as source_ok from calc.debt_snapshot where debt_key = 'card') d),
  'the card shows its Era balance and balance x APR / 12');
select pg_temp.check((select balance is null and est_monthly_interest is null from calc.debt_snapshot where debt_key = 'loan'),
  'a debt with no balance is not guessed');

-- The briefing, a normal day.
select pg_temp.check((select level = 'YELLOW' and today = '2026-02-10' and numbers_as_of = '2026-02-10 00:04-05' and next_income_on = '2026-02-13'
                        from calc.briefing), 'the briefing has its date, how old its numbers are and the next income');
select pg_temp.check((select items @> '[{"kind": "pending_matches"}]' and items @> '[{"kind": "late_bills"}]'
                             and items @> '[{"kind": "debt_no_balance"}]' and items @> '[{"kind": "no_balance"}]'
                        from calc.briefing), 'pending matches, late bills and missing balances are named');
select pg_temp.check((select (e -> 'data' ->> 'total')::numeric = 60.00 and e -> 'data' -> 'bills' @> '[{"bill_key": "gym"}]'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'due_before_income'),
  'bills due before the next income: the gym, 60.00');
select pg_temp.check(not exists (select 1 from calc.briefing, jsonb_array_elements(items) e where e ->> 'level' = 'RED'),
  'nothing is RED on a normal day');

-- A stated balance beats Era when it is newer (rule 3), and that can make it RED.
select actions.record_balance('james', 'chk', 30.00, '2026-02-10 09:00-05');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select balance = 30.00 and source = 'stated' from calc.account_balances where account_key = 'chk'),
  'a newer stated balance beats Era');
select pg_temp.check((select closing = -30.00 from calc.cash_projection where account_key = 'chk' and day = '2026-02-12'),
  'the projection starts from it');
select pg_temp.check((select level = 'RED' and items -> 0 ->> 'kind' = 'overdraft' and items -> 0 ->> 'text' like '%Gym%before the next income%'
                        from calc.briefing), 'an overdraft before the next income is RED, first, and names what pulls');

-- Era reporting a newer balance takes over again.
insert into raw.era_balances (era_account_id, current, available, as_of, payload)
values ('era-chk', 820.00, 800.00, '2026-02-10 12:00-05', '{}');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select balance = 800.00 and source = 'era' from calc.account_balances where account_key = 'chk'),
  'a newer Era balance takes over from the stated one');

-- A month with no income.
delete from ref.income_sources;
select actions.record_balance('james', 'chk', 30.00, '2026-02-10 13:00-05');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select level = 'YELLOW' and next_income_on is null from calc.briefing), 'no income: not RED');
select pg_temp.check((select items @> '[{"kind": "projection_incomplete", "level": "YELLOW"}]'
                             and items @> '[{"kind": "overdraft", "level": "YELLOW"}]' from calc.briefing),
  'no income: the briefing says the projection is incomplete and the low balance is only YELLOW');
select pg_temp.check((select (e -> 'data' ->> 'through')::date = '2026-02-23'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'due_before_income'),
  'no income: bills due are shown for the next 14 days');
select pg_temp.check(not exists (select 1 from calc.cash_projection where money_in > 0), 'no income: nothing comes in');

-- Stale data, keys and pulls.
insert into ref.api_keys (key_name, scope, expires_on, valid_from) values
  ('test-soon', 'banking:read', '2026-03-01', '2026-01-01'),
  ('test-expired', 'banking:read', '2026-02-01', '2026-01-01');
insert into raw.pull_runs (kind, status, started_at, finished_at, error)
values ('nightly', 'failed', '2026-02-10 00:30-05', '2026-02-10 00:31-05', 'auth: 401 from Era');
select calc.refresh_all(null, '2026-02-15');
select pg_temp.check((select items @> '[{"kind": "key_expiry", "level": "RED"}]' and items @> '[{"kind": "key_expiry", "level": "YELLOW"}]'
                        from calc.briefing), 'an expired key is RED, one expiring within 30 days is YELLOW');
select pg_temp.check((select items @> '[{"kind": "pull", "level": "RED"}]' from calc.briefing), 'a pull that failed on auth is RED');
select pg_temp.check((select items @> '[{"kind": "no_pull_today"}]' and items @> '[{"kind": "stale_accounts"}]' from calc.briefing),
  'five days on: no pull today and balances older than 3 days are YELLOW');
select pg_temp.check((select numbers_as_of = '2026-02-10 00:04-05' from calc.briefing), 'numbers_as_of is the last good pull');

-- Who can run it.
select pg_temp.expect_error('assistant_read', $$select calc.refresh_all()$$, '%permission denied%', 'assistant_read can''t run the refresh');
select pg_temp.expect_error('assistant_act', $$select calc.refresh_all()$$, '%permission denied%', 'assistant_act can''t run it directly');
select pg_temp.check((pg_temp.as_role('ingest', $$select calc.refresh_all(null, '2026-02-10') ->> 'ok'$$))::boolean, 'ingest can run the refresh');
select pg_temp.check((pg_temp.as_role('assistant_read', $$select level from calc.briefing$$)) is not null, 'assistant_read can read the briefing');
select pg_temp.expect_error('assistant_read', $$select calc._project(current_date)$$, '%permission denied%', 'the inner steps aren''t open to anyone');
rollback;
