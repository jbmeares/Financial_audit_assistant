-- Store a card's promo and rate parts as real numbers (James, 2026-11-15).
--
-- A chat misreported James's CareCredit: it said the second promo was $825 and called the
-- whole remainder "the rest of the balance at 32.99%". The parts lived in the free-text
-- ref.debts.note, and ref.debt_promos had only an amount and an end date, so chats retold them
-- in prose. The Oct 18, 2026 statement shows four parts: purchases at 32.99%, a fixed-payment
-- plan at 17.90% until paid off, and two deferred-interest promos (Dec 18 and Jan 18).
--
--   ref.debt_buckets        one row per part of a debt's balance: kind (deferred_interest,
--                           zero_apr or reduced_apr), amount, APR, end date (none for a
--                           reduced-APR plan), back interest built up on a deferred-interest
--                           promo, and the statement date the numbers come from. Versioned like
--                           the other ref tables. It replaces ref.debt_promos, which is kept,
--                           retired, so nothing is dropped.
--   calc._debt_parts        a debt's balance split into those parts, worked out once: each
--                           part's amount (capped at the balance), the rate it is charged now
--                           and its monthly interest, plus the rest of the balance at the APR.
--   calc.debt_snapshot      new columns promo_balance, reduced_apr_balance, full_apr_balance,
--                           deferred_interest_at_risk, parts (jsonb) and parts_text.
--                           est_monthly_interest is now the sum over the parts (a running promo
--                           is charged nothing, a reduced-APR plan its own rate). promo_end_on is
--                           the next running promo's end when the debt has parts.
--   calc.debt_parts         a view: one row per part, from the snapshot.
--   calc.refresh_all        the debt_snapshot step fills the new columns. Nothing else changes.
--   calc.debt_payoff_plan   reads ref.debt_buckets. A reduced-APR part is charged its own rate
--                           and paid down last (payments above the minimum go to the highest
--                           rate first). A promo that misses its deadline adds its back interest
--                           (what the last statement showed, so at least that much).
--   calc._build_briefing    for a debt with parts: a promo_ending item per promo ending within
--                           30 days, with its amount and back interest, and a GREEN debt_parts
--                           item with the split already worked out.
--
-- The amounts are data and go in from the SQL-editor file, never from this migration.
-- No DROP statements: functions keep their signatures and are replaced, and the briefing
-- builder keeps running under a new name like the earlier wrappers.

-- ---------------------------------------------------------------- ref.debt_buckets

create table ref.debt_buckets (
  id                bigint generated always as identity primary key,
  debt_key          text not null,
  kind              text not null check (kind in ('deferred_interest', 'zero_apr', 'reduced_apr')),
  amount            numeric(12, 2) not null check (amount > 0),
  apr               numeric(6, 3) not null check (apr >= 0),
  ends_on           date,
  deferred_interest numeric(12, 2) check (deferred_interest >= 0),
  as_of             date not null,
  source            text,
  note              text,
  valid_from        date not null default current_date,
  valid_to          date,
  created_at        timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check ((kind = 'reduced_apr') = (ends_on is null)),
  check (kind = 'deferred_interest' or deferred_interest is null)
);
comment on table ref.debt_buckets is
  'Parts of a debt''s balance with their own terms. The rest of the balance is at the debt''s APR.';
comment on column ref.debt_buckets.kind is
  'deferred_interest: no interest if paid in full by ends_on, else back interest from the purchase date at apr. zero_apr: no interest until ends_on, then apr. reduced_apr: charged apr until paid off (ends_on is null).';
comment on column ref.debt_buckets.amount is 'The part''s balance on the as_of statement.';
comment on column ref.debt_buckets.apr is
  'reduced_apr: the rate charged now. deferred_interest and zero_apr: the rate charged if it isn''t paid by ends_on (none while it runs).';
comment on column ref.debt_buckets.deferred_interest is
  'Back interest built up on a deferred-interest promo as of as_of. It is charged only if the promo isn''t paid in full by ends_on, and it keeps growing until then.';
comment on column ref.debt_buckets.as_of is 'The statement date these numbers come from.';

create trigger debt_buckets_debt before insert or update of debt_key on ref.debt_buckets
  for each row execute function ref.require_key('debt_key', 'ref.debts', 'debt_key', 'current');

create view ref.current_debt_buckets with (security_invoker = true) as
  select * from ref.debt_buckets
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

revoke all on ref.debt_buckets, ref.current_debt_buckets from anon, authenticated, public;
grant select on ref.debt_buckets, ref.current_debt_buckets to assistant_read;
alter table ref.debt_buckets enable row level security;
create policy assistant_reads on ref.debt_buckets for select to assistant_read using (true);

comment on table ref.debt_promos is
  'Retired 2026-11-15: replaced by ref.debt_buckets, which also holds the APR, the kind and the back interest. Nothing reads this table.';

