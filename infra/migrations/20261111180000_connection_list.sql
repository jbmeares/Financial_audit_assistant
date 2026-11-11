-- The running list of accounts that should be connected, and whether each one is.
-- James asked for it on 2026-11-11, after the "stale" list confused him: Era archives a
-- connection after about 30 days with no new data, so it drops out of his main view.
--
-- ref.accounts.connection says how each account is meant to reach us:
--   era     it should come through Era (connected, or still to connect)
--   manual  it can't or won't be connected; people tell us its balance
-- A row with connection 'era' and no era_account_id is an account still to connect.
--
-- calc.connection_status compares that list with what Era last sent. The briefing gets a
-- YELLOW item for accounts still to connect and accounts Era stopped listing. Stale balances
-- already have their own item (stale_accounts).

alter table ref.accounts add column connection text not null default 'era'
  check (connection in ('era', 'manual'));
comment on column ref.accounts.connection is
  'era: should come through Era (a row with no era_account_id is still to connect). manual: tracked by hand.';

-- Backfill for the new column only. Every account Era doesn't see today is tracked by hand.
update ref.accounts set connection = 'manual' where era_account_id is null;

-- select * froze the old column list; recreate so the view shows connection.
create or replace view ref.current_accounts with (security_invoker = true) as
  select * from ref.accounts
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- One row per current account, plus one per account Era shows that nobody has mapped yet.
-- status:
--   ok             Era sent data in the last 3 days
--   stale          Era still lists it, but its newest data is older than 3 days
--   gone_from_era  Era no longer lists it, or shows it as anything but visible (disconnected, hidden)
--   to_connect     it should come through Era but isn't connected yet
--   manual         tracked by hand
--   not_tracked    Era has it, but it isn't in ref.accounts
create view calc.connection_status with (security_invoker = true) as
with last_good as (
  select max(started_at) as started_at from raw.pull_runs where status in ('ok', 'partial')
), era as (
  select a.era_account_id,
         a.payload ->> 'institutionName' as institution,
         a.payload ->> 'name' as era_name,
         a.payload ->> 'accountMask' as mask,
         a.payload ->> 'visibility' as visibility,
         coalesce((a.payload -> 'archive' ->> 'effective')::boolean, false) as era_archived,
         a.last_seen_at,
         greatest((select max(b.as_of) from raw.era_balances b where b.era_account_id = a.era_account_id),
                  (a.payload ->> 'balanceAsOf')::timestamptz) as last_data_at
    from raw.era_accounts a
   where not coalesce((a.payload ->> 'unlisted')::boolean, false)
)
select r.account_key, r.name, r.owner, r.kind, r.connection, r.era_account_id,
       e.institution, e.era_archived, e.last_data_at,
       case
         when r.connection = 'manual' then 'manual'
         when r.era_account_id is null then 'to_connect'
         when e.era_account_id is null
              or coalesce(e.visibility, 'visible') <> 'visible'
              or e.last_seen_at < (select started_at from last_good) then 'gone_from_era'
         when e.last_data_at is null or e.last_data_at < now() - interval '3 days' then 'stale'
         else 'ok'
       end as status,
       r.note
  from ref.current_accounts r
  left join era e on e.era_account_id = r.era_account_id
union all
select null, trim(coalesce(e.institution, '') || ' ' || coalesce(e.era_name, '') || coalesce(' ' || e.mask, '')),
       null, null, null, e.era_account_id,
       e.institution, e.era_archived, e.last_data_at, 'not_tracked', null
  from era e
 where coalesce(e.visibility, 'visible') = 'visible'
   and not exists (select 1 from ref.current_accounts r where r.era_account_id = e.era_account_id);

comment on view calc.connection_status is
  'The accounts that should be connected and whether they are: ok, stale, gone_from_era, to_connect, manual, not_tracked.';

grant select on calc.connection_status to assistant_read;

-- Briefing: the old builder keeps its name as _build_briefing_core; the new _build_briefing
-- runs it, then adds the connection item. refresh_all calls _build_briefing by name.
alter function calc._build_briefing(date, bigint) rename to _build_briefing_core;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_rows jsonb;
  v_item jsonb;
begin
  perform calc._build_briefing_core(p_today, p_pull_run_id);

  select jsonb_agg(jsonb_build_object('account_key', account_key, 'name', name, 'status', status,
                                      'last_data_at', last_data_at) order by status desc, name)
    into v_rows from calc.connection_status where status in ('to_connect', 'gone_from_era');
  if v_rows is null then
    return;
  end if;

  v_item := jsonb_build_object('level', 'YELLOW', 'kind', 'connections',
    'text', concat_ws(' ',
              'Not connected yet: ' || (select string_agg(e ->> 'name', ', ') from jsonb_array_elements(v_rows) e
                                         where e ->> 'status' = 'to_connect') || '.',
              'Era no longer lists: ' || (select string_agg(e ->> 'name', ', ') from jsonb_array_elements(v_rows) e
                                           where e ->> 'status' = 'gone_from_era') || '.'),
    'data', jsonb_build_object('accounts', v_rows));

  -- Keep the order: RED, then YELLOW (this item last among them), then GREEN.
  update calc.briefing b
     set items = (select jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n)
                    from jsonb_array_elements(b.items || jsonb_build_array(v_item)) with ordinality as x(e, n)),
         level = case when b.level = 'GREEN' then 'YELLOW' else b.level end;
end
$$;
