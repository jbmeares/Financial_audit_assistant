-- E1, E6, E7. The briefing, the refresh that runs every step in order, and what_if.

-- ---------------------------------------------------------------- formatting helpers

create function calc._money(p numeric) returns text
language sql immutable set search_path = ''
as $$ select case when p < 0 then '-$' else '$' end || to_char(abs(p), 'FM999,999,990.00') $$;

create function calc._day_text(p date) returns text
language sql immutable set search_path = ''
as $$ select to_char(p, 'Dy Mon FMDD') $$;

-- ---------------------------------------------------------------- E6. the briefing

-- Rebuilds the one briefing row from the calc tables built earlier in the same refresh.
-- Levels follow rule 11: RED for an overdraft before the next income, a hard deadline at risk
-- or an expired key; YELLOW for something to check, stale data or a failed pull; GREEN otherwise.
create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_items        jsonb := '[]'::jsonb;
  v_latest       raw.pull_runs;
  v_last_good    raw.pull_runs;
  v_next_income  date;
  v_income_rows  jsonb;
  v_has_income   boolean;
  v_window_end   date;
  v_rows         jsonb;
  v_total        numeric;
  r              record;
begin
  -- The last pull.
  select * into v_latest from raw.pull_runs order by started_at desc, id desc limit 1;
  select * into v_last_good from raw.pull_runs where status in ('ok', 'partial') order by finished_at desc, id desc limit 1;

  if v_latest.id is null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'pull',
      'text', 'No Era pull has run yet, so there are no bank numbers.', 'data', '{}'::jsonb);
  elsif v_latest.status = 'failed' then
    v_items := v_items || jsonb_build_object(
      'level', case when v_latest.error ilike '%auth%' then 'RED' else 'YELLOW' end,
      'kind', 'pull',
      'text', case when v_latest.error ilike '%auth%'
                then 'Era rejected the API key, so the pull stopped. Make a new key in Era, replace the ERA_READ_KEY secret in Supabase, and update its expiry in ref.api_keys.'
                else 'The last Era pull failed: ' || coalesce(v_latest.error, 'no error recorded') || '.' end
              || coalesce(' The last good pull finished ' || to_char(v_last_good.finished_at at time zone 'America/New_York', 'Dy Mon FMDD at FMHH12:MI am') || '.',
                          ' No pull has finished well yet.'),
      'data', jsonb_build_object('pull_run_id', v_latest.id, 'error', v_latest.error, 'last_good_finished_at', v_last_good.finished_at));
  elsif v_latest.status = 'partial' then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'pull',
      'text', 'The last Era pull was partial: ' || coalesce(v_latest.error, 'no detail recorded') || '.',
      'data', jsonb_build_object('pull_run_id', v_latest.id, 'error', v_latest.error));
  elsif v_latest.status = 'running' and v_latest.id is distinct from p_pull_run_id and v_latest.started_at < now() - interval '1 hour' then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'pull',
      'text', 'An Era pull started ' || to_char(v_latest.started_at at time zone 'America/New_York', 'Dy Mon FMDD at FMHH12:MI am') || ' and hasn''t finished.',
      'data', jsonb_build_object('pull_run_id', v_latest.id));
  end if;

  if v_latest.id is not null and (v_latest.started_at at time zone 'America/New_York')::date < p_today then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'no_pull_today',
      'text', 'No Era pull since ' || calc._day_text((v_latest.started_at at time zone 'America/New_York')::date) || '.',
      'data', jsonb_build_object('last_started_at', v_latest.started_at));
  end if;

  -- Keys.
  for r in
    select key_name, expires_on, expires_on - p_today as days_left
      from ref.api_keys
     where valid_from <= p_today and (valid_to is null or valid_to > p_today)
       and expires_on - p_today <= 30
     order by expires_on
  loop
    v_items := v_items || jsonb_build_object(
      'level', case when r.days_left <= 0 then 'RED' else 'YELLOW' end,
      'kind', 'key_expiry',
      'text', case when r.days_left <= 0 then 'The ' || r.key_name || ' key expired ' || calc._day_text(r.expires_on) || '.'
                   else 'The ' || r.key_name || ' key expires ' || calc._day_text(r.expires_on) || ', in ' || r.days_left || ' days.' end,
      'data', jsonb_build_object('key_name', r.key_name, 'expires_on', r.expires_on, 'days_left', r.days_left));
  end loop;

  -- Accounts with no balance, and stale balances.
  select jsonb_agg(jsonb_build_object('account_key', account_key, 'name', name, 'kind', kind) order by account_key)
    into v_rows from calc.account_balances where balance is null;
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'no_balance',
      'text', 'No balance for ' || (select string_agg(e ->> 'name', ', ') from jsonb_array_elements(v_rows) e)
              || ', so it is left out of the numbers.',
      'data', jsonb_build_object('accounts', v_rows));
  end if;

  select jsonb_agg(jsonb_build_object('account_key', account_key, 'name', name, 'as_of', as_of, 'source', source) order by as_of)
    into v_rows from calc.account_balances where balance is not null and stale;
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'stale_accounts',
      'text', 'Balances older than 3 days: '
              || (select string_agg((e ->> 'name') || ' (' || calc._day_text(((e ->> 'as_of')::timestamptz at time zone 'America/New_York')::date) || ')', ', ')
                    from jsonb_array_elements(v_rows) e) || '.',
      'data', jsonb_build_object('accounts', v_rows));
  end if;

  -- Next income.
  select jsonb_agg(jsonb_build_object('income_key', i.income_key, 'name', i.name, 'on', n.d, 'amount', i.amount) order by n.d),
         min(n.d)
    into v_income_rows, v_next_income
    from ref.income_sources i
    cross join lateral (
      select min(pd) as d from calc._pay_dates(i.cadence, i.anchor_pay_date, greatest(p_today, i.valid_from),
                                               least(p_today + 62, coalesce(i.valid_to - 1, p_today + 62))) pd
    ) n
   where n.d is not null;
  v_has_income := exists (select 1 from ref.income_sources
                           where valid_from <= p_today + 62 and (valid_to is null or valid_to > p_today));

  if not v_has_income then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'projection_incomplete',
      'text', 'Projection incomplete: no income is on file, so it shows only money going out. A low balance isn''t flagged RED until income is entered.',
      'data', '{}'::jsonb);
  elsif v_next_income is not null then
    v_items := v_items || jsonb_build_object('level', 'GREEN', 'kind', 'next_income',
      'text', 'Next income: ' || calc._day_text(v_next_income) || ' ('
              || (select string_agg((e ->> 'name') || ' ' || calc._money((e ->> 'amount')::numeric), ', ')
                    from jsonb_array_elements(v_income_rows) e where (e ->> 'on')::date = v_next_income) || ').',
      'data', jsonb_build_object('on', v_next_income, 'sources', v_income_rows));
  end if;

  -- Overdrafts. RED before the next income; YELLOW later in the 60 days, or when there is no
  -- income on file (the projection can't be trusted to show a real overdraft then).
  for r in
    select p.account_key, ab.name, min(p.day) filter (where p.closing < 0) as first_below,
           (array_agg(p.closing order by p.closing, p.day))[1] as lowest,
           (array_agg(p.day order by p.closing, p.day))[1] as lowest_on
      from calc.cash_projection p
      join calc.account_balances ab on ab.account_key = p.account_key
     group by p.account_key, ab.name
    having min(p.closing) < 0
     order by min(p.day) filter (where p.closing < 0)
  loop
    v_items := v_items || jsonb_build_object(
      'level', case when v_has_income and (v_next_income is null or r.first_below < v_next_income) then 'RED' else 'YELLOW' end,
      'kind', 'overdraft',
      'text', r.name || ' goes below $0 on ' || calc._day_text(r.first_below)
              || coalesce(' when ' || (select string_agg((e ->> 'name') || ' (' || calc._money((e ->> 'amount')::numeric) || ')', ', ')
                                        from calc.cash_projection p2, jsonb_array_elements(p2.detail) e
                                       where p2.account_key = r.account_key and p2.day = r.first_below and e ->> 'direction' = 'out')
                          || ' comes out', '')
              || case when v_has_income and v_next_income is not null and r.first_below < v_next_income
                        then ', before the next income on ' || calc._day_text(v_next_income) else '' end
              || '. Lowest: ' || calc._money(r.lowest) || ' on ' || calc._day_text(r.lowest_on) || '.',
      'data', jsonb_build_object('account_key', r.account_key, 'first_below_zero_on', r.first_below,
                                 'lowest', r.lowest, 'lowest_on', r.lowest_on));
  end loop;

  -- Bills due before the next income (or in the next 14 days when no income is on file).
  v_window_end := coalesce(v_next_income - 1, p_today + 13);
  select jsonb_agg(jsonb_build_object('bill_key', bill_key, 'name', bill_name, 'due_on', due_on, 'amount', expected_amount,
                                      'account_key', account_key, 'autopay', autopay) order by due_on, bill_key),
         sum(expected_amount)
    into v_rows, v_total
    from calc.bill_cycles
   where status = 'not_seen_yet'
     and (due_on between p_today and v_window_end
          or (due_on < p_today and due_month = date_trunc('month', p_today)::date));
  v_items := v_items || jsonb_build_object('level', 'GREEN', 'kind', 'due_before_income',
    'text', case when v_rows is null then 'Nothing is due ' else (jsonb_array_length(v_rows) || case when jsonb_array_length(v_rows) = 1 then ' bill, ' else ' bills, ' end
                                                  || calc._money(v_total) || case when jsonb_array_length(v_rows) = 1 then ', is due ' else ', are due ' end) end
            || case when v_next_income is not null then 'before the next income on ' || calc._day_text(v_next_income) else 'in the next 14 days' end || '.',
    'data', jsonb_build_object('through', v_window_end, 'total', coalesce(v_total, 0), 'bills', coalesce(v_rows, '[]'::jsonb)));

  -- Late bills (a due month ended with no payment and no proposal waiting).
  select jsonb_agg(jsonb_build_object('bill_key', bill_key, 'name', bill_name, 'due_month', due_month, 'due_on', due_on,
                                      'amount', expected_amount) order by due_on)
    into v_rows from calc.bill_cycles where status = 'late';
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'late_bills',
      'text', 'Late (the due month ended with no payment recorded): '
              || (select string_agg((e ->> 'name') || ' due ' || calc._day_text((e ->> 'due_on')::date), ', ') from jsonb_array_elements(v_rows) e) || '.',
      'data', jsonb_build_object('bills', v_rows));
  end if;

  -- Pending matches.
  select jsonb_agg(jsonb_build_object('match_id', m.id, 'bill_key', m.bill_key, 'due_month', m.due_month, 'status', m.status,
                                      'score', m.score, 'amount', abs(t.amount), 'occurred_on', t.occurred_on, 'merchant', t.merchant)
                   order by t.occurred_on, m.id)
    into v_rows
    from knowledge.proposed_matches m
    left join raw.era_transactions t on t.era_transaction_id = m.era_transaction_id
   where m.status in ('pending', 'ambiguous');
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'pending_matches',
      'text', jsonb_array_length(v_rows) || case when jsonb_array_length(v_rows) = 1 then ' proposed bill match is' else ' proposed bill matches are' end
              || ' waiting for a yes or no.',
      'data', jsonb_build_object('matches', v_rows));
  end if;

  -- Debts with no balance, and promo rates ending within 30 days.
  select jsonb_agg(jsonb_build_object('debt_key', debt_key, 'account_key', account_key, 'balance_as_of', balance_as_of) order by debt_key)
    into v_rows from calc.debt_snapshot where balance is null;
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'debt_no_balance',
      'text', 'No balance for these debts, so their interest isn''t estimated: '
              || (select string_agg(e ->> 'debt_key', ', ') from jsonb_array_elements(v_rows) e) || '.',
      'data', jsonb_build_object('debts', v_rows));
  end if;

  for r in
    select debt_key, promo_end_on, promo_end_on - p_today as days_left from calc.debt_snapshot
     where promo_end_on is not null and promo_end_on - p_today between 0 and 30 order by promo_end_on
  loop
    v_items := v_items || jsonb_build_object('level', 'YELLOW', 'kind', 'promo_ending',
      'text', 'The promo rate on ' || r.debt_key || ' ends ' || calc._day_text(r.promo_end_on) || ', in ' || r.days_left || ' days.',
      'data', jsonb_build_object('debt_key', r.debt_key, 'promo_end_on', r.promo_end_on, 'days_left', r.days_left));
  end loop;

  -- Open questions.
  select jsonb_agg(jsonb_build_object('question_id', id, 'kind', kind, 'topic', topic, 'question', question, 'asked_for', asked_for) order by id)
    into v_rows from knowledge.open_questions where status = 'open';
  if v_rows is not null then
    v_items := v_items || jsonb_build_object('level', 'GREEN', 'kind', 'open_questions',
      'text', jsonb_array_length(v_rows) || case when jsonb_array_length(v_rows) = 1 then ' open question is' else ' open questions are' end || ' on file.',
      'data', jsonb_build_object('questions', v_rows));
  end if;

  delete from calc.briefing;
  insert into calc.briefing (generated_at, today, numbers_as_of, level, next_income_on, items)
  select now(), p_today, v_last_good.finished_at,
         case when bool_or(e ->> 'level' = 'RED') then 'RED' when bool_or(e ->> 'level' = 'YELLOW') then 'YELLOW' else 'GREEN' end,
         v_next_income,
         coalesce(jsonb_agg(e order by case e ->> 'level' when 'RED' then 0 when 'YELLOW' then 1 else 2 end, n), '[]'::jsonb)
    from jsonb_array_elements(v_items) with ordinality as x(e, n);
