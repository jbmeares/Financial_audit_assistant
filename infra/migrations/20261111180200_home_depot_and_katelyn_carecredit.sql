-- James reconnected two accounts in Era on 2026-11-11:
--   * The Home Depot card is now in Era (Era lists it as "Home Depot Credit Card by Citibank",
--     card 7210). It was tracked by hand.
--   * Katelyn's CareCredit 7825 came back as a new Era connection with a new Era id. The old
--     Era account (uagr_CMjOtzM5tyc) stopped at Sep 29.
-- A ref change closes the old row and adds a new one.
update ref.accounts set valid_to = current_date
 where account_key in ('home-depot-card', 'carecredit-katelyn') and valid_to is null and valid_from < current_date;

insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, note, connection, valid_from)
select account_key,
       case account_key when 'home-depot-card' then 'uagr_3pDvE3jHuwz' else 'uagr_5rRFJDjWSb2' end,
       case account_key when 'home-depot-card' then 'Home Depot card 7210' else name end,
       owner, kind, role,
       case account_key
         when 'home-depot-card' then 'Connected in Era 2026-11-11. Era lists the issuer as Citibank; this row used to say Synchrony'
         else 'Reconnected in Era 2026-11-11 as a new connection' end,
       'era', current_date
  from ref.accounts
 where account_key in ('home-depot-card', 'carecredit-katelyn') and valid_to = current_date
on conflict do nothing;
