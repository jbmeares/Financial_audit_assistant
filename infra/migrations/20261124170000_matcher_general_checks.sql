-- Matcher general checks and one-month bill notes (James, 2026-11-24: option B of "Smarter
-- finance, fewer rules", the bill half). Instead of a switch per bill:
--
--   1. Charges from the same merchant, on the same account, within 2 days count together. A
--      smaller one goes with the larger: a card fee (water) or a bill paid in two parts. It is
--      never proposed on its own, the larger charge's proposal names it, and confirming that
--      proposal records it for the same cycle. This replaces ref.bills.card_fee, which stays
--      (no DROP) but nothing reads it.
--   2. A bill's amount range and how late it runs come from its own confirmed payments in the
--      last year: the matcher's tolerance widens to the spread actually paid (a tolerance someone
--      set still wins), and a monthly bill that has been paid more than a week after its due date
--      gets that much more room, up to two weeks.
--   3. Card payments from any account: unchanged (20261114170000).
--   4. A one-month change ("holding it until the 20th", "this month is $95", "no bill this
--      month") is a note on that cycle (ref.bill_cycle_notes, action note_bill_cycle), not new
--      bill versions. The projection, payday plan and matcher use the noted date and amount.
-- No DROP statements.

-- ---------------------------------------------------------------- 1. charges that go together

-- Whether p_other came with p_main: same account, both money out, same merchant name, within 2
-- days, and smaller.
create function calc._companion_pair(p_main raw.era_transactions, p_other raw.era_transactions) returns boolean
language sql immutable set search_path = ''
as $$
  select p_main.era_transaction_id <> p_other.era_transaction_id
     and p_main.era_account_id = p_other.era_account_id
     and p_main.removed_at is null and p_other.removed_at is null
     and p_main.amount < 0 and p_other.amount < 0
     and abs(p_other.amount) < abs(p_main.amount)
     and abs(p_main.occurred_on - p_other.occurred_on) <= 2
     and nullif(lower(trim(p_main.merchant)), '') = lower(trim(p_other.merchant))
$$;

-- The smaller charges that came with a charge and aren't recorded or proposed yet.
create function calc._companions_of(p_main_tx text) returns setof raw.era_transactions
language sql stable set search_path = ''
as $$
  select f.*
    from raw.era_transactions m
    join raw.era_transactions f
      on f.era_account_id = m.era_account_id
     and f.occurred_on between m.occurred_on - 2 and m.occurred_on + 2
     and calc._companion_pair(m, f)
   where m.era_transaction_id = p_main_tx
     and not calc._tx_spoken_for(f.era_transaction_id)
   order by f.occurred_on, f.era_transaction_id
$$;

-- Whether a charge is the smaller companion of another charge, at a merchant that names a bill.
create function calc._is_companion(p_tx text, p_today date) returns boolean
language sql stable set search_path = ''
as $$
  select exists (
    select 1
      from raw.era_transactions f
      join raw.era_transactions m
        on m.era_account_id = f.era_account_id
       and m.occurred_on between f.occurred_on - 2 and f.occurred_on + 2
       and calc._companion_pair(m, f)
     where f.era_transaction_id = p_tx
       and exists (select 1 from ref.bills b
                     join ref.bill_aliases al
                       on al.bill_key = b.bill_key
                      and al.valid_from <= p_today and (al.valid_to is null or al.valid_to > p_today)
                    where b.valid_from <= p_today and (b.valid_to is null or b.valid_to > p_today)
                      and position(lower(al.alias) in lower(concat_ws(' ', f.merchant, f.payload ->> 'description'))) > 0))
$$;

comment on column ref.bills.card_fee is
  'Retired 2026-11-24: every bill now takes smaller same-merchant charges within 2 days with it (calc._companion_pair). Kept for history; nothing reads it.';

-- ---------------------------------------------------------------- 2. each bill's own history

-- How far this bill's confirmed payments in the last year strayed from its amount (a cycle's
-- payments added together), capped at half the amount. 0 with no history.
create function calc._bill_amount_spread(p_bill_key text, p_amount numeric, p_today date) returns numeric
language sql stable set search_path = ''
as $$
  select least(coalesce(max(abs(x.paid - p_amount)), 0), round(p_amount * 0.5, 2))
    from (select sum(pe.amount) as paid
            from ledger.payments_effective pe
           where pe.bill_key = p_bill_key and pe.paid_on > p_today - 365 and pe.amount > 0
           group by pe.due_month, pe.due_on) x
