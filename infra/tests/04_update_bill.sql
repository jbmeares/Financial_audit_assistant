\set ON_ERROR_STOP 1
\echo '== 04 update_bill keeps the old row'
begin;
\ir _helpers.sql
\ir _fixture.sql

select actions.update_bill('james', 'test-phone', '{"amount": 45.00}', current_date);

select pg_temp.check((select count(*) = 2 from ref.bills where bill_key = 'test-phone'), 'there are now two versions');
select pg_temp.check((select amount = 40.00 and valid_to = current_date from ref.bills where bill_key = 'test-phone' and valid_to is not null),
  'the old version is kept and closed');
select pg_temp.check((select amount = 45.00 and due_day = 5 and autopay from ref.current_bills where bill_key = 'test-phone'),
  'the new version has the change and keeps the other fields');

-- A new bill needs every required field.
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-new', '{"name": "New", "amount": 10}')$$,
  '%Missing: account_key, amount_kind, autopay, cadence, due_day%', 'a new bill with missing fields is refused');
select actions.update_bill('james', 'test-new',
  '{"name": "New", "amount": 10, "amount_kind": "variable", "due_day": 31, "account_key": "test-checking", "autopay": false, "cadence": "monthly"}');
select pg_temp.check(exists (select 1 from ref.current_bills where bill_key = 'test-new'), 'a new bill is created');

-- Bad input is refused by name.
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-phone', '{"colour": "blue"}')$$,
  '%doesn''t know these fields: colour%', 'an unknown field is refused by name');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-phone', '{"due_day": 40}', current_date + 1)$$,
  '%isn''t allowed%', 'a due day of 40 is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-phone', '{"amount": "lots"}', current_date + 2)$$,
  '%right type%', 'a non-number amount is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-phone', '{"account_key": "nope"}', current_date + 3)$$,
  '%Unknown account_key%', 'an unknown account is refused');
select pg_temp.expect_error(null, $$select actions.update_bill('james', 'test-phone', '{"amount": 50}', '2020-01-01')$$,
  '%can''t start before%', 'a change cannot start before the current version');
select pg_temp.check((select count(*) = 2 from ref.bills where bill_key = 'test-phone'), 'refused changes wrote nothing');

-- Ending a bill closes it with no new row.
select actions.update_bill('james', 'test-other', '{}', current_date, true);
select pg_temp.check(not exists (select 1 from ref.current_bills where bill_key = 'test-other'), 'an ended bill is no longer current');
select pg_temp.check((select count(*) = 1 from ref.bills where bill_key = 'test-other'), 'ending keeps the row');

-- An unknown person is refused.
select pg_temp.expect_error(null, $$select actions.update_bill('someone', 'test-phone', '{"amount": 1}')$$,
  '%Say who this is for%', 'an unknown person is refused');
rollback;
