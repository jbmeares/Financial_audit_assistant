-- C7. Who can do what. Row security is on for every table, and the public API roles
-- (anon, authenticated) get nothing. The owner (migrations, Claude Code with James present)
-- owns every table, so row security doesn't apply to it.

-- Nothing for the public API roles or PUBLIC.
do $$
declare
  s text;
begin
  foreach s in array array['raw', 'ref', 'ledger', 'knowledge', 'calc', 'actions'] loop
    execute format('revoke all on schema %I from anon, authenticated, public', s);
    execute format('revoke all on all tables in schema %I from anon, authenticated, public', s);
    execute format('revoke all on all sequences in schema %I from anon, authenticated, public', s);
    execute format('revoke all on all functions in schema %I from anon, authenticated, public', s);
    execute format('alter default privileges in schema %I revoke all on tables from anon, authenticated, public', s);
    execute format('alter default privileges in schema %I revoke all on sequences from anon, authenticated, public', s);
    execute format('alter default privileges in schema %I revoke all on functions from anon, authenticated, public', s);
  end loop;
end
$$;

-- ingest: writes raw, runs the calc refresh.
grant usage on schema raw, calc to ingest;
grant select, insert, update on all tables in schema raw to ingest;
grant delete on raw.era_recurring to ingest;
grant usage on all sequences in schema raw to ingest;
grant execute on function calc.refresh_all() to ingest;

-- assistant_read: reads ref, ledger, knowledge and calc (tables and views). Not raw, and no writes.
grant usage on schema ref, ledger, knowledge, calc to assistant_read;
grant select on all tables in schema ref, ledger, knowledge, calc to assistant_read;

-- assistant_act: runs the named functions, nothing else.
grant usage on schema actions to assistant_act;
grant execute on function
  actions.confirm_match(text, bigint, text, text),
  actions.reject_match(text, bigint, text),
  actions.record_balance(text, text, numeric, timestamptz, text),
  actions.log_life_event(text, date, text, numeric, text),
  actions.update_bill(text, text, jsonb, date, boolean),
  actions.void_entry(text, text, bigint, text),
  actions.log_question(text, text, text, text),
  actions.answer_question(text, bigint, text)
to assistant_act;

-- Row security on every table, with policies only for the roles above.
do $$
declare
  r record;
begin
  for r in
    select schemaname, tablename from pg_tables
    where schemaname in ('raw', 'ref', 'ledger', 'knowledge', 'calc')
  loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
    if r.schemaname = 'raw' then
      execute format('create policy ingest_writes on %I.%I for all to ingest using (true) with check (true)',
                     r.schemaname, r.tablename);
    else
      execute format('create policy assistant_reads on %I.%I for select to assistant_read using (true)',
                     r.schemaname, r.tablename);
    end if;
  end loop;
end
$$;