$$;

-- Extra days past the usual week a monthly bill's window gets: how much more than 7 days after
-- its due date it has been paid in the last year, at most 14.
create function calc._bill_late_days(p_bill_key text, p_today date) returns int
language sql stable set search_path = ''
as $$
  select least(greatest(coalesce(max(pe.paid_on - pe.due_on), 0) - 7, 0), 14)::int
    from ledger.payments_effective pe
   where pe.bill_key = p_bill_key and pe.paid_on > p_today - 365 and pe.due_on is not null
$$;

-- calc._match_window, with extra days at the end for a month-based bill that runs late.
create function calc._match_window_late(p_cadence text, p_every_weeks int, p_due_month date, p_due_on date, p_late_days int)
returns daterange
language sql immutable set search_path = ''
as $$
  select case when calc._is_date_cadence(p_cadence) or coalesce(p_late_days, 0) = 0 then w
              else daterange(lower(w), upper(w) + p_late_days, '[)') end
    from (select calc._match_window(p_cadence, p_every_weeks, p_due_month, p_due_on) as w) x
$$;

-- ---------------------------------------------------------------- 4. one-month notes

create table ref.bill_cycle_notes (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  bill_key    text not null,
  due_on      date not null,
  move_to     date,
  amount      numeric(12, 2) check (amount >= 0),
  skip        boolean not null default false,
  note        text not null check (length(trim(note)) > 0),
  set_by      text not null references ref.people (person),
  check (not (skip and (move_to is not null or amount is not null)))
);
comment on table ref.bill_cycle_notes is
  'A change to one cycle of a bill, not the bill itself: move_to (a new date, in the same month for a month-based bill), amount (this cycle only) or skip (no bill this cycle). due_on is the cycle''s normal due date. Never changed or deleted: the latest note for a cycle wins, and a note with none of the three puts the cycle back to normal.';
create index bill_cycle_notes_cycle on ref.bill_cycle_notes (bill_key, due_on, id);

create trigger bill_cycle_notes_keep_record before update or delete on ref.bill_cycle_notes
  for each row execute function knowledge.sort_answers_keep_record();

revoke all on ref.bill_cycle_notes from anon, authenticated, public;
grant select on ref.bill_cycle_notes to assistant_read;
alter table ref.bill_cycle_notes enable row level security;
create policy assistant_reads on ref.bill_cycle_notes for select to assistant_read using (true);

alter table calc.bill_cycles add column cycle_note text;
comment on column calc.bill_cycles.cycle_note is 'The one-month note on this cycle (ref.bill_cycle_notes), if any. due_on and expected_amount already include it.';

-- The cycles as before, then each cycle's latest note: a new date, a new amount, or no bill.
alter function calc._build_bill_cycles(date) rename to _build_bill_cycles_before_notes;

