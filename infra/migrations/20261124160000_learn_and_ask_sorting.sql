-- Learn-and-ask sorting (James, 2026-11-24: option B of "Smarter finance, fewer rules").
--
-- Budget sorting had grown to 51 priority-ranked rules, most of them exceptions to older ones,
-- and every new situation needed a build. Sorting now lives in the database only (Era keeps bank
-- cleanup: transfers and card payments), and a transaction gets its budget line from the first of:
--
--   1. You said so.       knowledge.sort_answers, kind one_charge: a person's word on that one
--                         charge. It always stands, exactly as said.
--   2. Merchant memory.   ref.merchant_memory, confirmed: "Chewy is Animals", "Montmorenci is a
--                         bill", or "Amazon varies: follow Era's category". Filled from the old
--                         rules and past transactions, then from people's answers.
--   3. Era's category.    ref.category_map: one row per Era category key, so a rename in Era
--                         keeps working.
--   4. Claude's guess.    ref.merchant_memory, not confirmed, for a merchant step 3 can't place.
--
-- Steps 3 and 4 are guesses: calc.spending_sorted labels them guessed, the briefing says how much
-- of each line is guessed, and calc.sort_questions lists each guessed merchant once, for the
-- weekly check-in and payday. An answer goes through actions.sort_spending and is remembered.
--
-- The account is a hint, not a rule: from a Personal account, a purchase on a line that doesn't
-- count from Personal accounts (Shopping), or with no line, is that person's fun money. A person's
-- answer on one charge, and a merchant remembered as "not budget spending" (a bill), stand as is.
--
-- ref.budget_rules stays (no DROP) but nothing reads it any more. Data (the category map, the
-- seeded memory, the switch-day answers that keep past numbers as they were) is seeded from an
-- SQL-editor file, never from this migration.

-- ---------------------------------------------------------------- merchant names

-- A merchant name as memory compares it: lower case, single spaces, trimmed.
create function calc._merchant_key(p text) returns text
language sql immutable set search_path = ''
as $$
  select nullif(lower(regexp_replace(trim(p), '\s+', ' ', 'g')), '')
$$;

-- Whether a remembered pattern names this merchant: the pattern as whole words inside the name,
-- so "playland" covers "playland of aiken" but "apple" doesn't cover "applebee's".
create function calc._merchant_matches(p_key text, p_pattern text) returns boolean
language sql immutable set search_path = ''
as $$
  select p_key = p_pattern
      or p_key ~ ('(^|[^a-z0-9])' || regexp_replace(p_pattern, '([^a-z0-9 ])', '\\\1', 'g') || '($|[^a-z0-9])')
$$;

-- ---------------------------------------------------------------- budget lines: the account hint

alter table ref.budget_lines
  add column personal_account_key text,
  add column counts_from_personal boolean not null default true;
comment on column ref.budget_lines.personal_account_key is
  'For a fun money line: the Personal account whose spending is this fun money.';
comment on column ref.budget_lines.counts_from_personal is
  'false for a line like Shopping: a purchase sorted to it from a Personal account counts as that person''s fun money instead. Food, Fuel, Animals and the like count from any account.';
create trigger budget_lines_personal_account before insert or update of personal_account_key on ref.budget_lines
  for each row execute function ref.require_key('personal_account_key', 'ref.accounts', 'account_key', 'current');

create or replace view ref.current_budget_lines with (security_invoker = true) as
  select * from ref.budget_lines
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

comment on table ref.budget_rules is
  'Retired 2026-11-24, kept for history: nothing reads it. Sorting is ref.merchant_memory, ref.category_map and knowledge.sort_answers (see calc.spending_sorted).';

-- ---------------------------------------------------------------- 3. the category map

