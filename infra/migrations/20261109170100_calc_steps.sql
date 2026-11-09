-- E2 to E5. The steps refresh_all() runs. Each takes "today" (a date in New York) so the
-- tests can pin it. They run as the owner with an empty search_path, so every name is
-- schema-qualified. None is granted to any role: only refresh_all() and what_if() are.
--
-- Defaults marked (proposed default) come from the build spec and are safe to tune.

-- ---------------------------------------------------------------- date helpers

-- Today in New York, where the household is.
create function calc._today() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'America/New_York')::date $$;

create function calc._month_end(p_day date) returns date
language sql immutable set search_path = ''
as $$ select (date_trunc('month', p_day) + interval '1 month - 1 day')::date $$;

-- The given day of a month. Past the end of a short month, it moves to the last day.
create function calc._day_in_month(p_month date, p_day int) returns date
language sql immutable set search_path = ''
as $$
  select make_date(extract(year from p_month)::int, extract(month from p_month)::int,
                   least(p_day, extract(day from calc._month_end(p_month))::int))
$$;

-- Whether a bill with this cadence falls due in p_month, counted from one known due date.
create function calc._cadence_due(p_cadence text, p_anchor date, p_month date) returns boolean
language sql immutable set search_path = ''
as $$
  select case p_cadence
    when 'monthly' then true
    else (((extract(year from p_month)::int * 12 + extract(month from p_month)::int)
          - (extract(year from p_anchor)::int * 12 + extract(month from p_anchor)::int))
          % (case p_cadence when 'quarterly' then 3 when 'semiannual' then 6 else 12 end) + 12)
         % (case p_cadence when 'quarterly' then 3 when 'semiannual' then 6 else 12 end) = 0
  end
$$;

-- Pay dates between p_from and p_to, counted forward (and back) from a known pay date.
create function calc._pay_dates(p_cadence text, p_anchor date, p_from date, p_to date) returns setof date
language sql immutable set search_path = ''
as $$
  select d from (
    select calc._day_in_month(m::date, extract(day from p_anchor)::int) as d
      from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') m
     where p_cadence = 'monthly'
    union all
    select p_anchor + 14 * k
      from generate_series(ceil((p_from - p_anchor) / 14.0)::int, floor((p_to - p_anchor) / 14.0)::int) k
     where p_cadence = 'biweekly'
  ) s
  where d between p_from and p_to
$$;

