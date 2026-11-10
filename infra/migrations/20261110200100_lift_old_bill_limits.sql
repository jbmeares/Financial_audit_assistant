-- Lifts the three Block C/E limits that 20261110200000 couldn't, because lifting them takes a DROP
-- and the Supabase confirm dialog for DROP statements doesn't open for James. He runs this one in
-- the SQL editor. Nothing is lost: ref.bills and calc.bill_cycles keep every row, and the
-- bills_schedule check added in 20261110200000 already enforces the new rules.
--
-- 1. bills_cadence_check allowed only monthly, quarterly, semiannual and annual. bills_schedule
--    now lists the cadences.
-- 2. bills_check1 required a cadence_anchor unless monthly. bills_schedule now says which fields
--    each cadence needs (per_paycheck needs income_key, not an anchor).
-- 3. due_day was required. Weekly, biweekly and per-paycheck bills have no day of the month.
-- 4. calc.bill_cycles was keyed one row per bill per month. Weekly, biweekly and per-paycheck
--    bills can fall due more than once a month, so it is keyed by due date instead.

alter table ref.bills drop constraint bills_cadence_check;
alter table ref.bills drop constraint bills_check1;
alter table ref.bills alter column due_day drop not null;

alter table calc.bill_cycles drop constraint bill_cycles_pkey;
alter table calc.bill_cycles add constraint bill_cycles_pkey primary key (bill_key, due_on);
