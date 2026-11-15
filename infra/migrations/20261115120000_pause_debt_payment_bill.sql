-- Pause the truck payments through December (James, 2026-11-15): skip the $500 per-paycheck
-- truck payment on the Nov 20, Dec 4, Dec 18 and Dec 31 Lincoln checks and pick it back up
-- with the first January check, to leave room for Christmas, Katelyn's birthday and some
-- breathing room. Capital One shows the next payment due Jan 16, 2027, so the loan is paid ahead.
--
-- The pause itself is data: the "auto-loan" bill's version closes on 2026-11-20 and a new
-- version starts 2027-01-01. A gap between versions already means "no payments" to the bill
-- schedule and the cash projection. This migration teaches the debt payoff plan the same thing:
--
--   calc._payment_bill    the newest (open) version of a debt's payment bill, as a monthly figure.
--                         The plan used calc.bill_monthly, which only shows bills in effect today,
--                         so during a pause it would fall back to the loan's required minimum.
--   calc.debt_payoff_plan a month the payment bill has no version for at all (a gap between an
--                         earlier and a later version) gets no payment on that debt, and that
--                         money isn't spent on other debts either. Interest still builds. A note
--                         names the paused months. A part-month gap counts as a normal month.
--
-- No DROP statements: the function keeps its signature and is replaced.

create or replace function calc._payment_bill(p_bill_key text)
returns table (bill_key text, name text, amount numeric, cadence text, monthly_amount numeric)
language sql stable security definer set search_path = ''
as $$
  select b.bill_key, b.name, b.amount, b.cadence,
         round(b.amount * calc._per_month(coalesce(i.cadence, b.cadence), b.every_weeks), 2)
    from ref.bills b
    left join ref.income_sources i
      on b.cadence = 'per_paycheck' and i.income_key = b.income_key and i.valid_to is null
   where b.bill_key = p_bill_key and b.valid_to is null
$$;
comment on function calc._payment_bill(text) is
  'The newest (open) version of a bill as a monthly figure, even if it starts later (a paused bill). Used by calc.debt_payoff_plan.';
