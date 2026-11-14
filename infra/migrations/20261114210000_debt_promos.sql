-- Fix to calc.debt_payoff_plan (James, 2026-11-14): a card can carry several promo balances,
-- each a part of its balance with its own end date (CareCredit: one promo due Dec 18, another
-- due Jan 18, the rest at the regular APR). A promo that has ended no longer keeps a debt at
-- the front of the plan.
--
--   ref.debt_promos         one row per promo: the debt, how much is on it, when it ends.
--                           Versioned like the other ref tables.
--   calc.debt_payoff_plan   a promo counts while ends_on is today or later. A debt with active
--                           promos goes first, soonest end first. During a promo its part is
--                           charged no interest; the rest of the balance is. Payments come off
--                           the soonest-ending promo first (assumption: it plans to clear each
--                           deadline in turn). promo_at_risk = some promo part is still owed at
--                           the end of its month. A debt with ref.debts.promo_end_on and no
--                           promo rows is treated as all on promo, as before.
--
-- The amounts are data and go in from the SQL-editor file, never from this migration.
-- No DROP statements: the function keeps its signature and is replaced.

create table ref.debt_promos (
  id          bigint generated always as identity primary key,
  debt_key    text not null,
  amount      numeric(12, 2) not null check (amount > 0),
  ends_on     date not null,
  note        text,
  valid_from  date not null default current_date,
  valid_to    date,
  created_at  timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on table ref.debt_promos is 'Promo balances on a debt: how much of the balance is on each promo and when it ends. The rest of the balance is at the debt''s APR.';
create trigger debt_promos_debt before insert or update of debt_key on ref.debt_promos
  for each row execute function ref.require_key('debt_key', 'ref.debts', 'debt_key', 'current');

create view ref.current_debt_promos with (security_invoker = true) as
  select * from ref.debt_promos
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

revoke all on ref.debt_promos, ref.current_debt_promos from anon, authenticated, public;
grant select on ref.debt_promos, ref.current_debt_promos to assistant_read;
alter table ref.debt_promos enable row level security;
create policy assistant_reads on ref.debt_promos for select to assistant_read using (true);

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
    select s.debt_key, s.balance, s.apr, s.minimum_payment,
           (select min(a.e) from unnest(v_akey, v_aend) a(k, e) where a.k = s.debt_key) as first_end
      from calc.debt_snapshot s
      join ref.current_debts rd on rd.debt_key = s.debt_key
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

    -- 2. Minimums, then 3. the rest in plan order. Each payment comes off the debt's
    --    soonest-ending promo part first.
    v_pool := v_budget;
    for pass in 1 .. 2 loop
      for j in 1 .. v_n loop
        if v_done[j] is null and v_pool > 0 then
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
      select u.k, u.ord::int as ord, u.done, u.months, u.interest
        from unnest(coalesce(v_keys, '{}'), v_done[1:v_n], v_months[1:v_n], v_int[1:v_n])
             with ordinality as u(k, done, months, interest, ord)
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
      select s.*, d.in_payoff_plan, a.name as account_name, m.ord, m.done, m.months, m.interest,
             rk.miss, pr.next_end, pr.txt
        from calc.debt_snapshot s
        join ref.current_debts d on d.debt_key = s.debt_key
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
comment on function calc.debt_payoff_plan(date, numeric) is 'The debt plan as it stands: plan order (active promos first, soonest end first, then highest APR), payoff month and interest for each debt, with minimums plus the extra debt line rolling forward. promo_end_on here is the next active promo end. p_extra overrides the extra a month.';
