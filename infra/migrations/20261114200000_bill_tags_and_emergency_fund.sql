-- Live dashboard plan, task 4: tag each bill with a category and whether it's a basic necessity,
-- and add the Emergency Fund ladder view that uses those tags (strategy/on-track.md, Level 3).
-- Nothing here drops anything, so it needs no Supabase confirm dialog.
--
--   1. ref.bills.category: a short lowercase word or two, such as "utilities". Null until tagged.
--      The list in use is in data/schema.md.
--   2. ref.bills.basic_necessity: true when the bill counts toward one month of basic necessities.
--      Null until tagged, so an untagged bill is never silently counted or silently left out.
--   3. update_bill accepts both and carries them to each new version; current_bills shows them.
--   4. calc.bill_monthly: each current bill's amount as a monthly figure, by cadence.
--   5. calc.emergency_fund_status: the Emergency Fund balance against 1, 3 and 6 months of basic
--      necessities (necessity bills plus the Food, Animals and Fuel budget lines).
--
-- The tags themselves are live data, set from James's answers in a separate migration.

-- ---------------------------------------------------------------- 1-2. the columns

alter table ref.bills add column category text check (category ~ '^[a-z]+( [a-z]+)*$');
alter table ref.bills add column basic_necessity boolean;
comment on column ref.bills.category is
  'What kind of bill it is, in a lowercase word or two (for example "utilities"). Null until tagged. The list in use is in data/schema.md.';
comment on column ref.bills.basic_necessity is
  'True when the bill counts toward a month of basic necessities for the Emergency Fund ladder (strategy/on-track.md). Null until tagged.';

create or replace view ref.current_bills with (security_invoker = true) as
  select * from ref.bills
  where valid_from <= current_date and (valid_to is null or valid_to > current_date);

-- ---------------------------------------------------------------- 3. update_bill

-- As in 20261114170000_card_payments_any_account, plus category and basic_necessity.
create or replace function actions.update_bill(
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
                              'autopay', 'cadence', 'cadence_anchor', 'every_weeks', 'income_key', 'note',
                              'pays_account_key', 'category', 'basic_necessity'];
  v_required  text[] := array['name', 'amount', 'amount_kind', 'account_key', 'autopay', 'cadence'];
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
      raise exception 'A new bill needs %, plus what its cadence needs. Missing: %. Unknown fields go in an open question, not a guess.',
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
                           cadence, cadence_anchor, every_weeks, income_key, note, pays_account_key, category,
                           basic_necessity, valid_from)
    values (p_bill_key, v_new.name, v_new.amount, v_new.amount_kind, v_new.tolerance, v_new.due_day, v_new.account_key,
            v_new.autopay, v_new.cadence, v_new.cadence_anchor, v_new.every_weeks, v_new.income_key, v_new.note,
            v_new.pays_account_key, v_new.category, v_new.basic_necessity, v_from)
    returning * into v_new;
  exception
    when check_violation or not_null_violation then
      raise exception 'That bill has a value that isn''t allowed. Amounts are at least 0 and amount_kind is fixed or variable. Cadence is monthly (needs due_day), every_other_month, quarterly, semiannual or annual (need due_day and a cadence_anchor date), weekly or biweekly (need a cadence_anchor date), every_n_weeks (needs a cadence_anchor date and every_weeks, 1 to 52), or per_paycheck (needs income_key). category is one or more lowercase words. bill_key is lowercase letters, digits, - or _. Nothing was written.'
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


-- ---------------------------------------------------------------- 4. monthly figures

-- How many times a cadence comes due in an average month. per_paycheck follows its income's
-- cadence; a budget line's paycheck period does the same.
create function calc._per_month(p_cadence text, p_every_weeks smallint default null)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case p_cadence
    when 'monthly'           then 1::numeric
    when 'month'             then 1::numeric
    when 'every_other_month' then 1::numeric / 2
    when 'quarterly'         then 1::numeric / 3
    when 'semiannual'        then 1::numeric / 6
    when 'annual'            then 1::numeric / 12
    when 'weekly'            then 52::numeric / 12
    when 'biweekly'          then 26::numeric / 12
    when 'every_n_weeks'     then 52::numeric / 12 / nullif(p_every_weeks, 0)
  end
$$;
comment on function calc._per_month(text, smallint) is
  'Times a cadence comes due in an average month (52 weeks a year). Null for a cadence it doesn''t know.';
grant execute on function calc._per_month(text, smallint) to assistant_read;

create view calc.bill_monthly with (security_invoker = true) as
  select b.bill_key, b.name, b.category, b.basic_necessity, b.cadence, b.amount_kind, b.amount,
         round(b.amount * calc._per_month(coalesce(i.cadence, b.cadence), b.every_weeks), 2) as monthly_amount
  from ref.current_bills b
  left join ref.current_income_sources i on b.cadence = 'per_paycheck' and i.income_key = b.income_key;
comment on view calc.bill_monthly is
  'Each current bill as a monthly figure: its amount times how often its cadence comes due in an average month. A variable bill uses its expected amount.';
grant select on calc.bill_monthly to assistant_read;

-- ---------------------------------------------------------------- 5. the ladder

create view calc.emergency_fund_status with (security_invoker = true) as
  with bills as (
    select coalesce(sum(monthly_amount) filter (where basic_necessity), 0) as necessity_bills,
           count(*) filter (where basic_necessity is null) as untagged_bills
    from calc.bill_monthly
  ), lines as (
    select coalesce(sum(round(l.amount * calc._per_month(coalesce(i.cadence, l.period)), 2)), 0) as necessity_lines
    from ref.current_budget_lines l
    left join ref.current_income_sources i on l.period = 'paycheck' and i.income_key = l.income_key
    where l.line_key in ('food', 'animals', 'fuel')
  ), fund as (
    select balance, as_of, source, stale from calc.account_balances where account_key = 'emergency-fund'
  ), totals as (
    select b.necessity_bills, l.necessity_lines, b.necessity_bills + l.necessity_lines as monthly_necessities,
           b.untagged_bills
    from bills b, lines l
  )
  select f.balance, f.as_of, f.source, f.stale,
         t.monthly_necessities, t.necessity_bills, t.necessity_lines, t.untagged_bills,
         t.monthly_necessities * 1 as target_1_month,
         t.monthly_necessities * 3 as target_3_months,
         t.monthly_necessities * 6 as target_6_months,
         round(f.balance / nullif(t.monthly_necessities, 0), 2) as months_covered,
         case
           when f.balance is null then null
           when f.balance >= t.monthly_necessities * 6 then 6
           when f.balance >= t.monthly_necessities * 3 then 3
           when f.balance >= t.monthly_necessities then 1
           else 0
         end as rung_reached
  from totals t left join fund f on true;
comment on view calc.emergency_fund_status is
  'One row: the Emergency Fund balance against 1, 3 and 6 months of basic necessities (strategy/on-track.md, Level 3). A month is the bills tagged basic_necessity plus the Food, Animals and Fuel budget lines, as monthly figures. untagged_bills counts bills not tagged yet, which are left out; the ladder is only complete when it is 0. rung_reached is 0, 1, 3 or 6.';
grant select on calc.emergency_fund_status to assistant_read;
