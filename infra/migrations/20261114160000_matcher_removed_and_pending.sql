-- Test 2 (Nov 14) found two proposals for one $61.11 Affirm charge: match 129 on the pending copy,
-- which Era dropped on Nov 11, and match 131 on the posted copy. The matcher already skipped removed
-- transactions when proposing, but a proposal made before the transaction was removed stayed open,
-- and confirm_match would then refuse it.
--
-- Three changes. Nothing here drops anything, so it needs no Supabase confirm dialog.
--   1. Each matcher run first withdraws open proposals whose transaction Era no longer sends
--      (status rejected, decided_by null: the build's "withdrawn" convention). The pairing can come
--      back if Era sends the transaction again.
--   2. confirm_match refuses a transaction that is still pending at the bank. A pending charge can
--      vanish and post under a new id, which would leave a ledger payment pointing at a transaction
--      that no longer exists and let the posted copy be proposed for another cycle. The proposal
--      still stands while it waits, so the bill shows as matched (not due, not late) and the cash
--      projection doesn't count it a second time. Once it posts, either the same proposal becomes
--      confirmable (Era kept the id) or it's withdrawn and the posted copy is proposed (new id).
--   3. The briefing's pending matches item marks the ones still pending at the bank, so the
--      assistant asks for a yes or no only on the ones that can be confirmed today.

-- ---------------------------------------------------------------- the matcher

-- As in 20261110200000_schedules_and_transfers, plus the withdrawal at the top.
create or replace function calc._run_matcher(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  -- Withdraw open proposals on transactions Era no longer sends (a pending charge that posted
  -- under a new id, or a copy on a replaced account). Withdrawn, not rejected by a person, so the
  -- pairing can come back if Era sends the transaction again.
  update knowledge.proposed_matches m
     set status = 'rejected', decided_at = now(), decided_by = null,
         decision_note = 'Withdrawn: Era no longer shows this transaction.'
    from raw.era_transactions t
   where t.era_transaction_id = m.era_transaction_id
     and t.removed_at is not null
     and m.status in ('pending', 'ambiguous');

  insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, due_on, score, reason, status)
  with tx as (
    select t.era_transaction_id, t.era_account_id, abs(t.amount) as amount, t.occurred_on,
           lower(concat_ws(' ', t.merchant, t.payload ->> 'description')) as name_text,
           calc._tx_tags(t.payload) as tags
      from raw.era_transactions t
     where t.amount < 0
       and t.removed_at is null
       and t.occurred_on between p_today - 45 and p_today
       and calc._not_a_bill_reason(t.payload, p_today) is null
       and not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = t.era_transaction_id
                          and m.status in ('pending', 'ambiguous', 'confirmed'))
       and not exists (select 1 from ledger.payments_effective p where p.era_transaction_id = t.era_transaction_id)
  ), bills as (
    select b.bill_key, b.name, b.amount, b.amount_kind,
           case b.cadence when 'every_other_month' then 2 when 'quarterly' then 3 when 'semiannual' then 6
                          when 'annual' then 12 else 1 end as months_apart,
           coalesce(b.tolerance, case b.amount_kind when 'fixed' then 0.01 else round(b.amount * 0.15, 2) end) as tolerance,
           a.era_account_id
      from ref.bills b
      left join ref.accounts a
        on a.account_key = b.account_key and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today)
     where b.valid_from <= p_today and (b.valid_to is null or b.valid_to > p_today)
  ), named as (
    select tx.era_transaction_id, b.bill_key,
           exists (select 1 from ref.bill_aliases al
                    where al.bill_key = b.bill_key
                      and al.valid_from <= p_today and (al.valid_to is null or al.valid_to > p_today)
                      and position(lower(al.alias) in tx.name_text) > 0)
             or ('bill:' || lower(b.bill_key)) = any (tx.tags)
             or ('bill:' || lower(b.name)) = any (tx.tags) as has_name
      from tx cross join bills b
  ), named_any as (
    -- Whether the transaction names any current bill, before cycles are looked at: a charge that
    -- names a bill already paid this month still isn't proposed for another bill.
    select n.*, bool_or(n.has_name) over (partition by n.era_transaction_id) as tx_names_a_bill
      from named n
  ), scored as (
    select tx.era_transaction_id, b.bill_key, cy.due_month, cy.due_on,
           case when b.era_account_id = tx.era_account_id then 30 else 0 end as s_account,
           case when abs(tx.amount - b.amount) <= b.tolerance then 40 else 0 end as s_amount,
           20 as s_date,
           case when n.has_name then 10 else 0 end as s_name,
           tx.amount = b.amount as exact,
           n.tx_names_a_bill,
           tx.amount as tx_amount, b.amount as bill_amount, tx.occurred_on
      from tx
      cross join bills b
      join named_any n on n.era_transaction_id = tx.era_transaction_id and n.bill_key = b.bill_key
      -- The cycle it would pay: an unpaid one whose window holds the date, the nearest due date first.
      join lateral (
        select c.due_month, c.due_on
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and tx.occurred_on <@ calc._match_window(c.cadence, c.every_weeks, c.due_month, c.due_on)
           and (calc._is_date_cadence(c.cadence)
                or abs(tx.occurred_on - c.due_on) <= abs(tx.occurred_on - (c.due_on - make_interval(months => b.months_apart))::date))
         order by (calc._is_date_cadence(c.cadence)
                   and exists (select 1 from knowledge.proposed_matches m
                                where m.bill_key = c.bill_key and m.status in ('pending', 'ambiguous')
                                  and coalesce(m.due_on = c.due_on, m.due_month = c.due_month))),
                  abs(tx.occurred_on - c.due_on), c.due_on
         limit 1
      ) cy on true
     -- A pairing already made is never proposed again, unless it was withdrawn (rejected by nobody).
     where not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = tx.era_transaction_id and m.bill_key = b.bill_key
                          and not (m.status = 'rejected' and m.decided_by is null))
  ), eligible as (
    select s.*, s.s_account + s.s_amount + s.s_date + s.s_name as score
      from scored s
     where (s.s_name > 0 or (s.exact and s.s_account > 0))
       and (s.s_name > 0 or not s.tx_names_a_bill)
  ), ranked as (
    select e.*,
           max(e.score) over (partition by e.era_transaction_id) as top,
           count(*) over (partition by e.era_transaction_id, e.score) as tied
      from eligible e
     where e.score >= 70
  )
  select r.era_transaction_id, r.bill_key, r.due_month, r.due_on, r.score,
         concat_ws('; ',
           'account ' || r.s_account,
           format('amount %s ($%s paid, bill $%s)', r.s_amount, r.tx_amount, r.bill_amount),
           format('date %s (%s, due %s)', r.s_date, r.occurred_on, r.due_on),
           'name ' || r.s_name),
         case when r.tied > 1 then 'ambiguous' else 'pending' end
    from ranked r
   where r.score = r.top
  on conflict (era_transaction_id, bill_key) do update
     set due_month = excluded.due_month, due_on = excluded.due_on, score = excluded.score, reason = excluded.reason,
         status = excluded.status, created_at = now(), decided_at = null, decision_note = null
   where knowledge.proposed_matches.status = 'rejected' and knowledge.proposed_matches.decided_by is null;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------- confirm_match