end
$$;

-- ---------------------------------------------------------------- E1. refresh_all

-- Runs every step in order: bill cycles, matcher, cash projection, debt snapshot, briefing.
-- The steps run inside one block. If any step errors, the block is rolled back, so the
-- previous numbers stay exactly as they were; the error is kept in calc.refresh_runs, on the
-- pull_runs row passed in (if any), and as a YELLOW item at the top of the old briefing saying
-- how old its numbers are. Readers never see a half-built set: other sessions see the old
-- numbers until the whole transaction commits.
--
-- It never raises for a failed step, so a named action that calls it still succeeds.
-- p_pull_run_id: the era-pull run calling it. p_today: defaults to today in New York.
create function calc.refresh_all(p_pull_run_id bigint default null, p_today date default null) returns jsonb
language plpgsql
security definer
set search_path = ''
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
                                    minimum_payment, est_monthly_interest, promo_end_on, payoff_priority)
    select d.debt_key, d.account_key, abs(ab.balance), ab.as_of, ab.source, coalesce(ab.stale, true), d.apr,
           d.minimum_payment, round(abs(ab.balance) * d.apr / 100 / 12, 2), d.promo_end_on, d.payoff_priority
      from ref.debts d
      left join calc.account_balances ab on ab.account_key = d.account_key
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

