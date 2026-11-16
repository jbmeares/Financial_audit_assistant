-- Smart note logging (James, 2026-11-16).
--
-- Katelyn tried a claude.ai chat on Nov 15. It went well, but James had to paste its output into
-- the project chat for anyone to learn from it. Chats now save a note the moment something worth
-- keeping happens, so the project coordinator can read them without anyone relaying:
--
--   knowledge.chat_notes   one row per note: when, who said it, what kind (correction, decision,
--                          fact, feedback, confusion), what was said, what the chat had answered,
--                          and whether it has been reviewed.
--   actions.log_note       the chats' only way to write one (tool log_note, needs a person).
--
-- The chat says "noted" each time, so nothing is saved without the person seeing it. There is no
-- "end of chat" step: a chat has no real end. Review happens in Claude Code as the owner: set
-- status to 'reviewed' with a review_note. What was said can't be edited afterwards.
-- No DROP statements.

create table knowledge.chat_notes (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  person       text not null references ref.people (person),
  kind         text not null check (kind in ('correction', 'decision', 'fact', 'feedback', 'confusion')),
  said         text not null check (length(trim(said)) > 0),
  chat_answer  text,
  topic        text,
  status       text not null default 'new' check (status in ('new', 'reviewed')),
  reviewed_at  timestamptz,
  review_note  text,
  check ((status = 'reviewed') = (reviewed_at is not null))
);
comment on table knowledge.chat_notes is
  'Notes a chat saved as they happened: a correction, decision, new fact, confusion or feedback. Read by the project coordinator, who marks each one reviewed.';
comment on column knowledge.chat_notes.person is 'Who said it (james or katelyn).';
comment on column knowledge.chat_notes.kind is
  'correction: a person corrected something the chat said. decision: a person decided something. fact: something new and true (a card swap, a bill change, a preference). feedback: how the chat did, good or bad. confusion: something the chat said that was unclear.';
comment on column knowledge.chat_notes.said is 'What the person said, in their words or close to them.';
comment on column knowledge.chat_notes.chat_answer is 'What the chat had said just before, when the note is about it (a correction, confusion or feedback).';
comment on column knowledge.chat_notes.review_note is 'What the reviewer did with it: filed in the repo, fixed in a PR, nothing needed.';
create index chat_notes_new on knowledge.chat_notes (created_at) where status = 'new';

-- What was said is a record: only the review fields can change after it's saved.
create function knowledge.chat_notes_keep_record() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.created_at, new.person, new.kind, new.said, new.chat_answer, new.topic)
     is distinct from
     (old.id, old.created_at, old.person, old.kind, old.said, old.chat_answer, old.topic) then
    raise exception 'A chat note keeps what was said. Only status, reviewed_at and review_note can change.'
      using errcode = 'P0001';
  end if;
  return new;
end
$$;
create trigger chat_notes_keep_record before update on knowledge.chat_notes
  for each row execute function knowledge.chat_notes_keep_record();

revoke all on knowledge.chat_notes from anon, authenticated, public;
grant select on knowledge.chat_notes to assistant_read;
alter table knowledge.chat_notes enable row level security;
create policy assistant_reads on knowledge.chat_notes for select to assistant_read using (true);

-- ---------------------------------------------------------------- log_note

create function actions.log_note(
  p_person       text,
  p_kind         text,
  p_said         text,
  p_chat_answer  text default null,
  p_topic        text default null
) returns knowledge.chat_notes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'kind', p_kind, 'said', p_said,
                                       'chat_answer', p_chat_answer, 'topic', p_topic);
  v_prior  jsonb;
  v_row    knowledge.chat_notes;
begin
  v_prior := actions._prior_result('log_note', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.chat_notes, v_prior);
  end if;

  if coalesce(p_kind, '') not in ('correction', 'decision', 'fact', 'feedback', 'confusion') then
    raise exception 'kind must be correction, decision, fact, feedback or confusion, not "%".', coalesce(p_kind, '')
      using errcode = 'P0001';
  end if;
  if nullif(trim(p_said), '') is null then
    raise exception 'The note is empty: say what the person said.' using errcode = 'P0001';
  end if;

  insert into knowledge.chat_notes (person, kind, said, chat_answer, topic)
  values (v_person, p_kind, trim(p_said), nullif(trim(p_chat_answer), ''), nullif(trim(p_topic), ''))
  returning * into v_row;

  perform actions._log_call('log_note', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

revoke all on function actions.log_note(text, text, text, text, text) from public;
grant execute on function actions.log_note(text, text, text, text, text) to assistant_act;