-- As in 20261110200000_schedules_and_transfers, plus: a pending transaction can't be confirmed yet.
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
  if v_tx.pending then
    raise exception 'The transaction for match % is still pending at the bank. Confirm it once it posts; nothing was written.', p_match_id
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

-- ---------------------------------------------------------------- briefing

-- The budget builder keeps running first; this rewrites its pending matches item.
alter function calc._build_briefing(date, bigint) rename to _build_briefing_before_pending_tx;

create function calc._build_briefing(p_today date, p_pull_run_id bigint) returns void
language plpgsql set search_path = ''
as $$
declare
  v_rows   jsonb;
  v_ready  int;
  v_wait   int;
  v_text   text;
begin
  perform calc._build_briefing_before_pending_tx(p_today, p_pull_run_id);

  select jsonb_agg(jsonb_build_object('match_id', m.id, 'bill_key', m.bill_key, 'due_month', m.due_month, 'due_on', m.due_on,
                                      'status', m.status, 'score', m.score, 'amount', abs(t.amount), 'occurred_on', t.occurred_on,
                                      'merchant', t.merchant, 'still_pending', coalesce(t.pending, false))
                   order by t.occurred_on, m.id),
         count(*) filter (where not coalesce(t.pending, false)),
         count(*) filter (where coalesce(t.pending, false))
    into v_rows, v_ready, v_wait
    from knowledge.proposed_matches m
    left join raw.era_transactions t on t.era_transaction_id = m.era_transaction_id
   where m.status in ('pending', 'ambiguous');

  if v_rows is null then
    return;
  end if;

  v_text := concat_ws(' ',
    case when v_ready > 0 then v_ready || case when v_ready = 1 then ' proposed bill match is' else ' proposed bill matches are' end
                               || ' waiting for a yes or no.' end,
    case when v_wait > 0 then v_wait || case when v_wait = 1 then ' more is' else ' more are' end
                              || ' still pending at the bank and can be confirmed once posted.' end);
  if v_ready = 0 then
    v_text := v_wait || case when v_wait = 1 then ' proposed bill match is' else ' proposed bill matches are' end
              || ' still pending at the bank and can be confirmed once posted.';
  end if;

  update calc.briefing b
     set items = (select jsonb_agg(case when e ->> 'kind' = 'pending_matches'
                                        then e || jsonb_build_object('text', v_text, 'data', jsonb_build_object('matches', v_rows))
                                        else e end order by n)
                    from jsonb_array_elements(b.items) with ordinality as x(e, n));
end
$$;
