-- Overdraft buffer per account (open question 8), 2026-11-15.
--
-- James: Chase charges no insufficient-funds fee on Personal 5695 until the balance is below
-- -$50, and he hardly uses that account, so a small dip below $0 there is fine. The briefing
-- still said RED for Personal (projected low -$41.51), which is noise (rule 11) and blocks the
-- shadow week.
--
-- 1. ref.accounts.overdraft_buffer: how far below $0 an account can go with no fee. Default 0,
--    which keeps today's behaviour. James confirmed (2026-11-15) that the same -$50 rule holds
--    for all four Chase checking accounts: Joint 1867, Bill Pay 1063, Personal 5695 and
--    Personal 2165 each get $50.
-- 2. The briefing's overdraft items respect it. For an account with a buffer:
--      - a dip below $0 that stays at or above -buffer is YELLOW ("within the $50 buffer");
--      - going below -buffer follows the old rule: RED before the next income, YELLOW later
--        (or with no income on file).
--    Accounts with no buffer are untouched.
--
-- No DROP: the current builder keeps running under a new name, like the earlier wrappers.

alter table ref.accounts add column overdraft_buffer numeric(12, 2) not null default 0
  check (overdraft_buffer >= 0);
comment on column ref.accounts.overdraft_buffer is
  'How far below $0 the account can go before the bank charges a fee. The briefing flags an overdraft RED only below -overdraft_buffer; a dip between $0 and -overdraft_buffer is YELLOW. 0 means any dip below $0 counts.';

update ref.accounts set overdraft_buffer = 50
 where account_key in ('joint-checking', 'bill-pay', 'james-personal', 'katelyn-personal') and valid_to is null;

alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_overdraft_buffer;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_items       jsonb;
  v_next_income date;
  v_has_income  boolean;
  v_buffer      numeric;
  v_first_past  date;
  v_out         text;
  v_new         jsonb := '[]'::jsonb;
  e             jsonb;
  n             bigint;
begin
  perform calc._build_briefing_before_overdraft_buffer(p_today, p_pull_run_id);

  select items, next_income_on into v_items, v_next_income from calc.briefing;
  if v_items is null or not exists (
       select 1 from jsonb_array_elements(v_items) x
         join ref.accounts a on a.account_key = x -> 'data' ->> 'account_key'
        where x ->> 'kind' = 'overdraft' and a.valid_to is null and a.overdraft_buffer > 0) then
    return;
  end if;

  v_has_income := exists (select 1 from ref.income_sources
                           where valid_from <= p_today + 62 and (valid_to is null or valid_to > p_today));

  for e, n in select x, o from jsonb_array_elements(v_items) with ordinality as t(x, o) loop
    if e ->> 'kind' = 'overdraft' then
      select a.overdraft_buffer into v_buffer
        from ref.accounts a
       where a.account_key = e -> 'data' ->> 'account_key'
         and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
       order by a.valid_from desc limit 1;

      if coalesce(v_buffer, 0) > 0 then
        select min(p.day) into v_first_past
          from calc.cash_projection p
         where p.account_key = e -> 'data' ->> 'account_key' and p.closing < -v_buffer;

        if v_first_past is null then
          e := jsonb_set(jsonb_set(e, '{level}', '"YELLOW"'), '{text}', to_jsonb(
                 replace(e ->> 'text', ' goes below $0 on ', ' dips below $0 on ')
                 || ' That stays within its ' || calc._money(v_buffer) || ' overdraft buffer, so no fee is expected.'));
        else
          select string_agg((d ->> 'name') || ' (' || calc._money((d ->> 'amount')::numeric) || ')', ', ')
            into v_out
            from calc.cash_projection p2, jsonb_array_elements(p2.detail) d
           where p2.account_key = e -> 'data' ->> 'account_key' and p2.day = v_first_past and d ->> 'direction' = 'out';
          e := jsonb_set(e, '{level}', to_jsonb(
                 case when v_has_income and (v_next_income is null or v_first_past < v_next_income) then 'RED' else 'YELLOW' end));
          -- Rebuild the text around the day it passes the buffer.
          e := jsonb_set(e, '{text}', to_jsonb(
                 (select ab.name from calc.account_balances ab where ab.account_key = e -> 'data' ->> 'account_key')
                 || ' goes below ' || calc._money(-v_buffer) || ' (past its ' || calc._money(v_buffer)
                 || ' overdraft buffer) on ' || calc._day_text(v_first_past)
                 || coalesce(' when ' || v_out || ' comes out', '')
                 || case when v_has_income and v_next_income is not null and v_first_past < v_next_income
                           then ', before the next income on ' || calc._day_text(v_next_income) else '' end
                 || '. Lowest: ' || calc._money((e -> 'data' ->> 'lowest')::numeric)
                 || ' on ' || calc._day_text((e -> 'data' ->> 'lowest_on')::date) || '.'));
        end if;
        e := jsonb_set(e, '{data}', (e -> 'data')
               || jsonb_build_object('overdraft_buffer', v_buffer, 'first_below_buffer_on', v_first_past));
      end if;
    end if;
    v_new := v_new || jsonb_build_array(jsonb_build_object('e', e, 'n', n));
  end loop;

  update calc.briefing b
     set items = (select coalesce(jsonb_agg(x -> 'e' order by case x -> 'e' ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end,
                                              (x ->> 'n')::bigint), '[]'::jsonb)
                    from jsonb_array_elements(v_new) x),
         level = (select case when bool_or(x -> 'e' ->> 'level' = 'RED') then 'RED'
                              when bool_or(x -> 'e' ->> 'level' = 'YELLOW') then 'YELLOW' else 'GREEN' end
                    from jsonb_array_elements(v_new) x);
end
$$;
