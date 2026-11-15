-- local-test: skip (live data: the household's bills)
--
-- Two due dates James gave on 2026-11-15 (thread "End Weight Watchers and add Pay in 4"). Both
-- bills were scheduled earlier than the money will leave Bill Pay, so the projection showed Bill
-- Pay below zero before the Nov 20 transfer. Data only: no schema change and no DROP statements.
-- valid_to is exclusive throughout.
--
-- 1. T-Mobile comes out on the 20th, not the 18th (bank data: Oct 20, Sep 21, Aug 18). This is
--    a lasting change: the open version closes today and an identical one with due day 20 starts.
-- 2. James is holding two card minimums until Nov 20, this cycle only: his CareCredit (due the
--    10th, not yet paid) and Capital One Platinum (due the 15th). For each, three versions: the
--    current one ends on its November due date, a one-off version due the 20th runs to Nov 20,
--    and the usual version picks up again on Nov 21, so December is due on the usual day.

-- 1. T-Mobile on the 20th.
update ref.bills set valid_to = '2026-11-15' where bill_key = 'phone' and valid_to is null;
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
                       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note, valid_from)
select bill_key, name, amount, amount_kind, tolerance, 20, account_key, autopay, cadence,
       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key,
       concat_ws('. ', note, 'Comes out on the 20th (James, 2026-11-15)'), '2026-11-15'
  from ref.bills where bill_key = 'phone' and valid_to = '2026-11-15';

-- 2. CareCredit (James) held to Nov 20 this month only.
update ref.bills set valid_to = '2026-11-10' where bill_key = 'card-carecredit-james' and valid_to is null;
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
                       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note,
                       valid_from, valid_to)
select bill_key, name, amount, amount_kind, tolerance, 20, account_key, autopay, cadence,
       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key,
       concat_ws('. ', note, 'November only: held to Nov 20 (James, 2026-11-15)'), '2026-11-10', '2026-11-21'
  from ref.bills where bill_key = 'card-carecredit-james' and valid_to = '2026-11-10';
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
                       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note, valid_from)
select bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note, '2026-11-21'
  from ref.bills where bill_key = 'card-carecredit-james' and valid_to = '2026-11-10';

-- 3. Capital One Platinum held to Nov 20 this month only.
update ref.bills set valid_to = '2026-11-15' where bill_key = 'card-capone-platinum' and valid_to is null;
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
                       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note,
                       valid_from, valid_to)
select bill_key, name, amount, amount_kind, tolerance, 20, account_key, autopay, cadence,
       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key,
       concat_ws('. ', note, 'November only: held to Nov 20 (James, 2026-11-15)'), '2026-11-15', '2026-11-21'
  from ref.bills where bill_key = 'card-capone-platinum' and valid_to = '2026-11-15';
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
                       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note, valid_from)
select bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay, cadence,
       cadence_anchor, every_weeks, income_key, category, basic_necessity, pays_account_key, note, '2026-11-21'
  from ref.bills where bill_key = 'card-capone-platinum' and valid_to = '2026-11-15';

select calc.refresh_all();
