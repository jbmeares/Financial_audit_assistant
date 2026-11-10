-- G1 follow-up. What the money interview needs that Blocks C and E didn't have:
--   1. Planned transfers between the household's own accounts (ref.transfers), in the cash projection.
--   2. More bill schedules: every_other_month, weekly, biweekly and per_paycheck (on each pay date
--      of one income source). Weekly, biweekly and per-paycheck bills can fall due more than once
--      a month, so a bill cycle is now one due date, not one month.
--   3. Pay dates that land on a weekend or a bank holiday move to the bank business day before.
--
-- Nothing here removes a constraint or an object, because the Supabase confirm dialog for
-- destructive statements doesn't open for James. The old checks that allow only the four
-- month-based cadences, the old one-cycle-per-month key on calc.bill_cycles and due_day's
-- NOT NULL are lifted by the next migration, which James runs in the SQL editor. Until then
-- everything here works for month-based bills, and a weekly, biweekly or per-paycheck bill is
-- refused at insert.

-- ---------------------------------------------------------------- 3. bank business days

-- Federal Reserve bank holidays, the days ACH payroll and benefit deposits don't settle.
-- A fixed-date holiday on a Sunday is observed the Monday after. One on a Saturday is not
-- observed at all (the Fed stays open the Friday before).
create function calc._is_bank_holiday(p_day date) returns boolean
language sql immutable set search_path = ''
as $$
  with d as (
    select extract(month from p_day)::int as m, extract(day from p_day)::int as dd, extract(isodow from p_day)::int as dow,
           extract(month from p_day - 1)::int as m_before, extract(day from p_day - 1)::int as dd_before
  ), fixed (m, dd) as (
    values (1, 1), (6, 19), (7, 4), (11, 11), (12, 25)  -- New Year, Juneteenth, Independence, Veterans, Christmas
  )
  select exists (select 1 from fixed f where f.m = d.m and f.dd = d.dd and d.dow between 1 and 5)
      or exists (select 1 from fixed f where f.m = d.m_before and f.dd = d.dd_before and d.dow = 1)
      or (d.m = 1 and d.dow = 1 and (d.dd - 1) / 7 = 2)    -- Martin Luther King Jr. Day, 3rd Monday
      or (d.m = 2 and d.dow = 1 and (d.dd - 1) / 7 = 2)    -- Washington's Birthday, 3rd Monday
      or (d.m = 5 and d.dow = 1 and d.dd > 24)             -- Memorial Day, last Monday
      or (d.m = 9 and d.dow = 1 and d.dd <= 7)             -- Labor Day, 1st Monday
      or (d.m = 10 and d.dow = 1 and (d.dd - 1) / 7 = 1)   -- Columbus Day, 2nd Monday
      or (d.m = 11 and d.dow = 4 and (d.dd - 1) / 7 = 3)   -- Thanksgiving, 4th Thursday
    from d
$$;

-- The day itself if banks are open, else the latest bank business day before it.
create function calc._prev_business_day(p_day date) returns date
language sql immutable set search_path = ''
as $$
  select max(d)::date
    from generate_series(p_day - 10, p_day, interval '1 day') d
   where extract(isodow from d) < 6 and not calc._is_bank_holiday(d::date)
$$;

-- Pay dates between p_from and p_to. Each scheduled date is counted forward (and back) from the
-- known pay date, then moved to the bank business day before when it lands on a weekend or a
-- bank holiday (Lincoln every other Friday, VA on the 1st). p_anchor is a scheduled date, before
-- any move. Same name and arguments as before, so the briefing's next-income line moves too.
create or replace function calc._pay_dates(p_cadence text, p_anchor date, p_from date, p_to date) returns setof date
language sql immutable set search_path = ''
as $$
  select paid from (
    select calc._prev_business_day(d) as paid from (
      select calc._day_in_month(m::date, extract(day from p_anchor)::int) as d
        from generate_series(date_trunc('month', p_from), date_trunc('month', p_to + 10), interval '1 month') m
       where p_cadence = 'monthly'
      union all
      select p_anchor + 14 * k
        from generate_series(ceil((p_from - p_anchor) / 14.0)::int, floor((p_to + 10 - p_anchor) / 14.0)::int) k
       where p_cadence = 'biweekly'
    ) scheduled
    where d >= p_from
  ) moved
  where paid between p_from and p_to
$$;

-- ---------------------------------------------------------------- 2. bill schedules

-- Cadences counted by due date rather than by month. They can fall due more than once a month.
create function calc._is_date_cadence(p_cadence text) returns boolean
language sql immutable set search_path = ''
as $$ select p_cadence in ('weekly', 'biweekly', 'per_paycheck') $$;

-- Month-based cadences: whether one falls due in p_month, counted from one known due date.
create or replace function calc._cadence_due(p_cadence text, p_anchor date, p_month date) returns boolean
language sql immutable set search_path = ''
as $$
  select case p_cadence
    when 'monthly' then true
    else (((extract(year from p_month)::int * 12 + extract(month from p_month)::int)
          - (extract(year from p_anchor)::int * 12 + extract(month from p_anchor)::int))
          % (case p_cadence when 'every_other_month' then 2 when 'quarterly' then 3 when 'semiannual' then 6 else 12 end) + 12)
         % (case p_cadence when 'every_other_month' then 2 when 'quarterly' then 3 when 'semiannual' then 6 else 12 end) = 0
  end
