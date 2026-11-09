-- E. Reshape the calc tables for Block E. They have never held data (refresh_all was a
-- placeholder), so they are dropped and made again with the columns the functions need.
-- calc is rebuilt by refresh_all() and never edited by hand.

drop function calc.refresh_all();
drop table calc.bill_cycles, calc.cash_projection, calc.debt_snapshot, calc.briefing;

-- E2. One row per bill per due month, from the bill's start to two months ahead.
create table calc.bill_cycles (
  bill_key           text not null,
  due_month          date not null check (due_month = date_trunc('month', due_month)::date),
  due_on             date not null,
  bill_name          text not null,
  account_key        text not null,
  amount_kind        text not null,
  autopay            boolean not null,
  expected_amount    numeric(12, 2) not null,
  status             text not null check (status in ('paid', 'pending_match', 'not_seen_yet', 'late')),
  payment_id         bigint,
  proposed_match_id  bigint,
  bill_version_id    bigint not null,
  refreshed_at       timestamptz not null default now(),
  primary key (bill_key, due_month)
);
comment on table calc.bill_cycles is 'Each bill in each due month. paid = a ledger payment exists; pending_match = a proposal waits; late = the month ended unpaid; otherwise not_seen_yet.';
comment on column calc.bill_cycles.bill_version_id is 'The ref.bills row used: the version in effect on the due date.';

-- E4. 60 days per checking and savings account.
create table calc.cash_projection (
  account_key     text not null,
  day             date not null,
  opening         numeric(12, 2) not null,
  money_in        numeric(12, 2) not null default 0,
  money_out       numeric(12, 2) not null default 0,
  closing         numeric(12, 2) not null,
  below_zero      boolean generated always as (closing < 0) stored,
  detail          jsonb not null default '[]'::jsonb,
  refreshed_at    timestamptz not null default now(),
  primary key (account_key, day)
);
comment on column calc.cash_projection.detail is 'What moves that day: [{kind: income|bill|change, key, name, amount}]. Money out is positive.';

-- The starting point of each account's projection, and any account left out.
create table calc.account_balances (
  account_key  text primary key,
  name         text not null,
  kind         text not null,
  balance      numeric(12, 2),
  as_of        timestamptz,
  source       text check (source in ('era', 'stated')),
  stale        boolean not null,
  refreshed_at timestamptz not null default now()
);
comment on table calc.account_balances is 'The balance each projection and debt starts from: the newer of Era''s and a stated one (rule 3). balance is null when there is none; such an account is left out and named in the briefing.';

-- E5.
create table calc.debt_snapshot (
  debt_key              text primary key,
  account_key           text not null,
  balance               numeric(12, 2),
  balance_as_of         timestamptz,
  balance_source        text check (balance_source in ('era', 'stated')),
  stale                 boolean not null,
  apr                   numeric(6, 3) not null,
  minimum_payment       numeric(12, 2) not null,
  est_monthly_interest  numeric(12, 2),
  promo_end_on          date,
  payoff_priority       smallint,
  refreshed_at          timestamptz not null default now()
);
comment on column calc.debt_snapshot.balance is 'Amount owed, as a positive number. Null when no balance is known: named in the briefing, never guessed.';

-- E6.
create table calc.briefing (
  id              boolean primary key default true check (id),
  generated_at    timestamptz not null default now(),
  today           date not null,
  numbers_as_of   timestamptz,
  level           text not null check (level in ('RED', 'YELLOW', 'GREEN')),
  next_income_on  date,
  items           jsonb not null default '[]'::jsonb
);
comment on table calc.briefing is 'Exactly one row: today''s picture. items are [{level, kind, text, data}], RED first.';
comment on column calc.briefing.numbers_as_of is 'When the last good pull finished. Null means no pull has finished yet.';

-- E1. One row per refresh attempt, kept so a failure is never silent.
create table calc.refresh_runs (
  id           bigint generated always as identity primary key,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  today        date not null,
  pull_run_id  bigint,
  ok           boolean,
  error        text,
  counts       jsonb not null default '{}'::jsonb
);
comment on table calc.refresh_runs is 'Every refresh_all() call. ok = false means the step failed and the previous numbers were kept.';

-- Same access as the other calc tables: read by assistant_read, nothing for anyone else.
do $$
declare
  t text;
begin
  foreach t in array array['bill_cycles', 'cash_projection', 'account_balances', 'debt_snapshot', 'briefing', 'refresh_runs'] loop
    execute format('revoke all on calc.%I from anon, authenticated, public', t);
    execute format('grant select on calc.%I to assistant_read', t);
    execute format('alter table calc.%I enable row level security', t);
    execute format('create policy assistant_reads on calc.%I for select to assistant_read using (true)', t);
  end loop;
end
$$;
