-- Shadow week (Nov 14): two Quicksilver payments were rejected by mistake (a misread answer), and no
-- tool could take a rejection back, so fixing it needed a build. reopen_match puts a match a person
-- rejected back to pending, with a reason, so it can be confirmed. The rejection stays on record:
-- in the match's note, and in knowledge.action_calls (the reject_match call). Nothing is dropped.

create function actions.reopen_match(
  p_person    text,
  p_match_id  bigint,
  p_reason    text
) returns knowledge.proposed_matches
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'match_id', p_match_id, 'reason', p_reason);
  v_prior  jsonb;
  v_match  knowledge.proposed_matches;
begin
  v_prior := actions._prior_result('reopen_match', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.proposed_matches, v_prior);
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'Reopening a match needs a reason (what was wrong about the rejection).' using errcode = 'P0001';
  end if;

  select * into v_match from knowledge.proposed_matches where id = p_match_id for update;
  if not found then
    raise exception 'There is no proposed match %.', p_match_id using errcode = 'P0001';
  end if;
  if v_match.status <> 'rejected' or v_match.decided_by is null then
    raise exception 'Match % is %, not rejected by a person, so there''s nothing to reopen.', p_match_id,
      case when v_match.status = 'rejected' then 'withdrawn by a build' else v_match.status end using errcode = 'P0001';
  end if;
  if exists (select 1 from knowledge.proposed_matches m
              where m.era_transaction_id = v_match.era_transaction_id and m.id <> v_match.id
                and m.status in ('pending', 'ambiguous', 'confirmed'))
     or exists (select 1 from ledger.payments_effective p where p.era_transaction_id = v_match.era_transaction_id) then
    raise exception 'That transaction is already matched or paid for another bill. Sort that one out first.' using errcode = 'P0001';
  end if;

  update knowledge.proposed_matches
     set status = 'pending', decided_at = null, decided_by = null,
         decision_note = format('Reopened by %s on %s: %s. Was rejected by %s on %s%s.', v_person, current_date, trim(p_reason),
                                v_match.decided_by, (v_match.decided_at at time zone 'America/New_York')::date,
                                ' (' || nullif(v_match.decision_note, '') || ')')
   where id = p_match_id
  returning * into v_match;

  perform calc.refresh_all();
  perform actions._log_call('reopen_match', v_person, v_args, to_jsonb(v_match));
  return v_match;
end
$$;

revoke all on function actions.reopen_match(text, bigint, text) from public;
grant execute on function actions.reopen_match(text, bigint, text) to assistant_act;