-- ---------------------------------------------------------------- calc._debt_parts

-- A debt's balance split into parts on p_today. Promos still running come first (soonest end
-- first), then reduced-APR plans, then the rest at the APR. Parts are capped so they never add
-- up to more than the balance. A debt with no parts is one full_apr part, as before.
create function calc._debt_parts(p_debt_key text, p_balance numeric, p_apr numeric, p_today date)
returns table (part_order int, kind text, amount numeric, statement_amount numeric, apr numeric,
               rate_now numeric, ends_on date, days_left int, monthly_interest numeric,
               deferred_interest numeric, as_of date, label text)
language sql stable set search_path = ''
as $$
  with b as (
    select b.kind, b.amount, b.apr, b.ends_on, b.deferred_interest, b.as_of,
           row_number() over (order by b.kind = 'reduced_apr', b.ends_on, b.apr desc, b.id) as n
      from ref.debt_buckets b
     where b.debt_key = p_debt_key
       and b.valid_from <= p_today and (b.valid_to is null or b.valid_to > p_today)
       and (b.kind = 'reduced_apr' or b.ends_on >= p_today)
       and p_balance is not null
  ), capped as (
    select b.*,
           greatest(least(b.amount, p_balance - coalesce(sum(b.amount) over (order by b.n
                                                 rows between unbounded preceding and 1 preceding), 0)), 0) as part
      from b
  ), parts as (
    select c.n::int as n, c.kind, c.part, c.amount as stmt, c.apr,
           case when c.kind = 'reduced_apr' then c.apr else 0 end as rate_now,
           c.ends_on, c.deferred_interest, c.as_of
      from capped c where c.part > 0
    union all
    select 1000, 'full_apr', p_balance - coalesce((select sum(c.part) from capped c), 0), null, p_apr, p_apr,
           null, null, null
     where p_balance is not null
  )
  select p.n, p.kind, p.part, p.stmt, p.apr, p.rate_now, p.ends_on, p.ends_on - p_today,
         round(p.part * p.rate_now / 1200, 2), p.deferred_interest, p.as_of,
         case p.kind
           when 'deferred_interest' then format(
             '%s on a deferred-interest promo: no interest if paid in full by %s. If not, back interest at %s%% is added (%s built up as of the %s statement).',
             calc._money(p.part), to_char(p.ends_on, 'Mon FMDD, YYYY'), to_char(p.apr, 'FM990.00'),
             calc._money(coalesce(p.deferred_interest, 0)), to_char(p.as_of, 'Mon FMDD'))
           when 'zero_apr' then format('%s at 0%% until %s, then %s%%.',
             calc._money(p.part), to_char(p.ends_on, 'Mon FMDD, YYYY'), to_char(p.apr, 'FM990.00'))
           when 'reduced_apr' then format('%s on a reduced-APR plan at %s%% until paid off.',
             calc._money(p.part), to_char(p.apr, 'FM990.00'))
           else format('%s at the full %s%% APR.', calc._money(p.part), to_char(p.apr, 'FM990.00'))
         end
    from parts p
   where p.part > 0 or (p.kind = 'full_apr' and not exists (select 1 from capped))
   order by p.n
$$;
comment on function calc._debt_parts(text, numeric, numeric, date) is
  'A debt''s balance split into its parts (ref.debt_buckets) on a day, with the rate each is charged now and its monthly interest. Used by calc.refresh_all.';

-- ---------------------------------------------------------------- calc.debt_snapshot

alter table calc.debt_snapshot
  add column promo_balance             numeric(12, 2),
  add column reduced_apr_balance       numeric(12, 2),
  add column full_apr_balance          numeric(12, 2),
  add column deferred_interest_at_risk numeric(12, 2),
  add column parts                     jsonb,
  add column parts_text                text;
comment on column calc.debt_snapshot.est_monthly_interest is
  'Interest a month at today''s balance, summed over the parts: a running promo is charged nothing, a reduced-APR plan its own rate, the rest the APR.';
comment on column calc.debt_snapshot.promo_balance is 'How much of the balance is on promos still running (deferred interest or 0%).';
comment on column calc.debt_snapshot.reduced_apr_balance is 'How much of the balance is on reduced-APR plans.';
comment on column calc.debt_snapshot.full_apr_balance is 'The rest of the balance, charged the full APR.';
comment on column calc.debt_snapshot.deferred_interest_at_risk is
  'Back interest built up on running deferred-interest promos, as of their statement: charged only if a promo isn''t paid in full by its end date.';
comment on column calc.debt_snapshot.parts is 'Each part of the balance (calc._debt_parts), in order. Also readable as rows in calc.debt_parts.';
comment on column calc.debt_snapshot.parts_text is 'The split in one sentence, ready to say.';

