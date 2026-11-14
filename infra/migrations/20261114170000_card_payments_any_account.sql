-- Shadow week day 1 (Nov 14): James paid November's Chase Amazon minimum with $150 from Joint on
-- Oct 30, but the bill is paid from Bill Pay, the amount isn't the minimum, and the transfer names
-- no bill, so the matcher proposed nothing and no tool could record the payment.
--
-- A card payment always lands on the card, whichever account sent it. So a card bill now says
-- which account it pays down (ref.bills.pays_account_key), and the matcher also looks at money
-- coming in to that account. Nothing here drops anything, so it needs no Supabase confirm dialog.
--
--   1. ref.bills.pays_account_key: the card or loan account the bill pays down. update_bill
--      accepts it, and current_bills shows it.
--   2. The matcher proposes a payment received on that account for the bill's unpaid cycle, from
--      any account, when it's at least the bill's amount less its tolerance (paying more than the
--      minimum still covers the minimum). It counts as a payment when Era files it under
--      "Transfers and card payments" or calls it a payment; a refund isn't one.
--   3. Each transfer has two sides (out of checking, in to the card). Only one is proposed for a
--      card bill's cycle: the card side wins in the same run, a cycle with an open proposal gets no
--      second one, and a side whose other side is already proposed or paid is skipped.
--   4. confirm_match accepts money in when it lands on the account the bill pays down, and closes
--      open proposals on the other side of the same transfer.

-- ---------------------------------------------------------------- 1. the column

alter table ref.bills add column pays_account_key text;
comment on column ref.bills.pays_account_key is
  'For a card or loan bill: the account it pays down. The matcher then also counts payments received on that account, from any account.';
create trigger bills_pays_account before insert or update of pays_account_key on ref.bills
  for each row execute function ref.require_key('pays_account_key', 'ref.accounts', 'account_key', 'current');

create or replace view ref.current_bills with (security_invoker = true) as
  select * from ref.bills
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- update_bill

-- As in 20261110143309_mcp_tools / 20261110200000_schedules_and_transfers, plus pays_account_key.
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
                              'autopay', 'cadence', 'cadence_anchor', 'every_weeks', 'income_key', 'note',
                              'pays_account_key'];
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
                           cadence, cadence_anchor, every_weeks, income_key, note, pays_account_key, valid_from)
    values (p_bill_key, v_new.name, v_new.amount, v_new.amount_kind, v_new.tolerance, v_new.due_day, v_new.account_key,
            v_new.autopay, v_new.cadence, v_new.cadence_anchor, v_new.every_weeks, v_new.income_key, v_new.note,
            v_new.pays_account_key, v_from)
    returning * into v_new;
  exception
    when check_violation or not_null_violation then
      raise exception 'That bill has a value that isn''t allowed. Amounts are at least 0 and amount_kind is fixed or variable. Cadence is monthly (needs due_day), every_other_month, quarterly, semiannual or annual (need due_day and a cadence_anchor date), weekly or biweekly (need a cadence_anchor date), every_n_weeks (needs a cadence_anchor date and every_weeks, 1 to 52), or per_paycheck (needs income_key). bill_key is lowercase letters, digits, - or _. Nothing was written.'
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

-- ---------------------------------------------------------------- 2-3. the matcher

-- Whether a transaction (or the other side of its transfer) is already spoken for: an open or
-- confirmed proposal, or a ledger payment.
create or replace function calc._tx_spoken_for(p_era_transaction_id text) returns boolean
language sql stable set search_path = ''
as $$
  select p_era_transaction_id is not null
     and (exists (select 1 from knowledge.proposed_matches m
                   where m.era_transaction_id = p_era_transaction_id
                     and m.status in ('pending', 'ambiguous', 'confirmed'))
          or exists (select 1 from ledger.payments_effective p where p.era_transaction_id = p_era_transaction_id))
$$;

