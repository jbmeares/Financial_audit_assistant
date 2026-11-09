-- C8. Named write functions. The MCP's action tools call these and nothing else.
-- Each one checks its input, writes in one transaction, records which person it was for,
-- and returns the new row. Bad input is refused with a plain sentence and nothing is written.
-- The same call (same arguments) within 10 minutes returns the first result instead of
-- writing again.
--
-- All run as the owner (security definer) with an empty search_path, so every name is
-- schema-qualified. assistant_act gets EXECUTE on the public ones only (see the access migration).

-- ---------------------------------------------------------------- helpers (not granted)

create function actions._person(p_person text) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person text := lower(trim(p_person));
  v_known  text;
begin
  if v_person is null or not exists (select 1 from ref.people where person = v_person and valid_to is null) then
    select string_agg(person, ' or ' order by person) into v_known from ref.people where valid_to is null;
    raise exception 'Say who this is for (%). "%" isn''t a known person.', v_known, coalesce(p_person, '')
      using errcode = 'P0001';
  end if;
  return v_person;
end
$$;

-- Returns the stored result of the same call made in the last 10 minutes, or null.
-- Takes a lock on the call so two identical calls arriving together can't both write.
create function actions._prior_result(p_action text, p_args jsonb) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_action || ':' || p_args::text, 0));
  select result into v_result
    from knowledge.action_calls
   where action = p_action
     and args = p_args
     and called_at > now() - interval '10 minutes'
   order by called_at desc
   limit 1;
  return v_result;
end
$$;

create function actions._log_call(p_action text, p_person text, p_args jsonb, p_result jsonb) returns void
language sql
security definer
set search_path = ''
as $$
  insert into knowledge.action_calls (action, person, args, result) values (p_action, p_person, p_args, p_result);
$$;

-- ---------------------------------------------------------------- confirm_match

create function actions.confirm_match(
  p_person    text,
  p_match_id  bigint,
  p_alias     text default null,
  p_note      text default null
) returns ledger.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'match_id', p_match_id, 'alias', p_alias, 'note', p_note);
  v_prior  jsonb;
  v_match  knowledge.proposed_matches;
  v_tx     raw.era_transactions;
  v_pay    ledger.payments;
begin
  v_prior := actions._prior_result('confirm_match', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ledger.payments, v_prior);
  end if;

  select * into v_match from knowledge.proposed_matches where id = p_match_id for update;
  if not found then
    raise exception 'There is no proposed match %.', p_match_id using errcode = 'P0001';
  end if;
  if v_match.status not in ('pending', 'ambiguous') then
    raise exception 'Match % is already %, so it can''t be confirmed.', p_match_id, v_match.status using errcode = 'P0001';
  end if;

  select * into v_tx from raw.era_transactions where era_transaction_id = v_match.era_transaction_id;
  if not found then
    raise exception 'The transaction for match % isn''t in the Era data.', p_match_id using errcode = 'P0001';
  end if;
  if v_tx.removed_at is not null then
    raise exception 'Era no longer shows the transaction for match % (it may have posted under a new id). Nothing was written.', p_match_id
      using errcode = 'P0001';
  end if;
  if v_tx.amount is null or v_tx.occurred_on is null then
    raise exception 'The transaction for match % has no amount or date yet.', p_match_id using errcode = 'P0001';
  end if;
  if v_tx.amount >= 0 then
    raise exception 'The transaction for match % is money in, not a payment.', p_match_id using errcode = 'P0001';
  end if;
  if exists (select 1 from ledger.payments_effective where era_transaction_id = v_tx.era_transaction_id) then
    raise exception 'That transaction is already recorded as a payment. Void that payment first if it was wrong.'
      using errcode = 'P0001';
  end if;

  insert into ledger.payments (bill_key, due_month, amount, paid_on, era_transaction_id, proposed_match_id, entered_by, note)
  values (v_match.bill_key, v_match.due_month, abs(v_tx.amount), v_tx.occurred_on, v_tx.era_transaction_id, v_match.id, v_person, p_note)
  returning * into v_pay;

  update knowledge.proposed_matches
     set status = 'confirmed', decided_at = now(), decided_by = v_person
   where id = v_match.id;

  -- One transaction pays one bill: close any other open proposal for the same transaction.
  update knowledge.proposed_matches
     set status = 'rejected', decided_at = now(), decided_by = v_person,
         decision_note = 'Another bill was confirmed for this transaction.'
   where era_transaction_id = v_match.era_transaction_id
     and id <> v_match.id
     and status in ('pending', 'ambiguous');

  -- A new merchant name becomes an alias, so the next one matches on name too.
  if nullif(trim(p_alias), '') is not null then
    insert into ref.bill_aliases (bill_key, alias) values (v_match.bill_key, trim(p_alias))
    on conflict do nothing;
  end if;

  perform calc.refresh_all();
  perform actions._log_call('confirm_match', v_person, v_args, to_jsonb(v_pay));
  return v_pay;
