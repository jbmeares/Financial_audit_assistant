\set ON_ERROR_STOP 1
\echo '== 12 transfers, more bill schedules and bank business days'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- More made-up data on top of the calc fixture (today is Tue 2026-02-10):
--   A bill-pay checking account starting at 1,000.00 (Era, Feb 9).
--   A monthly income of 2,000.00 on the 1st into checking. Mar 1 2026 is a Sunday, so it pays Fri Feb 27.
--   Transfers from checking to bill pay: 700.00 each paycheck, 1,500.00 each monthly payday.
--   Bills from bill pay: 500.00 each paycheck, 200.00 weekly from Mon Feb 2, and 90.00 every other
--   month on the 3rd (Mar, May, ...).
insert into raw.era_accounts (era_account_id, payload, content_hash) values ('era-bp', '{}', 'h');
insert into raw.era_balances (era_account_id, current, available, as_of, payload)
values ('era-bp', 1000.00, 1000.00, '2026-02-09 12:00-05', '{}');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from)
values ('bp', 'era-bp', 'Bill pay', 'joint', 'checking', 'pays bills', '2026-01-01');
insert into ref.income_sources (income_key, person, name, amount, cadence, anchor_pay_date, deposit_account_key, valid_from)
values ('monthly-pay', 'james', 'Monthly pay', 2000.00, 'monthly', '2026-01-01', 'chk', '2026-01-01');
insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence, income_key, valid_from) values
  ('pay-to-bp', 'Paycheck to bill pay', 'chk', 'bp', 700.00, 'per_paycheck', 'pay', '2026-01-01'),
  ('monthly-to-bp', 'Monthly pay to bill pay', 'chk', 'bp', 1500.00, 'per_paycheck', 'monthly-pay', '2026-01-01');
insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, cadence_anchor, income_key, valid_from) values
  ('auto', 'Auto loan', 500.00, 'fixed', null, 'bp', false, 'per_paycheck', null, 'pay', '2026-02-01'),
  ('school', 'School', 200.00, 'fixed', null, 'bp', false, 'weekly', '2026-02-02', null, '2026-02-01'),
  ('trash', 'Trash', 90.00, 'fixed', 3, 'bp', true, 'every_other_month', '2026-01-03', null, '2026-02-01');
insert into ref.bill_aliases (bill_key, alias, valid_from) values ('school', 'little sprouts', '2026-01-01');
insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('tx-school', 'era-bp', '{}', 'h', -200.00, '2026-02-09', false, 'LITTLE SPROUTS');

-- Bank holidays and business days.
select pg_temp.check(calc._is_bank_holiday('2026-11-26') and calc._is_bank_holiday('2026-01-19') and calc._is_bank_holiday('2026-02-16')
                     and calc._is_bank_holiday('2026-05-25') and calc._is_bank_holiday('2026-09-07') and calc._is_bank_holiday('2026-10-12')
                     and calc._is_bank_holiday('2026-11-11') and calc._is_bank_holiday('2026-12-25') and calc._is_bank_holiday('2026-06-19'),
  'Fed holidays are holidays');
select pg_temp.check(calc._is_bank_holiday('2027-07-05') and not calc._is_bank_holiday('2026-07-03'),
  'a holiday on Sunday is kept Monday; one on Saturday isn''t moved to Friday');
select pg_temp.check(not calc._is_bank_holiday('2026-11-27') and not calc._is_bank_holiday('2026-02-09'), 'ordinary days aren''t holidays');
select pg_temp.check(calc._prev_business_day('2026-08-01') = '2026-07-31' and calc._prev_business_day('2027-01-01') = '2026-12-31'
                     and calc._prev_business_day('2026-11-01') = '2026-10-30' and calc._prev_business_day('2026-02-10') = '2026-02-10',
  'weekends and holidays move to the bank business day before');

-- Pay dates move off weekends and holidays.
select pg_temp.check((select array_agg(d order by d) from calc._pay_dates('monthly', '2026-01-01', '2026-07-20', '2026-07-31') d) = '{2026-07-31}',
  'a pay date on Sat Aug 1 is paid Fri Jul 31, inside a range that ends Jul 31');
select pg_temp.check((select array_agg(d order by d) from calc._pay_dates('biweekly', '2026-12-11', '2026-12-20', '2027-01-10') d)
                     = '{2026-12-24,2027-01-08}', 'a Friday paycheck on Christmas is paid Thursday Dec 24');
