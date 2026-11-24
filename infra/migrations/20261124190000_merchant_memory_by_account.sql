-- Merchant memory can name an account (James, 2026-11-24): "Sam's Club on the Chase card 8115 is
-- Fuel" while Sam's Club anywhere else is Food. A row with account_key applies only to charges on
-- that account and beats the row without one. Everywhere else the account stays a hint.
-- One DROP: the old one-open-row-per-merchant index, replaced by one per merchant and account.

alter table ref.merchant_memory add column account_key text;
comment on column ref.merchant_memory.account_key is
  'Optional: this memory applies only to charges on this account (ref.accounts) and beats the same merchant without one. Example: Sam''s Club on the Chase card 8115 is Fuel.';
create trigger merchant_memory_account before insert or update of account_key on ref.merchant_memory
  for each row when (new.account_key is not null)
  execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'current');

create unique index merchant_memory_one_open_per_account on ref.merchant_memory (pattern, coalesce(account_key, ''))
  where valid_to is null;
drop index ref.merchant_memory_one_open;

create or replace view ref.current_merchant_memory with (security_invoker = true) as
  select * from ref.merchant_memory
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- sorting: account rows first

-- As in 20261124160000_learn_and_ask_sorting, with memory for this charge's account ahead of the
-- same merchant's memory without one.
create or replace function calc.spending_sorted(p_from date, p_to date)
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
           and (m.account_key is null or m.account_key = tx.account_key)
         order by m.confirmed desc, (m.account_key is not null) desc, length(m.pattern) desc, m.id desc limit 1) mem on true
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

-- ---------------------------------------------------------------- answers

-- As in 20261124160000_learn_and_ask_sorting; a person's answer about a merchant replaces its
-- general memory and leaves any account row alone.
create or replace function actions.sort_spending(
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
    update ref.merchant_memory set valid_to = current_date where pattern = v_key and account_key is null and valid_to is null;
    insert into ref.merchant_memory (pattern, line_key, follow_category, confirmed, source, set_by, note)
    values (v_key, v_line, v_follow, true, 'answer', v_person, nullif(trim(p_note), ''));
  elsif p_kind = 'guess' then
    if exists (select 1 from ref.current_merchant_memory m where m.pattern = v_key and m.account_key is null and m.confirmed) then
      raise exception 'Someone already said what "%" is, so there''s nothing to guess.', v_key using errcode = 'P0001';
    end if;
    update ref.merchant_memory set valid_to = current_date where pattern = v_key and account_key is null and valid_to is null;
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
