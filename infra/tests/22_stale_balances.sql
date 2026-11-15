\set ON_ERROR_STOP 1
\echo '== 22 balances more than a day old, and numbers_as_of during a pull'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- The fixture's balances are from Mon Feb 9 and "today" is Tue Feb 10: yesterday is fine.
update ref.accounts set connection = 'manual' where account_key = 'loan';
update raw.era_accounts set payload = '{"institutionName": "Chase Bank"}' where era_account_id in ('era-chk', 'era-sav');
update raw.era_accounts set payload = '{"institutionName": "Capital One"}' where era_account_id = 'era-card';

select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not (items @> '[{"kind": "stale_balances"}]') from calc.briefing),
  'balances from yesterday aren''t flagged');

-- Wed Feb 11: every Era balance is from Mon Feb 9.
select calc.refresh_all(null, '2026-02-11');
select pg_temp.check((select e ->> 'text' = 'Era hasn''t refreshed any bank since Mon Feb 9, so every balance here is from then. Open Era and refresh the bank connections.'
                             and e ->> 'level' = 'YELLOW' and (e -> 'data' ->> 'every_bank')::boolean
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'stale_balances'),
  'when every bank is two days old, the briefing says Era hasn''t refreshed any bank');
select pg_temp.check((select not (items @> '[{"kind": "stale_accounts"}]') from calc.briefing),
  'not yet in the 3-day stale list');

-- Only Capital One is behind.
insert into raw.era_balances (era_account_id, current, available, as_of, payload) values
  ('era-chk', 520.00, 500.00, '2026-02-10 12:00-05', '{}'),
  ('era-sav', 1000.00, null, '2026-02-10 12:00-05', '{}');
select calc.refresh_all(null, '2026-02-11');
select pg_temp.check((select e ->> 'text' = 'Balances more than a day old: Capital One (Test card, Mon Feb 9). Era may need those connections refreshed.'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'stale_balances'),
  'when one bank is behind, the briefing names it and its accounts');

-- A stated balance newer than Era's isn't stale.
insert into ledger.balance_statements (account_key, balance, as_of, entered_by, note)
values ('card', 1150.00, '2026-02-10 18:00-05', 'james', 'test');
select calc.refresh_all(null, '2026-02-11');
select pg_temp.check((select not (items @> '[{"kind": "stale_balances"}]') from calc.briefing),
  'a newer stated balance clears it');

-- Older than 3 days moves to the stale_accounts item and isn't listed twice.
select calc.refresh_all(null, '2026-02-15');
select pg_temp.check((select items @> '[{"kind": "stale_accounts"}]' and not (items @> '[{"kind": "stale_balances"}]') from calc.briefing),
  'balances older than 3 days are only in stale_accounts');

-- numbers_as_of during a pull's own refresh.
insert into raw.pull_runs (kind, status, started_at) values ('nightly', 'running', now());
select calc.refresh_all((select max(id) from raw.pull_runs), '2026-02-11');
select pg_temp.check((select numbers_as_of > '2026-02-10 00:04-05' and numbers_as_of <= clock_timestamp() from calc.briefing),
  'a running pull''s own refresh dates the numbers now, not the night before');
select calc.refresh_all(null, '2026-02-11');
select pg_temp.check((select numbers_as_of = '2026-02-10 00:04-05' from calc.briefing),
  'a refresh outside a pull still uses the last finished good pull');
rollback;