create table ref.category_map (
  id             bigint generated always as identity primary key,
  category_key   text not null check (category_key ~ '^fcat_'),
  category_name  text not null,
  line_key       text,
  note           text,
  valid_from     date not null default current_date,
  valid_to       date,
  created_at     timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on table ref.category_map is
  'Era category (by its key, so a rename keeps working) to budget line. line_key null: not budget spending (bills, investments). A category missing here has no line until someone answers. A line from this map is a guess until a person confirms the merchant.';
comment on column ref.category_map.category_name is 'Era''s name for the category when it was mapped; for reading only.';
create unique index category_map_one_open on ref.category_map (category_key) where valid_to is null;

create view ref.current_category_map with (security_invoker = true) as
  select * from ref.category_map
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- 2 and 4. merchant memory

create table ref.merchant_memory (
  id               bigint generated always as identity primary key,
  pattern          text not null check (pattern = calc._merchant_key(pattern) and length(pattern) >= 3),
  line_key         text,
  follow_category  boolean not null default false,
  confirmed        boolean not null default true,
  source           text not null check (source in ('seeded', 'answer', 'guess')),
  set_by           text references ref.people (person),
  note             text,
  valid_from       date not null default current_date,
  valid_to         date,
  created_at       timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (not (follow_category and line_key is not null)),
  check ((source = 'guess') = (not confirmed)),
  check (source = 'seeded' or set_by is not null)
);
comment on table ref.merchant_memory is
  'What each merchant is, for the budget. pattern: the merchant name in lower case; it matches a name that holds it as whole words, and the longest match wins. line_key null with follow_category false: not budget spending (a bill). follow_category: the merchant sells many kinds of things, so Era''s category decides (not a guess). confirmed false: Claude''s guess, used only when Era''s category gives nothing.';
comment on column ref.merchant_memory.source is 'seeded: from the old rules and past transactions (2026-11-24). answer: a person said so. guess: Claude guessed and nobody has confirmed it.';
create unique index merchant_memory_one_open on ref.merchant_memory (pattern) where valid_to is null;

create view ref.current_merchant_memory with (security_invoker = true) as
  select * from ref.merchant_memory
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- 1. answers

create table knowledge.sort_answers (
  id                  bigint generated always as identity primary key,
  created_at          timestamptz not null default now(),
  person              text references ref.people (person),
  kind                text not null check (kind in ('one_charge', 'merchant', 'guess', 'skip')),
  merchant_key        text,
  era_transaction_id  text,
  line_key            text,
  follow_category     boolean not null default false,
  note                text,
  check ((kind = 'one_charge') = (era_transaction_id is not null)),
  check (kind = 'one_charge' or merchant_key is not null),
  check (person is not null or kind = 'one_charge')
);
comment on table knowledge.sort_answers is
  'Every sorting answer, never changed or deleted. one_charge: a person''s word on one transaction (the latest one wins; person null = kept as the old rules sorted it at the 2026-11-24 switch). merchant: a person said what a merchant is (also written to ref.merchant_memory). guess: Claude''s guess for a merchant. skip: a person didn''t know, so the merchant isn''t asked about again.';
create index sort_answers_tx on knowledge.sort_answers (era_transaction_id, id) where kind = 'one_charge';
create index sort_answers_skip on knowledge.sort_answers (merchant_key) where kind = 'skip';

create function knowledge.sort_answers_keep_record() returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'A sorting answer is a record: it is never changed or deleted. Give a new answer instead.'
    using errcode = 'P0001';
end
$$;
create trigger sort_answers_keep_record before update or delete on knowledge.sort_answers
  for each row execute function knowledge.sort_answers_keep_record();

revoke all on ref.category_map, ref.current_category_map, ref.merchant_memory, ref.current_merchant_memory,
              knowledge.sort_answers from anon, authenticated, public;
grant select on ref.category_map, ref.current_category_map, ref.merchant_memory, ref.current_merchant_memory,
                knowledge.sort_answers to assistant_read;
alter table ref.category_map enable row level security;
alter table ref.merchant_memory enable row level security;
alter table knowledge.sort_answers enable row level security;
create policy assistant_reads on ref.category_map for select to assistant_read using (true);
create policy assistant_reads on ref.merchant_memory for select to assistant_read using (true);
create policy assistant_reads on knowledge.sort_answers for select to assistant_read using (true);

-- ---------------------------------------------------------------- sorting

-- Every spending transaction, its budget line, and how it got it. Which transactions count is
-- unchanged from 20261111220000_budget: money out from a checking account or a card, not removed,
-- not a transfer, card or loan payment, not a bill payment (a ledger payment or an open proposed
-- match). A replaced Era account's old transactions count under the account that replaced it.
--   sorted_by  you | memory | category | guess | none
--   guessed    true for category, guess and none: nobody has confirmed it
create function calc.spending_sorted(p_from date, p_to date)
returns table (era_transaction_id text, occurred_on date, amount numeric, merchant text, merchant_key text,
               era_category text, category_key text, account_key text, line_key text, sorted_by text, guessed boolean)
language sql stable security definer set search_path = ''
as $$
  with acct as (
    select a.account_key, a.kind, a.era_account_id as era_id from ref.current_accounts a where a.era_account_id is not null
    union all
    select a.account_key, a.kind, r.old_era_account_id
      from ref.current_accounts a join raw.era_account_replacements r on r.new_era_account_id = a.era_account_id
  ), lines as (
    select l.line_key, l.counts_from_personal, l.personal_account_key from ref.current_budget_lines l
  ), tx as (
    select t.era_transaction_id, t.occurred_on, -t.amount as amount, t.merchant, calc._merchant_key(t.merchant) as merchant_key,
           t.payload ->> 'category' as era_category, t.payload ->> 'categoryKey' as category_key, a.account_key
      from raw.era_transactions t
      left join acct a on a.era_id = t.era_account_id
     where t.removed_at is null
       and t.amount < 0
       and t.occurred_on between p_from and p_to
       and jsonb_typeof(t.payload -> 'transferLink') is distinct from 'object'
       and coalesce(t.payload ->> 'category', '') not in ('Transfers and card payments', 'Taxes and bank fees')
       and a.kind in ('checking', 'card')
       and not exists (select 1 from ledger.payments_effective p where p.era_transaction_id = t.era_transaction_id)
       and not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = t.era_transaction_id and m.status in ('pending', 'ambiguous'))
  ), layered as (
    select tx.*,
           said.found as said_found, said.line_key as said_line,
           mem.found as mem_found, mem.line_key as mem_line, mem.follow_category as mem_follow, mem.confirmed as mem_confirmed,
           cat.found as cat_found, cat.line_key as cat_line,
           fun.line_key as fun_line
      from tx
      left join lateral (
        select true as found, s.line_key from knowledge.sort_answers s
         where s.kind = 'one_charge' and s.era_transaction_id = tx.era_transaction_id
         order by s.id desc limit 1) said on true
      left join lateral (
        select true as found, m.line_key, m.follow_category, m.confirmed from ref.current_merchant_memory m
         where tx.merchant_key is not null and calc._merchant_matches(tx.merchant_key, m.pattern)
         order by m.confirmed desc, length(m.pattern) desc, m.id desc limit 1) mem on true
      left join lateral (
        select true as found, c.line_key from ref.current_category_map c
         where c.category_key = tx.category_key limit 1) cat on true
      left join lateral (
        select l.line_key from lines l where l.personal_account_key = tx.account_key limit 1) fun on true
  ), decided as (
    select l.*,
           case when l.said_found then 'you'
                when l.mem_found and l.mem_confirmed and not l.mem_follow then 'memory'
                when l.mem_found and l.mem_confirmed and l.mem_follow and l.cat_found then 'memory'
                when l.cat_found then 'category'
                when l.mem_found and not l.mem_confirmed then 'guess'
                else 'none' end as how
      from layered l
  ), based as (
    select d.*,
           case d.how when 'you' then d.said_line
                      when 'memory' then case when d.mem_follow then d.cat_line else d.mem_line end
                      when 'category' then d.cat_line
                      when 'guess' then d.mem_line end as base_line,
           -- A merchant remembered as not budget spending (a bill) stays that way from any account.
           (d.how = 'memory' and not d.mem_follow and d.mem_line is null) as known_not_spending
      from decided d
  )
  select b.era_transaction_id, b.occurred_on, b.amount, b.merchant, b.merchant_key, b.era_category, b.category_key, b.account_key,
         case when b.how <> 'you' and b.fun_line is not null and not b.known_not_spending
                   and (b.base_line is null
                        or not coalesce((select l.counts_from_personal from lines l where l.line_key = b.base_line), true))
              then b.fun_line
              else b.base_line end,
         b.how,
         b.how in ('category', 'guess', 'none')
    from based b