create function calc._build_bill_cycles(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  v_count := calc._build_bill_cycles_before_notes(p_today);

  with latest as (
    select distinct on (n.bill_key, n.due_on) n.*
      from ref.bill_cycle_notes n
     order by n.bill_key, n.due_on, n.id desc
  )
  delete from calc.bill_cycles c
   using latest n
   where c.bill_key = n.bill_key and c.due_on = n.due_on and n.skip and c.status <> 'paid';

  with latest as (
    select distinct on (n.bill_key, n.due_on) n.*
      from ref.bill_cycle_notes n
     order by n.bill_key, n.due_on, n.id desc
  )
  update calc.bill_cycles c
     set due_on = coalesce(n.move_to, c.due_on),
         expected_amount = coalesce(n.amount, c.expected_amount),
         cycle_note = case when n.move_to is null and n.amount is null and not n.skip then null else n.note end
    from latest n
   where c.bill_key = n.bill_key and c.due_on = n.due_on
     -- A move onto another cycle's date of the same bill is left out rather than break the refresh.
     and (n.move_to is null or n.move_to = c.due_on
          or not exists (select 1 from calc.bill_cycles o where o.bill_key = c.bill_key and o.due_on = n.move_to));

  select count(*) into v_count from calc.bill_cycles;
  return v_count;
end
$$;

-- The chats' way to note a one-month change. Pass the cycle's normal due date (from
-- calc.bill_cycles), plus a new date, a new amount, or skip. Nothing else: back to normal.
create function actions.note_bill_cycle(
  p_person    text,
  p_bill_key  text,
  p_due_on    date,
  p_note      text,
  p_move_to   date default null,
  p_amount    numeric default null,
  p_skip      boolean default false
) returns ref.bill_cycle_notes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person  text := actions._person(p_person);
  v_args    jsonb := jsonb_build_object('person', v_person, 'bill_key', p_bill_key, 'due_on', p_due_on, 'note', p_note,
                                        'move_to', p_move_to, 'amount', p_amount, 'skip', p_skip);
  v_prior   jsonb;
  v_cadence text;
  v_normal  boolean;
  v_row     ref.bill_cycle_notes;
begin
  v_prior := actions._prior_result('note_bill_cycle', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ref.bill_cycle_notes, v_prior);
  end if;

  if nullif(trim(p_note), '') is null then
    raise exception 'Say why in note, in their words ("holding it until the 20th").' using errcode = 'P0001';
  end if;
  select b.cadence into v_cadence from ref.bills b
   where b.bill_key = p_bill_key and b.valid_from <= p_due_on and (b.valid_to is null or b.valid_to > p_due_on)
   order by b.valid_from desc limit 1;
  if v_cadence is null then
    raise exception 'There is no bill "%" on %.', coalesce(p_bill_key, ''), p_due_on using errcode = 'P0001';
  end if;
  -- The cycle's normal date: no note in force has moved it, or it is the date a note moved it from.
  if not exists (select 1 from calc.bill_cycles c where c.bill_key = p_bill_key and c.due_on = p_due_on and c.cycle_note is null)
     and not exists (select 1 from ref.bill_cycle_notes n where n.bill_key = p_bill_key and n.due_on = p_due_on) then
    raise exception '"%" isn''t due on %. Use the cycle''s normal due date from calc.bill_cycles.', p_bill_key, p_due_on
      using errcode = 'P0001';
  end if;
  if coalesce(p_skip, false) and (p_move_to is not null or p_amount is not null) then
    raise exception 'A skipped cycle takes no new date or amount.' using errcode = 'P0001';
  end if;
  if p_amount is not null and p_amount < 0 then
    raise exception 'The amount is at least 0.' using errcode = 'P0001';
  end if;
  if p_move_to is not null then
    if calc._is_date_cadence(v_cadence) then
      if abs(p_move_to - p_due_on) > 14 then
        raise exception 'A one-cycle move is at most 14 days. For a lasting change, use update_bill.' using errcode = 'P0001';
      end if;
    elsif date_trunc('month', p_move_to) <> date_trunc('month', p_due_on) then
      raise exception 'A monthly bill''s cycle can move only within its month (% here). For a lasting change, use update_bill.',
        to_char(p_due_on, 'FMMonth') using errcode = 'P0001';
    end if;
  end if;
  if exists (select 1 from ledger.payments_effective pe
              where pe.bill_key = p_bill_key
                and case when calc._is_date_cadence(v_cadence) then pe.due_on = p_due_on
                         else pe.due_month = date_trunc('month', p_due_on)::date end) then
    raise exception 'That cycle is already paid, so there''s nothing to change.' using errcode = 'P0001';
  end if;

  insert into ref.bill_cycle_notes (bill_key, due_on, move_to, amount, skip, note, set_by)
  values (p_bill_key, p_due_on, p_move_to, p_amount, coalesce(p_skip, false), trim(p_note), v_person)
  returning * into v_row;

  perform calc.refresh_all();
  perform actions._log_call('note_bill_cycle', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

revoke all on function actions.note_bill_cycle(text, text, date, text, date, numeric, boolean) from public;
grant execute on function actions.note_bill_cycle(text, text, date, text, date, numeric, boolean) to assistant_act;

-- ---------------------------------------------------------------- the matcher

-- As in 20261123140000_card_fee, with companions for every bill instead of card_fee, the
-- tolerance widened by each bill's history, and late-running monthly bills given more room.
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
       -- A smaller charge that came with a bill's charge goes with it, never on its own.
       and not calc._is_companion(t.era_transaction_id, p_today)
  ), bills as (
    select b.bill_key, b.name, b.amount, b.amount_kind, b.pays_account_key,
           case b.cadence when 'every_other_month' then 2 when 'quarterly' then 3 when 'semiannual' then 6
                          when 'annual' then 12 else 1 end as months_apart,
           -- A tolerance someone set wins; otherwise the default, widened to what this bill has
           -- actually been paid at in the last year.
           coalesce(b.tolerance, greatest(case b.amount_kind when 'fixed' then 0.01 else round(b.amount * 0.15, 2) end,
                                          calc._bill_amount_spread(b.bill_key, b.amount, p_today))) as tolerance,
           calc._bill_late_days(b.bill_key, p_today) as late_days,
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
    select tx.era_transaction_id, b.bill_key, b.pays_account_key, cy.due_month, cy.due_on, comp.total as comp_total,
           case when b.era_account_id = tx.era_account_id then 30 else 0 end as s_account,
           -- The charge alone, or with the smaller charges that came with it, fits the bill.
           case when abs(tx.amount - b.amount) <= b.tolerance
                  or (comp.total > 0 and abs(tx.amount + comp.total - b.amount) <= b.tolerance) then 40 else 0 end as s_amount,
           20 as s_date,
           case when n.has_name then 10 else 0 end as s_name,
           (tx.amount = b.amount or (comp.total > 0 and tx.amount + comp.total = b.amount)) as exact,
           n.tx_names_a_bill,
           tx.amount as tx_amount, b.amount as bill_amount, tx.occurred_on
      from tx
      cross join bills b
      join named_any n on n.era_transaction_id = tx.era_transaction_id and n.bill_key = b.bill_key
      cross join lateral (select coalesce(sum(abs(c.amount)), 0) as total
                            from calc._companions_of(tx.era_transaction_id) c
                           where n.has_name) comp
      -- The cycle it would pay: an unpaid one whose window holds the date, the nearest due date first.
      join lateral (
        select c.due_month, c.due_on
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and tx.occurred_on <@ calc._match_window_late(c.cadence, c.every_weeks, c.due_month, c.due_on, b.late_days)
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
             case when s.comp_total > 0 then
               (select 'plus ' || string_agg(format('$%s (%s)', abs(f.amount), f.occurred_on), ' and ' order by f.occurred_on, f.era_transaction_id)
                       || ' from the same merchant within 2 days, recorded with it'
                  from calc._companions_of(s.era_transaction_id) f)
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
           and ci.occurred_on <@ calc._match_window_late(c.cadence, c.every_weeks, c.due_month, c.due_on, b.late_days)
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
    -- A smaller charge from the same merchant whose bill charge is already a ledger payment:
    -- proposed for that same cycle.
    select t.era_transaction_id, pe.bill_key, null::text as pays_account_key, pe.due_month, pe.due_on, 100 as score,
           format('$%s (%s) from the same merchant within 2 days of the %s payment of $%s on %s (ledger payment %s); it counts with the bill',
                  abs(t.amount), t.occurred_on, b.name, pe.amount, pe.paid_on, pe.id) as reason,
           false as card_side, t.occurred_on
      from raw.era_transactions t
      join raw.era_transactions mt
        on mt.era_account_id = t.era_account_id
       and mt.occurred_on between t.occurred_on - 2 and t.occurred_on + 2
       and calc._companion_pair(mt, t)
      join ledger.payments_effective pe on pe.era_transaction_id = mt.era_transaction_id
      join bills b on b.bill_key = pe.bill_key
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

-- ---------------------------------------------------------------- confirm_match

-- As in 20261123140000_card_fee, recording every smaller same-merchant charge with the bill.
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
  v_note   text;
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

  -- Smaller charges from the same merchant within 2 days (a card fee, a split payment) count with
  -- it, each as a payment for the same cycle. One still pending at the bank waits; the matcher
  -- proposes it once the bill is paid.
  if v_tx.amount < 0 then
    for v_fee in select * from calc._companions_of(v_tx.era_transaction_id) loop
      continue when v_fee.pending;
      v_note := case when abs(v_fee.amount) <= round(abs(v_tx.amount) * 0.10, 2) then 'Card fee that came with this bill.'
                     else 'Part of this bill, paid as a separate charge.' end;
      insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, era_transaction_id, proposed_match_id, entered_by, note)
      values (v_match.bill_key, v_match.due_month, v_match.due_on, abs(v_fee.amount), v_fee.occurred_on, v_fee.era_transaction_id,
              v_match.id, v_person, v_note);
      update knowledge.proposed_matches
         set status = 'rejected', decided_at = now(), decided_by = v_person,
             decision_note = 'Recorded with a confirmed bill payment from the same merchant.'
       where era_transaction_id = v_fee.era_transaction_id
         and status in ('pending', 'ambiguous');
    end loop;
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
