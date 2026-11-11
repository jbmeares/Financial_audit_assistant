\set ON_ERROR_STOP 1
\echo '== 13 the list of accounts that should be connected'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture. The fixture's 'loan' has no Era account, so it
-- reads as still to connect until it's marked manual.
update ref.accounts set connection = 'manual' where account_key = 'loan';
insert into raw.era_accounts (era_account_id, payload, content_hash, last_seen_at) values
  ('era-fresh', jsonb_build_object('name', 'Fresh card', 'visibility', 'visible'), 'h', now()),
  ('era-old', '{"name": "Old card", "visibility": "visible", "archive": {"effective": true}}', 'h', now()),
  ('era-cut', '{"name": "Cut loan", "visibility": "connectionSevered"}', 'h', now()),
  ('era-dropped', '{"name": "Dropped card", "visibility": "visible"}', 'h', '2026-01-01'),
  ('era-extra', '{"name": "Brokerage", "institutionName": "Bank", "accountMask": "6663", "visibility": "visible"}', 'h', now()),
  ('era-stub', '{"unlisted": true}', 'h', now());
insert into raw.era_balances (era_account_id, current, available, as_of, payload) values
  ('era-fresh', 10.00, null, now() - interval '1 day', '{}'),
  ('era-old', 10.00, null, now() - interval '40 days', '{}'),
  ('era-dropped', 10.00, null, now() - interval '1 day', '{}');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, valid_from) values
  ('fresh', 'era-fresh', 'Fresh card', 'james', 'card', '2026-01-01'),
  ('old', 'era-old', 'Old card', 'james', 'card', '2026-01-01'),
  ('cut', 'era-cut', 'Cut loan', 'joint', 'loan', '2026-01-01'),
  ('dropped', 'era-dropped', 'Dropped card', 'joint', 'card', '2026-01-01');
insert into ref.accounts (account_key, name, owner, kind, valid_from) values
  ('new-card', 'Katelyn new card', 'katelyn', 'card', '2026-01-01');

select pg_temp.check((select connection from ref.current_accounts where account_key = 'new-card') = 'era',
  'a new account defaults to "should come through Era"');
select pg_temp.check((select status from calc.connection_status where account_key = 'fresh') = 'ok', 'data from yesterday is ok');
select pg_temp.check((select status = 'stale' and era_archived from calc.connection_status where account_key = 'old'),
  'data 40 days old is stale, and Era''s archive flag shows');
select pg_temp.check((select status from calc.connection_status where account_key = 'cut') = 'gone_from_era',
  'a disconnected Era account is gone from Era');
select pg_temp.check((select status from calc.connection_status where account_key = 'dropped') = 'gone_from_era',
  'an account the last good pull didn''t list is gone from Era');
select pg_temp.check((select status from calc.connection_status where account_key = 'new-card') = 'to_connect',
  'an Era account with no Era id is still to connect');
select pg_temp.check((select status from calc.connection_status where account_key = 'loan') = 'manual', 'a manual account reads manual');
select pg_temp.check((select name from calc.connection_status where era_account_id = 'era-extra' and status = 'not_tracked') = 'Bank Brokerage 6663',
  'an Era account nobody mapped is listed as not tracked');
select pg_temp.check(not exists (select 1 from calc.connection_status where era_account_id in ('era-stub', 'era-cut') and status = 'not_tracked'),
  'stubs and disconnected accounts aren''t listed as not tracked');

-- The briefing.
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select e ->> 'text' = 'Not connected yet: Katelyn new card. Era no longer lists: Cut loan, Dropped card.'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'connections'),
  'the briefing names accounts to connect and accounts Era dropped');
select pg_temp.check((select (select array_agg(e ->> 'level' order by n) from jsonb_array_elements(items) with ordinality x(e, n))
                             = (select array_agg(e ->> 'level' order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n)
                                  from jsonb_array_elements(items) with ordinality x(e, n))
                        from calc.briefing), 'items stay in RED, YELLOW, GREEN order');
select pg_temp.check((select level <> 'GREEN' from calc.briefing), 'the connection item lifts a GREEN day to YELLOW');

update ref.accounts set connection = 'manual' where account_key = 'new-card';
update ref.accounts set valid_to = '2026-01-02' where account_key in ('cut', 'dropped');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select not (items @> '[{"kind": "connections"}]') from calc.briefing), 'no item when everything is connected or manual');

-- Who can read it.
select pg_temp.check((pg_temp.as_role('assistant_read', $$select count(*) from calc.connection_status$$))::int > 0,
  'assistant_read can read the list');
rollback;
