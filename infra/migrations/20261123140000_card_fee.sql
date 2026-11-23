-- The water bill (Montmorenci, paid from Bill Pay) always posts as two charges: the bill and a
-- small card fee, the same day (Nov 21: $34.07 + $1.66). The matcher proposed only the bill, so
-- the fee sat unmatched and the ledger showed less than was paid. James, 2026-11-22: that's the
-- normal pattern, and the fee counts with the bill. Nothing here drops anything, so it needs no
-- Supabase confirm dialog.
--
--   1. ref.bills.card_fee: true when the bill comes with a separate card fee charge. update_bill
--      accepts it and carries it to each new version; current_bills shows it. Off by default.
--   2. A card fee is a charge on the same account, under the same merchant name, within 2 days of
--      the bill's charge, and no more than 10% of it (past water fees ran 2.7% to 4.9%).
--   3. The matcher never proposes a card fee as a bill payment on its own. The bill's proposal
--      says which fee came with it.
--   4. confirm_match on the bill's charge also records the fee as a second payment for the same
--      cycle, when the fee has posted.
--   5. A fee that shows up (or posts) after its bill is already in the ledger is proposed for that
--      same cycle, so it can be confirmed too and never sits as a stray charge.

-- ---------------------------------------------------------------- 1. the column

alter table ref.bills add column card_fee boolean not null default false;
comment on column ref.bills.card_fee is
  'True when the bill posts with a separate small card fee charge (same account, same merchant, within 2 days, at most 10% of the bill). The fee is recorded with the bill.';

create or replace view ref.current_bills with (security_invoker = true) as
  select * from ref.bills
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- update_bill

-- As in 20261114200000_bill_tags_and_emergency_fund, plus card_fee.
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
                              'pays_account_key', 'category', 'basic_necessity', 'card_fee'];
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
                           cadence, cadence_anchor, every_weeks, income_key, note, pays_account_key, category,
                           basic_necessity, card_fee, valid_from)
    values (p_bill_key, v_new.name, v_new.amount, v_new.amount_kind, v_new.tolerance, v_new.due_day, v_new.account_key,
            v_new.autopay, v_new.cadence, v_new.cadence_anchor, v_new.every_weeks, v_new.income_key, v_new.note,
            v_new.pays_account_key, v_new.category, v_new.basic_necessity, coalesce(v_new.card_fee, false), v_from)
    returning * into v_new;
  exception
    when check_violation or not_null_violation then
      raise exception 'That bill has a value that isn''t allowed. Amounts are at least 0 and amount_kind is fixed or variable. Cadence is monthly (needs due_day), every_other_month, quarterly, semiannual or annual (need due_day and a cadence_anchor date), weekly or biweekly (need a cadence_anchor date), every_n_weeks (needs a cadence_anchor date and every_weeks, 1 to 52), or per_paycheck (needs income_key). category is one or more lowercase words. bill_key is lowercase letters, digits, - or _. Nothing was written.'
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



-- ---------------------------------------------------------------- 2. what a card fee is

-- Whether p_fee is the card fee that came with p_main.
create or replace function calc._card_fee_pair(p_main raw.era_transactions, p_fee raw.era_transactions) returns boolean
language sql immutable set search_path = ''
as $$
  select p_main.era_transaction_id <> p_fee.era_transaction_id
     and p_main.era_account_id = p_fee.era_account_id
     and p_main.removed_at is null and p_fee.removed_at is null
     and p_main.amount < 0 and p_fee.amount < 0
     and abs(p_fee.amount) <= round(abs(p_main.amount) * 0.10, 2)
     and abs(p_main.occurred_on - p_fee.occurred_on) <= 2
     and nullif(lower(trim(p_main.merchant)), '') = lower(trim(p_fee.merchant))
$$;

-- The card fee that came with a bill's charge and isn't recorded or proposed yet, or null.
create or replace function calc._card_fee_of(p_main_tx text) returns raw.era_transactions
language sql stable set search_path = ''
as $$
  select f.*
    from raw.era_transactions m
    join raw.era_transactions f
      on f.era_account_id = m.era_account_id
     and f.occurred_on between m.occurred_on - 2 and m.occurred_on + 2
     and calc._card_fee_pair(m, f)
   where m.era_transaction_id = p_main_tx
     and not calc._tx_spoken_for(f.era_transaction_id)
   order by abs(f.occurred_on - m.occurred_on), f.occurred_on, f.era_transaction_id
   limit 1
$$;