$$;
comment on function calc.spending_sorted(date, date) is
  'Spending transactions between two dates, the budget line each counts against, how it got it (you, memory, category, guess, none) and whether that is a guess.';

-- Same columns as before, so everything that reads it keeps working.
create or replace function calc.budget_spending(p_from date, p_to date)
returns table (era_transaction_id text, occurred_on date, amount numeric, merchant text,
               era_category text, account_key text, line_key text)
language sql stable security definer set search_path = ''
as $$
  select s.era_transaction_id, s.occurred_on, s.amount, s.merchant, s.era_category, s.account_key, s.line_key
    from calc.spending_sorted(p_from, p_to) s
$$;
comment on function calc.budget_spending(date, date) is
  'Spending transactions between two dates and the budget line each counts against (calc.spending_sorted without the labels).';

-- ---------------------------------------------------------------- questions

-- One row per merchant whose spending in the last 35 days is still a guess, biggest first, for
-- Claude to ask about at the weekly check-in or on payday. A merchant someone skipped isn't asked
-- again. Never a warning: the briefing shows it as GREEN.
create function calc.sort_questions(p_today date default null)
returns table (merchant_key text, merchant text, guess_line_key text, guess_line text, why text,
               charges int, total numeric, first_on date, last_on date, accounts text[], transactions text[])
