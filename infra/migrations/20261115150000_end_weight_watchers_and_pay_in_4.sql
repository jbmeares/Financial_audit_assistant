-- local-test: skip (live data: the household's bills)
--
-- Two bill changes James gave on 2026-11-15 (thread "End Weight Watchers and add Pay in 4").
-- Data only: no schema change and no DROP statements.
--
-- 1. Weight Watchers is cancelled (open question 6, already answered). Its last charge was Oct 3
--    and nothing came on Nov 3. The bill ends on 2026-11-03 (valid_to is exclusive), so the
--    unpaid Nov 3 cycle goes away and the projection stops counting it today and on Dec 3.
--
-- 2. James used Chase Pay in 4 on the Nov 13 Town Creek preschool charge from Bill Pay. The
--    charge came back to Bill Pay, and Chase takes four equal parts from Bill Pay instead, two
--    weeks apart: Nov 29, Dec 13, Dec 27 and Jan 10. Three things follow:
--      a. A new biweekly bill, "preschool-pay-in-4", for exactly those four dates. valid_to is
--         Jan 11 (exclusive), so nothing is scheduled after Jan 10. Tagged like the preschool bill
--         it pays for (kids, a necessity).
--      b. The Nov 13 preschool week counts as paid: a ledger payment with no bank transaction,
--         whose note points at the Pay in 4 bill. Without it the week shows late once Era drops
--         the reversed charge.
--      c. Match 132 (the Nov 13 charge to that week) is rejected for James, so the briefing stops
--         asking him to confirm it and the matcher never proposes that charge for preschool again.
--    The installments match by exact amount on Bill Pay. Once the first one shows up, an alias
--    for its bank description can be added so the name scores too.

-- 1. Weight Watchers ends.
update ref.bills
   set valid_to = '2026-11-03',
       note = concat_ws('. ', note, 'Cancelled; last charge Oct 3, 2026 (James, 2026-11-15)')
 where bill_key = 'weight-watchers' and valid_to is null;

-- 2a. The Pay in 4 installments.
insert into ref.bills (bill_key, name, amount, amount_kind, account_key, autopay, cadence, cadence_anchor,
                       category, basic_necessity, note, valid_from, valid_to)
select 'preschool-pay-in-4', 'Town Creek preschool, Chase Pay in 4', 43.75, 'fixed', 'bill-pay', true,
       'biweekly', '2026-11-29', 'kids', true,
       'Chase Pay in 4 on the Nov 13, 2026 Town Creek charge ($175 back to Bill Pay); four parts, '
       || 'Nov 29, Dec 13, Dec 27 and Jan 10 (James, 2026-11-15)',
       '2026-11-29', '2027-01-11'
 where not exists (select 1 from ref.bills where bill_key = 'preschool-pay-in-4');

-- 2b. The Nov 13 preschool week is paid (through Pay in 4).
insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, entered_by, note)
select 'preschool', '2026-11-01', '2026-11-13', 175.00, '2026-11-13', 'james',
       'James: paid with Chase Pay in 4; the card charge came back and the four parts are bill preschool-pay-in-4'
 where not exists (select 1 from ledger.payments_effective p
                    where p.bill_key = 'preschool' and p.due_on = '2026-11-13');

-- 2c. The reversed charge isn't the payment.
update knowledge.proposed_matches
   set status = 'rejected', decided_at = now(), decided_by = 'james',
       decision_note = 'Reversed: James used Chase Pay in 4 instead (bill preschool-pay-in-4)'
 where id = 132 and bill_key = 'preschool' and due_on = '2026-11-13' and status in ('pending', 'ambiguous');

select calc.refresh_all();
