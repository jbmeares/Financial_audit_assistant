-- Two read-only calculations for the live dashboard (plan task 3, 2026-11-14):
--
--   calc.paycheck_plan(today, days)   what each pay date funds: per-paycheck transfers,
--                                     per-paycheck bills and paycheck budget lines, and
--                                     what's left of the check after them.
--   calc.debt_payoff_plan(today, extra)
--                                     the debt plan as it stands (strategy/debt-plan.md):
--                                     promo balances first, soonest end first, then highest
--                                     APR. Minimums plus the extra debt line each month, each
--                                     paid-off payment rolling into the next target.
--
-- Both are STABLE functions, like calc.budget_status, so the query tool can read them
-- ("select * from calc.debt_payoff_plan()") and the tests can pin today.
--
-- Also ref.debts.in_payoff_plan, so a debt the written plan keeps outside the avalanche
-- (the loan from Katelyn's mom) is marked in data rather than guessed from its numbers.
--
-- No DROP statements (the Supabase confirm dialog for them doesn't open for James).

-- ---------------------------------------------------------------- ref.debts.in_payoff_plan

alter table ref.debts add column in_payoff_plan boolean not null default true;
comment on column ref.debts.in_payoff_plan is 'false for a debt the written plan keeps outside the avalanche (strategy/debt-plan.md). calc.debt_payoff_plan lists it but sends it no money.';

-- The view was made with select *, so it needs remaking to show the new column (added last).
create or replace view ref.current_debts with (security_invoker = true) as
  select * from ref.debts
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- strategy/debt-plan.md (James, 2026-11-11): the loan from Katelyn's mom sits outside the
-- avalanche. No row matches on a fresh test database.
update ref.debts set in_payoff_plan = false where debt_key = 'katelyn-mom-loan' and valid_to is null;

-- ---------------------------------------------------------------- paycheck plan

-- One row per pay date, from each income source's latest pay date on or before today
-- through today + p_days.
--   transfers   per-paycheck transfers on this income source's pay dates
--   bills       per-paycheck bills on this income source (from calc.bill_cycles, with status)
--   budget      paycheck budget lines that reset on this income source
-- left_over = the check, less transfers out of the deposit account, bills paid from the
-- deposit account, and the paycheck budget lines. A bill paid from another account (Bill Pay)
-- is listed but not subtracted, because a transfer already funds that account.
-- Pay dates come from the current income source, as in calc.budget_status. Transfers and
-- budget lines use the version in effect on the pay date, or today's for a pay date already
-- past, so the current paycheck shows today's plan.
create function calc.paycheck_plan(p_today date default null, p_days int default 45)
returns table (pay_on date, income_key text, income_name text, income_amount numeric,
               deposit_account_key text, is_current boolean, transfers_out numeric,
               bills_from_deposit numeric, budget_lines numeric, left_over numeric, items jsonb)
language sql stable security definer set search_path = ''
as $$
  with params as (
    select coalesce(p_today, (now() at time zone 'America/New_York')::date) as d,
           least(greatest(coalesce(p_days, 45), 0), 366) as days
  ), pays as (
    select i.income_key, i.name, i.amount, i.deposit_account_key, pd as pay_on,
           greatest(pd, p.d) as eff
      from params p, ref.current_income_sources i,
           calc._pay_dates(i.cadence, i.anchor_pay_date, p.d - 62, p.d + p.days) pd
  ), kept as (
    -- Drop pay dates before each source's latest one on or before today.
    select y.* from pays y, params p
     where y.pay_on >= coalesce((select max(z.pay_on) from pays z where z.income_key = y.income_key and z.pay_on <= p.d), y.pay_on)
  ), items as (
    select k.income_key, k.pay_on, 1 as grp, t.transfer_key as key,
           jsonb_build_object('kind', 'transfer', 'key', t.transfer_key, 'name', t.name, 'amount', t.amount,
                              'from_account_key', t.from_account_key, 'to_account_key', t.to_account_key,
                              'counts', t.from_account_key = k.deposit_account_key) as item,
           case when t.from_account_key = k.deposit_account_key then t.amount else 0 end as transfer_amt,
           0::numeric as bill_amt, 0::numeric as line_amt
      from kept k join ref.transfers t
        on t.cadence = 'per_paycheck' and t.income_key = k.income_key
       and t.valid_from <= k.eff and (t.valid_to is null or t.valid_to > k.eff)
    union all
    select k.income_key, k.pay_on, 2, c.bill_key,
           jsonb_build_object('kind', 'bill', 'key', c.bill_key, 'name', c.bill_name, 'amount', c.expected_amount,
                              'account_key', c.account_key, 'status', c.status,
                              'counts', c.account_key = k.deposit_account_key),
           0, case when c.account_key = k.deposit_account_key then c.expected_amount else 0 end, 0
      from kept k
      join calc.bill_cycles c on c.cadence = 'per_paycheck' and c.due_on = k.pay_on
      join ref.bills b on b.id = c.bill_version_id and b.income_key = k.income_key
    union all
    select k.income_key, k.pay_on, 3, l.line_key,
           jsonb_build_object('kind', 'budget_line', 'key', l.line_key, 'name', l.name, 'amount', l.amount,
                              'tracked', l.tracked, 'counts', true),
           0, 0, l.amount
      from kept k join ref.budget_lines l
        on l.period = 'paycheck' and l.income_key = k.income_key
       and l.valid_from <= k.eff and (l.valid_to is null or l.valid_to > k.eff)
  )
  select k.pay_on, k.income_key, k.name, k.amount, k.deposit_account_key,
         k.pay_on <= p.d,
         coalesce(sum(x.transfer_amt), 0), coalesce(sum(x.bill_amt), 0), coalesce(sum(x.line_amt), 0),
         k.amount - coalesce(sum(x.transfer_amt + x.bill_amt + x.line_amt), 0),
         coalesce(jsonb_agg(x.item order by x.grp, x.key) filter (where x.item is not null), '[]'::jsonb)
    from kept k cross join params p
    left join items x on x.income_key = k.income_key and x.pay_on = k.pay_on
   group by k.pay_on, k.income_key, k.name, k.amount, k.deposit_account_key, p.d
   order by k.pay_on, k.income_key
$$;
comment on function calc.paycheck_plan(date, int) is 'What each pay date funds (transfers, per-paycheck bills, paycheck budget lines) and what''s left of the check, from the current paycheck through today + p_days (default 45).';

-- ---------------------------------------------------------------- debt payoff plan

-- One row per current debt, in plan order, from calc.debt_snapshot (the last refresh).
-- Plan order (strategy/debt-plan.md): debts with a promo end date first, soonest first; then
-- highest APR; ties go to the smaller balance, then the key.
-- Each month from next month on (this month's payments are taken as already planned, as in
-- calc.what_if):
--   1. interest is added: balance x APR / 12, none while a promo runs (through the promo end
--      month);
--   2. every debt gets its minimum (or what's left of it);
--   3. the rest of the monthly amount goes to the first unpaid debt in plan order, then the
--      next. The monthly amount (all in-plan minimums plus the extra) never shrinks, so each
--      paid-off minimum rolls into the next target.
-- promo_at_risk: the payoff month ends after the promo end date. The steps are monthly, so a
-- payoff in the promo's last month counts as at risk unless that month ends first.
-- p_extra: the extra a month; null reads the 'extra-debt' budget line.
-- Left out of the money (listed, with a note): in_payoff_plan = false, no balance on file,
-- nothing owed. A payoff past 50 years is reported as null.
create function calc.debt_payoff_plan(p_today date default null, p_extra numeric default null)
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
  v_keys   text[];
  v_bal    numeric[];
  v_apr    numeric[];
  v_min    numeric[];
  v_promo  date[];
  v_int    numeric[];
  v_done   date[];
  v_months int[];
  v_n      int;
  v_budget numeric;
  v_pool   numeric;
  v_pay    numeric;
  v_month  date;
  v_left   int;
begin
  if p_extra is not null and p_extra < 0 then
    raise exception 'The extra a month can''t be negative.' using errcode = 'P0001';
  end if;
  v_extra := coalesce(p_extra,
                      (select l.amount from ref.current_budget_lines l where l.line_key = 'extra-debt'),
                      0);

  -- The debts that get money, in plan order.
  select array_agg(s.debt_key order by s.promo_end_on nulls last, s.apr desc, s.balance, s.debt_key),
         array_agg(s.balance order by s.promo_end_on nulls last, s.apr desc, s.balance, s.debt_key),
         array_agg(s.apr order by s.promo_end_on nulls last, s.apr desc, s.balance, s.debt_key),
         array_agg(s.minimum_payment order by s.promo_end_on nulls last, s.apr desc, s.balance, s.debt_key),
         array_agg(s.promo_end_on order by s.promo_end_on nulls last, s.apr desc, s.balance, s.debt_key)
    into v_keys, v_bal, v_apr, v_min, v_promo
    from calc.debt_snapshot s
    join ref.current_debts d on d.debt_key = s.debt_key
   where d.in_payoff_plan and s.balance > 0;

  v_n := coalesce(array_length(v_keys, 1), 0);
  v_int := array_fill(0::numeric, array[greatest(v_n, 1)]);
  v_done := array_fill(null::date, array[greatest(v_n, 1)]);
  v_months := array_fill(null::int, array[greatest(v_n, 1)]);
  v_budget := v_extra;
  for j in 1 .. v_n loop
    v_budget := v_budget + v_min[j];
  end loop;

  v_left := v_n;
  for i in 1 .. 600 loop
    exit when v_left = 0;
    v_month := (date_trunc('month', v_today) + make_interval(months => i))::date;
    for j in 1 .. v_n loop
      if v_done[j] is null and (v_promo[j] is null or v_month > date_trunc('month', v_promo[j])) then
        v_pay := round(v_bal[j] * v_apr[j] / 1200, 2);
        v_bal[j] := v_bal[j] + v_pay;
        v_int[j] := v_int[j] + v_pay;
      end if;
    end loop;
    v_pool := v_budget;
    for j in 1 .. v_n loop
      if v_done[j] is null then
        v_pay := least(v_min[j], v_bal[j], v_pool);
        v_bal[j] := v_bal[j] - v_pay;
        v_pool := v_pool - v_pay;
      end if;
    end loop;
    for j in 1 .. v_n loop
      if v_done[j] is null and v_pool > 0 then
        v_pay := least(v_pool, v_bal[j]);
        v_bal[j] := v_bal[j] - v_pay;
        v_pool := v_pool - v_pay;
      end if;
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
      select u.k, u.ord::int as ord, u.done, u.months, u.interest
        from unnest(coalesce(v_keys, '{}'), v_done[1:v_n], v_months[1:v_n], v_int[1:v_n])
             with ordinality as u(k, done, months, interest, ord)
    ), rows as (
      select s.*, d.in_payoff_plan, a.name as account_name, m.ord, m.done, m.months, m.interest
        from calc.debt_snapshot s
        join ref.current_debts d on d.debt_key = s.debt_key
        left join ref.current_accounts a on a.account_key = s.account_key
        left join sim m on m.k = s.debt_key
    )
    select r.ord, r.debt_key, coalesce(r.account_name, r.debt_key), r.balance, r.balance_as_of, r.stale,
           r.apr, r.minimum_payment, r.est_monthly_interest, r.promo_end_on, r.payoff_priority,
           r.ord is not null, r.ord = 1,
           r.done, r.months, r.interest,
           case when r.promo_end_on is not null and r.ord is not null
                then r.done is null or r.done > r.promo_end_on end,
           v_budget, v_extra,
           array_remove(array[
             case when not r.in_payoff_plan then 'Outside the payoff plan (strategy/debt-plan.md).' end,
             case when r.in_payoff_plan and r.balance is null then 'No balance on file, so it can''t be planned.' end,
             case when r.in_payoff_plan and r.balance <= 0 then 'Nothing owed.' end,
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
comment on function calc.debt_payoff_plan(date, numeric) is 'The debt plan as it stands: plan order (promo first, then highest APR), payoff month and interest for each debt, with minimums plus the extra debt line rolling forward. p_extra overrides the extra a month.';

revoke all on function calc.paycheck_plan(date, int), calc.debt_payoff_plan(date, numeric) from public;
grant execute on function calc.paycheck_plan(date, int), calc.debt_payoff_plan(date, numeric) to assistant_read;