language sql stable security definer set search_path = ''
as $$
  with params as (
    select coalesce(p_today, (now() at time zone 'America/New_York')::date) as d
  ), g as (
    select s.* from params p, calc.spending_sorted(p.d - 35, p.d) s
     where s.guessed and s.merchant_key is not null
       and not exists (select 1 from knowledge.sort_answers a where a.kind = 'skip' and a.merchant_key = s.merchant_key)
  ), per as (
    select g.merchant_key,
           min(g.merchant) as merchant,
           mode() within group (order by coalesce(g.line_key, '')) as guess_line_key,
           mode() within group (order by g.sorted_by) as how,
           mode() within group (order by g.era_category) as era_category,
           count(*)::int as charges, sum(g.amount) as total, min(g.occurred_on) as first_on, max(g.occurred_on) as last_on,
           array_agg(distinct g.account_key order by g.account_key) as accounts,
           array_agg(g.era_transaction_id order by g.occurred_on, g.era_transaction_id) as transactions
      from g group by g.merchant_key
  )
  select per.merchant_key, per.merchant, nullif(per.guess_line_key, ''),
         coalesce((select l.name from ref.current_budget_lines l where l.line_key = nullif(per.guess_line_key, '')), 'no budget line'),
         case per.how when 'category' then 'Era calls it ' || coalesce(per.era_category, 'nothing')
                      when 'guess' then 'Claude guessed earlier'
                      else 'nothing to go on' end
           || case when exists (select 1 from ref.current_budget_lines l
                                 where l.line_key = nullif(per.guess_line_key, '') and l.personal_account_key is not null)
                   then ', from a Personal account' else '' end,
         per.charges, per.total, per.first_on, per.last_on, per.accounts, per.transactions
    from per
   order by per.total desc, per.merchant_key