$$;

-- Every date a schedule falls on between p_from and p_to. Shared by bills and transfers.
--   monthly: p_day each month. every_other_month, quarterly, semiannual, annual: p_day in the
--     months counted from p_anchor. A day past the end of a short month moves to its last day.
--   weekly, biweekly: every 7 or 14 days from p_anchor.
--   per_paycheck: each pay date of income source p_income_key (already moved off weekends and
--     holidays), using the version of the income source in effect on that date.
create function calc._schedule_dates(p_cadence text, p_day int, p_anchor date, p_income_key text, p_from date, p_to date)
returns setof date
language sql stable set search_path = ''
as $$
  select calc._day_in_month(m::date, p_day)
    from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') m
   where p_cadence in ('monthly', 'every_other_month', 'quarterly', 'semiannual', 'annual')
     and calc._cadence_due(p_cadence, p_anchor, m::date)
     and calc._day_in_month(m::date, p_day) between p_from and p_to
  union all
  select p_anchor + s.step * k
    from (select case p_cadence when 'weekly' then 7 when 'biweekly' then 14 end as step) s,
         generate_series(ceil((p_from - p_anchor) / s.step::numeric)::int, floor((p_to - p_anchor) / s.step::numeric)::int) k
   where s.step is not null
  union all
  select pd
    from ref.income_sources i,
         calc._pay_dates(i.cadence, i.anchor_pay_date, greatest(p_from, i.valid_from), least(p_to, coalesce(i.valid_to - 1, p_to))) pd
   where p_cadence = 'per_paycheck' and i.income_key = p_income_key
$$;

-- The dates a payment can land on and still count for a cycle.
--   Month-based: from 7 days before the due month to 7 days after it (as before).
--   weekly: 3 days either side of the due date. biweekly, per_paycheck: 6 days before to 7 after.
create function calc._match_window(p_cadence text, p_due_month date, p_due_on date) returns daterange
language sql immutable set search_path = ''
as $$
  select case
    when p_cadence = 'weekly' then daterange(p_due_on - 3, p_due_on + 3, '[]')
    when p_cadence in ('biweekly', 'per_paycheck') then daterange(p_due_on - 6, p_due_on + 7, '[]')
    else daterange(p_due_month - 7, calc._month_end(p_due_month) + 7, '[]')
  end
$$;

-- ref.bills: the income source a per-paycheck bill follows, and the rule for which fields each
-- cadence needs. This check also lists the cadences allowed.
alter table ref.bills add column income_key text;
comment on column ref.bills.income_key is 'For cadence per_paycheck: the income source whose pay dates it falls due on.';
comment on column ref.bills.cadence is 'monthly, every_other_month, quarterly, semiannual, annual (due_day in the month), weekly, biweekly (every 7 or 14 days from cadence_anchor), or per_paycheck (each pay date of income_key).';
comment on column ref.bills.cadence_anchor is 'One known due date. Needed for every_other_month, quarterly, semiannual, annual, weekly and biweekly.';
comment on column ref.bills.due_day is 'Day of the month it is due, for the month-based cadences. Past the end of a short month, it moves to the last day. Not used by weekly, biweekly or per_paycheck.';
alter table ref.bills add constraint bills_schedule check (
  case
    when cadence = 'monthly' then due_day is not null
    when cadence in ('every_other_month', 'quarterly', 'semiannual', 'annual') then due_day is not null and cadence_anchor is not null
    when cadence in ('weekly', 'biweekly') then cadence_anchor is not null
    when cadence = 'per_paycheck' then income_key is not null
    else false
  end);
create trigger bills_income before insert or update of income_key on ref.bills
  for each row execute function ref.require_key('income_key', 'ref.income_sources', 'income_key', 'current');

create or replace view ref.current_bills with (security_invoker = true) as
  select * from ref.bills
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- Which occurrence a payment or a proposal is for. Month-based bills still pair by month, so a
-- later change of due day doesn't unpay a month; weekly, biweekly and per-paycheck bills pair by
-- this date. Null on rows written before this column existed.
alter table ledger.payments add column due_on date;
comment on column ledger.payments.due_on is 'The due date of the cycle it pays. Weekly, biweekly and per-paycheck bills pair on this; month-based bills pair on due_month.';
create index payments_bill_due_on on ledger.payments (bill_key, due_on);
alter table knowledge.proposed_matches add column due_on date;
comment on column knowledge.proposed_matches.due_on is 'The due date of the cycle it would pay.';

create or replace view ledger.payments_effective with (security_invoker = true) as
  select p.* from ledger.payments p
  where not exists (select 1 from ledger.voids v where v.payment_id = p.id);

alter table calc.bill_cycles add column cadence text;
comment on column calc.bill_cycles.cadence is 'The cadence of the bill version used. Weekly, biweekly and per_paycheck bills have one row per due date, so more than one a month.';
comment on table calc.bill_cycles is 'Each bill on each due date (one a month for month-based cadences). paid = a ledger payment exists; pending_match = a proposal waits; late = the due month ended unpaid; otherwise not_seen_yet.';