select pg_temp.check((select array_agg(d order by d) from calc._pay_dates('monthly', '2026-01-01', '2026-11-02', '2026-11-30') d) is null,
  'Sun Nov 1 moves to Oct 30, which is before the range, so it isn''t counted twice');

-- Schedules.
select pg_temp.check((select array_agg(d order by d) from calc._schedule_dates('every_other_month', 3, '2026-01-03', null, '2026-01-01', '2026-06-30') d)
                     = '{2026-01-03,2026-03-03,2026-05-03}', 'every other month counts from its known due date');
select pg_temp.check((select array_agg(d order by d) from calc._schedule_dates('biweekly', null, '2026-02-02', null, '2026-02-01', '2026-03-02') d)
                     = '{2026-02-02,2026-02-16,2026-03-02}', 'biweekly is every 14 days from its known date');
select pg_temp.check((select array_agg(d order by d) from calc._schedule_dates('per_paycheck', null, null, 'monthly-pay', '2026-02-01', '2026-04-30') d)
                     = '{2026-02-27,2026-04-01}', 'per paycheck follows the moved pay dates');

select calc.refresh_all(null, '2026-02-10');

-- Bill cycles.
select pg_temp.check((select array_agg(due_on order by due_on) from calc.bill_cycles where bill_key = 'auto' and due_month = '2026-02-01')
                     = '{2026-02-13,2026-02-27}', 'a per-paycheck bill falls due on each February payday');
select pg_temp.check((select count(*) = 4 from calc.bill_cycles where bill_key = 'school' and due_month = '2026-02-01'),
  'a weekly bill falls due four times in February');
select pg_temp.check((select array_agg(due_on order by due_on) from calc.bill_cycles where bill_key = 'trash') = '{2026-03-03}',
  'every other month: March only, through April');
select pg_temp.check((select cadence = 'weekly' from calc.bill_cycles where bill_key = 'school' and due_on = '2026-02-09'),
  'each cycle says its cadence');

-- The matcher pairs the school payment with the week it pays.
select pg_temp.check((select status = 'pending' and due_on = '2026-02-09' and score = 100 from knowledge.proposed_matches where era_transaction_id = 'tx-school'),
  'the weekly payment is proposed for the Feb 9 cycle');
select pg_temp.check((select status = 'pending_match' from calc.bill_cycles where bill_key = 'school' and due_on = '2026-02-09')
                     and (select status = 'not_seen_yet' from calc.bill_cycles where bill_key = 'school' and due_on = '2026-02-02'),
  'only that week is pending; the week before is still not seen');

-- The projection: transfers move money between the two accounts.
select pg_temp.check((select money_out = 200.00 and closing = 800.00 from calc.cash_projection where account_key = 'bp' and day = '2026-02-10'),
  'the unseen Feb 2 school week comes out today');
select pg_temp.check((select money_in = 700.00 and money_out = 500.00 and closing = 1000.00
                             and detail @> '[{"kind": "transfer", "key": "pay-to-bp", "direction": "in"}, {"kind": "bill", "key": "auto"}]'
                        from calc.cash_projection where account_key = 'bp' and day = '2026-02-13'),
  'on payday the transfer comes in and the auto loan goes out');
select pg_temp.check((select money_in = 1000.00 and money_out = 700.00 and closing = 740.00
                             and detail @> '[{"kind": "transfer", "key": "pay-to-bp", "direction": "out"}]'
                        from calc.cash_projection where account_key = 'chk' and day = '2026-02-13'),
  'and the same transfer leaves checking');
select pg_temp.check((select money_in = 3000.00 and money_out = 2200.00
                             and detail @> '[{"kind": "income", "key": "monthly-pay"}]'
                        from calc.cash_projection where account_key = 'chk' and day = '2026-02-27'),
  'the Mar 1 monthly pay (a Sunday) arrives Fri Feb 27, with both transfers out');
select pg_temp.check((select money_in = 2200.00 and money_out = 500.00 and closing = 2300.00 from calc.cash_projection where account_key = 'bp' and day = '2026-02-27'),
  'bill pay gets both transfers on Feb 27');
select pg_temp.check((select money_out = 90.00 and closing = 2010.00 from calc.cash_projection where account_key = 'bp' and day = '2026-03-03'),
  'the every-other-month bill comes out Mar 3');