end
$$;

-- ---------------------------------------------------------------- reject_match

create function actions.reject_match(
  p_person    text,
  p_match_id  bigint,
  p_reason    text default null
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
  v_prior := actions._prior_result('reject_match', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.proposed_matches, v_prior);
  end if;

  select * into v_match from knowledge.proposed_matches where id = p_match_id for update;
  if not found then
    raise exception 'There is no proposed match %.', p_match_id using errcode = 'P0001';
  end if;
  if v_match.status not in ('pending', 'ambiguous') then
    raise exception 'Match % is already %, so it can''t be rejected.', p_match_id, v_match.status using errcode = 'P0001';
  end if;

  update knowledge.proposed_matches
     set status = 'rejected', decided_at = now(), decided_by = v_person, decision_note = p_reason
   where id = p_match_id
  returning * into v_match;

  perform calc.refresh_all();
  perform actions._log_call('reject_match', v_person, v_args, to_jsonb(v_match));
  return v_match;
end
$$;

-- ---------------------------------------------------------------- record_balance

create function actions.record_balance(
  p_person       text,
  p_account_key  text,
  p_balance      numeric,
  p_as_of        timestamptz default null,
  p_note         text default null
) returns ledger.balance_statements
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'account_key', p_account_key, 'balance', p_balance,
                                       'as_of', p_as_of, 'note', p_note);
  v_prior  jsonb;
  v_row    ledger.balance_statements;
begin
  v_prior := actions._prior_result('record_balance', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ledger.balance_statements, v_prior);
  end if;

  if not exists (select 1 from ref.accounts where account_key = p_account_key and valid_to is null) then
    raise exception 'There is no account "%".', coalesce(p_account_key, '') using errcode = 'P0001';
  end if;
  if p_balance is null then
    raise exception 'A balance is needed.' using errcode = 'P0001';
  end if;
  if p_as_of > now() + interval '1 hour' then
    raise exception 'A stated balance can''t be dated in the future.' using errcode = 'P0001';
  end if;

  insert into ledger.balance_statements (account_key, balance, as_of, entered_by, note)
  values (p_account_key, p_balance, coalesce(p_as_of, now()), v_person, p_note)
  returning * into v_row;

  perform calc.refresh_all();
  perform actions._log_call('record_balance', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

-- ---------------------------------------------------------------- log_life_event

create function actions.log_life_event(
  p_person       text,
  p_occurred_on  date,
  p_title        text,
  p_amount       numeric default null,
  p_story_path   text default null
) returns knowledge.life_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'occurred_on', p_occurred_on, 'title', p_title,
                                       'amount', p_amount, 'story_path', p_story_path);
  v_prior  jsonb;
  v_row    knowledge.life_events;
