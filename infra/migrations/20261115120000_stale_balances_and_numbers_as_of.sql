-- Two briefing fixes found in the shadow week (open question 7), 2026-11-15.
--
-- 1. numbers_as_of was one night behind. The nightly pull calls calc.refresh_all before it
--    marks its own run ok, so the briefing looked up "the last good pull" and found the night
--    before. Now, when the refresh is called by a pull that is still running, numbers_as_of is
--    the time this refresh ran (the pull finishes a moment later).
--
-- 2. Era balances more than a day old were silent until they were 3 days old. On Nov 15 every
--    bank Era reads (Chase, Capital One, Synchrony, Mr. Cooper, ...) still showed balances from
--    Fri Nov 13, and nothing said so. A new YELLOW item, stale_balances, names Era-connected
--    checking, savings, card and loan balances dated before yesterday (New York time). Ones
--    already older than 3 days stay in the stale_accounts item, so nothing is listed twice.
--    Investment and retirement accounts and manual accounts are left out.
--
-- No DROP: the current builder keeps running under a new name, like the earlier wrappers.

alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_stale_balances;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_rows      jsonb;
  v_item      jsonb;
  v_oldest    date;
  v_all       boolean;
  v_text      text;
begin
  perform calc._build_briefing_before_stale_balances(p_today, p_pull_run_id);

  -- 1. A pull that is still running and called this refresh is the newest good pull.
  if p_pull_run_id is not null
     and exists (select 1 from raw.pull_runs where id = p_pull_run_id and status = 'running') then
    update calc.briefing set numbers_as_of = clock_timestamp();
  end if;

  -- 2. Era balances dated before yesterday.
  with tracked as (
    select ab.account_key, ab.name, ab.as_of, ab.stale, ab.source,
           coalesce(ea.payload ->> 'institutionName', 'Era') as institution
      from calc.account_balances ab
      join ref.accounts a
        on a.account_key = ab.account_key
       and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
      left join raw.era_accounts ea on ea.era_account_id = a.era_account_id
     where a.connection = 'era'
       and a.era_account_id is not null
       and a.kind in ('checking', 'savings', 'card', 'loan')
       and ab.balance is not null
  )
  select jsonb_agg(jsonb_build_object('account_key', account_key, 'name', name, 'institution', institution, 'as_of', as_of)
                   order by institution, name),
         min((as_of at time zone 'America/New_York')::date),
         not exists (select 1 from tracked t where t.source = 'era'
                        and (t.as_of at time zone 'America/New_York')::date >= p_today - 1)
    into v_rows, v_oldest, v_all
    from tracked
   where source = 'era'
     and not stale
     and (as_of at time zone 'America/New_York')::date < p_today - 1;

  if v_rows is null then
    return;
  end if;

  if v_all then
    v_text := 'Era hasn''t refreshed any bank since ' || calc._day_text(v_oldest)
              || ', so every balance here is from then. Open Era and refresh the bank connections.';
  else
    v_text := 'Balances more than a day old: '
              || (select string_agg(i.institution || ' (' || i.names || ', ' || calc._day_text(i.d) || ')', '; ' order by i.institution)
                    from (select e ->> 'institution' as institution,
                                 string_agg(e ->> 'name', ', ' order by e ->> 'name') as names,
                                 min(((e ->> 'as_of')::timestamptz at time zone 'America/New_York')::date) as d
                            from jsonb_array_elements(v_rows) e
                           group by 1) i)
              || '. Era may need those connections refreshed.';
  end if;

  v_item := jsonb_build_object('level', 'YELLOW', 'kind', 'stale_balances', 'text', v_text,
    'data', jsonb_build_object('oldest', v_oldest, 'every_bank', v_all, 'accounts', v_rows));

  -- Keep the order: RED, then YELLOW (this item last among them), then GREEN.
  update calc.briefing b
     set items = (select jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n)
                    from jsonb_array_elements(b.items || jsonb_build_array(v_item)) with ordinality as x(e, n)),
         level = case when b.level = 'GREEN' then 'YELLOW' else b.level end;
end
$$;

comment on column calc.briefing.numbers_as_of is
  'When the last good pull finished. During a pull''s own refresh, the time of that refresh. Null means no pull has finished yet. This is when we last asked Era, not how new the bank balances are: see the stale_balances item.';
