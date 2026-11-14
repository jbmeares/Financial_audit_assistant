-- local-test: skip (live data: the household's card bills)
--
-- Points each card minimum at the card it pays down, so the matcher sees payments into the card
-- from any account (20261114170000_card_payments_any_account). This fills a new field, so it's set
-- on every version of these bills rather than as a new version.
--
-- Then renames the three bills whose cards Chase reissued (seen at the Nov 11 Chase reconnect, see
-- 20261111200000_chase_reconnect): Amazon 1525 -> 4639, Amazon 3328 -> 8104, Chase Card 5804 -> 8115.
-- The bill keys stay the same, because keys are stable ids; only the names change, as new
-- versions from today so the old names stay in history.

update ref.bills b
   set pays_account_key = m.account_key
  from (values
    ('card-amazon-1525', 'amazon-card-1525'),
    ('card-amazon-3328', 'amazon-card-3328'),
    ('card-apple', 'apple-card'),
    ('card-capone-platinum', 'capone-platinum'),
    ('card-carecredit-james', 'carecredit-james'),
    ('card-carecredit-katelyn', 'carecredit-katelyn'),
    ('card-chase-5804', 'chase-card-5804'),
    ('card-home-depot', 'home-depot-card'),
    ('card-kohls-3609', 'kohls-3609'),
    ('card-kohls-9708', 'kohls-9708'),
    ('card-quicksilver-2509', 'quicksilver-2509'),
    ('card-quicksilver-4407', 'quicksilver-4407')
  ) as m(bill_key, account_key)
 where b.bill_key = m.bill_key
   and exists (select 1 from ref.accounts a where a.account_key = m.account_key and a.valid_to is null);

with renames(bill_key, new_name, old_number) as (
  values ('card-amazon-1525', 'Chase Amazon 4639 minimum', '1525'),
         ('card-amazon-3328', 'Chase Amazon 8104 minimum', '3328'),
         ('card-chase-5804', 'Chase Card 8115 minimum', '5804')
), closed as (
  update ref.bills b
     set valid_to = date '2026-11-14'
    from renames r
   where b.bill_key = r.bill_key and b.valid_to is null and b.valid_from < date '2026-11-14'
  returning b.*, r.new_name, r.old_number
)
insert into ref.bills (bill_key, name, amount, amount_kind, tolerance, due_day, account_key, autopay,
                       cadence, cadence_anchor, every_weeks, income_key, note, pays_account_key, valid_from)
select c.bill_key, c.new_name, c.amount, c.amount_kind, c.tolerance, c.due_day, c.account_key, c.autopay,
       c.cadence, c.cadence_anchor, c.every_weeks, c.income_key,
       concat_ws('. ', c.note, 'Card number was ' || c.old_number || ' until Chase reissued it (seen Nov 11)'),
       c.pays_account_key, date '2026-11-14'
  from closed c;

select calc.refresh_all();