grant execute on function calc._payment_bill(text) to assistant_read;

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
  -- Active promos, as given: debt key, end date, amount.
  v_akey   text[];
  v_aend   date[];
  v_aamt   numeric[];
  -- One entry per debt that gets money, in plan order.
  v_keys   text[];
  v_bal    numeric[];
  v_apr    numeric[];
  v_min    numeric[];
  v_int    numeric[];
  v_done   date[];
  v_months int[];
  -- One entry per promo part on those debts, soonest end first.
  v_pdebt  int[];
  v_pend   date[];
  v_pleft  numeric[];
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

  -- Active promos: promo rows, else the debt's own promo_end_on for the whole balance.
  select array_agg(x.debt_key), array_agg(x.ends_on), array_agg(x.amount)
    into v_akey, v_aend, v_aamt
    from (
      select p.debt_key, p.ends_on, p.amount from ref.current_debt_promos p where p.ends_on >= v_today
      union all
      select s.debt_key, s.promo_end_on, s.balance from calc.debt_snapshot s
       where s.promo_end_on >= v_today and s.balance > 0
         and not exists (select 1 from ref.current_debt_promos p where p.debt_key = s.debt_key)
    ) x;

  -- The debts that get money, in plan order: soonest active promo first, then highest APR;
  -- ties to the smaller balance, then the key.
  with d as (
    select s.debt_key, s.balance, s.apr,
           greatest(s.minimum_payment, coalesce(bm.monthly_amount, 0)) as minimum_payment,
           (select min(a.e) from unnest(v_akey, v_aend) a(k, e) where a.k = s.debt_key) as first_end
      from calc.debt_snapshot s
      join ref.current_debts rd on rd.debt_key = s.debt_key
      left join calc._payment_bill(rd.payment_bill_key) bm on true
     where rd.in_payoff_plan and s.balance > 0
  )
  select array_agg(d.debt_key order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.balance order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.apr order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key),
         array_agg(d.minimum_payment order by d.first_end nulls last, d.apr desc, d.balance, d.debt_key)
    into v_keys, v_bal, v_apr, v_min
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
  select array_agg(x.idx order by x.e, x.idx), array_agg(x.e order by x.e, x.idx), array_agg(x.part order by x.e, x.idx)
    into v_pdebt, v_pend, v_pleft
    from (
      select k.idx::int as idx, a.e,
             greatest(least(a.amt, v_bal[k.idx] - coalesce(sum(a.amt) over (partition by k.idx order by a.e, a.amt
                                                    rows between unbounded preceding and 1 preceding), 0)), 0) as part
        from unnest(v_akey, v_aend, v_aamt) a(k, e, amt)
        join unnest(coalesce(v_keys, '{}')) with ordinality as k(key, idx) on k.key = a.k
    ) x where x.part > 0;
  v_np := coalesce(array_length(v_pdebt, 1), 0);
  v_pmiss := array_fill(false, array[greatest(v_np, 1)]);
  -- A promo ending this month: this month's payments are already planned, so whatever is
  -- still on it counts as at risk.
  for q in 1 .. v_np loop
    if date_trunc('month', v_pend[q]) = date_trunc('month', v_today) then
      v_pmiss[q] := true;
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

    -- 1. Interest on what isn't on a running promo.
    for j in 1 .. v_n loop
      if v_done[j] is null then
        v_part := 0;
        for q in 1 .. v_np loop
          if v_pdebt[q] = j and v_month <= date_trunc('month', v_pend[q]) then
            v_part := v_part + v_pleft[q];
          end if;
        end loop;
        v_pay := round(greatest(v_bal[j] - v_part, 0) * v_apr[j] / 1200, 2);
        v_bal[j] := v_bal[j] + v_pay;
        v_int[j] := v_int[j] + v_pay;
      end if;
    end loop;

    -- 2. Minimums (or the scheduled payment), then 3. the rest in plan order. Each payment comes off the debt's
    --    soonest-ending promo part first.
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

    -- A promo part still owed at the end of its month misses its deadline, and from then on
    -- it is charged interest like the rest.
    for q in 1 .. v_np loop
      if v_month = date_trunc('month', v_pend[q]) and v_pleft[q] > 0 then
        v_pmiss[q] := true;
        v_pleft[q] := 0;
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
    ), rows as (
      select s.*, d.in_payoff_plan, a.name as account_name, m.ord, m.done, m.months, m.interest, m.paused,
             rk.miss, pr.next_end, pr.txt, bm.name as bill_name, bm.amount as bill_amount,
             bm.cadence as bill_cadence, bm.monthly_amount as bill_monthly
        from calc.debt_snapshot s
        join ref.current_debts d on d.debt_key = s.debt_key
        left join calc._payment_bill(d.payment_bill_key) bm on true
        left join ref.current_accounts a on a.account_key = s.account_key
        left join sim m on m.k = s.debt_key
        left join risk rk on rk.k = s.debt_key
        left join promos pr on pr.k = s.debt_key
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
             case when r.ord is not null and r.txt is not null then 'On promo: ' || r.txt || '. The rest is at the full APR.' end,
             case when r.ord is not null and r.bill_monthly > r.minimum_payment
                  then format('Planned at $%s a month from the bill "%s" ($%s %s), not the $%s minimum.',
                              to_char(r.bill_monthly, 'FM999999990.00'), r.bill_name,
                              to_char(r.bill_amount, 'FM999999990.00'),
                              case r.bill_cadence when 'per_paycheck' then 'each paycheck' else r.bill_cadence end,
                              to_char(r.minimum_payment, 'FM999999990.00')) end,
             case when r.ord is not null and r.paused is not null
                  then format('Payments paused: nothing planned for %s (the bill "%s" has no version then). Interest still builds.',
                              r.paused, r.bill_name) end,
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
comment on function calc.debt_payoff_plan(date, numeric) is 'The debt plan as it stands: plan order (active promos first, soonest end first, then highest APR), payoff month and interest for each debt, with minimums (or the scheduled bill named by ref.debts.payment_bill_key, when larger, from its newest version; nothing in a month that bill is paused for) plus the extra debt line rolling forward. promo_end_on here is the next active promo end. p_extra overrides the extra a month.';
