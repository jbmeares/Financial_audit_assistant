-- One payday plan, and low-balance warnings only where they matter (James, 2026-11-19).
--
-- 1. calc.payday_plan(today): on payday James sits down and pays every bill he can, not only
--    the ones due that day. The plan is one list for the paycheck's stretch (the pay date
--    through the day before the next income):
--      - incomes landing on the pay date and the transfers made that day;
--      - every unpaid bill from a checking or savings account due through the end of the
--        stretch, late ones first, then ones already past their due date, then by due date.
--        Each says autopay or manual and which account it comes from, with that account's
--        running balance if everything is paid on payday;
--      - the paycheck budget lines set aside from the deposit account (Food, Fuel);
--      - any other money moving later in the stretch;
--      - per account: the balance after the money comes in, and what's left at the end.
--    Paying early doesn't change the end-of-stretch balance, only when it's reached, so
--    "what's left" is also the stretch's low point.
--    The pay date is today when today is a pay date, otherwise the next one. Numbers come
--    from calc.cash_projection, calc.bill_cycles and calc.paycheck_plan as of the last
--    refresh, so p_today should be the refresh day (the briefing passes it).
--    A bill is called late only when its due month ended unpaid (rule 4); one past its due
--    date in the same month is "past its due date".
--
-- 2. The briefing gets a payday_plan item from two days before a pay date through the pay
--    date. While it's there, the due_before_income item is left out: its bills are in the
--    plan, so they live in one place.
--
-- 3. Overdraft warnings look only through the next two paychecks (today: through the day
--    before the third pay date after today). A dip that stays inside an account's overdraft
--    buffer is only mentioned when it happens before the next pay date after today.
--    Before this, the briefing scanned the whole 60-day projection, so a $14.82 charge on
--    Jan 17 showed up in November. RED rules are unchanged (RED only ever applied before the
--    next income). Far-off dips are still in calc.cash_projection for anyone who asks.
--
-- No DROP: the current builder keeps running under a new name, like the earlier wrappers.

-- ---------------------------------------------------------------- pay dates after a day

-- Distinct pay dates across current income sources, strictly after p_day, in order.
create function calc._pay_dates_after(p_day date, p_count int)
returns setof date
language sql stable set search_path = ''
as $$
  select distinct pd
    from ref.income_sources i,
         calc._pay_dates(i.cadence, i.anchor_pay_date, greatest(p_day + 1, i.valid_from),
                         least(p_day + 120, coalesce(i.valid_to - 1, p_day + 120))) pd
   where i.valid_from <= p_day + 120 and (i.valid_to is null or i.valid_to > p_day)
   order by pd
   limit greatest(p_count, 0)
$$;

-- Last day low-balance warnings look at: the day before the (p_paychecks + 1)th pay date
-- after p_today, so the stretches of the next p_paychecks paychecks are covered.
-- Without enough income on file, 30 days.
create function calc._warning_window_end(p_today date, p_paychecks int default 2)
returns date
language sql stable set search_path = ''
as $$
  select coalesce((select d - 1 from calc._pay_dates_after(p_today, p_paychecks + 1) d
                    order by d offset p_paychecks limit 1),
                  p_today + 30)
$$;

-- ---------------------------------------------------------------- the payday plan