$$;
comment on function calc.sort_questions(date) is
  'Merchants whose recent spending is still a guess, one row each, with the guess and why. Ask at the weekly check-in or on payday, once each.';

revoke all on function calc.spending_sorted(date, date), calc.sort_questions(date),
                       calc._merchant_key(text), calc._merchant_matches(text, text) from public;
grant execute on function calc.spending_sorted(date, date), calc.sort_questions(date),
                          calc._merchant_key(text), calc._merchant_matches(text, text) to assistant_read;

-- ---------------------------------------------------------------- the briefing

alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_sorting;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_items    jsonb;
  v_guessed  jsonb;
  v_text     text;
  v_qs       jsonb;
  v_count    int;
begin
  perform calc._build_briefing_before_sorting(p_today, p_pull_run_id);
  select items into v_items from calc.briefing;
  if v_items is null then
    return;
  end if;

  -- How much of each budget line, this period, is still a guess.
  with st as (
    select * from calc.budget_status(p_today) where tracked
  ), sp as (
    select * from calc.spending_sorted((select min(period_start) from st), p_today) where guessed and line_key is not null
  )
  select jsonb_object_agg(st.line_key, x.amount order by st.sort, st.line_key),
         string_agg(st.name || ' $' || to_char(x.amount, 'FM999990'), ', ' order by st.sort, st.line_key)
    into v_guessed, v_text
    from st
    join lateral (select sum(sp.amount) as amount from sp
                   where sp.line_key = st.line_key and sp.occurred_on between st.period_start and st.period_end) x on x.amount > 0;

  if v_guessed is not null then
    update calc.briefing b
       set items = (select jsonb_agg(case when e ->> 'kind' = 'budget'
                                          then jsonb_set(jsonb_set(e, '{text}', to_jsonb((e ->> 'text') || ' Guessed so far, until someone confirms: ' || v_text || '.')),
                                                         '{data,guessed}', v_guessed)
                                          else e end order by n)
                      from jsonb_array_elements(b.items) with ordinality as x(e, n));
  end if;

  -- The merchants to ask about, as one GREEN item.
  select jsonb_agg(to_jsonb(q) order by q.total desc, q.merchant_key), count(*)
    into v_qs, v_count
    from calc.sort_questions(p_today) q;
  if v_count > 0 then
    v_text := case when v_count = 1 then '1 place to check' else v_count || ' places to check' end
              || ' at the next weekly check-in or payday: '
              || (select string_agg((q ->> 'merchant') || ' (' || (q ->> 'guess_line') || '?)', ', ' order by n)
                    from jsonb_array_elements(v_qs) with ordinality as x(q, n) where n <= 5)
              || case when v_count > 5 then format(', and %s more', v_count - 5) else '' end || '.';
    update calc.briefing b
       set items = b.items || jsonb_build_array(jsonb_build_object('level', 'GREEN', 'kind', 'sort_questions', 'text', v_text,
                                                                  'data', jsonb_build_object('questions', v_qs)));
  end if;
end
$$;

-- ---------------------------------------------------------------- sort_spending

-- The chats' one way to record a sorting answer.
--   one_charge  p_era_transaction_id and p_line: this one charge goes on that line ('none': not
--               budget spending). Always stands.
--   merchant    p_merchant and p_line: what this merchant is, remembered from now on. p_line
--               'none' = not budget spending (a bill); 'varies' = follow Era's category.
--   guess       p_merchant and p_line: Claude's guess, for a merchant Era's category can't place.
--               Still asked about. Never replaces a confirmed memory.
--   skip        p_merchant: the person doesn't know; don't ask again. It stays a guess.
create function actions.sort_spending(
  p_person              text,
  p_kind                text,
  p_line                text default null,
  p_merchant            text default null,
  p_era_transaction_id  text default null,
  p_note                text default null
) returns knowledge.sort_answers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person  text := actions._person(p_person);
  v_args    jsonb := jsonb_build_object('person', v_person, 'kind', p_kind, 'line', p_line, 'merchant', p_merchant,
                                        'era_transaction_id', p_era_transaction_id, 'note', p_note);
  v_prior   jsonb;
  v_key     text := calc._merchant_key(p_merchant);
  v_line    text := nullif(lower(trim(p_line)), '');
  v_follow  boolean := false;
  v_row     knowledge.sort_answers;
