-- Block F. What the finance MCP server needs in the database, beyond the named actions
-- (C8) and the calculations (E):
--
--   F2 query:            mcp.run_query, which runs one SELECT as assistant_read and can't
--                        switch roles part way (it is a security definer function owned by
--                        assistant_read, and Postgres refuses SET ROLE inside one).
--   F2 create_era_rule:  knowledge.era_rule_previews plus three actions, so a rule is only
--                        sent to Era after a preview, once, by the preview's id.
--   F5 call log:         knowledge.tool_calls and actions.log_tool_call.
--
-- No DROP statements (the Supabase confirm dialog for them doesn't open for James).

-- ---------------------------------------------------------------- the mcp schema

create schema mcp;
comment on schema mcp is 'Functions only the finance MCP server calls. No tables.';
revoke all on schema mcp from anon, authenticated, public;
alter default privileges in schema mcp revoke all on functions from anon, authenticated, public;
grant usage on schema mcp to assistant_read;

-- F2 query. Runs one SELECT and returns at most p_limit + 1 rows as a JSON array, so the
-- caller can tell the result was cut. Guards:
--   * runs as assistant_read (owner, security definer), which can only read;
--   * the caller must already be in a read-only transaction, so nothing can write, not
--     even pg_net's request queue (which would otherwise let a query reach the internet);
--   * SET ROLE and set_config('role', ...) are refused inside a security definer function;
--   * the text is wrapped as a subquery and sent with a bound parameter, so it is exactly
--     one statement, and it must be a SELECT or WITH.
-- The statement timeout is set by the caller (SET LOCAL statement_timeout), since a
-- function-level setting doesn't apply to the statement already running.
create function mcp.run_query(p_sql text, p_limit int default 500) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_sql    text := btrim(coalesce(p_sql, ''));
  v_result jsonb;
begin
  if current_setting('transaction_read_only') <> 'on' then
    raise exception 'query runs only inside a read-only transaction.' using errcode = 'P0001';
  end if;
  -- One trailing semicolon is a habit, not a second statement.
  v_sql := regexp_replace(v_sql, ';\s*$', '');
  if v_sql !~* '^\s*(select|with)\M' then
    raise exception 'query takes one SELECT (or WITH ... SELECT). Writes go through the named actions.'
      using errcode = 'P0001';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'The row limit is between 1 and 500.' using errcode = 'P0001';
  end if;
  -- The newline before the closing parenthesis stops a trailing -- comment from eating it.
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from (select * from (%s%s) q limit $1) q',
    v_sql, E'\n')
    into v_result
    using p_limit + 1;
  return v_result;
end
$$;
comment on function mcp.run_query(text, int) is 'F2 query: one SELECT as assistant_read, read-only, at most 500 rows (501 returned means more exist).';

-- Nobody else may call it. Revoked before the hand-over, while postgres still owns it.
revoke all on function mcp.run_query(text, int) from public;

-- Hand the function to assistant_read. ALTER ... OWNER needs the new owner to have CREATE
-- on the schema at that moment, so it gets it and loses it again here.
grant create on schema mcp to assistant_read;
alter function mcp.run_query(text, int) owner to assistant_read;
revoke create on schema mcp from assistant_read;

-- ---------------------------------------------------------------- F5 call log

create table knowledge.tool_calls (
  id         bigint generated always as identity primary key,
  tool       text not null,
  person     text,
  ok         boolean not null,
  error      text,
  ms         integer,
  called_at  timestamptz not null default now()
);
comment on table knowledge.tool_calls is 'F5: every finance MCP tool call: which tool, for which person (when the tool takes one), ok or error, how long it took.';
comment on column knowledge.tool_calls.person is 'As the caller gave it. Not checked against ref.people, so a refused call is still logged.';
create index tool_calls_recent on knowledge.tool_calls (called_at desc);

-- ---------------------------------------------------------------- Era rule previews

create table knowledge.era_rule_previews (
  id            uuid primary key default gen_random_uuid(),
  person        text not null references ref.people (person),
  rule          jsonb not null check (jsonb_typeof(rule) = 'object'),
  summary       text not null check (length(trim(summary)) > 0),
  status        text not null default 'preview'
                check (status in ('preview', 'sending', 'created', 'failed')),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '30 minutes',
  sent_at       timestamptz,
  finished_at   timestamptz,
  era_rule_id   text,
  era_response  jsonb,
  error         text,
  check ((status = 'preview') = (sent_at is null)),
  check ((status in ('created', 'failed')) = (finished_at is not null))
);
comment on table knowledge.era_rule_previews is 'create_era_rule step 1 stores the exact rule here; step 2 sends that stored rule to Era once, by id. A preview expires after 30 minutes.';