create view calc.debt_parts with (security_invoker = true) as
  select s.debt_key, s.account_key, s.balance, s.balance_as_of, p.*
    from calc.debt_snapshot s
    cross join lateral jsonb_to_recordset(coalesce(s.parts, '[]')) as p(
      part_order int, kind text, amount numeric, statement_amount numeric, apr numeric, rate_now numeric,
      ends_on date, days_left int, monthly_interest numeric, deferred_interest numeric, as_of date, label text);
comment on view calc.debt_parts is
  'One row per part of each debt''s balance, from the last refresh: promos, reduced-APR plans and the rest at the APR, with each part''s monthly interest.';
revoke all on calc.debt_parts from anon, authenticated, public;
grant select on calc.debt_parts to assistant_read;

-- ---------------------------------------------------------------- calc.refresh_all

create or replace function calc.refresh_all(p_pull_run_id bigint default null, p_today date default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_today   date := coalesce(p_today, calc._today());
  v_run_id  bigint;
  v_step    text;
  v_counts  jsonb := '{}'::jsonb;
  v_n       int;
  v_error   text;
  v_fail    text := current_setting('calc.fail_step', true);  -- test hook: names a step to fail
  v_item    jsonb;
begin
  -- One refresh at a time (the nightly pull and an action can arrive together).
  perform pg_advisory_xact_lock(hashtextextended('calc.refresh_all', 0));

  insert into calc.refresh_runs (today, pull_run_id) values (v_today, p_pull_run_id) returning id into v_run_id;

  begin
    v_step := 'bill_cycles';
    if v_fail = v_step then raise exception 'test failure in %', v_step; end if;
    v_n := calc._build_bill_cycles(v_today);
    v_counts := v_counts || jsonb_build_object('bill_cycles', v_n);

    v_step := 'matcher';
    if v_fail = v_step then raise exception 'test failure in %', v_step; end if;
    v_n := calc._run_matcher(v_today);
    perform calc._set_cycle_status(v_today);
    v_counts := v_counts || jsonb_build_object('new_matches', v_n);

    v_step := 'cash_projection';
    if v_fail = v_step then raise exception 'test failure in %', v_step; end if;
    delete from calc.account_balances;
    insert into calc.account_balances (account_key, name, kind, balance, as_of, source, stale)
    select account_key, name, kind, balance, as_of, source, stale from calc._latest_balances(v_today);
    delete from calc.cash_projection;
    insert into calc.cash_projection (account_key, day, opening, money_in, money_out, closing, detail)
    select account_key, day, opening, money_in, money_out, closing, detail from calc._project(v_today, null);
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('projection_days', v_n);

    v_step := 'debt_snapshot';
    if v_fail = v_step then raise exception 'test failure in %', v_step; end if;
    delete from calc.debt_snapshot;
    insert into calc.debt_snapshot (debt_key, account_key, balance, balance_as_of, balance_source, stale, apr,
                                    minimum_payment, est_monthly_interest, promo_end_on, payoff_priority,
                                    promo_balance, reduced_apr_balance, full_apr_balance,
                                    deferred_interest_at_risk, parts, parts_text)
    select d.debt_key, d.account_key, abs(ab.balance), ab.as_of, ab.source, coalesce(ab.stale, true), d.apr,
           d.minimum_payment,
           case when ab.balance is not null then coalesce(pt.interest, 0) end,
           case when hb.has_buckets then pt.next_end else d.promo_end_on end,
           d.payoff_priority,
           case when ab.balance is not null then coalesce(pt.promo, 0) end,
           case when ab.balance is not null then coalesce(pt.reduced, 0) end,
           case when ab.balance is not null then coalesce(pt.full_apr, 0) end,
           case when ab.balance is not null then coalesce(pt.di, 0) end,
           pt.parts,
           case when hb.has_buckets and ab.balance is not null then
             format('%s owes %s: %s About %s interest a month at today''s balance.',
                    coalesce(a.name, d.debt_key), calc._money(abs(ab.balance)), pt.labels, calc._money(coalesce(pt.interest, 0)))
             || coalesce(format(' Promo and plan amounts are from the %s statement; payments since then come off the full-APR part first.',
                                to_char(pt.stmt, 'Mon FMDD, YYYY')), '')
           end
      from ref.debts d
      left join calc.account_balances ab on ab.account_key = d.account_key
      left join ref.accounts a
        on a.account_key = d.account_key and a.valid_from <= v_today and (a.valid_to is null or a.valid_to > v_today)
      cross join lateral (
        select exists (select 1 from ref.debt_buckets b
                        where b.debt_key = d.debt_key
                          and b.valid_from <= v_today and (b.valid_to is null or b.valid_to > v_today)) as has_buckets
      ) hb
      left join lateral (
        select sum(p.monthly_interest) as interest,
               sum(p.amount) filter (where p.kind in ('deferred_interest', 'zero_apr')) as promo,
               sum(p.amount) filter (where p.kind = 'reduced_apr') as reduced,
               sum(p.amount) filter (where p.kind = 'full_apr') as full_apr,
               sum(p.deferred_interest) filter (where p.kind = 'deferred_interest') as di,
               min(p.ends_on) filter (where p.kind in ('deferred_interest', 'zero_apr')) as next_end,
               max(p.as_of) as stmt,
               jsonb_agg(to_jsonb(p) order by p.part_order) as parts,
               string_agg(p.label, ' ' order by p.part_order) as labels
          from calc._debt_parts(d.debt_key, abs(ab.balance), d.apr, v_today) p
      ) pt on true
     where d.valid_from <= v_today and (d.valid_to is null or d.valid_to > v_today);
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('debts', v_n);

    v_step := 'briefing';
    if v_fail = v_step then raise exception 'test failure in %', v_step; end if;
    perform calc._build_briefing(v_today, p_pull_run_id);
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is null then
    update calc.refresh_runs set finished_at = clock_timestamp(), ok = true, counts = v_counts where id = v_run_id;
    update raw.pull_runs set counts = counts || jsonb_build_object('calc', v_counts) where id = p_pull_run_id;
    return jsonb_build_object('ok', true, 'today', v_today, 'counts', v_counts);
  end if;

  -- Failed: the steps were rolled back. Say so everywhere someone will look.
  update calc.refresh_runs set finished_at = clock_timestamp(), ok = false, error = v_step || ': ' || v_error where id = v_run_id;
  update raw.pull_runs set error = concat_ws(' | ', error, 'calc refresh failed in ' || v_step || ': ' || v_error)
   where id = p_pull_run_id;

  v_item := jsonb_build_object('level', 'YELLOW', 'kind', 'refresh_failed',
    'text', 'Today''s refresh failed in ' || replace(v_step, '_', ' ') || ', so these numbers are from '
            || coalesce((select to_char(generated_at at time zone 'America/New_York', 'Dy Mon FMDD at FMHH12:MI am') from calc.briefing), 'no earlier refresh')
            || ', not today.',
    'data', jsonb_build_object('step', v_step, 'error', v_error, 'refresh_run_id', v_run_id));

  if exists (select 1 from calc.briefing) then
    update calc.briefing b
       set level = case when b.level = 'RED' then 'RED' else 'YELLOW' end,
           items = (select coalesce(jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n), '[]'::jsonb)
                      from jsonb_array_elements(jsonb_build_array(v_item) || (
                             select coalesce(jsonb_agg(old order by o), '[]'::jsonb)
                               from jsonb_array_elements(b.items) with ordinality as y(old, o)
                              where old ->> 'kind' <> 'refresh_failed')) with ordinality as x(e, n));
  else
    insert into calc.briefing (generated_at, today, numbers_as_of, level, items)
    values (now(), v_today, null, 'YELLOW', jsonb_build_array(v_item));
  end if;

  return jsonb_build_object('ok', false, 'today', v_today, 'step', v_step, 'error', v_error);
