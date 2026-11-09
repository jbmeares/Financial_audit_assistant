-- C3. ref: what the household told us is true.
-- Every row has valid_from and valid_to (exclusive). A change closes the old row and adds
-- a new one, so history is kept. A row is in effect on day d when
--   valid_from <= d and (valid_to is null or d < valid_to).
-- Each versioned table has a stable *_key (for example 'phone') shared by all its versions,
-- and at most one open version (valid_to is null) per key.

-- Checks that a key column points at a row that exists.
-- Trigger arguments: column, target table, target key column, mode ('current' or 'any'),
-- and optionally one extra literal value that is always allowed (for example 'joint').
create function ref.require_key() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_value text := to_jsonb(new) ->> tg_argv[0];
  v_ok    boolean;
begin
  if v_value is null or (tg_nargs > 4 and v_value = tg_argv[4]) then
    return new;
  end if;
  if tg_argv[3] = 'current' then
    execute format('select exists (select 1 from %s where %I = $1 and valid_to is null)', tg_argv[1], tg_argv[2])
      into v_ok using v_value;
  else
    execute format('select exists (select 1 from %s where %I = $1)', tg_argv[1], tg_argv[2])
      into v_ok using v_value;
  end if;
  if not v_ok then
    raise exception 'Unknown %: "%". It isn''t in %.', tg_argv[0], v_value, tg_argv[1]
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end
$$;

create table ref.people (
  person        text primary key check (person ~ '^[a-z][a-z0-9_]*$'),
  display_name  text not null,
  valid_from    date not null default current_date,
  valid_to      date,
  created_at    timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);

insert into ref.people (person, display_name) values
  ('james', 'James'),
  ('katelyn', 'Katelyn');

create table ref.accounts (
  id              bigint generated always as identity primary key,
  account_key     text not null check (account_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  era_account_id  text,
  name            text not null,
  owner           text not null,
  kind            text not null check (kind in ('checking', 'savings', 'card', 'loan')),
  role            text,
  note            text,
  valid_from      date not null default current_date,
  valid_to        date,
  created_at      timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on column ref.accounts.era_account_id is 'The Era account this maps to. Null for an account Era doesn''t see.';
comment on column ref.accounts.owner is 'A person key from ref.people, or ''joint''.';
comment on column ref.accounts.role is 'What the account is for, in words (for example, which one pays bills).';
create unique index accounts_one_open on ref.accounts (account_key) where valid_to is null;
create unique index accounts_era_one_open on ref.accounts (era_account_id) where valid_to is null and era_account_id is not null;
create trigger accounts_owner before insert or update of owner on ref.accounts
  for each row execute function ref.require_key('owner', 'ref.people', 'person', 'current', 'joint');

create table ref.bills (
  id              bigint generated always as identity primary key,
  bill_key        text not null check (bill_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  name            text not null,
  amount          numeric(12, 2) not null check (amount >= 0),
  amount_kind     text not null check (amount_kind in ('fixed', 'variable')),
  tolerance       numeric(12, 2) check (tolerance >= 0),
  due_day         smallint not null check (due_day between 1 and 31),
  account_key     text not null,
  autopay         boolean not null,
  cadence         text not null check (cadence in ('monthly', 'quarterly', 'semiannual', 'annual')),
  cadence_anchor  date,
  note            text,
  valid_from      date not null default current_date,
  valid_to        date,
  created_at      timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (cadence = 'monthly' or cadence_anchor is not null)
);
comment on column ref.bills.tolerance is 'How far a payment can be from amount and still match, in dollars. Null uses the matcher default for amount_kind.';
comment on column ref.bills.due_day is 'Day of the month it is due. Past the end of a short month, it moves to the last day.';
comment on column ref.bills.account_key is 'The account it is paid from.';
comment on column ref.bills.cadence_anchor is 'One known due date, needed when cadence is not monthly.';
create unique index bills_one_open on ref.bills (bill_key) where valid_to is null;
create trigger bills_account before insert or update of account_key on ref.bills
  for each row execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'current');

create table ref.bill_aliases (
  id          bigint generated always as identity primary key,
  bill_key    text not null,
  alias       text not null check (length(trim(alias)) > 0),
  valid_from  date not null default current_date,
  valid_to    date,
  created_at  timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on table ref.bill_aliases is 'Names a bill shows up as in transactions.';
create unique index bill_aliases_one_open on ref.bill_aliases (bill_key, lower(alias)) where valid_to is null;
create trigger bill_aliases_bill before insert or update of bill_key on ref.bill_aliases
  for each row execute function ref.require_key('bill_key', 'ref.bills', 'bill_key', 'any');

create table ref.debts (
  id               bigint generated always as identity primary key,
  debt_key         text not null check (debt_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  account_key      text not null,
  apr              numeric(6, 3) not null check (apr between 0 and 100),
  minimum_payment  numeric(12, 2) not null check (minimum_payment >= 0),
  promo_end_on     date,
  payoff_priority  smallint check (payoff_priority > 0),
  note             text,
  valid_from       date not null default current_date,
  valid_to         date,
  created_at       timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on column ref.debts.apr is 'Annual rate in percent, for example 24.990.';
comment on column ref.debts.payoff_priority is '1 is paid off first.';
create unique index debts_one_open on ref.debts (debt_key) where valid_to is null;
create trigger debts_account before insert or update of account_key on ref.debts
  for each row execute function ref.require_key('account_key', 'ref.accounts', 'account_key', 'current');

create table ref.income_sources (
  id                   bigint generated always as identity primary key,
  income_key           text not null check (income_key ~ '^[a-z0-9][a-z0-9_-]*$'),
  person               text not null references ref.people (person),
  name                 text not null,
  amount               numeric(12, 2) not null check (amount > 0),
  cadence              text not null check (cadence in ('monthly', 'biweekly')),
  anchor_pay_date      date not null,
  deposit_account_key  text not null,
  note                 text,
  valid_from           date not null default current_date,
  valid_to             date,
  created_at           timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on column ref.income_sources.anchor_pay_date is 'One known pay date. Future pay dates are counted forward from it.';
create unique index income_sources_one_open on ref.income_sources (income_key) where valid_to is null;
create trigger income_sources_account before insert or update of deposit_account_key on ref.income_sources
  for each row execute function ref.require_key('deposit_account_key', 'ref.accounts', 'account_key', 'current');

create table ref.api_keys (
  id          bigint generated always as identity primary key,
  key_name    text not null check (key_name ~ '^[a-z0-9][a-z0-9_-]*$'),
  scope       text not null,
  expires_on  date not null,
  note        text,
  valid_from  date not null default current_date,
  valid_to    date,
  created_at  timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
comment on table ref.api_keys is 'Which keys exist and when they expire. Never the key itself: keys live in Supabase secrets.';
create unique index api_keys_one_open on ref.api_keys (key_name) where valid_to is null;
