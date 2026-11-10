-- Task 19 follow-up: the matcher on real data.
--
-- The first real run proposed almost any Bill Pay outflow near a bill's amount, because account
-- (30) + amount (40) + date (20) reached 70 with no name at all: a Netflix charge for the
-- Anthropic bill, a Chase overdraft fee for a Chase card minimum, a OneMain payment for the
-- electric bill, and transfers between the household's own checking accounts. It also
-- proposed payments that fell outside every cycle's date window, which attached October
-- payments to November and December.
--
-- New rules, on top of the same 100-point score (see data/calculations.md):
--   1. Not a bill payment, never proposed: a transfer to another of the household's checking or
--      savings accounts, a fee (overdraft, late, ...), or an interest charge. Card payments are
--      transfers too, but to a card, so they stay in.
--   2. The payment must fall inside the cycle's date window (7 days before to 7 days after the
--      due month). A payment outside every window waits for a person.
--   3. It needs a name (an alias or an Era bill: tag) or the exact amount from the bill's own
--      account. Near the amount with no name is not enough.
--   4. When a transaction names one or more bills, only those bills are considered.
--   5. A payment closer to the bill's previous due date than to this cycle's is left alone: it
--      paid the earlier one. (October's payments made just inside November's window no longer
--      land on November when tracking starts in November.)
-- The name also counts when the alias is in Era's description, not only the merchant name.
--
-- Withdrawn proposals: a proposal can be withdrawn by setting it to rejected with no person in
-- decided_by (reject_match always names a person). A withdrawn pairing can be proposed again; only
-- a person's no is permanent. This is how the proposals made under the old rules were cleared,
-- because removing rows needs the Supabase confirm dialog, which doesn't open for James.
-- Nothing here needs that dialog.

-- Why a money-out transaction can't be a bill payment, or null when it can be.
create or replace function calc._not_a_bill_reason(p_payload jsonb, p_today date) returns text
language sql stable set search_path = ''
as $$
  select case
    when exists (
           select 1 from ref.accounts a
            where a.era_account_id = p_payload #>> '{transferLink,counterpartAccountGroupKey}'
              and a.kind in ('checking', 'savings')
              and a.valid_from <= p_today and (a.valid_to is null or a.valid_to > p_today))
      or coalesce(p_payload ->> 'description', '') ~* '^online transfer to (checking|savings|chk|sav)\M'
      then 'transfer between own accounts'
    when concat_ws(' ', p_payload ->> 'description', p_payload ->> 'originalDescription') ~* '\mfees?\M'
      then 'fee'
    when concat_ws(' ', p_payload ->> 'description', p_payload ->> 'originalDescription') ~* '\m(interest|finance charge)\M'
      then 'interest'
  end
$$;

create or replace function calc._run_matcher(p_today date) returns int
language plpgsql set search_path = ''
as $$
declare
  v_count int;
begin
  insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
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
           case b.cadence when 'quarterly' then 3 when 'semiannual' then 6 when 'annual' then 12 else 1 end as months_apart,
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
    select tx.era_transaction_id, b.bill_key, cy.due_month,
           case when b.era_account_id = tx.era_account_id then 30 else 0 end as s_account,
           case when abs(tx.amount - b.amount) <= b.tolerance then 40 else 0 end as s_amount,
           20 as s_date,
           case when n.has_name then 10 else 0 end as s_name,
           tx.amount = b.amount as exact,
           n.tx_names_a_bill,
           tx.amount as tx_amount, b.amount as bill_amount, tx.occurred_on, cy.due_on
      from tx
      cross join bills b
      join named_any n on n.era_transaction_id = tx.era_transaction_id and n.bill_key = b.bill_key
      -- The cycle it would pay: an unpaid one whose window holds the date, the nearest due date first.
      join lateral (
        select c.due_month, c.due_on
          from calc.bill_cycles c
         where c.bill_key = b.bill_key
           and c.status <> 'paid'
           and tx.occurred_on between c.due_month - 7 and calc._month_end(c.due_month) + 7
           and abs(tx.occurred_on - c.due_on) <= abs(tx.occurred_on - (c.due_on - make_interval(months => b.months_apart))::date)
         order by abs(tx.occurred_on - c.due_on), c.due_month
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
  select r.era_transaction_id, r.bill_key, r.due_month, r.score,
         concat_ws('; ',
           'account ' || r.s_account,
           format('amount %s ($%s paid, bill $%s)', r.s_amount, r.tx_amount, r.bill_amount),
           format('date %s (%s, due %s)', r.s_date, r.occurred_on, r.due_on),
           'name ' || r.s_name),
         case when r.tied > 1 then 'ambiguous' else 'pending' end
    from ranked r
   where r.score = r.top
  on conflict (era_transaction_id, bill_key) do update
     set due_month = excluded.due_month, score = excluded.score, reason = excluded.reason,
         status = excluded.status, created_at = now(), decided_at = null, decision_note = null
   where knowledge.proposed_matches.status = 'rejected' and knowledge.proposed_matches.decided_by is null;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;