end
$$;

-- ---------------------------------------------------------------- calc.debt_payoff_plan

create or replace function calc.debt_payoff_plan(p_today date default null, p_extra numeric default null)
returns table (plan_order int, debt_key text, name text, balance numeric, balance_as_of timestamptz,
               stale boolean, apr numeric, minimum_payment numeric, est_monthly_interest numeric,
               promo_end_on date, payoff_priority smallint, in_plan boolean, is_target boolean,
               payoff_month date, months_to_payoff int, total_interest numeric, promo_at_risk boolean,
               monthly_amount numeric, extra numeric, notes text[])
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_today  date := coalesce(p_today, (now() at time zone 'America/New_York')::date);
  v_extra  numeric;
  -- Active promos, as given: debt key, end date, amount, back interest built up.
  v_akey   text[];
  v_aend   date[];
  v_aamt   numeric[];
  v_adi    numeric[];
  -- One entry per debt that gets money, in plan order.
  v_keys   text[];
  v_bal    numeric[];
  v_apr    numeric[];
  v_min    numeric[];
  v_int    numeric[];
  v_done   date[];
  v_months int[];
  -- Reduced-APR part of each of those debts and its rate.
  v_rpart  numeric[];
  v_rapr   numeric[];
  -- One entry per promo part on those debts, soonest end first.
  v_pdebt  int[];
  v_pend   date[];
  v_pleft  numeric[];
  v_pdi    numeric[];
  v_pmiss  boolean[];
  v_np     int;
  v_n      int;
  v_budget numeric;
  v_pool   numeric;
  v_pay    numeric;
  v_part   numeric;
  v_month  date;
  v_left   int;
  -- Pauses: whole months when a debt's payment bill has no version in effect, between an
  -- earlier version and a later one (a gap in its history).
  v_gdebt  text[];
  v_gfrom  date[];
  v_gto    date[];
  v_skip   boolean[];
  v_pmon   text[];
