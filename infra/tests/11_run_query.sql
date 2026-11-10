\set ON_ERROR_STOP 1
\echo '== 11 query runs one read-only SELECT as assistant_read'
-- The helpers live in pg_temp for this session; create them before the read-only transaction.
\ir _helpers.sql
begin read only;
set local role assistant_read;

select pg_temp.check(mcp.run_query('select 1 as one') = '[{"one": 1}]', 'a SELECT returns its rows as JSON');
select pg_temp.check(mcp.run_query('with a as (select 2 as two) select * from a;') = '[{"two": 2}]',
  'WITH works, and a trailing semicolon is fine');
select pg_temp.check(mcp.run_query('select 3 as three -- a trailing comment') = '[{"three": 3}]',
  'a trailing comment does not break the wrapper');
select pg_temp.check(jsonb_array_length(mcp.run_query('select g from generate_series(1, 2000) g')) = 501,
  'at most 501 rows come back, so the caller knows there were more');
select pg_temp.check(jsonb_array_length(mcp.run_query('select g from generate_series(1, 20) g', 5)) = 6,
  'a smaller limit is honoured');
select pg_temp.check(mcp.run_query('select count(*) as n from raw.pull_runs') is not null, 'it reads the finance schemas');
select pg_temp.check(mcp.run_query('select current_user as u') = '[{"u": "assistant_read"}]', 'it runs as assistant_read');

select pg_temp.expect_error(null, $$select mcp.run_query('delete from ref.bills')$$,
  '%one SELECT%', 'a non-SELECT is refused');
select pg_temp.expect_error(null, $$select mcp.run_query('select 1; select 2')$$,
  '%syntax error%', 'two statements are refused');
select pg_temp.expect_error(null, $$select mcp.run_query('select set_config(''role'', ''postgres'', true)')$$,
  '%security-definer%', 'it cannot switch role with set_config');
select pg_temp.expect_error(null, $$select mcp.run_query('select 1) q; set role postgres; select (1')$$,
  '%syntax error%', 'breaking out of the wrapper is refused');
select pg_temp.expect_error(null, $$select mcp.run_query('select * from (select 1) x where false union all select null from pg_authid')$$,
  '%permission denied%', 'it cannot read what assistant_read can''t');
select pg_temp.expect_error(null, $$select mcp.run_query('select 1', 900)$$,
  '%between 1 and 500%', 'the limit is capped at 500');

rollback;