create function calc.payday_plan(p_today date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_today    date := coalesce(p_today, (now() at time zone 'America/New_York')::date);
  v_pay      date;
  v_next     date;
  v_through  date;
  v_incomes  jsonb;
  v_xfers    jsonb;
  v_bills    jsonb := '[]'::jsonb;
  v_asides   jsonb := '[]'::jsonb;
  v_later    jsonb;
  v_accounts jsonb := '[]'::jsonb;
  v_bal      jsonb := '{}'::jsonb;   -- account_key -> running balance
  v_start    jsonb;
  r          record;
  b          numeric;
begin
  -- The pay date: today if today is one, else the next.
  select min(pd) into v_pay
    from ref.income_sources i,
         calc._pay_dates(i.cadence, i.anchor_pay_date, greatest(v_today, i.valid_from),
                         least(v_today + 62, coalesce(i.valid_to - 1, v_today + 62))) pd
   where i.valid_from <= v_today + 62 and (i.valid_to is null or i.valid_to > v_today);
  if v_pay is null then
    return null;
  end if;
  select d into v_next from calc._pay_dates_after(v_pay, 1) d;
  v_through := coalesce(v_next - 1, v_pay + 13);

  -- Incomes landing on the pay date. in_balance: the projection treats it as already in the
  -- account's balance (the balance is from the pay date itself), so it isn't added again.
  select jsonb_agg(jsonb_build_object(
           'income_key', i.income_key, 'name', i.name, 'amount', i.amount,
           'account_key', i.deposit_account_key, 'account_name', ab.name,
           'in_balance', not exists (select 1 from calc.cash_projection p, jsonb_array_elements(p.detail) e
                                      where p.account_key = i.deposit_account_key and p.day = v_pay
                                        and e ->> 'kind' = 'income' and e ->> 'key' = i.income_key))
         order by i.income_key)
    into v_incomes
    from ref.income_sources i
    left join calc.account_balances ab on ab.account_key = i.deposit_account_key
   where i.valid_from <= v_pay and (i.valid_to is null or i.valid_to > v_pay)
     and exists (select 1 from calc._pay_dates(i.cadence, i.anchor_pay_date, v_pay, v_pay));

  -- Starting balances: today's balance plus everything that isn't a bill through the pay
  -- date (income, transfers in, transfers out). Accounts the projection covers only.
  for r in
    select p.account_key, ab.name,
           (array_agg(p.opening order by p.day))[1]
             + coalesce(sum((select coalesce(sum(case when e ->> 'direction' = 'in' then 1 else -1 end * (e ->> 'amount')::numeric), 0)
                               from jsonb_array_elements(p.detail) e where e ->> 'kind' <> 'bill')), 0) as start,
           coalesce(a.overdraft_buffer, 0) as buffer
      from calc.cash_projection p
      join calc.account_balances ab on ab.account_key = p.account_key
      left join ref.accounts a on a.account_key = p.account_key
       and a.valid_from <= v_today and (a.valid_to is null or a.valid_to > v_today)
     where p.day between v_today and v_pay
     group by p.account_key, ab.name, a.overdraft_buffer
  loop
    v_bal := v_bal || jsonb_build_object(r.account_key, r.start);
    v_accounts := v_accounts || jsonb_build_array(jsonb_build_object(
      'account_key', r.account_key, 'name', r.name, 'start', r.start, 'overdraft_buffer', r.buffer));
  end loop;

  -- Transfers made on the pay date.
  select jsonb_agg(jsonb_build_object('key', e ->> 'key', 'name', e ->> 'name', 'amount', (e ->> 'amount')::numeric,
                                      'to_account_key', p.account_key, 'to_account_name', ab.name,
                                      'from_account_key', t.from_account_key,
                                      'from_account_name', (select ab2.name from calc.account_balances ab2 where ab2.account_key = t.from_account_key))
                   order by e ->> 'key')
    into v_xfers
    from calc.cash_projection p
    join calc.account_balances ab on ab.account_key = p.account_key,
         jsonb_array_elements(p.detail) e
    left join lateral (select t.from_account_key from ref.transfers t
                        where t.transfer_key = e ->> 'key' order by t.valid_from desc limit 1) t on true
   where p.day = v_pay and e ->> 'kind' = 'transfer' and e ->> 'direction' = 'in';

  -- Every unpaid bill paid from a checking or savings account, due through the stretch's
  -- end: late ones, ones past their due date, and ones due by the end of the stretch.
  for r in
    select c.bill_key, c.bill_name, c.due_on, c.due_month, c.expected_amount as amount, c.amount_kind,
           c.account_key, ab.name as account_name, c.autopay, c.status = 'late' as late,
           c.status = 'not_seen_yet' and c.due_on < v_today as past_due_date
      from calc.bill_cycles c
      join calc.account_balances ab on ab.account_key = c.account_key
     where ab.kind in ('checking', 'savings')
       and c.expected_amount > 0
       and (c.status = 'late'
            or (c.status = 'not_seen_yet' and c.due_on <= v_through
                and (c.due_on >= v_today or c.due_month = date_trunc('month', v_today)::date)))
     order by (c.status = 'late') desc, (c.due_on < v_today) desc, c.due_on, c.autopay, c.bill_name
  loop
    b := coalesce((v_bal ->> r.account_key)::numeric, 0) - r.amount;
    v_bal := v_bal || jsonb_build_object(r.account_key, b);
    v_bills := v_bills || jsonb_build_array(jsonb_build_object(
      'bill_key', r.bill_key, 'name', r.bill_name, 'due_on', r.due_on, 'amount', r.amount,
      'amount_kind', r.amount_kind, 'account_key', r.account_key, 'account_name', r.account_name,
      'autopay', r.autopay, 'late', r.late, 'past_due_date', r.past_due_date,
      'balance_after', b));
  end loop;

  -- Paycheck budget lines, set aside from the deposit account.
  for r in
    select pp.deposit_account_key as account_key, (x ->> 'key') as line_key, (x ->> 'name') as name,
           (x ->> 'amount')::numeric as amount
      from calc.paycheck_plan(v_today, 62) pp, jsonb_array_elements(pp.items) x
     where pp.pay_on = v_pay and x ->> 'kind' = 'budget_line'
     order by pp.income_key, x ->> 'key'
  loop
    b := coalesce((v_bal ->> r.account_key)::numeric, 0) - r.amount;
    v_bal := v_bal || jsonb_build_object(r.account_key, b);
    v_asides := v_asides || jsonb_build_array(jsonb_build_object(
      'line_key', r.line_key, 'name', r.name, 'amount', r.amount, 'account_key', r.account_key,
      'account_name', (select ab.name from calc.account_balances ab where ab.account_key = r.account_key),
      'balance_after', b));
  end loop;

  -- Other money moving later in the stretch (not bills), in date order.
  select jsonb_agg(jsonb_build_object('on', p.day, 'kind', e ->> 'kind', 'key', e ->> 'key', 'name', e ->> 'name',
                                      'amount', (e ->> 'amount')::numeric, 'direction', e ->> 'direction',
                                      'account_key', p.account_key, 'account_name', ab.name)
                   order by p.day, p.account_key, e ->> 'key')
    into v_later
    from calc.cash_projection p
    join calc.account_balances ab on ab.account_key = p.account_key,
         jsonb_array_elements(p.detail) e
   where p.day > v_pay and p.day <= v_through and e ->> 'kind' <> 'bill';
  for r in select x ->> 'account_key' as k, case when x ->> 'direction' = 'in' then 1 else -1 end * (x ->> 'amount')::numeric as amt
             from jsonb_array_elements(coalesce(v_later, '[]'::jsonb)) x loop
    v_bal := v_bal || jsonb_build_object(r.k, coalesce((v_bal ->> r.k)::numeric, 0) + r.amt);
  end loop;

  -- Accounts: keep the ones with something happening, and say what's left.
  select coalesce(jsonb_agg(a || jsonb_build_object('left', (v_bal ->> (a ->> 'account_key'))::numeric)
                            order by a ->> 'name'), '[]'::jsonb)
    into v_accounts
    from jsonb_array_elements(v_accounts) a
   where exists (select 1 from jsonb_array_elements(v_bills) x where x ->> 'account_key' = a ->> 'account_key')
      or exists (select 1 from jsonb_array_elements(v_asides) x where x ->> 'account_key' = a ->> 'account_key')
      or exists (select 1 from jsonb_array_elements(coalesce(v_xfers, '[]')) x
                  where a ->> 'account_key' in (x ->> 'to_account_key', x ->> 'from_account_key'))
      or exists (select 1 from jsonb_array_elements(coalesce(v_incomes, '[]')) x where x ->> 'account_key' = a ->> 'account_key');

  return jsonb_build_object(
    'pay_on', v_pay, 'through', v_through, 'next_income_on', v_next,
    'incomes', coalesce(v_incomes, '[]'::jsonb),
    'transfers', coalesce(v_xfers, '[]'::jsonb),
    'bills', v_bills,
    'set_asides', v_asides,
    'later', coalesce(v_later, '[]'::jsonb),
    'accounts', v_accounts,
    'totals', jsonb_build_object(
      'bills', (select coalesce(sum((x ->> 'amount')::numeric), 0) from jsonb_array_elements(v_bills) x),
      'manual', (select coalesce(sum((x ->> 'amount')::numeric), 0) from jsonb_array_elements(v_bills) x where not (x ->> 'autopay')::boolean),
      'autopay', (select coalesce(sum((x ->> 'amount')::numeric), 0) from jsonb_array_elements(v_bills) x where (x ->> 'autopay')::boolean),
      'manual_count', (select count(*) from jsonb_array_elements(v_bills) x where not (x ->> 'autopay')::boolean),
      'bill_count', jsonb_array_length(v_bills)));
end
$$;
comment on function calc.payday_plan(date) is 'One plan for a paycheck: incomes and transfers on the pay date, every unpaid bill due through the day before the next income (late and past-due first) with the paying account''s running balance if all are paid on payday, paycheck budget set-asides, and what''s left per account.';

revoke all on function calc.payday_plan(date) from public;
grant execute on function calc.payday_plan(date) to assistant_read;

-- ---------------------------------------------------------------- the briefing

alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_payday_plan;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_items       jsonb;
  v_plan        jsonb;
  v_window_end  date;
  v_next_after  date;
  v_new         jsonb := '[]'::jsonb;
  v_text        text;
  e             jsonb;
  n             bigint;
  v_key         text;
  v_buffer      numeric;
  v_first_zero  date;
  v_first_past  date;
  v_low         numeric;
  v_low_on      date;
  v_name        text;
begin
  perform calc._build_briefing_before_payday_plan(p_today, p_pull_run_id);
  select items into v_items from calc.briefing;
  if v_items is null then
    return;
  end if;

  v_window_end := calc._warning_window_end(p_today, 2);
  select d into v_next_after from calc._pay_dates_after(p_today, 1) d;

  -- The payday plan, from two days before a pay date through the pay date.
  v_plan := calc.payday_plan(p_today);
  if v_plan is not null and (v_plan ->> 'pay_on')::date - p_today > 2 then
    v_plan := null;
  end if;

  for e, n in select x, o from jsonb_array_elements(v_items) with ordinality as t(x, o) loop
    if e ->> 'kind' = 'due_before_income' and v_plan is not null then
      continue;   -- its bills are in the payday plan
    end if;

    if e ->> 'kind' = 'overdraft' and e ->> 'level' <> 'RED' then
      v_key := e -> 'data' ->> 'account_key';
      select a.overdraft_buffer into v_buffer from ref.accounts a
       where a.account_key = v_key and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
       order by a.valid_from desc limit 1;
      v_buffer := coalesce(v_buffer, 0);
      select min(p.day) filter (where p.closing < 0), min(p.day) filter (where p.closing < -v_buffer)
        into v_first_zero, v_first_past
        from calc.cash_projection p where p.account_key = v_key and p.day <= v_window_end;

      if v_first_past is not null then
        null;   -- passes the buffer (or $0) inside the window: keep as built
      elsif v_buffer > 0 and v_first_zero is not null and v_next_after is not null and v_first_zero < v_next_after then
        -- Inside the buffer before the next pay date: say so, with the low point in that stretch.
        select p.closing, p.day into v_low, v_low_on from calc.cash_projection p
         where p.account_key = v_key and p.day < v_next_after order by p.closing, p.day limit 1;
        select ab.name into v_name from calc.account_balances ab where ab.account_key = v_key;
        v_text := v_name || ' dips below $0 on ' || calc._day_text(v_first_zero)
                  || ', before the next income on ' || calc._day_text(v_next_after)
                  || '. Lowest: ' || calc._money(v_low) || ' on ' || calc._day_text(v_low_on)
                  || '. That stays within its ' || calc._money(v_buffer) || ' overdraft buffer, so no fee is expected.';
        e := jsonb_build_object('level', 'YELLOW', 'kind', 'overdraft', 'text', v_text,
               'data', jsonb_build_object('account_key', v_key, 'first_below_zero_on', v_first_zero,
                                          'lowest', v_low, 'lowest_on', v_low_on, 'overdraft_buffer', v_buffer,
                                          'first_below_buffer_on', null, 'window_end', v_window_end));
      else
        continue;   -- only beyond the window, or a small dip inside the buffer later on
      end if;
    end if;

    v_new := v_new || jsonb_build_array(jsonb_build_object('e', e, 'n', n));
  end loop;

  if v_plan is not null then
    v_text := 'Payday plan for ' || calc._day_text((v_plan ->> 'pay_on')::date) || ', through '
              || calc._day_text((v_plan ->> 'through')::date) || ': '
              || coalesce((select string_agg((x ->> 'name') || ' ' || calc._money((x ->> 'amount')::numeric), ' and ')
                             from jsonb_array_elements(v_plan -> 'incomes') x) || ' in. ', '')
              || (v_plan -> 'totals' ->> 'bill_count') || ' bills to cover, '
              || calc._money((v_plan -> 'totals' ->> 'bills')::numeric) || ' ('
              || (v_plan -> 'totals' ->> 'manual_count') || ' to pay by hand, '
              || calc._money((v_plan -> 'totals' ->> 'manual')::numeric) || '). Left after everything: '
              || coalesce((select string_agg((a ->> 'name') || ' ' || calc._money((a ->> 'left')::numeric), ', ' order by a ->> 'name')
                             from jsonb_array_elements(v_plan -> 'accounts') a), 'nothing on file') || '.';
    v_new := v_new || jsonb_build_array(jsonb_build_object(
      'e', jsonb_build_object('level', 'GREEN', 'kind', 'payday_plan', 'text', v_text, 'data', v_plan),
      'n', 0));
  end if;

  update calc.briefing b
     set items = (select coalesce(jsonb_agg(x -> 'e' order by case x -> 'e' ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end,
                                              (x ->> 'n')::bigint), '[]'::jsonb)
                    from jsonb_array_elements(v_new) x),
         level = (select coalesce(case when bool_or(x -> 'e' ->> 'level' = 'RED') then 'RED'
                                       when bool_or(x -> 'e' ->> 'level' = 'YELLOW') then 'YELLOW' end, 'GREEN')
                    from jsonb_array_elements(v_new) x);
end
$$;
