-- Test helpers, created in pg_temp so they vanish with the session.
-- Every test file runs inside BEGIN ... ROLLBACK, so nothing it writes is kept.

-- Fails unless p_ok is true.
create function pg_temp.check(p_ok boolean, p_what text) returns void
language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAIL: %', p_what;
  end if;
  raise notice 'ok: %', p_what;
end
$$;

-- Runs p_sql as p_role (null = the owner) and fails unless it errors with a message like p_like.
create function pg_temp.expect_error(p_role text, p_sql text, p_like text, p_what text) returns void
language plpgsql as $$
begin
  begin
    if p_role is not null then
      execute format('set local role %I', p_role);
    end if;
    execute p_sql;
  exception when others then
    if sqlerrm not ilike p_like then
      raise exception 'FAIL: % (expected an error like "%", got "%")', p_what, p_like, sqlerrm;
    end if;
    raise notice 'ok: %', p_what;
    return;
  end;
  raise exception 'FAIL: % (no error from: %)', p_what, p_sql;
end
$$;

-- Runs p_sql as p_role and returns the first column of the first row as text.
create function pg_temp.as_role(p_role text, p_sql text) returns text
language plpgsql as $$
declare
  v text;
begin
  execute format('set local role %I', p_role);
  execute p_sql into v;
  reset role;
  return v;
end
$$;