begin
  v_prior := actions._prior_result('sort_spending', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.sort_answers, v_prior);
  end if;

  if coalesce(p_kind, '') not in ('one_charge', 'merchant', 'guess', 'skip') then
    raise exception 'kind must be one_charge, merchant, guess or skip, not "%".', coalesce(p_kind, '') using errcode = 'P0001';
  end if;

  if p_kind = 'one_charge' then
    if p_era_transaction_id is null or not exists (select 1 from raw.era_transactions where era_transaction_id = p_era_transaction_id) then
      raise exception 'There is no transaction "%". Find its era_transaction_id with query first.', coalesce(p_era_transaction_id, '')
        using errcode = 'P0001';
    end if;
    v_key := (select calc._merchant_key(t.merchant) from raw.era_transactions t where t.era_transaction_id = p_era_transaction_id);
  else
    if p_era_transaction_id is not null then
      raise exception 'era_transaction_id goes only with kind one_charge.' using errcode = 'P0001';
    end if;
    if v_key is null or length(v_key) < 3 then
      raise exception 'Say which merchant (at least 3 letters), as calc.sort_questions names it.' using errcode = 'P0001';
    end if;
  end if;

  if p_kind = 'skip' then
    v_line := null;
  elsif v_line is null then
    raise exception 'Say which line: a budget line key from ref.current_budget_lines, or "none" for not budget spending%.',
      case when p_kind = 'merchant' then ', or "varies" to follow Era''s category' else '' end using errcode = 'P0001';
  elsif v_line = 'none' then
    v_line := null;
  elsif v_line = 'varies' then
    if p_kind <> 'merchant' then
      raise exception '"varies" goes only with kind merchant.' using errcode = 'P0001';
    end if;
    v_line := null;
    v_follow := true;
  elsif not exists (select 1 from ref.current_budget_lines l where l.line_key = v_line and l.tracked) then
    raise exception 'There is no budget line "%". Use a line_key from ref.current_budget_lines, or "none".', v_line using errcode = 'P0001';
  end if;

  if p_kind = 'merchant' then
    update ref.merchant_memory set valid_to = current_date where pattern = v_key and valid_to is null;
    insert into ref.merchant_memory (pattern, line_key, follow_category, confirmed, source, set_by, note)
    values (v_key, v_line, v_follow, true, 'answer', v_person, nullif(trim(p_note), ''));
  elsif p_kind = 'guess' then
    if exists (select 1 from ref.current_merchant_memory m where m.pattern = v_key and m.confirmed) then
      raise exception 'Someone already said what "%" is, so there''s nothing to guess.', v_key using errcode = 'P0001';
    end if;
    update ref.merchant_memory set valid_to = current_date where pattern = v_key and valid_to is null;
    insert into ref.merchant_memory (pattern, line_key, confirmed, source, set_by, note)
    values (v_key, v_line, false, 'guess', v_person, nullif(trim(p_note), ''));
  end if;

  insert into knowledge.sort_answers (person, kind, merchant_key, era_transaction_id, line_key, follow_category, note)
  values (v_person, p_kind, v_key, case when p_kind = 'one_charge' then p_era_transaction_id end, v_line, v_follow, nullif(trim(p_note), ''))
  returning * into v_row;

  perform calc.refresh_all();
  perform actions._log_call('sort_spending', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

revoke all on function actions.sort_spending(text, text, text, text, text, text) from public;
grant execute on function actions.sort_spending(text, text, text, text, text, text) to assistant_act;
