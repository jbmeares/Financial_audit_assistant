\set ON_ERROR_STOP 1
\echo '== 23 overdraft buffer per account'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Checking at $30 with the $60 gym bill on Thu Feb 12 dips to -$30 before Fri Feb 13's income.
select actions.record_balance('james', 'chk', 30.00, '2026-02-10 09:00-05');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select level = 'RED' from calc.briefing), 'no buffer: a dip below $0 before income is RED');

-- A $50 buffer: -$30 stays inside it, so YELLOW, and nothing else is RED.
update ref.accounts set overdraft_buffer = 50 where account_key = 'chk' and valid_to is null;
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select e ->> 'level' = 'YELLOW'
                             and e ->> 'text' like '%dips below $0 on Thu Feb 12%within its $50.00 overdraft buffer, so no fee is expected.'
                             and (e -> 'data' ->> 'overdraft_buffer')::numeric = 50
                             and e -> 'data' -> 'first_below_buffer_on' = 'null'::jsonb
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft'),
  'a dip that stays inside the buffer is YELLOW and says so');
select pg_temp.check((select level <> 'RED' from calc.briefing), 'inside the buffer: the briefing is not RED');

-- A $20 buffer: -$30 passes it before income, so RED again, named against the buffer.
update ref.accounts set overdraft_buffer = 20 where account_key = 'chk' and valid_to is null;
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select e ->> 'level' = 'RED'
                             and e ->> 'text' like 'Joint checking goes below -$20.00 (past its $20.00 overdraft buffer) on Thu Feb 12 when Gym%before the next income on Fri Feb 13.%'
                             and (e -> 'data' ->> 'first_below_buffer_on')::date = '2026-02-12'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'overdraft'),
  'past the buffer before income is RED and names the day it passes the buffer');
select pg_temp.check((select level = 'RED' and items -> 0 ->> 'kind' = 'overdraft' from calc.briefing),
  'past the buffer: RED and first');

-- A buffer can't be negative.
select pg_temp.check((select count(*) = 0 from ref.accounts where overdraft_buffer < 0), 'no negative buffers');
rollback;