begin
  if p_extra is not null and p_extra < 0 then
    raise exception 'The extra a month can''t be negative.' using errcode = 'P0001';
  end if;
  v_extra := coalesce(p_extra,
                      (select l.amount from ref.current_budget_lines l where l.line_key = 'extra-debt'),
                      0);

  -- Active promos: promo parts in ref.debt_buckets, else (for a debt with no parts at all) the
  -- debt's own promo_end_on for the whole balance.
  select array_agg(x.debt_key), array_agg(x.ends_on), array_agg(x.amount), array_agg(x.di)
    into v_akey, v_aend, v_aamt, v_adi
    from (
      select b.debt_key, b.ends_on, b.amount, coalesce(b.deferred_interest, 0) as di
        from ref.debt_buckets b
       where b.kind in ('deferred_interest', 'zero_apr') and b.ends_on >= v_today
         and b.valid_from <= v_today and (b.valid_to is null or b.valid_to > v_today)
      union all
      select s.debt_key, s.promo_end_on, s.balance, 0 from calc.debt_snapshot s
       where s.promo_end_on >= v_today and s.balance > 0
         and not exists (select 1 from ref.debt_buckets b
                          where b.debt_key = s.debt_key
                            and b.valid_from <= v_today and (b.valid_to is null or b.valid_to > v_today))
    ) x;

  -- The debts that get money, in plan order: soonest active promo first, then highest APR;
  -- ties to the smaller balance, then the key.
  with d as (
    select s.debt_key, s.balance, s.apr,
           greatest(s.minimum_payment, coalesce(bm.monthly_amount, 0)) as minimum_payment,
           (select min(a.e) from unnest(v_akey, v_aend) a(k, e) where a.k = s.debt_key) as first_end,
           r.amt as r_amt, r.apr as r_apr
      from calc.debt_snapshot s
      join ref.current_debts rd on rd.debt_key = s.debt_key
      left join calc._payment_bill(rd.payment_bill_key) bm on true
      left join lateral (
        select sum(b.amount) as amt, sum(b.amount * b.apr) / sum(b.amount) as apr
          from ref.debt_buckets b
         where b.debt_key = s.debt_key and b.kind = 'reduced_apr'
           and b.valid_from <= v_today and (b.valid_to is null or b.valid_to > v_today)
      ) r on true
     where rd.in_payoff_plan and s.balance > 0
  )
  select array_agg(d.debt_key order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.balance order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.apr order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.minimum_payment order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(coalesce(d.r_amt, 0) order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(coalesce(d.r_apr, 0) order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key)
    into v_keys, v_bal, v_apr, v_min, v_rpart, v_rapr
    from d;

  v_n := coalesce(array_length(v_keys, 1), 0);
  v_int := array_fill(0::numeric, array[greatest(v_n, 1)]);
  v_done := array_fill(null::date, array[greatest(v_n, 1)]);
  v_months := array_fill(null::int, array[greatest(v_n, 1)]);
  v_skip := array_fill(false, array[greatest(v_n, 1)]);
  v_pmon := array_fill(null::text, array[greatest(v_n, 1)]);

  -- Gaps in each planned debt's payment bill: from a version's valid_to to the next version's
  -- valid_from, when that comes later (the truck's paused payments, Nov 2026 to Jan 2027).
  select array_agg(g.debt_key), array_agg(g.gap_from), array_agg(g.gap_to)
    into v_gdebt, v_gfrom, v_gto
    from (
      select rd.debt_key, b.valid_to as gap_from,
             (select min(b2.valid_from) from ref.bills b2
               where b2.bill_key = b.bill_key and b2.valid_from >= b.valid_to) as gap_to
        from ref.current_debts rd
        join ref.bills b on b.bill_key = rd.payment_bill_key and b.valid_to is not null
       where rd.debt_key = any(coalesce(v_keys, '{}'))
         and not exists (select 1 from ref.bills b3
                          where b3.bill_key = b.bill_key and b3.id <> b.id
                            and b3.valid_from <= b.valid_to and (b3.valid_to is null or b3.valid_to > b.valid_to))
    ) g
   where g.gap_to > g.gap_from;

  -- Promo parts on those debts, capped so they never add up to more than the balance.
  select array_agg(x.idx order by x.e, x.idx), array_agg(x.e order by x.e, x.idx),
         array_agg(x.part order by x.e, x.idx), array_agg(x.di order by x.e, x.idx)
    into v_pdebt, v_pend, v_pleft, v_pdi
    from (
      select k.idx::int as idx, a.e, a.di,
             greatest(least(a.amt, v_bal[k.idx] - coalesce(sum(a.amt) over (partition by k.idx order by a.e, a.amt
                                                    rows between unbounded preceding and 1 preceding), 0)), 0) as part
        from unnest(v_akey, v_aend, v_aamt, v_adi) a(k, e, amt, di)
        join unnest(coalesce(v_keys, '{}')) with ordinality as k(key, idx) on k.key = a.k
    ) x where x.part > 0;
  v_np := coalesce(array_length(v_pdebt, 1), 0);
  v_pmiss := array_fill(false, array[greatest(v_np, 1)]);
  -- A reduced-APR part never counts for more than what the promos leave.
  for j in 1 .. v_n loop
    v_part := 0;
    for q in 1 .. v_np loop
      if v_pdebt[q] = j then v_part := v_part + v_pleft[q]; end if;
    end loop;
    v_rpart[j] := least(v_rpart[j], greatest(v_bal[j] - v_part, 0));
  end loop;
  -- A promo ending this month: this month's payments are already planned, so whatever is
  -- still on it counts as at risk, and its back interest is added.
  for q in 1 .. v_np loop
    if date_trunc('month', v_pend[q]) = date_trunc('month', v_today) then
      v_pmiss[q] := true;
      v_bal[v_pdebt[q]] := v_bal[v_pdebt[q]] + v_pdi[q];
      v_int[v_pdebt[q]] := v_int[v_pdebt[q]] + v_pdi[q];
    end if;
  end loop;

  v_budget := v_extra;
  for j in 1 .. v_n loop
    v_budget := v_budget + v_min[j];
  end loop;

  v_left := v_n;
  for i in 1 .. 600 loop
    exit when v_left = 0;
    v_month := (date_trunc('month', v_today) + make_interval(months => i))::date;

    -- 1. Interest: none on a running promo, the plan's rate on a reduced-APR part, the APR on
    --    the rest.
    for j in 1 .. v_n loop
      if v_done[j] is null then
        v_part := 0;
        for q in 1 .. v_np loop
          if v_pdebt[q] = j and v_month <= date_trunc('month', v_pend[q]) then
            v_part := v_part + v_pleft[q];
          end if;
        end loop;
        v_pay := round(v_rpart[j] * v_rapr[j] / 1200
                       + greatest(v_bal[j] - v_part - v_rpart[j], 0) * v_apr[j] / 1200, 2);
        v_bal[j] := v_bal[j] + v_pay;
        v_int[j] := v_int[j] + v_pay;
      end if;
    end loop;

    -- 2. Minimums (or the scheduled payment), then 3. the rest in plan order. Each payment comes
    --    off the debt's soonest-ending promo part first, then the full-APR part, then a
    --    reduced-APR part.
    -- A debt whose payment bill is paused for this whole month gets nothing, and its planned
    -- payment isn't spent on the other debts either: the household keeps it that month.
    v_pool := v_budget;
    for j in 1 .. v_n loop
      v_skip[j] := false;
      if v_done[j] is null then
        for g in 1 .. coalesce(array_length(v_gdebt, 1), 0) loop
          if v_gdebt[g] = v_keys[j] and v_month >= v_gfrom[g] and calc._month_end(v_month) < v_gto[g] then
            v_skip[j] := true;
          end if;
        end loop;
        if v_skip[j] then
          v_pool := v_pool - v_min[j];
          v_pmon[j] := concat_ws(', ', v_pmon[j], to_char(v_month, 'Mon YYYY'));
        end if;
      end if;
    end loop;
    v_pool := greatest(v_pool, 0);
    for pass in 1 .. 2 loop
      for j in 1 .. v_n loop
        if v_done[j] is null and not v_skip[j] and v_pool > 0 then
          v_pay := least(case when pass = 1 then v_min[j] else v_pool end, v_bal[j], v_pool);
          v_bal[j] := v_bal[j] - v_pay;
          v_pool := v_pool - v_pay;
          for q in 1 .. v_np loop
            if v_pdebt[q] = j and v_pay > 0 and v_pleft[q] > 0 then
              v_part := least(v_pay, v_pleft[q]);
              v_pleft[q] := v_pleft[q] - v_part;
              v_pay := v_pay - v_part;
            end if;
          end loop;
        end if;
      end loop;
    end loop;

    -- A promo part still owed at the end of its month misses its deadline: its back interest
    -- is added (at least what the last statement showed), and from then on it is charged
    -- interest like the rest.
    for q in 1 .. v_np loop
      if v_month = date_trunc('month', v_pend[q]) and v_pleft[q] > 0 then
        v_pmiss[q] := true;
        v_pleft[q] := 0;
        v_bal[v_pdebt[q]] := v_bal[v_pdebt[q]] + v_pdi[q];
        v_int[v_pdebt[q]] := v_int[v_pdebt[q]] + v_pdi[q];
      end if;
    end loop;

    -- The reduced-APR part is paid last: it is never more than what the promos leave.
    for j in 1 .. v_n loop
      v_part := 0;
      for q in 1 .. v_np loop
        if v_pdebt[q] = j then v_part := v_part + v_pleft[q]; end if;
      end loop;
      v_rpart[j] := least(v_rpart[j], greatest(v_bal[j] - v_part, 0));
    end loop;

    for j in 1 .. v_n loop
      if v_done[j] is null and v_bal[j] <= 0 then
        v_done[j] := calc._month_end(v_month);
        v_months[j] := i;
        v_left := v_left - 1;
      end if;
    end loop;
  end loop;

  return query
    with sim as (
      select u.k, u.ord::int as ord, u.done, u.months, u.interest, u.paused
        from unnest(coalesce(v_keys, '{}'), v_done[1:v_n], v_months[1:v_n], v_int[1:v_n], v_pmon[1:v_n])
             with ordinality as u(k, done, months, interest, paused, ord)
    ), risk as (
      select v_keys[r.j] as k, bool_or(r.miss) as miss
        from unnest(coalesce(v_pdebt, '{}'), v_pmiss[1:v_np]) r(j, miss)
       group by r.j
    ), promos as (
      select a.k, min(a.e) as next_end,
             string_agg(format('$%s by %s', to_char(a.amt, 'FM999999990.00'), to_char(a.e, 'Mon FMDD, YYYY')), ', ' order by a.e) as txt
        from unnest(coalesce(v_akey, '{}'), v_aend, v_aamt) a(k, e, amt)
       group by a.k
    ), reduced as (
      select b.debt_key as k,
             string_agg(format('$%s at %s%%', to_char(b.amount, 'FM999999990.00'), to_char(b.apr, 'FM990.00')), ', ' order by b.id) as txt
        from ref.debt_buckets b
       where b.kind = 'reduced_apr'
         and b.valid_from <= v_today and (b.valid_to is null or b.valid_to > v_today)
       group by b.debt_key
    ), rows as (
      select s.*, d.in_payoff_plan, a.name as account_name, m.ord, m.done, m.months, m.interest, m.paused,
             rk.miss, pr.next_end, pr.txt, rp.txt as reduced_txt, bm.name as bill_name, bm.amount as bill_amount,
             bm.cadence as bill_cadence, bm.monthly_amount as bill_monthly
        from calc.debt_snapshot s
        join ref.current_debts d on d.debt_key = s.debt_key
        left join calc._payment_bill(d.payment_bill_key) bm on true
        left join ref.current_accounts a on a.account_key = s.account_key
        left join sim m on m.k = s.debt_key
        left join risk rk on rk.k = s.debt_key
        left join promos pr on pr.k = s.debt_key
        left join reduced rp on rp.k = s.debt_key
    )
    select r.ord, r.debt_key, coalesce(r.account_name, r.debt_key), r.balance, r.balance_as_of, r.stale,
           r.apr, r.minimum_payment, r.est_monthly_interest, r.next_end, r.payoff_priority,
           r.ord is not null, r.ord = 1,
           r.done, r.months, r.interest, r.miss,
           v_budget, v_extra,
           array_remove(array[
             case when not r.in_payoff_plan then 'Outside the payoff plan (strategy/debt-plan.md).' end,
             case when r.in_payoff_plan and r.balance is null then 'No balance on file, so it can''t be planned.' end,
             case when r.in_payoff_plan and r.balance <= 0 then 'Nothing owed.' end,
             case when r.ord is not null and r.txt is not null and r.reduced_txt is null
                  then 'On promo: ' || r.txt || '. The rest is at the full APR.' end,
             case when r.ord is not null and r.txt is not null and r.reduced_txt is not null
                  then 'On promo: ' || r.txt || '. On a reduced-APR plan: ' || r.reduced_txt || '. The rest is at the full APR.' end,
             case when r.ord is not null and r.txt is null and r.reduced_txt is not null
                  then 'On a reduced-APR plan: ' || r.reduced_txt || '. The rest is at the full APR.' end,
             case when r.ord is not null and r.bill_monthly > r.minimum_payment
                  then format('Planned at $%s a month from the bill "%s" ($%s %s), not the $%s minimum.',
                              to_char(r.bill_monthly, 'FM999999990.00'), r.bill_name,
                              to_char(r.bill_amount, 'FM999999990.00'),
                              case r.bill_cadence when 'per_paycheck' then 'each paycheck' else r.bill_cadence end,
                              to_char(r.minimum_payment, 'FM999999990.00')) end,
             case when r.ord is not null and r.paused is not null
                  then format('Payments paused: nothing planned for %s (the bill "%s" has no version then). Interest still builds.',
                              r.paused, r.bill_name) end,
             case when r.ord is not null and r.miss
                  then 'A promo misses its deadline at this pace, so its back interest is added (at least what the last statement showed).' end,
             case when r.stale and r.balance is not null then 'The balance is older than 3 days.' end,
             case when r.ord is not null and r.minimum_payment = 0
                  then 'The minimum on file is $0, so it only shrinks once the extra reaches it.' end,
             case when r.ord is not null and r.done is null then 'Not paid off within 50 years at this pace.' end,
             case when r.payoff_priority is not null and r.ord is not null and r.payoff_priority <> r.ord
                  then format('payoff_priority on file is %s; the written plan puts it at %s.', r.payoff_priority, r.ord) end
           ], null)
      from rows r
     order by r.ord nulls last, r.debt_key;
end
$$;
comment on function calc.debt_payoff_plan(date, numeric) is 'The debt plan as it stands: plan order (active promos first, soonest end first, then highest APR), payoff month and interest for each debt, with minimums (or the scheduled bill named by ref.debts.payment_bill_key, when larger, from its newest version; nothing in a month that bill is paused for) plus the extra debt line rolling forward. Promo and reduced-APR parts come from ref.debt_buckets. promo_end_on here is the next active promo end. p_extra overrides the extra a month.';

-- ---------------------------------------------------------------- briefing

alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_debt_parts;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_new  jsonb := '[]'::jsonb;
  v_with text[];
begin
  perform calc._build_briefing_before_debt_parts(p_today, p_pull_run_id);

  -- Debts with parts: their promo_ending items are rebuilt from the parts.
  select coalesce(array_agg(s.debt_key), '{}') into v_with
    from calc.debt_snapshot s where s.parts_text is not null;
  if cardinality(v_with) = 0 then
    return;
  end if;

  -- One promo_ending item per promo ending within 30 days, with its amount and back interest.
  select coalesce(jsonb_agg(jsonb_build_object('level', 'YELLOW', 'kind', 'promo_ending',
           'text', case p.kind
             when 'deferred_interest' then format(
               '%s of %s is on a deferred-interest promo that ends %s, in %s days. Paid in full by then, it costs no interest; if not, back interest is added (%s built up as of the %s statement, and growing).',
               calc._money(p.amount), coalesce(a.name, p.debt_key), calc._day_text(p.ends_on), p.days_left,
               calc._money(coalesce(p.deferred_interest, 0)), to_char(p.as_of, 'Mon FMDD'))
             else format('%s of %s is at 0%% until %s, in %s days, then %s%%.',
               calc._money(p.amount), coalesce(a.name, p.debt_key), calc._day_text(p.ends_on), p.days_left,
               to_char(p.apr, 'FM990.00'))
           end,
           'data', jsonb_build_object('debt_key', p.debt_key, 'promo_end_on', p.ends_on, 'days_left', p.days_left,
                                      'kind', p.kind, 'amount', p.amount, 'apr', p.apr,
                                      'deferred_interest', p.deferred_interest, 'as_of', p.as_of))
           order by p.ends_on, p.debt_key), '[]'::jsonb)
    into v_new
    from calc.debt_parts p
    left join ref.accounts a
      on a.account_key = p.account_key and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
   where p.debt_key = any(v_with)
     and p.kind in ('deferred_interest', 'zero_apr')
     and p.days_left between 0 and 30;

  -- The split, already worked out, for a chat to quote when asked (GREEN).
  select v_new || coalesce(jsonb_agg(jsonb_build_object('level', 'GREEN', 'kind', 'debt_parts',
           'text', s.parts_text,
           'data', jsonb_build_object('debt_key', s.debt_key, 'balance', s.balance, 'balance_as_of', s.balance_as_of,
                                      'promo_balance', s.promo_balance, 'reduced_apr_balance', s.reduced_apr_balance,
                                      'full_apr_balance', s.full_apr_balance,
                                      'deferred_interest_at_risk', s.deferred_interest_at_risk,
                                      'est_monthly_interest', s.est_monthly_interest, 'parts', s.parts))
           order by s.debt_key), '[]'::jsonb)
    into v_new
    from calc.debt_snapshot s where s.debt_key = any(v_with);

  -- Keep the order: RED, then YELLOW, then GREEN.
  update calc.briefing b
     set items = (select coalesce(jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n), '[]'::jsonb)
                    from jsonb_array_elements(
                           (select coalesce(jsonb_agg(old order by o), '[]'::jsonb)
                              from jsonb_array_elements(b.items) with ordinality as y(old, o)
                             where not (old ->> 'kind' = 'promo_ending' and old -> 'data' ->> 'debt_key' = any(v_with)))
                           || v_new) with ordinality as x(e, n)),
         level = case when b.level = 'GREEN' and v_new @> '[{"level": "YELLOW"}]' then 'YELLOW' else b.level end;
end
$$;