-- Whether money coming in to an account is a payment (not a refund or a reward credit).
create or replace function calc._is_payment_in(p_payload jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select coalesce(p_payload ->> 'category', '') = 'Transfers and card payments'
      or concat_ws(' ', p_payload ->> 'description', p_payload ->> 'originalDescription') ~* '\m(payment|pymt)\M'
$$;

-- As in 20261114160000_matcher_removed_and_pending, plus the card side of a payment.
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
    -- Money out: a bill paid from one of our accounts.
    select t.era_transaction_id, t.era_account_id, abs(t.amount) as amount, t.occurred_on,
           lower(concat_ws(' ', t.merchant, t.payload ->> 'description')) as name_text,
           calc._tx_tags(t.payload) as tags,
           t.payload #>> '{transferLink,linkedTransactionId}' as other_side
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
    select b.bill_key, b.name, b.amount, b.amount_kind, b.pays_account_key,
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
    select tx.era_transaction_id, b.bill_key, b.pays_account_key, cy.due_month, cy.due_on,
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
       -- For a card bill, the card side of this transfer may already be proposed or paid.
       and not (b.pays_account_key is not null and calc._tx_spoken_for(tx.other_side))
  ), eligible as (
    select s.era_transaction_id, s.bill_key, s.pays_account_key, s.due_month, s.due_on,
           s.s_account + s.s_amount + s.s_date + s.s_name as score,
           concat_ws('; ',
             'account ' || s.s_account,
             format('amount %s ($%s paid, bill $%s)', s.s_amount, s.tx_amount, s.bill_amount),
             format('date %s (%s, due %s)', s.s_date, s.occurred_on, s.due_on),
             'name ' || s.s_name) as reason,
           false as card_side, s.occurred_on
      from scored s
     where (s.s_name > 0 or (s.exact and s.s_account > 0))
       and (s.s_name > 0 or not s.tx_names_a_bill)
  ), card_in as (
    -- Money in: a payment received on the account a card bill pays down, from any account.
    select t.era_transaction_id, t.amount, t.occurred_on, acct.account_key, acct.name as account_name,
           t.payload #>> '{transferLink,linkedTransactionId}' as other_side,
           t.payload #>> '{transferLink,counterpartAccountName}' as from_name
      from raw.era_transactions t
      join lateral (select a.account_key, a.name from ref.accounts a
                     where a.era_account_id = t.era_account_id
                     order by a.valid_from desc limit 1) acct on true
     where t.amount > 0
       and t.removed_at is null
       and t.occurred_on between p_today - 45 and p_today
       and calc._is_payment_in(t.payload)
       and coalesce(calc._not_a_bill_reason(t.payload, p_today), '') not in ('fee', 'interest')
       and not calc._tx_spoken_for(t.era_transaction_id)
       and not calc._tx_spoken_for(t.payload #>> '{transferLink,linkedTransactionId}')
  ), card_eligible as (
    select ci.era_transaction_id, b.bill_key, b.pays_account_key, cy.due_month, cy.due_on, 100 as score,
           concat_ws('; ',
             format('card payment received on %s%s', ci.account_name, ' from ' || ci.from_name),
             format('amount $%s paid, bill $%s', ci.amount, b.amount),
             format('date %s, due %s', ci.occurred_on, cy.due_on)) as reason,
           true as card_side, ci.occurred_on
      from card_in ci
      join bills b on b.pays_account_key = ci.account_key
      join lateral (
        select c.due_month, c.due_on
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and ci.occurred_on <@ calc._match_window(c.cadence, c.every_weeks, c.due_month, c.due_on)
           and (calc._is_date_cadence(c.cadence)
                or abs(ci.occurred_on - c.due_on) <= abs(ci.occurred_on - (c.due_on - make_interval(months => b.months_apart))::date))
         order by abs(ci.occurred_on - c.due_on), c.due_on
         limit 1
      ) cy on true
     where ci.amount >= b.amount - b.tolerance
       and not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = ci.era_transaction_id and m.bill_key = b.bill_key
                          and not (m.status = 'rejected' and m.decided_by is null))
  ), ranked as (
    select e.*,
           max(e.score) over (partition by e.era_transaction_id) as top,
           count(*) over (partition by e.era_transaction_id, e.score) as tied
      from (select * from eligible union all select * from card_eligible) e
     where e.score >= 70
  ), one_per_card_cycle as (
    -- A card bill gets one proposal per cycle: none if one is already open, else the card side
    -- first, then the earliest payment.
    select r.*,
           case when r.pays_account_key is null then 1
                else row_number() over (partition by r.bill_key, r.due_month
                                        order by r.card_side desc, r.occurred_on, r.era_transaction_id) end as n
      from ranked r
     where r.score = r.top
       and not (r.pays_account_key is not null
                and exists (select 1 from knowledge.proposed_matches m
                             where m.bill_key = r.bill_key and m.due_month = r.due_month
                               and m.status in ('pending', 'ambiguous')))
  )
  select o.era_transaction_id, o.bill_key, o.due_month, o.due_on, o.score, o.reason,
         case when o.tied > 1 then 'ambiguous' else 'pending' end
    from one_per_card_cycle o
   where o.n = 1
  on conflict (era_transaction_id, bill_key) do update
     set due_month = excluded.due_month, due_on = excluded.due_on, score = excluded.score, reason = excluded.reason,
         status = excluded.status, created_at = now(), decided_at = null, decision_note = null
   where knowledge.proposed_matches.status = 'rejected' and knowledge.proposed_matches.decided_by is null;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------- 4. confirm_match

-- As in 20261114160000_matcher_removed_and_pending, plus money in on the account the bill pays
-- down, and closing the other side of the same transfer.
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
  v_other  text;
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
  -- Money in counts only when it lands on the account this bill pays down (a card payment).
  if v_tx.amount >= 0 and not exists (
       select 1 from ref.bills b
         join ref.accounts a on a.account_key = b.pays_account_key
        where b.bill_key = v_match.bill_key and a.era_account_id = v_tx.era_account_id) then
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

  -- And the other side of the same transfer (out of checking, in to the card) is the same money.
  v_other := v_tx.payload #>> '{transferLink,linkedTransactionId}';
  if v_other is not null then
    update knowledge.proposed_matches
       set status = 'rejected', decided_at = now(), decided_by = v_person,
           decision_note = 'The other side of this transfer was confirmed.'
     where era_transaction_id = v_other
       and status in ('pending', 'ambiguous');
  end if;

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