-- Tag strings on an Era transaction, from "tags" or "appliedTags" (Era's docs use the second),
-- whatever shape they come in (strings, or objects with a name). Era's exact format is checked against real data in task 19.
create function calc._tx_tags(p_payload jsonb) returns text[]
language sql immutable set search_path = ''
as $$
  select coalesce(array_agg(lower(t)) filter (where t is not null), '{}')
    from (
      select case jsonb_typeof(e)
               when 'string' then e #>> '{}'
               when 'object' then coalesce(e ->> 'name', e ->> 'tag', e ->> 'label')
             end as t
        from unnest(array['tags', 'appliedTags']) k,
             jsonb_array_elements(case when jsonb_typeof(p_payload -> k) = 'array' then p_payload -> k else '[]'::jsonb end) e
    ) s
$$;

-- ---------------------------------------------------------------- balances (E4, E5)

-- The balance each account starts from: the newer of Era's latest and a stated one. A stated
-- balance wins when it is as new or newer (rule 3). Checking and savings use Era's "available"
-- figure when there is one; cards and loans use "current". Stale = older than 3 days.
create function calc._latest_balances(p_today date)
returns table (account_key text, name text, kind text, balance numeric, as_of timestamptz, source text, stale boolean)
language sql stable set search_path = ''
as $$
  select a.account_key, a.name, a.kind,
         case when s.as_of is not null and (e.as_of is null or s.as_of >= e.as_of) then s.balance else e.balance end,
         case when s.as_of is not null and (e.as_of is null or s.as_of >= e.as_of) then s.as_of else e.as_of end,
         case when s.as_of is not null and (e.as_of is null or s.as_of >= e.as_of) then 'stated'
              when e.as_of is not null then 'era' end,
         coalesce((greatest(s.as_of, e.as_of) at time zone 'America/New_York')::date < p_today - 3, true)
    from ref.accounts a
    left join lateral (
      select case when a.kind in ('checking', 'savings') then coalesce(b.available, b.current) else b.current end as balance,
             coalesce(b.as_of, b.pulled_at) as as_of
        from raw.era_balances b
       where b.era_account_id = a.era_account_id
         and (b.available is not null or b.current is not null)
       order by coalesce(b.as_of, b.pulled_at) desc, b.id desc
       limit 1
    ) e on true
    left join lateral (
      select bs.balance, bs.as_of
        from ledger.balance_statements_effective bs
       where bs.account_key = a.account_key
       order by bs.as_of desc, bs.id desc
       limit 1
    ) s on true
   where a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
$$;

-- ---------------------------------------------------------------- E2. bill cycles

-- One row per bill per due month, from the bill's first version to two months ahead. Each
-- month uses the version in effect on its own due date. If a change of due day leaves no
-- version covering its own due date that month, the newest version overlapping the month is
-- used, as long as the bill hadn't ended by then.
-- Status here is paid or not; refresh_all sets pending_match and late after the matcher runs.
create function calc._build_bill_cycles(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  delete from calc.bill_cycles;

  insert into calc.bill_cycles (bill_key, due_month, due_on, bill_name, account_key, amount_kind, autopay,
                                expected_amount, status, payment_id, bill_version_id)
  with starts as (
    select bill_key, min(valid_from) as start_on from ref.bills group by bill_key
  ), months as (
    select s.bill_key, s.start_on, m::date as due_month
      from starts s,
           generate_series(date_trunc('month', s.start_on), date_trunc('month', p_today) + interval '2 months', interval '1 month') m
  ), candidates as (
    select m.bill_key, m.due_month, b.id, b.name, b.account_key, b.amount_kind, b.autopay, b.amount, b.valid_from, b.valid_to,
           calc._day_in_month(m.due_month, b.due_day) as due_on
      from months m
      join ref.bills b
        on b.bill_key = m.bill_key
       and b.valid_from <= calc._month_end(m.due_month)
       and (b.valid_to is null or b.valid_to > m.due_month)
     where calc._cadence_due(b.cadence, b.cadence_anchor, m.due_month)
       and calc._day_in_month(m.due_month, b.due_day) >= m.start_on
  ), ranked as (
    select c.*,
           (c.valid_from <= c.due_on and (c.valid_to is null or c.due_on < c.valid_to)) as covers_due,
           row_number() over (
             partition by c.bill_key, c.due_month
             order by (c.valid_from <= c.due_on and (c.valid_to is null or c.due_on < c.valid_to)) desc,
                      c.valid_from desc, c.id desc) as rn
      from candidates c
  )
  select r.bill_key, r.due_month, r.due_on, r.name, r.account_key, r.amount_kind, r.autopay, r.amount,
         case when p.payment_id is not null then 'paid' else 'not_seen_yet' end,
         p.payment_id, r.id
    from ranked r
    left join lateral (
      select min(pe.id) as payment_id
        from ledger.payments_effective pe
       where pe.bill_key = r.bill_key and pe.due_month = r.due_month
    ) p on true
   where r.rn = 1
     and (r.covers_due
          or exists (select 1 from ref.bills b2
                      where b2.bill_key = r.bill_key and (b2.valid_to is null or b2.valid_to > r.due_on)));

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- Sets pending_match and late on the cycles that aren't paid. A waiting proposal comes before
-- late: the bill may have been paid and only needs a "yes" in a chat (rule 11, don't cry wolf).
create function calc._set_cycle_status(p_today date) returns void
language sql set search_path = ''
as $$
  update calc.bill_cycles c
     set proposed_match_id = pm.id,
         status = case when pm.id is not null then 'pending_match'
                       when calc._month_end(c.due_month) < p_today then 'late'
                       else 'not_seen_yet' end
    from (
      select c2.bill_key, c2.due_month,
             (select min(m.id) from knowledge.proposed_matches m
               where m.bill_key = c2.bill_key and m.due_month = c2.due_month and m.status in ('pending', 'ambiguous')) as id
        from calc.bill_cycles c2
       where c2.status <> 'paid'
    ) pm
   where c.bill_key = pm.bill_key and c.due_month = pm.due_month
$$;

-- ---------------------------------------------------------------- E3. the matcher

-- For each money-out transaction from the last 45 days that isn't paired yet, scores each
-- current bill out of 100 (proposed default):
--   account 30 (paid from the bill's account), amount 40 (within tolerance: the bill's own,
--   else $0.01 fixed or 15% variable), date 20 (between 7 days before and 7 days after the due
--   month), name 10 (an alias in the merchant name, or an Era tag bill:<key or name>).
-- The best bill scoring 70 or more is proposed. A tie at the top proposes each tied bill as
-- ambiguous. A transaction with a proposal still waiting gets nothing new, a pairing that
-- already exists (including a rejected one) is never proposed again, and nothing is confirmed.
create function calc._run_matcher(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
  with tx as (
    select t.era_transaction_id, t.era_account_id, abs(t.amount) as amount, t.occurred_on, t.merchant,
           calc._tx_tags(t.payload) as tags
      from raw.era_transactions t
     where t.amount < 0
       and t.removed_at is null
       and t.occurred_on between p_today - 45 and p_today
       and not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = t.era_transaction_id
                          and m.status in ('pending', 'ambiguous', 'confirmed'))
       and not exists (select 1 from ledger.payments_effective p where p.era_transaction_id = t.era_transaction_id)
  ), bills as (
    select b.bill_key, b.name, b.amount, b.amount_kind,
           coalesce(b.tolerance, case b.amount_kind when 'fixed' then 0.01 else round(b.amount * 0.15, 2) end) as tolerance,
           a.era_account_id
      from ref.bills b
      left join ref.accounts a
        on a.account_key = b.account_key and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
     where b.valid_from <= p_today and (b.valid_to is null or b.valid_to > p_today)
  ), scored as (
    select tx.era_transaction_id, b.bill_key, cy.due_month,
           case when b.era_account_id = tx.era_account_id then 30 else 0 end as s_account,
           case when abs(tx.amount - b.amount) <= b.tolerance then 40 else 0 end as s_amount,
           case when tx.occurred_on between cy.due_month - 7 and calc._month_end(cy.due_month) + 7 then 20 else 0 end as s_date,
           case when exists (select 1 from ref.bill_aliases al
                              where al.bill_key = b.bill_key
                                and al.valid_from <= p_today and (al.valid_to is null or al.valid_to > p_today)
                                and position(lower(al.alias) in lower(coalesce(tx.merchant, ''))) > 0)
                  or ('bill:' || lower(b.bill_key)) = any (tx.tags)
                  or ('bill:' || lower(b.name)) = any (tx.tags)
                then 10 else 0 end as s_name,
           tx.amount as tx_amount, b.amount as bill_amount, tx.occurred_on, cy.due_on
      from tx
      cross join bills b
      -- The cycle it would pay: the nearest unpaid one, preferring one whose window holds the date.
      join lateral (
        select c.due_month, c.due_on
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and abs(tx.occurred_on - c.due_on) <= 45
         order by (tx.occurred_on between c.due_month - 7 and calc._month_end(c.due_month) + 7) desc,
                  abs(tx.occurred_on - c.due_on), c.due_month
         limit 1
      ) cy on true
     where not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = tx.era_transaction_id and m.bill_key = b.bill_key)
  ), ranked as (
    select s.*, s.s_account + s.s_amount + s.s_date + s.s_name as score,
           max(s.s_account + s.s_amount + s.s_date + s.s_name) over (partition by s.era_transaction_id) as top,
           count(*) filter (where s.s_account + s.s_amount + s.s_date + s.s_name >= 70)
             over (partition by s.era_transaction_id, s.s_account + s.s_amount + s.s_date + s.s_name) as tied
      from scored s
  )
  select r.era_transaction_id, r.bill_key, r.due_month, r.score,
         concat_ws('; ',
           'account ' || r.s_account,
           format('amount %s ($%s paid, bill $%s)', r.s_amount, r.tx_amount, r.bill_amount),
           format('date %s (%s, due %s)', r.s_date, r.occurred_on, r.due_on),
           'name ' || r.s_name),
         case when r.tied > 1 then 'ambiguous' else 'pending' end
    from ranked r
   where r.score >= 70 and r.score = r.top
  on conflict (era_transaction_id, bill_key) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------- E4. cash projection

-- The day-by-day projection for each checking and savings account that has a balance, over
-- 60 days starting today. Shared by refresh_all() and what_if(), which passes p_changes.
-- Money in: each income source's pay dates (the version in effect on the date), counted after
--   the starting balance's date.
-- Money out: unpaid bills not seen yet on their due dates, from the account they're paid from.
--   One already past due this month comes out today. A pending match is left out, because the
--   transaction has already happened. A late bill (an earlier month) is left out and the
--   briefing names it.
-- p_changes is a checked what_if list (see what_if). Null means none.
create function calc._project(p_today date, p_changes jsonb default null)
returns table (account_key text, day date, opening numeric, money_in numeric, money_out numeric, closing numeric, detail jsonb)
language sql stable set search_path = ''
as $$
  with params as (
    select p_today as d0, p_today + 59 as d1, coalesce(p_changes, '[]'::jsonb) as changes
  ), changes as (
    select c from params, jsonb_array_elements(params.changes) c
  ), starts as (
    select lb.account_key, lb.balance, (lb.as_of at time zone 'America/New_York')::date as as_of_day
      from calc._latest_balances(p_today) lb
     where lb.kind in ('checking', 'savings') and lb.balance is not null
  ), income as (
    select i.deposit_account_key as account_key, pd as day, 'income'::text as kind, i.income_key as key, i.name,
           coalesce((select (ch.c ->> 'amount')::numeric from changes ch
                      where ch.c ->> 'type' = 'income_change' and ch.c ->> 'income_key' = i.income_key
                        and (ch.c ->> 'from')::date <= pd
                      order by (ch.c ->> 'from')::date desc limit 1), i.amount) as amount
      from ref.income_sources i, params,
           calc._pay_dates(i.cadence, i.anchor_pay_date, greatest(params.d0, i.valid_from),
                           least(params.d1, coalesce(i.valid_to - 1, params.d1))) pd
  ), bills as (
    select c.account_key, greatest(c.due_on, params.d0) as day, 'bill'::text as kind, c.bill_key as key, c.bill_name as name,
           c.expected_amount as amount
      from calc.bill_cycles c, params
     where c.status = 'not_seen_yet'
       and (c.due_on between params.d0 and params.d1
            or (c.due_on < params.d0 and c.due_month = date_trunc('month', params.d0)::date))
       and not exists (select 1 from changes ch
                        where ch.c ->> 'type' = 'skip_bill' and ch.c ->> 'bill_key' = c.bill_key
                          and date_trunc('month', (ch.c ->> 'due_month')::date)::date = c.due_month)
  ), one_offs as (
    select ch.c ->> 'account_key' as account_key, d as day, 'change'::text as kind,
           ch.c ->> 'type' as key, coalesce(ch.c ->> 'label', ch.c ->> 'debt_key', ch.c ->> 'type') as name,
           (ch.c ->> 'amount')::numeric as amount
      from changes ch, params,
           lateral (
             select (ch.c ->> 'on')::date as d
              where not coalesce((ch.c ->> 'monthly')::boolean, false)
             union all
             select calc._day_in_month(m::date, extract(day from (ch.c ->> 'on')::date)::int)
               from generate_series(date_trunc('month', (ch.c ->> 'on')::date), date_trunc('month', params.d1), interval '1 month') m
              where coalesce((ch.c ->> 'monthly')::boolean, false)
           ) dates
     where ch.c ->> 'type' in ('one_off_expense', 'extra_payment')
       and dates.d between params.d0 and params.d1
  ), moves as (
    select i.account_key, i.day, i.kind, i.key, i.name, i.amount as money_in, 0::numeric as money_out
      from income i join starts s on s.account_key = i.account_key
     where i.day > s.as_of_day and i.amount > 0
    union all
    select b.account_key, b.day, b.kind, b.key, b.name, 0, b.amount from bills b
    union all
    select o.account_key, o.day, o.kind, o.key, o.name, 0, o.amount from one_offs o
  ), daily as (
    select s.account_key, d::date as day, s.balance,
           coalesce(sum(m.money_in), 0) as money_in,
           coalesce(sum(m.money_out), 0) as money_out,
           coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'key', m.key, 'name', m.name,
                                                 'amount', m.money_in + m.money_out, 'direction',
                                                 case when m.money_in > 0 then 'in' else 'out' end)
                              order by m.kind, m.key) filter (where m.kind is not null), '[]'::jsonb) as detail
      from starts s
      cross join params
      cross join generate_series(params.d0, params.d1, interval '1 day') d
      left join moves m on m.account_key = s.account_key and m.day = d::date
     group by s.account_key, d, s.balance
  )
  select account_key, day,
         balance + sum(money_in - money_out) over w - (money_in - money_out),
         money_in, money_out,
         balance + sum(money_in - money_out) over w,
         detail
    from daily
  window w as (partition by account_key order by day rows between unbounded preceding and current row)
