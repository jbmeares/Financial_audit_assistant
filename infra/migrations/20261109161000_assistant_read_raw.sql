-- Let chats look up transactions and balances: assistant_read gets read-only access to raw.
-- James approved this on 2026-11-09 (the open point on the Block C pull request).
-- raw stays written by ingest only.

grant usage on schema raw to assistant_read;
grant select on all tables in schema raw to assistant_read;

do $$
declare
  r record;
begin
  for r in select tablename from pg_tables where schemaname = 'raw' loop
    execute format('create policy assistant_reads on raw.%I for select to assistant_read using (true)', r.tablename);
  end loop;
end
$$;
