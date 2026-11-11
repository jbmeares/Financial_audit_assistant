-- James re-added both Chase logins in Era on 2026-11-11 (Katelyn's, to fix the Amazon card stuck
-- at Aug 15, then his own). Every Chase account came back with a new Era id, and every
-- transaction with a new id too. Three cards also came back with new numbers:
-- Katelyn's Amazon 1525 -> 4639, James's Amazon 3328 -> 8104, Chase Card 5804 -> 8115.
--
-- Left alone, the nightly pull would store the last 30 days of Chase transactions a second time
-- under the new ids, and the matcher would propose bills that are already paid.
--
-- The fix, for this reconnect and any later one:
--   * raw.era_account_replacements says which new Era account replaces which old one, and the
--     cutover date: the old account's transactions are used before it, the new account's from it.
--   * ingest_transactions marks a new account's transactions from before the cutover as removed
--     on arrival, and keeps them removed every night after. Nothing is deleted.
--   * The old accounts' rows from the cutover on are marked removed once, here.
--   * ref.accounts points each account at its new Era id (old row closed, new row added).
--
-- Cutover per account: the day after the old account's last posted transaction, moved earlier to
-- its first still-pending one (a pending charge never settles on a dead account, so the new
-- account's copy is the one to keep), and never earlier than the day after a transaction already
-- recorded as a payment in the ledger.

create table raw.era_account_replacements (
  old_era_account_id  text primary key,
  new_era_account_id  text not null unique,
  cutover             date not null,
  note                text,
  created_at          timestamptz not null default now(),
  check (old_era_account_id <> new_era_account_id)
);
comment on table raw.era_account_replacements is
  'An Era account that replaced another (a reconnect gives new ids). Old account''s transactions count before cutover, the new one''s from cutover.';

alter table raw.era_account_replacements enable row level security;
create policy ingest_writes on raw.era_account_replacements for all to ingest using (true) with check (true);
grant select on raw.era_account_replacements to ingest;

-- True when a transaction on this account and date is covered by the account it replaced.
create function raw.is_superseded(p_era_account_id text, p_occurred_on date)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from raw.era_account_replacements r
                  where r.new_era_account_id = p_era_account_id and p_occurred_on < r.cutover);
$$;
revoke all on function raw.is_superseded(text, date) from public, anon, authenticated;
grant execute on function raw.is_superseded(text, date) to ingest;

-- ingest_transactions from 20261109163152_pull_functions, with one change: a transaction that
-- raw.is_superseded covers arrives removed and stays removed, instead of being brought back.
create or replace function raw.ingest_transactions(p_run bigint, p_rows jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_new int := 0;
  v_changed int := 0;
  v_total int := 0;
begin
  drop table if exists _incoming_tx;
  create temp table _incoming_tx (
    id text primary key, account_id text, payload jsonb, hash text,
    amount numeric(12, 2), occurred_on date, pending boolean, merchant text
  ) on commit drop;

  insert into _incoming_tx
  select distinct on (r->>'id')
         r->>'id', r->>'account_id', r->'payload', md5((r->'payload')::text),
         (r->>'amount')::numeric, (r->>'occurred_on')::date, (r->>'pending')::boolean, r->>'merchant'
    from jsonb_array_elements(p_rows) r;
  get diagnostics v_total = row_count;

  -- A transaction from an account Era didn't list (hidden or disconnected) still gets kept:
  -- its account is added as a stub, marked so, until Era lists it.
  insert into raw.era_accounts (era_account_id, payload, content_hash, last_pull_run_id)
  select distinct i.account_id, '{"unlisted": true}'::jsonb, md5('{"unlisted": true}'), p_run
    from _incoming_tx i
   where not exists (select 1 from raw.era_accounts a where a.era_account_id = i.account_id);

  select count(*) filter (where t.era_transaction_id is null),
         count(*) filter (where t.era_transaction_id is not null and t.content_hash <> i.hash)
    into v_new, v_changed
    from _incoming_tx i
    left join raw.era_transactions t on t.era_transaction_id = i.id;

  insert into raw.era_transactions as t
         (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant,
          last_pull_run_id, removed_at)
  select id, account_id, payload, hash, amount, occurred_on, pending, merchant, p_run,
         case when raw.is_superseded(account_id, occurred_on) then now() end
    from _incoming_tx
  on conflict (era_transaction_id) do update
     set era_account_id   = excluded.era_account_id,
         payload          = case when t.content_hash <> excluded.content_hash then excluded.payload else t.payload end,
         amount           = case when t.content_hash <> excluded.content_hash then excluded.amount else t.amount end,
         occurred_on      = case when t.content_hash <> excluded.content_hash then excluded.occurred_on else t.occurred_on end,
         pending          = case when t.content_hash <> excluded.content_hash then excluded.pending else t.pending end,
         merchant         = case when t.content_hash <> excluded.content_hash then excluded.merchant else t.merchant end,
         content_hash     = excluded.content_hash,
         last_seen_at     = now(),
         removed_at       = case when raw.is_superseded(excluded.era_account_id, excluded.occurred_on)
                                 then coalesce(t.removed_at, now()) end,
         last_pull_run_id = p_run;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'unchanged', v_total - v_new - v_changed);
