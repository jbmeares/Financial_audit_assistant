-- C1 and C7. The five layers, a schema for the named write functions, and the three roles.
-- Each layer only reads from the layers above it: raw -> ref -> ledger -> knowledge -> calc.

create schema raw;
create schema ref;
create schema ledger;
create schema knowledge;
create schema calc;
create schema actions;

comment on schema raw       is 'Exactly what Era sent. Written by the nightly pull only.';
comment on schema ref       is 'What the household told us is true. Rows carry valid_from and valid_to so changes keep their history.';
comment on schema ledger    is 'Append-only record of payments, stated balances and adjustments. Mistakes get a void row, never an edit.';
comment on schema knowledge is 'Claude''s working memory about the data: proposed matches, open questions, life events.';
comment on schema calc      is 'Numbers rebuilt by SQL functions (Block E). Never edited by hand.';
comment on schema actions   is 'The named write functions. The only thing assistant_act can run.';

revoke all on schema raw, ref, ledger, knowledge, calc, actions from public;

-- Functions are executable by PUBLIC by default in Postgres. Turn that off for everything
-- created in these schemas from now on; access is granted one function at a time.
alter default privileges in schema raw, ref, ledger, knowledge, calc, actions
  revoke execute on functions from public;

-- Roles. They start without a login. Blocks D and F give ingest, assistant_read and
-- assistant_act a login and a password, kept as Supabase secrets, never in this repo.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'ingest') then
    create role ingest nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'assistant_read') then
    create role assistant_read nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'assistant_act') then
    create role assistant_act nologin;
  end if;
end
$$;

comment on role ingest         is 'Nightly pull: writes raw, runs the calc refresh.';
comment on role assistant_read is 'Every Claude conversation: reads ref, ledger, knowledge and calc.';
comment on role assistant_act  is 'The MCP action tools: runs the named functions in actions, nothing else.';

-- Let the owner switch into each role (SET ROLE) so tests can check what the role can do.
-- INHERIT FALSE: the owner doesn't pick up their rights by default.
grant ingest, assistant_read, assistant_act to current_user with inherit false, set true;
