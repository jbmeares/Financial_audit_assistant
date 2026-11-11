-- Apple Card moves to "tracked by hand". James, 2026-11-11: the Apple sign-on with Era
-- isn't working, so for now its balance is entered by hand. A ref change closes the old row
-- and adds a new one.
update ref.accounts set valid_to = current_date
 where account_key = 'apple-card' and valid_to is null and valid_from < current_date;

insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, note, connection, valid_from)
select account_key, era_account_id, name, owner, kind, role,
       'Apple sign-on with Era not working (James, 2026-11-11); balance entered by hand for now',
       'manual', current_date
  from ref.accounts
 where account_key = 'apple-card' and valid_to = current_date
on conflict do nothing;
