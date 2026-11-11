-- The household budget (James, 2026-11-11). It replaces the old v2 envelopes, which failed
-- because nobody checked them and nothing happened when a line ran over.
--
-- How it works:
--   * Bill Pay gets fixed transfers (ref.transfers) big enough to cover every bill at its
--     high month. Whatever stays in Joint is spending money.
--   * ref.budget_lines: what each line may spend, per paycheck (resets each payday of
--     income_key) or per calendar month.
--   * ref.budget_rules: which transactions count against which line, by Era category,
--     merchant and/or account. The most specific rule (lowest priority number) wins.
--   * calc.budget_status(today): spent and left for each line this period. A line that
--     runs over borrows from its borrows_from line (Shopping). Once that is empty too,
--     the briefing turns YELLOW.
--   * The briefing gets a 'budget' item every day.
--
-- Amounts are data, not code: the real lines and rules are seeded from an SQL-editor file,
-- never from this migration.

-- ---------------------------------------------------------------- budget lines

create table ref.budget_lines (
  id            bigint generated always as identity primary key,
  line_key      text not null check (line_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  name          text not null,
  amount        numeric(12, 2) not null check (amount >= 0),
  period        text not null check (period in ('paycheck', 'month')),
  income_key    text,
  borrows_from  text,
  tracked       boolean not null default true,
  sort          smallint not null default 100,
  note          text,
  valid_from    date not null default current_date,
  valid_to      date,
  created_at    timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check ((period = 'paycheck') = (income_key is not null)),
  check (borrows_from is null or borrows_from <> line_key)
);
comment on table ref.budget_lines is 'What each spending line may spend. Versioned like the other ref tables. Food, Animals and Fuel keep those names: the Level 3 Emergency Fund counts them as basic necessities.';
comment on column ref.budget_lines.period is 'paycheck: resets on each pay date of income_key. month: resets on the 1st.';
comment on column ref.budget_lines.borrows_from is 'The line this one borrows from when it runs over (Shopping).';
comment on column ref.budget_lines.tracked is 'false for a line that is an amount only, such as the extra debt payment. No transactions count against it.';
create unique index budget_lines_one_open on ref.budget_lines (line_key) where valid_to is null;
create trigger budget_lines_income before insert or update of income_key on ref.budget_lines
  for each row execute function ref.require_key('income_key', 'ref.income_sources', 'income_key', 'current');

create view ref.current_budget_lines with (security_invoker = true) as
  select * from ref.budget_lines
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- rules

create table ref.budget_rules (
  id            bigint generated always as identity primary key,
  line_key      text,
  era_category  text,
  merchant      text,
  account_key   text,
  priority      smallint not null default 100,
  note          text,
  valid_from    date not null default current_date,
  valid_to      date,
  created_at    timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (era_category is not null or merchant is not null or account_key is not null)
);
comment on table ref.budget_rules is 'Which transactions count against which budget line. Every condition given must match: era_category exactly, merchant as a case-insensitive substring of the merchant name, account_key as the account it was spent from. The lowest priority number wins. A rule with no line_key means "doesn''t count" (for example everything Bill Pay pays).';
create trigger budget_rules_account before insert or update of account_key on ref.budget_rules
  for each row execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'current');

create view ref.current_budget_rules with (security_invoker = true) as
  select * from ref.budget_rules
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

revoke all on ref.budget_lines, ref.current_budget_lines, ref.budget_rules, ref.current_budget_rules
  from anon, authenticated, public;
grant select on ref.budget_lines, ref.current_budget_lines, ref.budget_rules, ref.current_budget_rules
  to assistant_read;
alter table ref.budget_lines enable row level security;
alter table ref.budget_rules enable row level security;
create policy assistant_reads on ref.budget_lines for select to assistant_read using (true);
create policy assistant_reads on ref.budget_rules for select to assistant_read using (true);

-- ---------------------------------------------------------------- spending

-- Every spending transaction and the budget line it counts against (null: no rule matched).
-- Left out: money in, removed rows, transfers between own accounts, card and loan payments,
-- anything not spent from a checking account or a card, and transactions that are, or may
-- be, a bill payment (a ledger payment or an open proposed match). Rules with no line_key
-- (for example everything from Bill Pay) make a transaction count against nothing.
-- A replaced Era account's old transactions count under the account that replaced it.
create function calc.budget_spending(p_from date, p_to date)
returns table (era_transaction_id text, occurred_on date, amount numeric, merchant text,
               era_category text, account_key text, line_key text)
language sql stable security definer set search_path = ''
as $$
  with acct as (
    select a.account_key, a.kind, a.era_account_id as era_id from ref.current_accounts a where a.era_account_id is not null
    union all
    select a.account_key, a.kind, r.old_era_account_id
      from ref.current_accounts a join raw.era_account_replacements r on r.new_era_account_id = a.era_account_id
  ), tx as (
    select t.era_transaction_id, t.occurred_on, -t.amount as amount, t.merchant,
           t.payload ->> 'category' as era_category, a.account_key
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
  )
  select tx.*,
         (select r.line_key from ref.current_budget_rules r
           where (r.era_category is null or r.era_category = tx.era_category)
             and (r.merchant is null or tx.merchant ilike '%' || r.merchant || '%')
             and (r.account_key is null or r.account_key = tx.account_key)
           order by r.priority, r.id limit 1)
    from tx
$$;
comment on function calc.budget_spending(date, date) is 'Spending transactions between two dates and the budget line each counts against.';

-- ---------------------------------------------------------------- status

