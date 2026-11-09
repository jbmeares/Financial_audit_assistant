-- C6. calc: rebuilt by SQL, never edited. Block E writes the functions that fill these
-- tables and may reshape them with a new migration. The columns are a starting point.

create table calc.bill_cycles (
  bill_key           text not null,
  due_month          date not null,
  due_on             date not null,
  expected_amount    numeric(12, 2) not null,
  status             text not null check (status in ('paid', 'pending_match', 'not_seen_yet', 'late')),
  payment_id         bigint,
  proposed_match_id  bigint,
  refreshed_at       timestamptz not null default now(),
  primary key (bill_key, due_month)
);

create table calc.cash_projection (
  account_key   text not null,
  day           date not null,
  opening       numeric(12, 2) not null,
  money_in      numeric(12, 2) not null default 0,
  money_out     numeric(12, 2) not null default 0,
  closing       numeric(12, 2) not null,
  below_zero    boolean generated always as (closing < 0) stored,
  refreshed_at  timestamptz not null default now(),
  primary key (account_key, day)
);

create table calc.debt_snapshot (
  debt_key              text primary key,
  account_key           text not null,
  balance               numeric(12, 2),
  balance_as_of         timestamptz,
  apr                   numeric(6, 3),
  minimum_payment       numeric(12, 2),
  est_monthly_interest  numeric(12, 2),
  payoff_priority       smallint,
  refreshed_at          timestamptz not null default now()
);

create table calc.briefing (
  id              boolean primary key default true check (id),
  generated_at    timestamptz not null default now(),
  numbers_as_of   timestamptz,
  level           text check (level in ('RED', 'YELLOW', 'GREEN')),
  items           jsonb not null default '[]'::jsonb
);
comment on table calc.briefing is 'Exactly one row: today''s picture.';

-- Placeholder until Block E. record_balance and void_entry call it so the projection is
-- re-run when a balance is stated or a ledger row is voided.
create function calc.refresh_all() returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Block E replaces this body: bill cycles, matcher, cash projection, debt snapshot, briefing.
  return;
end
$$;
