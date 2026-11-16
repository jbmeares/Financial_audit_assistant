\set ON_ERROR_STOP 1
\echo '== 25 chats save notes as they happen'
begin;
\ir _helpers.sql
\ir _fixture.sql

create temp table t_n as
  select * from actions.log_note('katelyn', 'feedback', 'That breakdown was really clear', 'Here is what is due before Friday...', 'briefing');
select pg_temp.check((select person = 'katelyn' and kind = 'feedback' and status = 'new' and chat_answer like 'Here is%' from t_n),
  'a note is saved as new, with who said it and what the chat had answered');

select actions.log_note('katelyn', 'feedback', 'That breakdown was really clear', 'Here is what is due before Friday...', 'briefing');
select pg_temp.check((select count(*) = 1 from knowledge.chat_notes), 'the same note twice writes one row');

select pg_temp.expect_error(null, $$select actions.log_note('james', 'gossip', 'x')$$,
  '%kind must be%', 'an unknown kind is refused');
select pg_temp.expect_error(null, $$select actions.log_note('james', 'fact', '  ')$$,
  '%note is empty%', 'an empty note is refused');
select pg_temp.expect_error(null, $$select actions.log_note('someone', 'fact', 'x')$$,
  '%isn''t a known person%', 'an unknown person is refused');

select pg_temp.check(pg_temp.as_role('assistant_act', $$select (actions.log_note('james', 'correction', 'The phone bill is $45 now', 'The phone bill is $40')).id$$) is not null,
  'assistant_act saves a note through the action');
select pg_temp.check(pg_temp.as_role('assistant_read', $$select count(*) from knowledge.chat_notes$$)::int = 2,
  'assistant_read reads the notes');
select pg_temp.expect_error('assistant_read', $$select actions.log_note('james', 'fact', 'x')$$,
  '%permission denied%', 'assistant_read cannot save a note');
select pg_temp.expect_error('assistant_act', $$update knowledge.chat_notes set status = 'reviewed', reviewed_at = now()$$,
  '%permission denied%', 'assistant_act cannot mark notes reviewed');

update knowledge.chat_notes set status = 'reviewed', reviewed_at = now(), review_note = 'Filed in people/katelyn.md'
 where id = (select id from t_n);
select pg_temp.check((select status = 'reviewed' from knowledge.chat_notes where id = (select id from t_n)),
  'the owner marks a note reviewed');
select pg_temp.expect_error(null, $$update knowledge.chat_notes set said = 'changed'$$,
  '%keeps what was said%', 'what was said cannot be edited');
select pg_temp.expect_error(null, $$update knowledge.chat_notes set status = 'reviewed' where status = 'new'$$,
  '%check constraint%', 'reviewed needs a reviewed_at');

rollback;
