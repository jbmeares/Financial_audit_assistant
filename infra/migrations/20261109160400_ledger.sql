-- C4. ledger: append-only. A trigger refuses every UPDATE, DELETE and TRUNCATE.
-- A mistake gets a row in ledger.voids that points at the original and gives a reason.
-- The only way around the trigger is a migration that drops it, which shows in git.

create function ledger.refuse_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'The ledger is append-only: % on %.% is refused. To cancel a row, void it with a reason.',
    tg_op, tg_table_schema, tg_table_name
    using errcode = 'insufficient_privilege';
end
$$;

create table ledger.payments (
  id                  bigint generated always as identity primary key,
  bill_key            text not null,
  due_month           date not null check (due_month = date_trunc('month', due_month)::date),
  amount              numeric(12, 2) not null check (amount > 0),
  paid_on             date not null,
  era_transaction_id  text,
  proposed_match_id   bigint,
  entered_by          text not null references ref.people (person),
  entered_at          timestamptz not null default now(),
  note                text
);
comment on table ledger.payments is 'A bill is paid only when a row here says so (constitution rule 4).';
comment on column ledger.payments.due_month is 'First day of the month whose bill this payment covers.';
comment on column ledger.payments.era_transaction_id is 'The Era transaction it came from. Not a foreign key, so raw can be rebuilt without touching the ledger.';
create index payments_bill_month on ledger.payments (bill_key, due_month);
create index payments_era_tx on ledger.payments (era_transaction_id);
create trigger payments_bill before insert on ledger.payments
  for each row execute function ref.require_key('bill_key', 'ref.bills', 'bill_key', 'any');

create table ledger.balance_statements (
  id           bigint generated always as identity primary key,
  account_key  text not null,
  balance      numeric(12, 2) not null,
  as_of        timestamptz not null,
  entered_by   text not null references ref.people (person),
  entered_at   timestamptz not null default now(),
  note         text
);
comment on table ledger.balance_statements is 'A balance someone stated. It beats Era until Era reports a newer one (rule 3).';
create index balance_statements_account on ledger.balance_statements (account_key, as_of desc);
create trigger balance_statements_account before insert on ledger.balance_statements
  for each row execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'any');

create table ledger.adjustments (
  id            bigint generated always as identity primary key,
  account_key   text,
  bill_key      text,
  amount        numeric(12, 2) not null,
  effective_on  date not null,
  reason        text not null check (length(trim(reason)) > 0),
  entered_by    text not null references ref.people (person),
  entered_at    timestamptz not null default now(),
  check (account_key is not null or bill_key is not null)
);
comment on table ledger.adjustments is 'Named in Design v1 without detail. No action writes here yet; only the owner role can, in Claude Code.';
create trigger adjustments_account before insert on ledger.adjustments
  for each row execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'any');
create trigger adjustments_bill before insert on ledger.adjustments
  for each row execute function ref.require_key('bill_key', 'ref.bills', 'bill_key', 'any');

create table ledger.voids (
  id                    bigint generated always as identity primary key,
  payment_id            bigint unique references ledger.payments (id),
  balance_statement_id  bigint unique references ledger.balance_statements (id),
  adjustment_id         bigint unique references ledger.adjustments (id),
  reason                text not null check (length(trim(reason)) > 0),
  entered_by            text not null references ref.people (person),
  entered_at            timestamptz not null default now(),
  check (num_nonnulls(payment_id, balance_statement_id, adjustment_id) = 1)
);
comment on table ledger.voids is 'Cancels exactly one ledger row, with a reason. The original stays.';

do $$
declare
  t text;
begin
  foreach t in array array['payments', 'balance_statements', 'adjustments', 'voids'] loop
    execute format('create trigger %I before update or delete on ledger.%I for each row execute function ledger.refuse_change()', t || '_append_only', t);
    execute format('create trigger %I before truncate on ledger.%I for each statement execute function ledger.refuse_change()', t || '_no_truncate', t);
  end loop;
end
$$;
