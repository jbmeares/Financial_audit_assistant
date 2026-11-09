-- D2. Let the history load be run again from the top (for example after a fix to how it
-- reads Era) without touching earlier pull_runs rows: only full runs started after p_after count.
drop function raw.next_full_month(date);

create function raw.next_full_month(p_floor date default date '2000-01-01', p_after timestamptz default '-infinity')
returns date
language sql
stable
set search_path = ''
as $$
  with done as (
    select window_start, coalesce((counts->>'transactions_seen')::int, 0) as seen
      from raw.pull_runs
     where kind = 'full' and status = 'ok' and started_at > p_after
  ), oldest as (
    select min(window_start) as m from done
  ), last_two as (
    select seen from done order by window_start asc limit 2
  )
  select case
    when (select m from oldest) is null then date_trunc('month', now() at time zone 'America/New_York')::date
    when (select count(*) from last_two) = 2 and (select sum(seen) from last_two) = 0 then null
    when ((select m from oldest) - interval '1 month')::date < p_floor then null
    else ((select m from oldest) - interval '1 month')::date
  end;
$$;

revoke all on function raw.next_full_month(date, timestamptz) from public, anon, authenticated;
grant execute on function raw.next_full_month(date, timestamptz) to ingest;