$$;

-- ---------------------------------------------------------------- E5. debt payoff

-- The month a debt is paid off, paying p_payment each month plus extras, with interest at
-- p_apr / 12 each month. Extras: [{on, amount, monthly}]. Null when it isn't paid off within
-- 50 years (for example, the payment doesn't cover the interest). An estimate that assumes the
-- minimum stays the same.
create function calc._payoff_month(p_balance numeric, p_apr numeric, p_payment numeric, p_today date,
                                   p_extras jsonb default '[]'::jsonb) returns date
language plpgsql immutable set search_path = ''
as $$
declare
  v_balance numeric := p_balance;
  v_month   date := date_trunc('month', p_today)::date;
  v_extra   numeric;
begin
  if v_balance is null then
    return null;
  end if;
  for i in 0 .. 600 loop
    if v_balance <= 0 then
      return calc._month_end((v_month - interval '1 month')::date);
    end if;
    select coalesce(sum((e ->> 'amount')::numeric), 0) into v_extra
      from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) e
     where (coalesce((e ->> 'monthly')::boolean, false) and date_trunc('month', (e ->> 'on')::date) <= v_month)
        or (not coalesce((e ->> 'monthly')::boolean, false) and date_trunc('month', (e ->> 'on')::date) = v_month);
    if i > 0 then
      v_balance := v_balance + round(v_balance * p_apr / 1200, 2);
    end if;
    v_balance := v_balance - v_extra - case when i > 0 then p_payment else 0 end;
    v_month := (v_month + interval '1 month')::date;
  end loop;
  return null;
end
$$;