-- ---------------------------------------------------------------- 1. transfers

create table ref.transfers (
  id                bigint generated always as identity primary key,
  transfer_key      text not null check (transfer_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  name              text not null,
  from_account_key  text not null,
  to_account_key    text not null,
  amount            numeric(12, 2) not null check (amount > 0),
  cadence           text not null,
  day_of_month      smallint check (day_of_month between 1 and 31),
  cadence_anchor    date,
  income_key        text,
  note              text,
  valid_from        date not null default current_date,
  valid_to          date,
  created_at        timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (from_account_key <> to_account_key),
  constraint transfers_schedule check (
    case
      when cadence = 'monthly' then day_of_month is not null
      when cadence in ('every_other_month', 'quarterly', 'semiannual', 'annual') then day_of_month is not null and cadence_anchor is not null
      when cadence in ('weekly', 'biweekly') then cadence_anchor is not null
      when cadence = 'per_paycheck' then income_key is not null
      else false
    end)
);
comment on table ref.transfers is 'Planned moves of money between the household''s own accounts (for example Joint to Bill Pay each payday). Versioned like the other ref tables. They move money in the projection; they are not bills and are never matched.';
comment on column ref.transfers.cadence is 'Same cadences as ref.bills. per_paycheck follows the pay dates of income_key, after they move off weekends and holidays.';
create unique index transfers_one_open on ref.transfers (transfer_key) where valid_to is null;
create trigger transfers_from before insert or update of from_account_key on ref.transfers
  for each row execute function ref.require_key('from_account_key', 'ref.accounts', 'account_key', 'current');
create trigger transfers_to before insert or update of to_account_key on ref.transfers
  for each row execute function ref.require_key('to_account_key', 'ref.accounts', 'account_key', 'current');
create trigger transfers_income before insert or update of income_key on ref.transfers
  for each row execute function ref.require_key('income_key', 'ref.income_sources', 'income_key', 'current');

create view ref.current_transfers with (security_invoker = true) as
  select * from ref.transfers
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

revoke all on ref.transfers, ref.current_transfers from anon, authenticated, public;
grant select on ref.transfers, ref.current_transfers to assistant_read;
alter table ref.transfers enable row level security;
create policy assistant_reads on ref.transfers for select to assistant_read using (true);

-- ---------------------------------------------------------------- bill cycles

-- One row per bill per due date, from the bill's first version to the end of the month two
-- months ahead.
-- Month-based cadences: one row a month. Each month uses the version in effect on its own due
--   date. If a change of due day leaves no version covering its own due date that month, the
--   newest version overlapping the month is used, as long as the bill hadn't ended by then.
-- weekly, biweekly, per_paycheck: one row per date, from the version in effect on that date.
-- Paid: a ledger payment for the same month (month-based) or the same due date (the others).
-- Status here is paid or not; refresh_all sets pending_match and late after the matcher runs.
create or replace function calc._build_bill_cycles(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count   int;
  v_horizon date := calc._month_end((date_trunc('month', p_today) + interval '2 months')::date);
begin
  delete from calc.bill_cycles;

  insert into calc.bill_cycles (bill_key, due_month, due_on, bill_name, account_key, amount_kind, autopay,
                                expected_amount, status, payment_id, bill_version_id, cadence)
  with starts as (
    select bill_key, min(valid_from) as start_on from ref.bills group by bill_key
  ), months as (
    select s.bill_key, s.start_on, m::date as due_month
      from starts s,
           generate_series(date_trunc('month', s.start_on), date_trunc('month', p_today) + interval '2 months', interval '1 month') m
  ), candidates as (
    select m.bill_key, m.due_month, b.id, b.name, b.account_key, b.amount_kind, b.autopay, b.amount, b.valid_from, b.valid_to,
           b.cadence, calc._day_in_month(m.due_month, b.due_day) as due_on
      from months m
      join ref.bills b
        on b.bill_key = m.bill_key
       and b.valid_from <= calc._month_end(m.due_month)
       and (b.valid_to is null or b.valid_to > m.due_month)
     where not calc._is_date_cadence(b.cadence)
       and calc._cadence_due(b.cadence, b.cadence_anchor, m.due_month)
       and calc._day_in_month(m.due_month, b.due_day) >= m.start_on
  ), ranked as (
    select c.*,
           (c.valid_from <= c.due_on and (c.valid_to is null or c.due_on < c.valid_to)) as covers_due,
           row_number() over (
             partition by c.bill_key, c.due_month
             order by (c.valid_from <= c.due_on and (c.valid_to is null or c.due_on < c.valid_to)) desc,
                      c.valid_from desc, c.id desc) as rn
      from candidates c
  ), cycles as (
    select r.bill_key, r.due_month, r.due_on, r.name, r.account_key, r.amount_kind, r.autopay, r.amount, r.id, r.cadence
      from ranked r
     where r.rn = 1
       and (r.covers_due
            or exists (select 1 from ref.bills b2
                        where b2.bill_key = r.bill_key and (b2.valid_to is null or b2.valid_to > r.due_on)))
    union all
    select b.bill_key, date_trunc('month', d)::date, d, b.name, b.account_key, b.amount_kind, b.autopay, b.amount, b.id, b.cadence
      from ref.bills b,
           calc._schedule_dates(b.cadence, b.due_day, b.cadence_anchor, b.income_key, b.valid_from,
                                least(coalesce(b.valid_to - 1, v_horizon), v_horizon)) d
     where calc._is_date_cadence(b.cadence)
  )
  select c.bill_key, c.due_month, c.due_on, c.name, c.account_key, c.amount_kind, c.autopay, c.amount,
         case when p.payment_id is not null then 'paid' else 'not_seen_yet' end,
         p.payment_id, c.id, c.cadence
    from cycles c
    left join lateral (
      select min(pe.id) as payment_id
        from ledger.payments_effective pe
       where pe.bill_key = c.bill_key
         and case when calc._is_date_cadence(c.cadence)
                  then coalesce(pe.due_on = c.due_on, pe.due_month = c.due_month)
                  else pe.due_month = c.due_month end
    ) p on true;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- Sets pending_match and late on the cycles that aren't paid. A waiting proposal comes before
-- late: the bill may have been paid and only needs a "yes" in a chat (rule 11, don't cry wolf).
-- Late means the due month ended unpaid (rule 4), for every cadence.
create or replace function calc._set_cycle_status(p_today date) returns void
language sql set search_path = ''
as $$
  update calc.bill_cycles c
     set proposed_match_id = pm.id,
         status = case when pm.id is not null then 'pending_match'
                       when calc._month_end(c.due_month) < p_today then 'late'
                       else 'not_seen_yet' end
    from (
      select c2.bill_key, c2.due_on,
             (select min(m.id) from knowledge.proposed_matches m
               where m.bill_key = c2.bill_key and m.status in ('pending', 'ambiguous')
                 and case when calc._is_date_cadence(c2.cadence)
                          then coalesce(m.due_on = c2.due_on, m.due_month = c2.due_month)
                          else m.due_month = c2.due_month end) as id
        from calc.bill_cycles c2
       where c2.status <> 'paid'
    ) pm
   where c.bill_key = pm.bill_key and c.due_on = pm.due_on
$$;

-- ---------------------------------------------------------------- the matcher

-- As before (see calculations.md), with two changes for bills that fall due more than once a
-- month: the date points use calc._match_window (a few days around the due date for weekly,
-- biweekly and per-paycheck bills), and among those bills' cycles one with a proposal already
-- waiting is picked last. Each proposal records the due date of the cycle it would pay.
create or replace function calc._run_matcher(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, due_on, score, reason, status)
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
    select tx.era_transaction_id, b.bill_key, cy.due_month, cy.due_on,
           case when b.era_account_id = tx.era_account_id then 30 else 0 end as s_account,
           case when abs(tx.amount - b.amount) <= b.tolerance then 40 else 0 end as s_amount,
           case when tx.occurred_on <@ cy.win then 20 else 0 end as s_date,
           case when exists (select 1 from ref.bill_aliases al
                              where al.bill_key = b.bill_key
                                and al.valid_from <= p_today and (al.valid_to is null or al.valid_to > p_today)
                                and position(lower(al.alias) in lower(coalesce(tx.merchant, ''))) > 0)
                  or ('bill:' || lower(b.bill_key)) = any (tx.tags)
                  or ('bill:' || lower(b.name)) = any (tx.tags)
                then 10 else 0 end as s_name,
           tx.amount as tx_amount, b.amount as bill_amount, tx.occurred_on
      from tx
      cross join bills b
      -- The cycle it would pay: the nearest unpaid one, preferring one whose window holds the date.
      join lateral (
        select c.due_month, c.due_on, calc._match_window(c.cadence, c.due_month, c.due_on) as win
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and abs(tx.occurred_on - c.due_on) <= 45
         order by (tx.occurred_on <@ calc._match_window(c.cadence, c.due_month, c.due_on)) desc,
                  (calc._is_date_cadence(c.cadence)
                   and exists (select 1 from knowledge.proposed_matches m
                                where m.bill_key = c.bill_key and m.status in ('pending', 'ambiguous')
                                  and coalesce(m.due_on = c.due_on, m.due_month = c.due_month))),
                  abs(tx.occurred_on - c.due_on), c.due_on
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
  select r.era_transaction_id, r.bill_key, r.due_month, r.due_on, r.score,
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

-- ---------------------------------------------------------------- cash projection

-- As before (see calculations.md), plus:
-- Transfers: each planned transfer comes out of its from-account and goes into its to-account on
--   its dates. Like income, a side counts only on days after that account's starting balance, so
--   a transfer already inside a balance isn't counted twice. what_if's income_change doesn't stop
--   a per-paycheck transfer.
-- skip_bill can name one due date (due_on) instead of the whole month.
create or replace function calc._project(p_today date, p_changes jsonb default null)
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
  ), transfers as (
    select t.transfer_key as key, t.name, t.from_account_key, t.to_account_key, t.amount, td as day
      from ref.transfers t, params,
           calc._schedule_dates(t.cadence, t.day_of_month, t.cadence_anchor, t.income_key,
                                greatest(params.d0, t.valid_from), least(params.d1, coalesce(t.valid_to - 1, params.d1))) td
  ), bills as (
    select c.account_key, greatest(c.due_on, params.d0) as day, 'bill'::text as kind, c.bill_key as key, c.bill_name as name,
           c.expected_amount as amount
      from calc.bill_cycles c, params
     where c.status = 'not_seen_yet'
       and (c.due_on between params.d0 and params.d1
            or (c.due_on < params.d0 and c.due_month = date_trunc('month', params.d0)::date))
       and not exists (select 1 from changes ch
                        where ch.c ->> 'type' = 'skip_bill' and ch.c ->> 'bill_key' = c.bill_key
                          and date_trunc('month', (ch.c ->> 'due_month')::date)::date = c.due_month
                          and (ch.c ->> 'due_on' is null or (ch.c ->> 'due_on')::date = c.due_on))
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
    select t.from_account_key, t.day, 'transfer', t.key, t.name, 0, t.amount
      from transfers t join starts s on s.account_key = t.from_account_key
     where t.day > s.as_of_day
    union all
    select t.to_account_key, t.day, 'transfer', t.key, t.name, t.amount, 0
      from transfers t join starts s on s.account_key = t.to_account_key
     where t.day > s.as_of_day
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

comment on column calc.cash_projection.detail is 'What moves that day: [{kind: income|transfer|bill|change, key, name, amount, direction: in|out}]. Amounts are positive.';

-- ---------------------------------------------------------------- what_if

-- Read-only. Takes a list of changes and returns how the 60-day projection moves: the lowest
-- balance and its date on each account, the first day below $0, and debt payoff dates that
-- move. It is STABLE, so Postgres itself refuses any write inside it.
-- Changes (one object or a list):
--   {"type": "extra_payment",   "debt_key", "amount", "on", "account_key", "monthly"?}
--   {"type": "skip_bill",       "bill_key", "due_month", "due_on"? (one date, for bills due more than once a month)}
--   {"type": "one_off_expense", "account_key", "amount", "on", "label"?}
--   {"type": "income_change",   "income_key", "amount" (the new amount, 0 = stops), "from"}
-- A change, field or key it doesn't recognize is refused by name, never ignored.
create or replace function calc.what_if(p_changes jsonb, p_today date default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today    date := coalesce(p_today, calc._today());
  v_list     jsonb;
  v_norm     jsonb := '[]'::jsonb;
  v_change   jsonb;
  v_n        int;
  v_type     text;
  v_allowed  text[];
  v_required text[];
  v_bad      text;
  v_amount   numeric;
  v_accounts jsonb;
  v_payoffs  jsonb;
  v_notes    jsonb := '[]'::jsonb;
begin
  v_list := case jsonb_typeof(p_changes)
              when 'array' then p_changes
              when 'object' then jsonb_build_array(p_changes)
            end;
  if v_list is null then
    raise exception 'what_if takes a change or a list of changes, each like {"type": "one_off_expense", ...}.' using errcode = 'P0001';
  end if;

  for v_change, v_n in select e, n from jsonb_array_elements(v_list) with ordinality as x(e, n) loop
    if jsonb_typeof(v_change) <> 'object' then
      raise exception 'Change % isn''t an object with a type.', v_n using errcode = 'P0001';
    end if;
    v_type := v_change ->> 'type';
    case v_type
      when 'extra_payment' then
        v_allowed := array['type', 'debt_key', 'amount', 'on', 'account_key', 'monthly'];
        v_required := array['debt_key', 'amount', 'on', 'account_key'];
      when 'skip_bill' then
        v_allowed := array['type', 'bill_key', 'due_month', 'due_on'];
        v_required := array['bill_key', 'due_month'];
      when 'one_off_expense' then
        v_allowed := array['type', 'account_key', 'amount', 'on', 'label'];
        v_required := array['account_key', 'amount', 'on'];
      when 'income_change' then
        v_allowed := array['type', 'income_key', 'amount', 'from'];
        v_required := array['income_key', 'amount', 'from'];
      else
        raise exception 'what_if doesn''t know the change "%" (change %). It knows extra_payment, skip_bill, one_off_expense and income_change.',
          coalesce(v_type, ''), v_n using errcode = 'P0001';
    end case;

    select string_agg(k, ', ' order by k) into v_bad from jsonb_object_keys(v_change) k where k <> all (v_allowed);
    if v_bad is not null then
      raise exception 'Change % (%) doesn''t take: %. It takes: %.', v_n, v_type, v_bad, array_to_string(v_allowed[2:], ', ')
        using errcode = 'P0001';
    end if;
    select string_agg(k, ', ' order by k) into v_bad
      from unnest(v_required) k where not (v_change ? k) or v_change -> k = 'null'::jsonb;
    if v_bad is not null then
      raise exception 'Change % (%) needs: %.', v_n, v_type, v_bad using errcode = 'P0001';
    end if;

    begin
      v_amount := (v_change ->> 'amount')::numeric;
      perform (v_change ->> 'on')::date, (v_change ->> 'from')::date, (v_change ->> 'due_month')::date,
              (v_change ->> 'due_on')::date, (v_change ->> 'monthly')::boolean;
    exception when others then
      raise exception 'Change % (%) has a value of the wrong type: %. Amounts are numbers, dates are YYYY-MM-DD, monthly is true or false.',
        v_n, v_type, sqlerrm using errcode = 'P0001';
    end;
    if v_amount < 0 or (v_amount = 0 and v_type <> 'income_change') then
      raise exception 'Change % (%) needs an amount above 0.', v_n, v_type using errcode = 'P0001';
    end if;
    if v_change ? 'due_on' and date_trunc('month', (v_change ->> 'due_on')::date) <> date_trunc('month', (v_change ->> 'due_month')::date) then
      raise exception 'Change % (skip_bill): due_on % isn''t in due_month %.', v_n, v_change ->> 'due_on', v_change ->> 'due_month'
        using errcode = 'P0001';
    end if;

    if v_change ? 'account_key' and not exists (
         select 1 from ref.accounts where account_key = v_change ->> 'account_key'
            and valid_from <= v_today and (valid_to is null or valid_to > v_today)) then
      raise exception 'Change %: there is no account "%".', v_n, v_change ->> 'account_key' using errcode = 'P0001';
    end if;
    if v_change ? 'debt_key' and not exists (
         select 1 from ref.debts where debt_key = v_change ->> 'debt_key'
            and valid_from <= v_today and (valid_to is null or valid_to > v_today)) then
      raise exception 'Change %: there is no debt "%".', v_n, v_change ->> 'debt_key' using errcode = 'P0001';
    end if;
    if v_change ? 'bill_key' and not exists (select 1 from ref.bills where bill_key = v_change ->> 'bill_key') then
      raise exception 'Change %: there is no bill "%".', v_n, v_change ->> 'bill_key' using errcode = 'P0001';
    end if;
    if v_change ? 'income_key' and not exists (select 1 from ref.income_sources where income_key = v_change ->> 'income_key') then
      raise exception 'Change %: there is no income source "%".', v_n, v_change ->> 'income_key' using errcode = 'P0001';
    end if;

    if v_type = 'skip_bill' and not exists (
         select 1 from calc.bill_cycles where bill_key = v_change ->> 'bill_key'
            and due_month = date_trunc('month', (v_change ->> 'due_month')::date)::date
            and (v_change ->> 'due_on' is null or due_on = (v_change ->> 'due_on')::date)
            and status = 'not_seen_yet') then
      v_notes := v_notes || to_jsonb(format('Change %s: %s isn''t due unpaid %s, so skipping it changes nothing.',
                                            v_n, v_change ->> 'bill_key',
                                            case when v_change ? 'due_on' then 'on that date' else 'in that month' end));
    end if;
    v_norm := v_norm || v_change;
  end loop;

  -- Lowest balance and first day below $0 on each account, before and after.
  with base as (
    select * from calc._project(v_today, null)
  ), scen as (
    select * from calc._project(v_today, v_norm)
  ), summary as (
    select 'baseline' as which, account_key,
           (array_agg(closing order by closing, day))[1] as lowest,
           (array_agg(day order by closing, day))[1] as lowest_on,
           min(day) filter (where closing < 0) as first_below_zero_on,
           (array_agg(closing order by day desc))[1] as end_balance
      from base group by account_key
    union all
    select 'scenario', account_key,
           (array_agg(closing order by closing, day))[1],
           (array_agg(day order by closing, day))[1],
           min(day) filter (where closing < 0),
           (array_agg(closing order by day desc))[1]
      from scen group by account_key
  )
  select jsonb_agg(jsonb_build_object(
           'account_key', b.account_key,
           'baseline', jsonb_build_object('lowest', b.lowest, 'lowest_on', b.lowest_on,
                                          'first_below_zero_on', b.first_below_zero_on, 'end_balance', b.end_balance),
           'scenario', jsonb_build_object('lowest', s.lowest, 'lowest_on', s.lowest_on,
                                          'first_below_zero_on', s.first_below_zero_on, 'end_balance', s.end_balance),
           'lowest_change', s.lowest - b.lowest,
           'end_change', s.end_balance - b.end_balance) order by b.account_key)
    into v_accounts
    from summary b join summary s on s.account_key = b.account_key and s.which = 'scenario'
   where b.which = 'baseline';

  -- Payoff dates for the debts an extra payment touches.
  select jsonb_agg(jsonb_build_object(
           'debt_key', d.debt_key,
           'balance', d.balance,
           'baseline_payoff', calc._payoff_month(d.balance, d.apr, d.minimum_payment, v_today),
           'scenario_payoff', calc._payoff_month(d.balance, d.apr, d.minimum_payment, v_today,
                                (select jsonb_agg(c) from jsonb_array_elements(v_norm) c
                                  where c ->> 'type' = 'extra_payment' and c ->> 'debt_key' = d.debt_key))) order by d.debt_key)
    into v_payoffs
    from calc.debt_snapshot d
   where d.debt_key in (select c ->> 'debt_key' from jsonb_array_elements(v_norm) c where c ->> 'type' = 'extra_payment');

  if exists (select 1 from jsonb_array_elements(v_norm) c
              join calc.debt_snapshot d on d.debt_key = c ->> 'debt_key' where d.balance is null) then
    v_notes := v_notes || to_jsonb('A debt in the changes has no balance, so its payoff date can''t be estimated.'::text);
  end if;
  if not exists (select 1 from ref.income_sources where valid_to is null or valid_to > v_today) then
    v_notes := v_notes || to_jsonb('No income is on file, so both projections show only money going out.'::text);
  end if;
  if exists (select 1 from jsonb_array_elements(v_norm) c where c ->> 'type' = 'income_change')
     and exists (select 1 from ref.transfers where cadence = 'per_paycheck' and (valid_to is null or valid_to > v_today)) then
    v_notes := v_notes || to_jsonb('Planned transfers that follow a paycheck still happen in the scenario, even if that income changes.'::text);
  end if;
  if exists (select 1 from calc.account_balances where balance is null and kind in ('checking', 'savings')) then
    v_notes := v_notes || to_jsonb('Accounts with no balance are left out: '
      || (select string_agg(name, ', ' order by name) from calc.account_balances where balance is null and kind in ('checking', 'savings')) || '.');
  end if;
  v_notes := v_notes || to_jsonb('Payoff dates assume the minimum payment stays the same and payments start next month. They are estimates.'::text);

  return jsonb_build_object(
    'today', v_today,
    'numbers_as_of', (select numbers_as_of from calc.briefing),
    'changes', v_norm,
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'payoffs', coalesce(v_payoffs, '[]'::jsonb),
    'notes', v_notes);
end
$$;

-- ---------------------------------------------------------------- actions

-- confirm_match: as before, and the payment records the due date of the cycle it pays.
create or replace function actions.confirm_match(
  p_person    text,
  p_match_id  bigint,
  p_alias     text default null,
  p_note      text default null
) returns ledger.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'match_id', p_match_id, 'alias', p_alias, 'note', p_note);
  v_prior  jsonb;
  v_match  knowledge.proposed_matches;
  v_tx     raw.era_transactions;
  v_pay    ledger.payments;
begin
  v_prior := actions._prior_result('confirm_match', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ledger.payments, v_prior);
  end if;

  select * into v_match from knowledge.proposed_matches where id = p_match_id for update;
  if not found then
    raise exception 'There is no proposed match %.', p_match_id using errcode = 'P0001';
  end if;
  if v_match.status not in ('pending', 'ambiguous') then
    raise exception 'Match % is already %, so it can''t be confirmed.', p_match_id, v_match.status using errcode = 'P0001';
  end if;

  select * into v_tx from raw.era_transactions where era_transaction_id = v_match.era_transaction_id;
  if not found then
    raise exception 'The transaction for match % isn''t in the Era data.', p_match_id using errcode = 'P0001';
  end if;
  if v_tx.removed_at is not null then
    raise exception 'Era no longer shows the transaction for match % (it may have posted under a new id). Nothing was written.', p_match_id
      using errcode = 'P0001';
  end if;
  if v_tx.amount is null or v_tx.occurred_on is null then
    raise exception 'The transaction for match % has no amount or date yet.', p_match_id using errcode = 'P0001';
  end if;
  if v_tx.amount >= 0 then
    raise exception 'The transaction for match % is money in, not a payment.', p_match_id using errcode = 'P0001';
  end if;
  if exists (select 1 from ledger.payments_effective where era_transaction_id = v_tx.era_transaction_id) then
    raise exception 'That transaction is already recorded as a payment. Void that payment first if it was wrong.'
      using errcode = 'P0001';
  end if;

  insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, era_transaction_id, proposed_match_id, entered_by, note)
  values (v_match.bill_key, v_match.due_month, v_match.due_on, abs(v_tx.amount), v_tx.occurred_on, v_tx.era_transaction_id,
          v_match.id, v_person, p_note)
  returning * into v_pay;

  update knowledge.proposed_matches
     set status = 'confirmed', decided_at = now(), decided_by = v_person
   where id = v_match.id;

  -- One transaction pays one bill: close any other open proposal for the same transaction.
  update knowledge.proposed_matches
     set status = 'rejected', decided_at = now(), decided_by = v_person,
         decision_note = 'Another bill was confirmed for this transaction.'
   where era_transaction_id = v_match.era_transaction_id
     and id <> v_match.id
     and status in ('pending', 'ambiguous');

  -- A new merchant name becomes an alias, so the next one matches on name too.
  if nullif(trim(p_alias), '') is not null then
    insert into ref.bill_aliases (bill_key, alias) values (v_match.bill_key, trim(p_alias))
    on conflict do nothing;
  end if;

  perform calc.refresh_all();
  perform actions._log_call('confirm_match', v_person, v_args, to_jsonb(v_pay));
  return v_pay;
end
$$;

-- update_bill: as before, plus income_key, and due_day is needed only by the month-based cadences
-- (the bills_schedule check says which fields each cadence needs).
create or replace function actions.update_bill(
  p_person          text,
  p_bill_key        text,
  p_changes         jsonb default '{}'::jsonb,
  p_effective_from  date default null,
  p_end             boolean default false
) returns ref.bills
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person    text := actions._person(p_person);
  v_changes   jsonb := coalesce(p_changes, '{}'::jsonb);
  v_from      date := coalesce(p_effective_from, current_date);
  v_args      jsonb := jsonb_build_object('person', v_person, 'bill_key', p_bill_key, 'changes', v_changes,
                                          'effective_from', p_effective_from, 'end', p_end);
  v_allowed   text[] := array['name', 'amount', 'amount_kind', 'tolerance', 'due_day', 'account_key',
                              'autopay', 'cadence', 'cadence_anchor', 'income_key', 'note'];
  v_required  text[] := array['name', 'amount', 'amount_kind', 'account_key', 'autopay', 'cadence'];
  v_bad       text;
  v_prior     jsonb;
  v_old       ref.bills;
  v_new       ref.bills;
begin
  v_prior := actions._prior_result('update_bill', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ref.bills, v_prior);
  end if;

  if jsonb_typeof(v_changes) <> 'object' then
    raise exception 'Changes must be a set of field names and values.' using errcode = 'P0001';
  end if;
  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(v_changes) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'update_bill doesn''t know these fields: %. It accepts: %.', v_bad, array_to_string(v_allowed, ', ')
      using errcode = 'P0001';
  end if;

  select * into v_old from ref.bills where bill_key = p_bill_key and valid_to is null for update;

  if p_end then
    if v_old.id is null then
      raise exception 'There is no open bill "%" to end.', coalesce(p_bill_key, '') using errcode = 'P0001';
    end if;
    if v_changes <> '{}'::jsonb then
      raise exception 'Ending a bill takes no other changes.' using errcode = 'P0001';
    end if;
    if v_from < v_old.valid_from then
      raise exception 'The bill''s current version starts %, so it can''t end before that.', v_old.valid_from using errcode = 'P0001';
    end if;
    update ref.bills set valid_to = v_from where id = v_old.id returning * into v_new;
    perform calc.refresh_all();
    perform actions._log_call('update_bill', v_person, v_args, to_jsonb(v_new));
    return v_new;
  end if;

  if v_old.id is null then
    -- A new bill.
    if nullif(trim(p_bill_key), '') is null then
      raise exception 'A new bill needs a bill_key, a short name like "phone".' using errcode = 'P0001';
    end if;
    select string_agg(k, ', ' order by k) into v_bad
      from unnest(v_required) k where not (v_changes ? k) or v_changes -> k = 'null'::jsonb;
    if v_bad is not null then
      raise exception 'A new bill needs %, plus what its cadence needs. Missing: %. Unknown fields go in an open question, not a guess.',
        array_to_string(v_required, ', '), v_bad using errcode = 'P0001';
    end if;
    v_new := jsonb_populate_record(null::ref.bills, v_changes);
  else
    if v_changes = '{}'::jsonb then
      raise exception 'No changes were given for "%".', p_bill_key using errcode = 'P0001';
    end if;
    if v_from < v_old.valid_from then
      raise exception 'The bill''s current version starts %, so a change can''t start before that.', v_old.valid_from
        using errcode = 'P0001';
    end if;
    update ref.bills set valid_to = v_from where id = v_old.id;
    v_new := jsonb_populate_record(v_old, v_changes);
  end if;

  begin
    insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay,
                           cadence, cadence_anchor, income_key, note, valid_from)
    values (p_bill_key, v_new.name, v_new.amount, v_new.amount_kind, v_new.tolerance, v_new.due_day, v_new.account_key,
            v_new.autopay, v_new.cadence, v_new.cadence_anchor, v_new.income_key, v_new.note, v_from)
    returning * into v_new;
  exception
    when check_violation or not_null_violation then
      raise exception 'That bill has a value that isn''t allowed. Amounts are at least 0 and amount_kind is fixed or variable. Cadence is monthly (needs due_day), every_other_month, quarterly, semiannual or annual (need due_day and a cadence_anchor date), weekly or biweekly (need a cadence_anchor date), or per_paycheck (needs income_key). bill_key is lowercase letters, digits, - or _. Nothing was written.'
        using errcode = 'P0001';
  end;

  perform calc.refresh_all();
  perform actions._log_call('update_bill', v_person, v_args, to_jsonb(v_new));
  return v_new;
exception
  when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
    raise exception 'One of the values for "%" isn''t the right type (%). Nothing was written.', coalesce(p_bill_key, ''), sqlerrm
      using errcode = 'P0001';
end
$$;

-- ---------------------------------------------------------------- access

-- New functions: no role but the owner. what_if, refresh_all and the actions keep their grants.
revoke all on function calc._is_bank_holiday(date), calc._prev_business_day(date), calc._is_date_cadence(text),
                       calc._schedule_dates(text, int, date, text, date, date), calc._match_window(text, date, date)
  from public, anon, authenticated;