-- ---------------------------------------------------------------- E7. what_if

-- Read-only. Takes a list of changes and returns how the 60-day projection moves: the lowest
-- balance and its date on each account, the first day below $0, and debt payoff dates that
-- move. It is STABLE, so Postgres itself refuses any write inside it.
-- Changes (one object or a list):
--   {"type": "extra_payment",   "debt_key", "amount", "on", "account_key", "monthly"?}
--   {"type": "skip_bill",       "bill_key", "due_month"}
--   {"type": "one_off_expense", "account_key", "amount", "on", "label"?}
--   {"type": "income_change",   "income_key", "amount" (the new amount, 0 = stops), "from"}
-- A change, field or key it doesn't recognize is refused by name, never ignored.
create function calc.what_if(p_changes jsonb, p_today date default null) returns jsonb
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
        v_allowed := array['type', 'bill_key', 'due_month'];
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
              (v_change ->> 'monthly')::boolean;
    exception when others then
      raise exception 'Change % (%) has a value of the wrong type: %. Amounts are numbers, dates are YYYY-MM-DD, monthly is true or false.',
        v_n, v_type, sqlerrm using errcode = 'P0001';
    end;
    if v_amount < 0 or (v_amount = 0 and v_type <> 'income_change') then
      raise exception 'Change % (%) needs an amount above 0.', v_n, v_type using errcode = 'P0001';
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
            and due_month = date_trunc('month', (v_change ->> 'due_month')::date)::date and status = 'not_seen_yet') then
      v_notes := v_notes || to_jsonb(format('Change %s: %s isn''t due unpaid in that month, so skipping it changes nothing.',
                                            v_n, v_change ->> 'bill_key'));
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

-- ---------------------------------------------------------------- access

revoke all on all functions in schema calc from public, anon, authenticated;
grant execute on function calc.refresh_all(bigint, date) to ingest;
grant execute on function calc.what_if(jsonb, date) to assistant_read;
