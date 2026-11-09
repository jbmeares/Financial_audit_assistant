-- D1. The write path for the nightly Era pull. The era-pull Edge Function fetches from Era,
-- turns each record into a plain row, and hands the rows to these functions. They run as
-- ingest (security invoker), so the pull can only touch raw and the calc refresh.
--
-- Rows come in already typed: { id, account_id, amount, occurred_on, pending, merchant, payload }.
-- The content hash is taken here, from the payload, so "did it change" has one definition.

-- Start a run. Takes the lock (the unique index on running rows). A run left "running" for more
-- than 30 minutes is a crashed function, so it is closed as failed first and doesn't block forever.
create function raw.start_pull(p_kind text, p_window_start date default null, p_window_end date default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  update raw.pull_runs
     set status = 'failed', finished_at = now(),
         error = 'abandoned: still running after 30 minutes (the function was likely cut off)'
   where status = 'running' and started_at < now() - interval '30 minutes';

  begin
    insert into raw.pull_runs (kind, window_start, window_end)
    values (p_kind, p_window_start, p_window_end)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'another pull is already running' using errcode = 'P0001';
  end;
  return v_id;
end
$$;

-- Close a run with its status, counts and error.
create function raw.finish_pull(p_run bigint, p_status text, p_counts jsonb default '{}'::jsonb, p_error text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- Merge, don't overwrite: the calc refresh may already have added its counts and error.
  update raw.pull_runs
     set status = p_status, finished_at = now(),
         counts = counts || coalesce(p_counts, '{}'::jsonb),
         error = nullif(concat_ws('; ', p_error, error), '')
   where id = p_run and status = 'running';
  if not found then
    raise exception 'pull run % is not running', p_run;
  end if;
end
$$;

-- Accounts: upsert by Era id. Returns how many accounts Era listed.
create function raw.ingest_accounts(p_run bigint, p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_changed integer;
begin
  with incoming as (
    select r->>'id' as id, r->'payload' as payload, md5((r->'payload')::text) as hash
      from jsonb_array_elements(p_rows) r
  ), up as (
    insert into raw.era_accounts as a (era_account_id, payload, content_hash, last_pull_run_id)
    select id, payload, hash, p_run from incoming
    on conflict (era_account_id) do update
       set payload = excluded.payload, content_hash = excluded.content_hash,
           last_seen_at = now(), last_pull_run_id = p_run
    returning 1
  )
  select count(*) into v_changed from up;
  return v_changed;
end
$$;

-- Balances: a new row every pull, so history is kept.
create function raw.ingest_balances(p_run bigint, p_rows jsonb)
returns integer
language sql
set search_path = ''
as $$
  with ins as (
    insert into raw.era_balances (era_account_id, current, available, as_of, payload, pull_run_id)
    select r->>'account_id', (r->>'current')::numeric, (r->>'available')::numeric,
           (r->>'as_of')::timestamptz, r->'payload', p_run
      from jsonb_array_elements(p_rows) r
    returning 1
  )
  select count(*)::int from ins;
$$;

-- Transactions: upsert by Era id. "Last seen" moves on every pull; the payload and typed
-- columns change only when the hash does. A transaction that comes back clears removed_at.
-- Returns {"new": n, "changed": n, "unchanged": n}.
create function raw.ingest_transactions(p_run bigint, p_rows jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_new int := 0;
  v_changed int := 0;
  v_total int := 0;
begin
  drop table if exists _incoming_tx;
  create temp table _incoming_tx (
    id text primary key, account_id text, payload jsonb, hash text,
    amount numeric(12, 2), occurred_on date, pending boolean, merchant text
  ) on commit drop;

  insert into _incoming_tx
  select distinct on (r->>'id')
         r->>'id', r->>'account_id', r->'payload', md5((r->'payload')::text),
         (r->>'amount')::numeric, (r->>'occurred_on')::date, (r->>'pending')::boolean, r->>'merchant'
    from jsonb_array_elements(p_rows) r;
  get diagnostics v_total = row_count;

  -- A transaction from an account Era didn't list (hidden or disconnected) still gets kept:
  -- its account is added as a stub, marked so, until Era lists it.
  insert into raw.era_accounts (era_account_id, payload, content_hash, last_pull_run_id)
  select distinct i.account_id, '{"unlisted": true}'::jsonb, md5('{"unlisted": true}'), p_run
    from _incoming_tx i
   where not exists (select 1 from raw.era_accounts a where a.era_account_id = i.account_id);

  select count(*) filter (where t.era_transaction_id is null),
         count(*) filter (where t.era_transaction_id is not null and t.content_hash <> i.hash)
    into v_new, v_changed
    from _incoming_tx i
    left join raw.era_transactions t on t.era_transaction_id = i.id;

  insert into raw.era_transactions as t
         (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant, last_pull_run_id)
  select id, account_id, payload, hash, amount, occurred_on, pending, merchant, p_run from _incoming_tx
  on conflict (era_transaction_id) do update
     set era_account_id   = excluded.era_account_id,
         payload          = case when t.content_hash <> excluded.content_hash then excluded.payload else t.payload end,
         amount           = case when t.content_hash <> excluded.content_hash then excluded.amount else t.amount end,
         occurred_on      = case when t.content_hash <> excluded.content_hash then excluded.occurred_on else t.occurred_on end,
         pending          = case when t.content_hash <> excluded.content_hash then excluded.pending else t.pending end,
         merchant         = case when t.content_hash <> excluded.content_hash then excluded.merchant else t.merchant end,
         content_hash     = excluded.content_hash,
         last_seen_at     = now(),
         removed_at       = null,
         last_pull_run_id = p_run;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'unchanged', v_total - v_new - v_changed);
end
$$;

-- After a complete read of a window: any transaction in that window (and in one of the accounts
-- that were read in full) that this run didn't see is marked removed. Typically a pending charge
-- that posted under a new id. Nothing is deleted. Returns how many were marked.
create function raw.mark_removed(p_run bigint, p_window_start date, p_window_end date, p_account_ids text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count int;
begin
  update raw.era_transactions
     set removed_at = now()
   where occurred_on between p_window_start and p_window_end
     and era_account_id = any (p_account_ids)
     and removed_at is null
     and last_pull_run_id is distinct from p_run;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- Recurring: replaced as a whole snapshot.
create function raw.replace_recurring(p_run bigint, p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count int;
begin
  delete from raw.era_recurring where true;
  insert into raw.era_recurring (era_recurring_id, era_account_id, payload, pull_run_id)
  select distinct on (r->>'id') r->>'id', r->>'account_id', r->'payload', p_run
    from jsonb_array_elements(p_rows) r;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- D2. Where the full history load is. It walks backwards one month per run from the current
-- month. It is done once two months in a row come back with no transactions, or it reaches
-- p_floor. Returns the next month to load, or null when the load is complete.
create function raw.next_full_month(p_floor date default date '2000-01-01')
returns date
language sql
stable
set search_path = ''
as $$
  with done as (
    select window_start, coalesce((counts->>'transactions_seen')::int, 0) as seen
      from raw.pull_runs
     where kind = 'full' and status = 'ok'
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

-- D3. The schedule fires at 04:00 and 05:00 UTC. Only the one that lands in the midnight hour
-- in New York should pull. The function asks this, so the rule lives in one place.
create function raw.is_midnight_eastern(p_at timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select extract(hour from p_at at time zone 'America/New_York') = 0;
$$;

-- Ingest runs these, nothing else new.
revoke all on function
  raw.start_pull(text, date, date), raw.finish_pull(bigint, text, jsonb, text),
  raw.ingest_accounts(bigint, jsonb), raw.ingest_balances(bigint, jsonb),
  raw.ingest_transactions(bigint, jsonb), raw.mark_removed(bigint, date, date, text[]),
  raw.replace_recurring(bigint, jsonb), raw.next_full_month(date), raw.is_midnight_eastern(timestamptz)
from public, anon, authenticated;

grant execute on function
  raw.start_pull(text, date, date), raw.finish_pull(bigint, text, jsonb, text),
  raw.ingest_accounts(bigint, jsonb), raw.ingest_balances(bigint, jsonb),
  raw.ingest_transactions(bigint, jsonb), raw.mark_removed(bigint, date, date, text[]),
  raw.replace_recurring(bigint, jsonb), raw.next_full_month(date), raw.is_midnight_eastern(timestamptz)
to ingest;

-- ingest_transactions stages rows in a temp table; ingest gets TEMP through PUBLIC (the default).