end
$$;

-- ---------------------------------------------------------------- the 2026-11-11 Chase reconnect

create temp table _chase (account_key text, old_id text, new_id text, new_name text) on commit drop;
insert into _chase values
  ('joint-checking',   'uagr_8k3KTkbp234', 'uagr_1t082JFn1yl', null),
  ('bill-pay',         'uagr_BzrV82Icj3z', 'uagr_5DBVipY8tyh', null),
  ('james-personal',   'uagr_FCNfNkdTrwY', 'uagr_KuKZPy5LzjN', null),
  ('emergency-fund',   'uagr_5qzxj8yScNO', 'uagr_5GIvfrjejYq', null),
  ('james-brokerage',  'uagr_K3ri4RiR47w', 'uagr_Dkj3rnblyxu', null),
  ('katelyn-personal', 'uagr_KJRKVHytXqL', 'uagr_6zxskqF29Kl', null),
  ('amazon-card-3328', 'uagr_290naw4Ry59', 'uagr_7VRfqDhj5V0', 'Chase Amazon Card 8104 (was 3328)'),
  ('chase-card-5804',  'uagr_KfqZKo5xYZg', 'uagr_Fj4pLcvqIDC', 'Chase Card 8115 (was 5804)'),
  ('amazon-card-1525', 'uagr_Cm33jCy8Fzk', 'uagr_CI4f4I5qnnJ', 'Chase Amazon 4639 (was 1525)');

insert into raw.era_account_replacements (old_era_account_id, new_era_account_id, cutover, note)
select c.old_id, c.new_id,
       greatest(
         coalesce(least(max(t.occurred_on) filter (where not t.pending) + 1,
                        min(t.occurred_on) filter (where t.pending)),
                  current_date),
         coalesce(max(t.occurred_on) filter (where exists (select 1 from ledger.payments p
                                                             where p.era_transaction_id = t.era_transaction_id)) + 1,
                  '-infinity'::date)),
       'Chase login re-added in Era 2026-11-11 (' || c.account_key || ')'
  from _chase c
  left join raw.era_transactions t on t.era_account_id = c.old_id and t.removed_at is null
 where exists (select 1 from ref.accounts a where a.era_account_id = c.old_id)
 group by c.old_id, c.new_id, c.account_key;

-- The old accounts' rows from the cutover on: the new account's copies take over.
update raw.era_transactions t
   set removed_at = now()
  from raw.era_account_replacements r
 where t.era_account_id = r.old_era_account_id
   and t.occurred_on >= r.cutover
   and t.removed_at is null;

-- Any new-account rows already pulled from before the cutover.
update raw.era_transactions t
   set removed_at = now()
 where raw.is_superseded(t.era_account_id, t.occurred_on)
   and t.removed_at is null;

-- ref.accounts: a row that only started today just takes the new id. An older one is closed and
-- the same account is added again on its new Era id.
update ref.accounts a
   set era_account_id = c.new_id, name = coalesce(c.new_name, a.name)
  from _chase c
 where a.account_key = c.account_key and a.era_account_id = c.old_id
   and a.valid_to is null and a.valid_from >= current_date;

update ref.accounts a
   set valid_to = current_date
  from _chase c
 where a.account_key = c.account_key and a.era_account_id = c.old_id
   and a.valid_to is null and a.valid_from < current_date;

insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, note, connection, valid_from)
select a.account_key, c.new_id, coalesce(c.new_name, a.name), a.owner, a.kind, a.role,
       case when c.new_name is not null
            then 'Chase issued a new card number; Era id changed when the Chase login was re-added 2026-11-11'
            else 'Era id changed when the Chase login was re-added 2026-11-11' end,
       a.connection, current_date
  from ref.accounts a
  join _chase c on c.account_key = a.account_key and c.old_id = a.era_account_id
 where a.valid_to = current_date
on conflict do nothing;