-- Whether a charge is the card fee of another charge, for a bill that comes with one.
create or replace function calc._is_card_fee(p_tx text, p_today date) returns boolean
language sql stable set search_path = ''
as $$
  select exists (
    select 1
      from raw.era_transactions f
      join raw.era_transactions m
        on m.era_account_id = f.era_account_id
       and m.occurred_on between f.occurred_on - 2 and f.occurred_on + 2
       and calc._card_fee_pair(m, f)
     where f.era_transaction_id = p_tx
       and exists (select 1 from ref.bills b
                     join ref.bill_aliases al
                       on al.bill_key = b.bill_key
                      and al.valid_from <= p_today and (al.valid_to is null or al.valid_to > p_today)
                    where b.card_fee
                      and b.valid_from <= p_today and (b.valid_to is null or b.valid_to > p_today)
                      and position(lower(al.alias) in lower(concat_ws(' ', f.merchant, f.payload ->> 'description'))) > 0))
$$;

-- ---------------------------------------------------------------- 3 and 5. the matcher

-- As in 20261114170000_card_payments_any_account, plus card fees: a fee isn't proposed on its own,
-- the bill's proposal names the fee that came with it, and a fee whose bill is already in the
-- ledger is proposed for that same cycle.
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
       -- A card fee goes with its bill's charge, never on its own (fee_eligible below).
       and not calc._is_card_fee(t.era_transaction_id, p_today)
  ), bills as (
    select b.bill_key, b.name, b.amount, b.amount_kind, b.pays_account_key, b.card_fee,
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
    select tx.era_transaction_id, b.bill_key, b.pays_account_key, b.card_fee, cy.due_month, cy.due_on,
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
             'name ' || s.s_name,
             case when s.card_fee then
               (select format('plus card fee $%s (%s), recorded with it', abs(f.amount), f.occurred_on)
                  from calc._card_fee_of(s.era_transaction_id) f where f.era_transaction_id is not null)
             end) as reason,
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
  ), fee_eligible as (
    -- A card fee whose bill charge is already a ledger payment: proposed for that same cycle.
    select t.era_transaction_id, pe.bill_key, null::text as pays_account_key, pe.due_month, pe.due_on, 100 as score,
           format('card fee $%s (%s) that came with the %s payment of $%s on %s (ledger payment %s); it counts with the bill',
                  abs(t.amount), t.occurred_on, b.name, pe.amount, pe.paid_on, pe.id) as reason,
           false as card_side, t.occurred_on
      from raw.era_transactions t
      join raw.era_transactions mt
        on mt.era_account_id = t.era_account_id
       and mt.occurred_on between t.occurred_on - 2 and t.occurred_on + 2
       and calc._card_fee_pair(mt, t)
      join ledger.payments_effective pe on pe.era_transaction_id = mt.era_transaction_id
      join bills b on b.bill_key = pe.bill_key and b.card_fee
     where t.amount < 0
       and t.removed_at is null
       and t.occurred_on between p_today - 45 and p_today
       and not calc._tx_spoken_for(t.era_transaction_id)
       and not exists (select 1 from knowledge.proposed_matches m
                        where m.era_transaction_id = t.era_transaction_id and m.bill_key = pe.bill_key
                          and not (m.status = 'rejected' and m.decided_by is null))
  ), ranked as (
    select e.*,
           max(e.score) over (partition by e.era_transaction_id) as top,
           count(*) over (partition by e.era_transaction_id, e.score) as tied
      from (select * from eligible union all select * from card_eligible union all select * from fee_eligible) e
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

-- As in 20261114170000_card_payments_any_account, plus the card fee that came with the bill.
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
  v_fee    raw.era_transactions;
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

  -- A bill that comes with a card fee: the fee counts with it, as a second payment for the same
  -- cycle. A fee still pending at the bank waits; the matcher proposes it once the bill is paid.
  if v_tx.amount < 0 and exists (
       select 1 from ref.bills b
        where b.bill_key = v_match.bill_key and b.card_fee
          and b.valid_from <= current_date and (b.valid_to is null or b.valid_to > current_date)) then
    v_fee := calc._card_fee_of(v_tx.era_transaction_id);
    if v_fee.era_transaction_id is not null and not v_fee.pending then
      insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, era_transaction_id, proposed_match_id, entered_by, note)
      values (v_match.bill_key, v_match.due_month, v_match.due_on, abs(v_fee.amount), v_fee.occurred_on, v_fee.era_transaction_id,
              v_match.id, v_person, 'Card fee that came with this bill.');
      update knowledge.proposed_matches
         set status = 'rejected', decided_at = now(), decided_by = v_person,
             decision_note = 'Recorded as the card fee of a confirmed bill payment.'
       where era_transaction_id = v_fee.era_transaction_id
         and status in ('pending', 'ambiguous');
    end if;
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
