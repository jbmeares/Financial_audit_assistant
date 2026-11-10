\set ON_ERROR_STOP 1
\echo '== 10 the MCP server''s call log, Era rule previews and query guard'
begin;
\ir _helpers.sql
\ir _fixture.sql

-- F5 call log: assistant_act writes it through the action, assistant_read reads it.
select pg_temp.as_role('assistant_act', $$select actions.log_tool_call('get_briefing', null, true, null, 12)::text$$);
select pg_temp.as_role('assistant_act', $$select actions.log_tool_call('record_balance', 'nobody', false, 'Say who this is for', 30)::text$$);
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from knowledge.tool_calls$$)::int = 2,
  'tool calls are logged, refused ones too');
select pg_temp.expect_error('assistant_read', $$select actions.log_tool_call('x', null, true)$$,
  '%permission denied%', 'assistant_read cannot write the call log');
select pg_temp.expect_error('assistant_act', $$insert into knowledge.tool_calls (tool, ok) values ('x', true)$$,
  '%permission denied%', 'assistant_act cannot insert into the call log directly');

-- Era rule previews: stage, claim once, finish.
create temp table t_p as
  select * from actions.stage_era_rule('james', '{"ruleName": "Test", "filters": [{"type": "merchant_match", "pattern": "x"}], "actions": [{"type": "hide_transaction"}]}', 'Hide x');
select pg_temp.check((select status = 'preview' and expires_at > now() from t_p), 'a staged rule waits as a preview');
select pg_temp.expect_error(null, $$select actions.stage_era_rule('nobody', '{"a": 1}', 's')$$,
  '%isn''t a known person%', 'staging needs a known person');
select pg_temp.expect_error(null, $$select actions.stage_era_rule('james', '[]', 's')$$,
  '%JSON object%', 'staging refuses a rule that is not an object');

select actions.claim_era_rule('james', (select id from t_p));
select pg_temp.check((select status = 'sending' from knowledge.era_rule_previews where id = (select id from t_p)),
  'claiming marks the preview as sending');
select pg_temp.expect_error(null, format($$select actions.claim_era_rule('james', %L)$$, (select id from t_p)),
  '%already being sent%', 'a preview can be claimed only once');

select actions.finish_era_rule((select id from t_p), true, 'rule_test', '{"rule": {"id": "rule_test"}}');
select pg_temp.check((select status = 'created' and era_rule_id = 'rule_test' from knowledge.era_rule_previews where id = (select id from t_p)),
  'finishing records the Era rule id');
select pg_temp.expect_error(null, format($$select actions.claim_era_rule('james', %L)$$, (select id from t_p)),
  '%already created in Era (rule rule_test)%', 'a created rule can''t be sent again');
select pg_temp.expect_error(null, format($$select actions.finish_era_rule(%L, true)$$, (select id from t_p)),
  '%nothing to finish%', 'a finished preview can''t be finished again');

create temp table t_old as
  select * from actions.stage_era_rule('james', '{"ruleName": "Old"}', 'Old one');
update knowledge.era_rule_previews set expires_at = now() - interval '1 minute' where id = (select id from t_old);
select pg_temp.expect_error(null, format($$select actions.claim_era_rule('james', %L)$$, (select id from t_old)),
  '%expired%', 'an expired preview can''t be sent');
select pg_temp.expect_error(null, $$select actions.claim_era_rule('james', gen_random_uuid())$$,
  '%no rule preview%', 'an unknown preview id is refused');
select pg_temp.expect_error('assistant_read', format($$select actions.claim_era_rule('james', %L)$$, (select id from t_p)),
  '%permission denied%', 'assistant_read cannot send a rule');

-- run_query refuses a read-write transaction (the rest is in 11, inside a read-only one).
select pg_temp.expect_error('assistant_read', $$select mcp.run_query('select 1')$$,
  '%read-only transaction%', 'query refuses to run outside a read-only transaction');
select pg_temp.expect_error('assistant_act', $$select mcp.run_query('select 1')$$,
  '%permission denied%', 'assistant_act cannot run query');
select pg_temp.expect_error('anon', $$select mcp.run_query('select 1')$$,
  '%permission denied%', 'anon cannot run query');
select pg_temp.check((select pg_get_userbyid(proowner) = 'assistant_read' and prosecdef
                        from pg_proc where oid = 'mcp.run_query(text, int)'::regprocedure),
  'query runs as assistant_read');

rollback;