-- One row per current budget line for the period that contains p_today.
--   spent     what counted against the line this period
--   left      amount - spent (negative when over)
--   borrowed  for a line others borrow from: what they ran over by this month
--   left_after_borrowing  left - borrowed
-- A paycheck line's overage is charged to the month its pay period started in, so a
-- payday mid-month never drops an overage.
create function calc.budget_status(p_today date default null)
returns table (line_key text, name text, period text, period_start date, period_end date,
               amount numeric, spent numeric, "left" numeric, borrows_from text,
               borrowed numeric, left_after_borrowing numeric, tracked boolean, sort smallint)
language sql stable security definer set search_path = ''
as $$
  with params as (
    select coalesce(p_today, (now() at time zone 'America/New_York')::date) as d
  ), lines as (
    select l.*, i.cadence, i.anchor_pay_date
      from ref.current_budget_lines l
      left join ref.current_income_sources i on i.income_key = l.income_key
  ), pays as (
    -- Pay dates around today for each paycheck line, from 45 days before the month began.
    select l.line_key, pd
      from lines l, params p,
           calc._pay_dates(l.cadence, l.anchor_pay_date, date_trunc('month', p.d)::date - 45, p.d + 45) pd
     where l.period = 'paycheck'
  ), periods as (
    -- Every period of every line that touches this month, with its own start and end.
    select l.line_key, date_trunc('month', p.d)::date as s, (date_trunc('month', p.d) + interval '1 month - 1 day')::date as e
      from lines l, params p where l.period = 'month'
    union all
    select x.line_key, x.pd, coalesce((select min(y.pd) from pays y where y.line_key = x.line_key and y.pd > x.pd) - 1, x.pd + 13)
      from pays x, params p
     where x.pd <= p.d and x.pd >= (select coalesce(max(z.pd), x.pd) from pays z where z.line_key = x.line_key and z.pd < date_trunc('month', p.d))
  ), spend as (
    select * from calc.budget_spending((select date_trunc('month', d)::date - 45 from params), (select d + 1 from params))
  ), per_period as (
    select pr.line_key, pr.s, pr.e, l.amount,
           coalesce((select sum(sp.amount) from spend sp where sp.line_key = pr.line_key and sp.occurred_on between pr.s and pr.e), 0) as spent
      from periods pr join lines l using (line_key)
  ), now_period as (
    select pp.* from per_period pp, params p where p.d between pp.s and pp.e
  ), over_this_month as (
    -- What each borrowing line ran over by, in periods that started this month.
    select l.borrows_from as lender, sum(greatest(pp.spent - pp.amount, 0)) as over
      from per_period pp join lines l using (line_key), params p
     where l.borrows_from is not null and l.tracked and pp.s >= date_trunc('month', p.d)
     group by l.borrows_from
  )
  select l.line_key, l.name, l.period, np.s, np.e, l.amount,
         case when l.tracked then np.spent end,
         case when l.tracked then l.amount - np.spent end,
         l.borrows_from,
         case when l.tracked then coalesce(o.over, 0) end,
         case when l.tracked then l.amount - np.spent - coalesce(o.over, 0) end,
         l.tracked, l.sort
    from lines l
    join now_period np using (line_key)
    left join over_this_month o on o.lender = l.line_key
   order by l.sort, l.line_key
$$;
comment on function calc.budget_status(date) is 'Spent and left for each budget line in the period that contains the given day (default: today, Eastern).';

revoke all on function calc.budget_spending(date, date), calc.budget_status(date) from public;
grant execute on function calc.budget_spending(date, date), calc.budget_status(date) to assistant_read;

-- ---------------------------------------------------------------- briefing

-- The connection-list builder keeps running first; the budget item goes last.
alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_budget;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_rows  jsonb;
  v_text  text;
  v_level text;
  v_item  jsonb;
begin
  perform calc._build_briefing_before_budget(p_today, p_pull_run_id);

  select jsonb_agg(to_jsonb(s) order by s.sort, s.line_key) into v_rows
    from calc.budget_status(p_today) s where s.tracked;
  if v_rows is null then
    return;
  end if;

  -- A line borrowing from another reads as $0 left once over; its overage shows on the lender.
  select string_agg(format('%s $%s left of $%s%s', e ->> 'name',
                      to_char(case when e ->> 'borrows_from' is not null
                                   then greatest((e ->> 'left')::numeric, 0)
                                   else (e ->> 'left_after_borrowing')::numeric end, 'FM999990'),
                      to_char((e ->> 'amount')::numeric, 'FM999990'),
                      case when e ->> 'period' = 'paycheck' then ' through ' || to_char((e ->> 'period_end')::date, 'Mon FMDD') else ' this month' end),
                    '. ' order by (e ->> 'sort')::int, e ->> 'line_key') || '.'
    into v_text from jsonb_array_elements(v_rows) e;

  v_level := case when exists (select 1 from jsonb_array_elements(v_rows) e
                                where e ->> 'borrows_from' is null and (e ->> 'left_after_borrowing')::numeric < 0)
                  then 'YELLOW' else 'GREEN' end;
  if v_level = 'YELLOW' then
    v_text := 'Over budget: ' || (select string_agg(e ->> 'name', ', ') from jsonb_array_elements(v_rows) e
                                   where e ->> 'borrows_from' is null and (e ->> 'left_after_borrowing')::numeric < 0)
              || ' is empty after covering other lines. ' || v_text;
  end if;

  v_item := jsonb_build_object('level', v_level, 'kind', 'budget', 'text', 'Budget: ' || v_text,
                               'data', jsonb_build_object('lines', v_rows));

  update calc.briefing b
     set items = (select jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n)
                    from jsonb_array_elements(b.items || jsonb_build_array(v_item)) with ordinality as x(e, n)),
         level = case when v_level = 'YELLOW' and b.level = 'GREEN' then 'YELLOW' else b.level end;
end
$$;
