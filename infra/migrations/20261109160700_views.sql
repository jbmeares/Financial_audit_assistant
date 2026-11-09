-- Read views. security_invoker means each view runs with the reader's own rights,
-- so row security and grants still apply.

create view ref.current_accounts with (security_invoker = true) as
  select * from ref.accounts
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

create view ref.current_bills with (security_invoker = true) as
  select * from ref.bills
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

create view ref.current_bill_aliases with (security_invoker = true) as
  select * from ref.bill_aliases
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

create view ref.current_debts with (security_invoker = true) as
  select * from ref.debts
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

create view ref.current_income_sources with (security_invoker = true) as
  select * from ref.income_sources
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

create view ref.current_api_keys with (security_invoker = true) as
  select *, expires_on - current_date as days_left from ref.api_keys
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- Ledger rows that haven't been voided.
create view ledger.payments_effective with (security_invoker = true) as
  select p.* from ledger.payments p
  where not exists (select 1 from ledger.voids v where v.payment_id = p.id);

create view ledger.balance_statements_effective with (security_invoker = true) as
  select b.* from ledger.balance_statements b
  where not exists (select 1 from ledger.voids v where v.balance_statement_id = b.id);

create view ledger.adjustments_effective with (security_invoker = true) as
  select a.* from ledger.adjustments a
  where not exists (select 1 from ledger.voids v where v.adjustment_id = a.id);
