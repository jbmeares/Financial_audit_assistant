-- C5. knowledge: Claude's working memory about the data.

create table knowledge.proposed_matches (
  id                  bigint generated always as identity primary key,
  era_transaction_id  text not null,
  bill_key            text not null,
  due_month           date not null check (due_month = date_trunc('month', due_month)::date),
  score               smallint not null check (score between 0 and 100),
  reason              text not null,
  status              text not null default 'pending'
                      check (status in ('pending', 'confirmed', 'rejected', 'ambiguous')),
  created_at          timestamptz not null default now(),
  decided_at          timestamptz,
  decided_by          text references ref.people (person),
  decision_note       text,
  -- A pairing is proposed once. A rejected pairing can never come back.
  unique (era_transaction_id, bill_key),
  check ((status in ('pending', 'ambiguous')) = (decided_at is null))
);
comment on table knowledge.proposed_matches is 'The nightly matcher proposes; a person confirms or rejects in a chat. Nothing is confirmed automatically.';
create index proposed_matches_open on knowledge.proposed_matches (status) where status in ('pending', 'ambiguous');
create trigger proposed_matches_bill before insert on knowledge.proposed_matches
  for each row execute function ref.require_key('bill_key', 'ref.bills', 'bill_key', 'any');

create table knowledge.open_questions (
  id           bigint generated always as identity primary key,
  kind         text not null default 'question' check (kind in ('question', 'new_context')),
  topic        text,
  question     text not null check (length(trim(question)) > 0),
  asked_for    text not null references ref.people (person),
  status       text not null default 'open' check (status in ('open', 'answered')),
  answer       text,
  answered_by  text references ref.people (person),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  check ((status = 'answered') = (answer is not null and answered_by is not null and answered_at is not null))
);
comment on column knowledge.open_questions.kind is '''new_context'' is something parked from claude.ai to be filed in the repo in the next Claude Code session (rule 22).';
comment on column knowledge.open_questions.asked_for is 'The person the question was logged for.';

create table knowledge.life_events (
  id           bigint generated always as identity primary key,
  occurred_on  date not null,
  title        text not null check (length(trim(title)) > 0),
  amount       numeric(12, 2),
  story_path   text check (story_path ~ '^life/.+\.md$'),
  entered_by   text not null references ref.people (person),
  entered_at   timestamptz not null default now()
);
comment on table knowledge.life_events is 'The date and dollar figure of something that happened. The story lives in the repo file at story_path.';

create table knowledge.action_calls (
  id         bigint generated always as identity primary key,
  action     text not null,
  person     text,
  args       jsonb not null,
  result     jsonb not null,
  called_at  timestamptz not null default now()
);
comment on table knowledge.action_calls is 'Every successful named action and what it returned. A repeat of the same call within 10 minutes returns the stored result instead of writing again.';
create index action_calls_recent on knowledge.action_calls (action, called_at desc);