-- Row security, same pattern as the other knowledge tables: assistant_read reads, the
-- named functions write.
do $$
declare
  t text;
begin
  foreach t in array array['tool_calls', 'era_rule_previews'] loop
    execute format('revoke all on knowledge.%I from anon, authenticated, public', t);
    execute format('grant select on knowledge.%I to assistant_read', t);
    execute format('alter table knowledge.%I enable row level security', t);
    execute format('create policy assistant_reads on knowledge.%I for select to assistant_read using (true)', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------- actions

create function actions.log_tool_call(
  p_tool    text,
  p_person  text,
  p_ok      boolean,
  p_error   text default null,
  p_ms      integer default null
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into knowledge.tool_calls (tool, person, ok, error, ms)
  values (left(p_tool, 100), left(p_person, 100), p_ok, left(p_error, 2000), p_ms);
$$;

-- Step 1: store the rule as it will be sent. Nothing goes to Era.
create function actions.stage_era_rule(
  p_person   text,
  p_rule     jsonb,
  p_summary  text
) returns knowledge.era_rule_previews
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_row    knowledge.era_rule_previews;
begin
  if p_rule is null or jsonb_typeof(p_rule) <> 'object' or p_rule = '{}'::jsonb then
    raise exception 'The rule must be a JSON object with the fields Era expects.' using errcode = 'P0001';
  end if;
  if p_summary is null or length(trim(p_summary)) = 0 then
    raise exception 'Give the rule a one-line summary for the preview.' using errcode = 'P0001';
  end if;
  insert into knowledge.era_rule_previews (person, rule, summary)
  values (v_person, p_rule, trim(p_summary))
  returning * into v_row;
  return v_row;
end
$$;

-- Step 2a: claim a preview for sending. Only a fresh, unsent preview can be claimed, and
-- only once, so a retried confirm can't create the rule twice.
create function actions.claim_era_rule(
  p_person      text,
  p_preview_id  uuid
) returns knowledge.era_rule_previews
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_row    knowledge.era_rule_previews;
begin
  select * into v_row from knowledge.era_rule_previews where id = p_preview_id for update;
  if not found then
    raise exception 'There''s no rule preview with that id. Make a preview first.' using errcode = 'P0001';
  end if;
  if v_row.status = 'created' then
    raise exception 'That rule was already created in Era (rule %). Nothing was sent again.', coalesce(v_row.era_rule_id, 'id not returned')
      using errcode = 'P0001';
  end if;
  if v_row.status = 'sending' then
    raise exception 'That rule is already being sent. Check Era before trying again.' using errcode = 'P0001';
  end if;
  if v_row.status = 'failed' then
    raise exception 'Sending that preview failed (%). Make a new preview to try again.', coalesce(v_row.error, 'no detail')
      using errcode = 'P0001';
  end if;
  if v_row.expires_at < now() then
    raise exception 'That preview expired at %. Make a new one.', to_char(v_row.expires_at at time zone 'America/New_York', 'HH12:MI AM "Eastern"')
      using errcode = 'P0001';
  end if;
  update knowledge.era_rule_previews
     set status = 'sending', sent_at = now()
   where id = p_preview_id
  returning * into v_row;
  perform actions._log_call('claim_era_rule', v_person, jsonb_build_object('preview_id', p_preview_id), to_jsonb(v_row));
  return v_row;
end
$$;

-- Step 2b: record what Era answered.
create function actions.finish_era_rule(
  p_preview_id    uuid,
  p_ok            boolean,
  p_era_rule_id   text default null,
  p_era_response  jsonb default null,
  p_error         text default null
) returns knowledge.era_rule_previews
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row knowledge.era_rule_previews;
begin
  update knowledge.era_rule_previews
     set status = case when p_ok then 'created' else 'failed' end,
         finished_at = now(),
         era_rule_id = p_era_rule_id,
         era_response = p_era_response,
         error = case when p_ok then null else coalesce(p_error, 'no detail') end
   where id = p_preview_id and status = 'sending'
  returning * into v_row;
  if not found then
    raise exception 'That preview isn''t being sent, so there is nothing to finish.' using errcode = 'P0001';
  end if;
  return v_row;
end
$$;

revoke all on function
  actions.log_tool_call(text, text, boolean, text, integer),
  actions.stage_era_rule(text, jsonb, text),
  actions.claim_era_rule(text, uuid),
  actions.finish_era_rule(uuid, boolean, text, jsonb, text)
from public;
grant execute on function
  actions.log_tool_call(text, text, boolean, text, integer),
  actions.stage_era_rule(text, jsonb, text),
  actions.claim_era_rule(text, uuid),
  actions.finish_era_rule(uuid, boolean, text, jsonb, text)
to assistant_act;