begin
  v_prior := actions._prior_result('log_life_event', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.life_events, v_prior);
  end if;

  if p_occurred_on is null then
    raise exception 'A life event needs the date it happened.' using errcode = 'P0001';
  end if;
  if nullif(trim(p_title), '') is null then
    raise exception 'A life event needs a short title.' using errcode = 'P0001';
  end if;
  if p_story_path is not null and p_story_path !~ '^life/.+\.md$' then
    raise exception 'The story file must be a Markdown file under life/, for example life/2026-q3.md.' using errcode = 'P0001';
  end if;

  insert into knowledge.life_events (occurred_on, title, amount, story_path, entered_by)
  values (p_occurred_on, trim(p_title), p_amount, p_story_path, v_person)
  returning * into v_row;

  perform actions._log_call('log_life_event', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

-- ---------------------------------------------------------------- update_bill

-- Changes a bill by closing its open row and adding a new one, so the old version is kept.
-- With no open row for p_bill_key, it creates the bill (every required field must be given).
-- p_end closes the bill with no new row (a cancelled bill).
create function actions.update_bill(
  p_person          text,
  p_bill_key        text,
  p_changes         jsonb default '{}'::jsonb,
  p_effective_from  date default null,
  p_end             boolean default false
) returns ref.bills
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person    text := actions._person(p_person);
  v_changes   jsonb := coalesce(p_changes, '{}'::jsonb);
  v_from      date := coalesce(p_effective_from, current_date);
  v_args      jsonb := jsonb_build_object('person', v_person, 'bill_key', p_bill_key, 'changes', v_changes,
                                          'effective_from', p_effective_from, 'end', p_end);
  v_allowed   text[] := array['name', 'amount', 'amount_kind', 'tolerance', 'due_day', 'account_key',
                              'autopay', 'cadence', 'cadence_anchor', 'note'];
  v_required  text[] := array['name', 'amount', 'amount_kind', 'due_day', 'account_key', 'autopay', 'cadence'];
  v_bad       text;
  v_prior     jsonb;
  v_old       ref.bills;
  v_new       ref.bills;
begin
  v_prior := actions._prior_result('update_bill', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ref.bills, v_prior);
  end if;

  if jsonb_typeof(v_changes) <> 'object' then
    raise exception 'Changes must be a set of field names and values.' using errcode = 'P0001';
  end if;
  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(v_changes) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'update_bill doesn''t know these fields: %. It accepts: %.', v_bad, array_to_string(v_allowed, ', ')
      using errcode = 'P0001';
  end if;

  select * into v_old from ref.bills where bill_key = p_bill_key and valid_to is null for update;

  if p_end then
    if v_old.id is null then
      raise exception 'There is no open bill "%" to end.', coalesce(p_bill_key, '') using errcode = 'P0001';
    end if;
    if v_changes <> '{}'::jsonb then
      raise exception 'Ending a bill takes no other changes.' using errcode = 'P0001';
    end if;
    if v_from < v_old.valid_from then
      raise exception 'The bill''s current version starts %, so it can''t end before that.', v_old.valid_from using errcode = 'P0001';
    end if;
    update ref.bills set valid_to = v_from where id = v_old.id returning * into v_new;
    perform calc.refresh_all();
    perform actions._log_call('update_bill', v_person, v_args, to_jsonb(v_new));
    return v_new;
  end if;

  if v_old.id is null then
    -- A new bill.
    if nullif(trim(p_bill_key), '') is null then
      raise exception 'A new bill needs a bill_key, a short name like "phone".' using errcode = 'P0001';
    end if;
    select string_agg(k, ', ' order by k) into v_bad
      from unnest(v_required) k where not (v_changes ? k) or v_changes -> k = 'null'::jsonb;
    if v_bad is not null then
      raise exception 'A new bill needs %. Missing: %. Unknown fields go in an open question, not a guess.',
        array_to_string(v_required, ', '), v_bad using errcode = 'P0001';
    end if;
    v_new := jsonb_populate_record(null::ref.bills, v_changes);
  else
    if v_changes = '{}'::jsonb then
      raise exception 'No changes were given for "%".', p_bill_key using errcode = 'P0001';
    end if;
    if v_from < v_old.valid_from then
      raise exception 'The bill''s current version starts %, so a change can''t start before that.', v_old.valid_from
        using errcode = 'P0001';
    end if;
    update ref.bills set valid_to = v_from where id = v_old.id;
    v_new := jsonb_populate_record(v_old, v_changes);
  end if;

  begin
    insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay,
                           cadence, cadence_anchor, note, valid_from)
    values (p_bill_key, v_new.name, v_new.amount, v_new.amount_kind, v_new.tolerance, v_new.due_day, v_new.account_key,
            v_new.autopay, v_new.cadence, v_new.cadence_anchor, v_new.note, v_from)
    returning * into v_new;
  exception
    when check_violation or not_null_violation then
      raise exception 'That bill has a value that isn''t allowed (amounts at least 0, due day 1 to 31, amount_kind fixed or variable, cadence monthly, quarterly, semiannual or annual with a cadence_anchor date unless monthly, bill_key in lowercase letters, digits, - or _). Nothing was written.'
        using errcode = 'P0001';
  end;

  perform calc.refresh_all();
  perform actions._log_call('update_bill', v_person, v_args, to_jsonb(v_new));
  return v_new;
exception
  when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
    raise exception 'One of the values for "%" isn''t the right type (%). Nothing was written.', coalesce(p_bill_key, ''), sqlerrm
      using errcode = 'P0001';
end
$$;

-- ---------------------------------------------------------------- void_entry

create function actions.void_entry(
  p_person    text,
  p_entry     text,
  p_entry_id  bigint,
  p_reason    text
) returns ledger.voids
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'entry', p_entry, 'entry_id', p_entry_id, 'reason', p_reason);
  v_prior  jsonb;
  v_void   ledger.voids;
  v_match  bigint;
