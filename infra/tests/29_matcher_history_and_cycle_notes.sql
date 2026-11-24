\set ON_ERROR_STOP 1
\echo '== 29 each bill''s history widens the matcher; one-month changes are notes on a cycle'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- ---------------------------------------------------------------- amount range from history

-- Gym is fixed at $60. Last month it was confirmed at $64.50, so a $63 charge now fits.
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('gym', 'iron gym', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  ('h-gym-jan', 'era-chk', '{}', 'h', -64.50, '2026-01-12', false, 'IRON GYM'),
  ('h-gym-feb', 'era-chk', '{}', 'h', -63.00, '2026-02-09', false, 'IRON GYM');
select pg_temp.check(calc._bill_amount_spread('gym', 60.00, '2026-02-10') = 0, 'no history, no spread');
insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, era_transaction_id, entered_by)
values ('gym', '2026-01-01', '2026-01-12', 64.50, '2026-01-12', 'h-gym-jan', 'james');
select pg_temp.check(calc._bill_amount_spread('gym', 60.00, '2026-02-10') = 4.50, 'the spread is how far a confirmed payment strayed');
select pg_temp.check(calc._bill_amount_spread('gym', 60.00, '2027-03-01') = 0, 'only the last year counts');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select reason like '%amount 40 ($63.00 paid, bill $60.00)%' from knowledge.proposed_matches
                       where era_transaction_id = 'h-gym-feb' and bill_key = 'gym'),
  'a fixed bill matches within the range it has actually been paid at');

-- A tolerance someone set still wins.
update ref.bills set tolerance = 1.00 where bill_key = 'gym';
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('h-gym-mar', 'era-chk', '{}', 'h', -63.00, '2026-03-11', false, 'IRON GYM');
select calc.refresh_all(null, '2026-03-12');
select pg_temp.check(coalesce((select reason like '%amount 0 %' from knowledge.proposed_matches where era_transaction_id = 'h-gym-mar' and bill_key = 'gym'), true),
  'a tolerance someone set beats the history');

-- ---------------------------------------------------------------- late-running bills

select pg_temp.check(calc._bill_late_days('power', '2026-02-10') = 0, 'no late history, no extra days');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('h-power-late', 'era-chk', '{}', 'h', -100.00, '2026-01-27', false, 'CITY POWER');
insert into ledger.payments (bill_key, due_month, due_on, amount, paid_on, era_transaction_id, entered_by)
values ('power', '2025-12-01', '2025-12-15', 100.00, '2026-01-27', 'h-power-late', 'james');
select pg_temp.check(calc._bill_late_days('power', '2026-02-10') = 14, 'paid 43 days after its due date: capped at 14 extra days');
select pg_temp.check(upper(calc._match_window_late('monthly', null, '2026-02-01', '2026-02-15', 10)) = '2026-03-18'
                     and upper(calc._match_window('monthly', null, '2026-02-01', '2026-02-15')) = '2026-03-08',
  'a late-running monthly bill''s window ends later');
select pg_temp.check(calc._match_window_late('weekly', null, '2026-02-01', '2026-02-10', 10) = calc._match_window('weekly', null, '2026-02-01', '2026-02-10'),
  'a week-based bill''s window doesn''t change');

-- ---------------------------------------------------------------- one-month notes

select calc.refresh_all(null, '2026-02-10');
-- Rent is due Feb 28 (the 31st in a short month). Hold it to the 20th; the next month is unchanged.
select actions.note_bill_cycle('james', 'rent', '2026-02-28', 'holding it until the 20th', '2026-02-20');
select pg_temp.check((select due_on = '2026-02-20' and cycle_note = 'holding it until the 20th' from calc.bill_cycles
                       where bill_key = 'rent' and due_month = '2026-02-01'),
  'a note moves one cycle');
select pg_temp.check((select due_on = '2026-03-31' and cycle_note is null from calc.bill_cycles where bill_key = 'rent' and due_month = '2026-03-01'),
  'the next cycle is unchanged');
select pg_temp.check((select count(*) = 1 from ref.bills where bill_key = 'rent'), 'and the bill gets no new version');
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check(exists (select 1 from calc.cash_projection where day = '2026-02-20' and money_out >= 600)
                     and not exists (select 1 from calc.cash_projection where day = '2026-02-28' and money_out >= 600),
  'the projection takes the money out on the new date');

select actions.note_bill_cycle('james', 'power', '2026-02-15', 'this month is higher', null, 140.00);
select pg_temp.check((select expected_amount = 140 and due_on = '2026-02-15' from calc.bill_cycles where bill_key = 'power' and due_month = '2026-02-01'),
  'a note can change one cycle''s amount');

select actions.note_bill_cycle('katelyn', 'phone', '2026-03-05', 'no phone bill in March, they''re crediting it', null, null, true);
select pg_temp.check(not exists (select 1 from calc.bill_cycles where bill_key = 'phone' and due_month = '2026-03-01'),
  'a skipped cycle isn''t expected');

select actions.note_bill_cycle('james', 'power', '2026-02-15', 'back to normal');
select pg_temp.check((select expected_amount = 100 and cycle_note is null from calc.bill_cycles where bill_key = 'power' and due_month = '2026-02-01'),
  'a note with nothing in it puts the cycle back to normal');

select pg_temp.expect_error(null, $$select actions.note_bill_cycle('james', 'rent', '2026-03-31', 'x', '2026-04-02')$$,
  '%only within its month%', 'a monthly cycle can''t move into another month');
select pg_temp.expect_error(null, $$select actions.note_bill_cycle('james', 'rent', '2026-03-30', 'x', '2026-03-20')$$,
  '%isn''t due on%', 'the cycle has to be named by its normal due date');
select pg_temp.expect_error(null, $$select actions.note_bill_cycle('james', 'rent', '2026-03-31', '  ', '2026-03-20')$$,
  '%Say why%', 'a note needs a reason');
select pg_temp.expect_error(null, $$select actions.note_bill_cycle('james', 'rent', '2026-03-31', 'x', '2026-03-20', null, true)$$,
  '%takes no new date%', 'a skip takes nothing else');
select pg_temp.expect_error(null, $$select actions.note_bill_cycle('james', 'gym', '2026-01-12', 'x', null, 50)$$,
  '%already paid%', 'a paid cycle can''t be noted');
select pg_temp.expect_error(null, $$update ref.bill_cycle_notes set note = 'y'$$,
  '%never changed or deleted%', 'a note is a record');
select pg_temp.expect_error('assistant_read', $$select actions.note_bill_cycle('james', 'rent', '2026-03-31', 'x', '2026-03-20')$$,
  '%permission denied%', 'reads can''t write notes');

rollback;
