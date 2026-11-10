-- D2. Let the history load be run again from the top (for example after a fix to how it
-- reads Era) without touching earlier pull_runs rows: only full runs started after p_after count.
--
-- Added as raw.next_full_month_after, and raw.next_full_month now calls it. No DROP, because the
-- Supabase confirm dialog for DROP statements doesn't open for James. A new name instead of a second
-- form of next_full_month, because next_full_month('2026-08-15') would then pick the wrong one.

create function raw.next_full_month_after(p_after timestamptz, p_floor date default date '2000-01-01')
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

create or replace function raw.next_full_month(p_floor date default date '2000-01-01')
returns date
language sql
stable
set search_path = ''
as $$
  select raw.next_full_month_after('-infinity'::timestamptz, p_floor);
$$;

revoke all on function raw.next_full_month_after(timestamptz, date) from public, anon, authenticated;
grant execute on function raw.next_full_month_after(timestamptz, date) to ingest;