begin
  v_prior := actions._prior_result('void_entry', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::ledger.voids, v_prior);
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A void needs a reason.' using errcode = 'P0001';
  end if;

  if p_entry = 'payment' then
    select proposed_match_id into v_match from ledger.payments where id = p_entry_id;
    if not found then
      raise exception 'There is no payment %.', p_entry_id using errcode = 'P0001';
    end if;
    if exists (select 1 from ledger.voids where payment_id = p_entry_id) then
      raise exception 'Payment % is already voided.', p_entry_id using errcode = 'P0001';
    end if;
    insert into ledger.voids (payment_id, reason, entered_by) values (p_entry_id, trim(p_reason), v_person)
    returning * into v_void;
    -- A voided confirmation means the pairing was wrong. Reject it so it never comes back.
    if v_match is not null then
      update knowledge.proposed_matches
         set status = 'rejected', decided_at = now(), decided_by = v_person,
             decision_note = 'Payment ' || p_entry_id || ' voided: ' || trim(p_reason)
       where id = v_match;
    end if;
  elsif p_entry = 'balance_statement' then
    if not exists (select 1 from ledger.balance_statements where id = p_entry_id) then
      raise exception 'There is no balance statement %.', p_entry_id using errcode = 'P0001';
    end if;
    if exists (select 1 from ledger.voids where balance_statement_id = p_entry_id) then
      raise exception 'Balance statement % is already voided.', p_entry_id using errcode = 'P0001';
    end if;
    insert into ledger.voids (balance_statement_id, reason, entered_by) values (p_entry_id, trim(p_reason), v_person)
    returning * into v_void;
  elsif p_entry = 'adjustment' then
    if not exists (select 1 from ledger.adjustments where id = p_entry_id) then
      raise exception 'There is no adjustment %.', p_entry_id using errcode = 'P0001';
    end if;
    if exists (select 1 from ledger.voids where adjustment_id = p_entry_id) then
      raise exception 'Adjustment % is already voided.', p_entry_id using errcode = 'P0001';
    end if;
    insert into ledger.voids (adjustment_id, reason, entered_by) values (p_entry_id, trim(p_reason), v_person)
    returning * into v_void;
  else
    raise exception 'void_entry can void a payment, balance_statement or adjustment, not "%".', coalesce(p_entry, '')
      using errcode = 'P0001';
  end if;

  perform calc.refresh_all();
  perform actions._log_call('void_entry', v_person, v_args, to_jsonb(v_void));
  return v_void;
end
$$;

-- ---------------------------------------------------------------- log_question

create function actions.log_question(
  p_person    text,
  p_question  text,
  p_topic     text default null,
  p_kind      text default 'question'
) returns knowledge.open_questions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'question', p_question, 'topic', p_topic, 'kind', p_kind);
  v_prior  jsonb;
  v_row    knowledge.open_questions;
begin
  v_prior := actions._prior_result('log_question', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.open_questions, v_prior);
  end if;

  if nullif(trim(p_question), '') is null then
    raise exception 'The question is empty.' using errcode = 'P0001';
  end if;
  if coalesce(p_kind, '') not in ('question', 'new_context') then
    raise exception 'kind must be question or new_context, not "%".', coalesce(p_kind, '') using errcode = 'P0001';
  end if;

  insert into knowledge.open_questions (kind, topic, question, asked_for)
  values (p_kind, nullif(trim(p_topic), ''), trim(p_question), v_person)
  returning * into v_row;

  perform actions._log_call('log_question', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;

-- ---------------------------------------------------------------- answer_question

create function actions.answer_question(
  p_person       text,
  p_question_id  bigint,
  p_answer       text
) returns knowledge.open_questions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person text := actions._person(p_person);
  v_args   jsonb := jsonb_build_object('person', v_person, 'question_id', p_question_id, 'answer', p_answer);
  v_prior  jsonb;
  v_row    knowledge.open_questions;
begin
  v_prior := actions._prior_result('answer_question', v_args);
  if v_prior is not null then
    return jsonb_populate_record(null::knowledge.open_questions, v_prior);
  end if;

  if nullif(trim(p_answer), '') is null then
    raise exception 'The answer is empty.' using errcode = 'P0001';
  end if;

  select * into v_row from knowledge.open_questions where id = p_question_id for update;
  if not found then
    raise exception 'There is no open question %.', p_question_id using errcode = 'P0001';
  end if;
  if v_row.status <> 'open' then
    raise exception 'Question % was already answered.', p_question_id using errcode = 'P0001';
  end if;

  update knowledge.open_questions
     set status = 'answered', answer = trim(p_answer), answered_by = v_person, answered_at = now()
   where id = p_question_id
  returning * into v_row;

  perform actions._log_call('answer_question', v_person, v_args, to_jsonb(v_row));
  return v_row;
end
$$;
