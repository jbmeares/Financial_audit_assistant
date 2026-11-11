-- A disconnected (severed) Era account is still listed, but Era returns none of its
-- transactions. raw.mark_removed took "listed and not seen" to mean "gone", so the first pull
-- after the 2026-11-11 Chase reconnect would have marked the old Chase accounts' rows removed
-- for the whole window. Their replacements' copies of those days are removed by design (they
-- fall before the cutover), so those days would have vanished. A full history re-run would
-- have done the same to all of the old accounts' history.
--
-- mark_removed now leaves alone:
--   * an account that raw.era_account_replacements says was replaced (its history is the
--     record before the cutover, and nothing after it is used), and
--   * an account Era lists as severed (visibility contains "sever"), since Era sends nothing
--     for it, so "not seen" says nothing.
--
-- Also: Katelyn's CareCredit 7825 came back under a new Era id when it was reconnected
-- (old uagr_CMjOtzM5tyc, last posted 2026-09-09; new uagr_5rRFJDjWSb2). Same card, same
-- mask. It gets a replacement row with the same cutover rule as the Chase accounts, so the
-- new id's copies of old days don't count twice.

create or replace function raw.mark_removed(p_run bigint, p_window_start date, p_window_end date, p_account_ids text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count int;
begin
  update raw.era_transactions t
     set removed_at = now()
   where t.occurred_on between p_window_start and p_window_end
     and t.era_account_id = any (p_account_ids)
     and t.removed_at is null
     and t.last_pull_run_id is distinct from p_run
     and not exists (select 1 from raw.era_account_replacements r
                      where r.old_era_account_id = t.era_account_id)
     and not exists (select 1 from raw.era_accounts a
                      where a.era_account_id = t.era_account_id
                        and a.payload->>'visibility' ilike '%sever%');
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

grant select on raw.era_accounts to ingest;

insert into raw.era_account_replacements (old_era_account_id, new_era_account_id, cutover, note)
select 'uagr_CMjOtzM5tyc', 'uagr_5rRFJDjWSb2',
       coalesce(least(max(t.occurred_on) filter (where not t.pending) + 1,
                      min(t.occurred_on) filter (where t.pending)),
                current_date),
       'CareCredit 7825 (Katelyn) reconnected in Era with a new id'
  from raw.era_transactions t
 where t.era_account_id = 'uagr_CMjOtzM5tyc' and t.removed_at is null
   and exists (select 1 from ref.accounts a where a.era_account_id = 'uagr_CMjOtzM5tyc')
having count(*) > 0
on conflict do nothing;
