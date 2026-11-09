\set ON_ERROR_STOP 1
\echo '== 01 the ledger refuses UPDATE, DELETE and TRUNCATE'
begin;
\ir _helpers.sql
\ir _fixture.sql

insert into ledger.balance_statements (account_key, balance, as_of, entered_by)
values ('test-checking', 100.00, now(), 'james');

select pg_temp.expect_error(null, $$update ledger.balance_statements set balance = 1$$,
  '%append-only%', 'owner UPDATE on ledger is refused');
select pg_temp.expect_error(null, $$delete from ledger.balance_statements$$,
  '%append-only%', 'owner DELETE on ledger is refused');
select pg_temp.expect_error(null, $$truncate ledger.balance_statements cascade$$,
  '%append-only%', 'owner TRUNCATE on ledger is refused');
select pg_temp.expect_error(null, $$truncate ledger.voids$$,
  '%append-only%', 'TRUNCATE on ledger.voids is refused');
select pg_temp.check((select count(*) = 1 from ledger.balance_statements), 'the row is still there');
rollback;