select pg_temp.check((select next_income_on = '2026-02-13' from calc.briefing), 'transfers aren''t income in the briefing');

-- Confirming the match pays that week only.
select actions.confirm_match('james', (select id from knowledge.proposed_matches where era_transaction_id = 'tx-school'));
select calc.refresh_all(null, '2026-02-10');
select pg_temp.check((select due_on = '2026-02-09' and due_month = '2026-02-01' from ledger.payments_effective where era_transaction_id = 'tx-school'),
  'the payment records the due date it pays');
select pg_temp.check((select status = 'paid' from calc.bill_cycles where bill_key = 'school' and due_on = '2026-02-09')
                     and (select status = 'not_seen_yet' from calc.bill_cycles where bill_key = 'school' and due_on = '2026-02-16'),
  'that week is paid and the next isn''t');

-- what_if can skip one week.
select pg_temp.check((select (a ->> 'end_change')::numeric = 200.00
                        from jsonb_array_elements(calc.what_if('{"type": "skip_bill", "bill_key": "school", "due_month": "2026-02-01", "due_on": "2026-02-16"}', '2026-02-10') -> 'accounts') a
                       where a ->> 'account_key' = 'bp'), 'skip_bill with due_on skips one week');
select pg_temp.expect_error(null, $$select calc.what_if('{"type": "skip_bill", "bill_key": "school", "due_month": "2026-03-01", "due_on": "2026-02-16"}', '2026-02-10')$$,
  '%isn''t in due_month%', 'a due_on outside its due_month is refused');

-- Each cadence needs its own fields.
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'bad-auto',
  '{"name": "X", "amount": 1, "amount_kind": "fixed", "account_key": "bp", "autopay": false, "cadence": "per_paycheck"}')$$,
  '%per_paycheck (needs income_key)%', 'a per-paycheck bill with no income source is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'bad-week',
  '{"name": "X", "amount": 1, "amount_kind": "fixed", "account_key": "bp", "autopay": false, "cadence": "weekly"}')$$,
  '%weekly or biweekly (need a cadence_anchor date)%', 'a weekly bill with no known date is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'bad-cadence',
  '{"name": "X", "amount": 1, "amount_kind": "fixed", "due_day": 1, "account_key": "bp", "autopay": false, "cadence": "daily"}')$$,
  '%isn''t allowed%', 'an unknown cadence is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'bad-income',
  '{"name": "X", "amount": 1, "amount_kind": "fixed", "account_key": "bp", "autopay": false, "cadence": "per_paycheck", "income_key": "nope"}')$$,
  '%Unknown income_key%', 'a per-paycheck bill on an unknown income source is refused');
select actions.update_bill('james', 'gas-card',
  '{"name": "Gas card", "amount": 50, "amount_kind": "fixed", "account_key": "bp", "autopay": true, "cadence": "per_paycheck", "income_key": "pay"}',
  '2026-02-01');
select pg_temp.check((select due_day is null and income_key = 'pay' from ref.current_bills where bill_key = 'gas-card'),
  'a per-paycheck bill needs no due day');

-- Transfers are checked too.
select pg_temp.expect_error(null, $$insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence, income_key)
                                    values ('loop', 'Loop', 'bp', 'bp', 1, 'per_paycheck', 'pay')$$,
  '%check%', 'a transfer to the same account is refused');
select pg_temp.expect_error(null, $$insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence, income_key)
                                    values ('ghost', 'Ghost', 'nowhere', 'bp', 1, 'per_paycheck', 'pay')$$,
  '%Unknown from_account_key%', 'a transfer from an unknown account is refused');
select pg_temp.expect_error(null, $$insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence)
                                    values ('nodate', 'No date', 'chk', 'bp', 1, 'monthly')$$,
  '%transfers_schedule%', 'a monthly transfer needs a day of the month');
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) from ref.current_transfers') = '2',
  'the chat read role can read transfers');
select pg_temp.expect_error('assistant_read', $$insert into ref.transfers (transfer_key, name, from_account_key, to_account_key, amount, cadence, day_of_month)
                                                values ('x', 'X', 'chk', 'bp', 1, 'monthly', 1)$$,
  '%permission denied%', 'the chat read role can''t write transfers');

rollback;
