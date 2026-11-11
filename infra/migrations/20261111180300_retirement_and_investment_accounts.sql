-- Two new account kinds, retirement and investment, for James's 401k and brokerage (2026-11-11).
-- Only checking and savings feed the cash projection, so neither changes the cash numbers.
alter table ref.accounts drop constraint accounts_kind_check;
alter table ref.accounts add constraint accounts_kind_check
  check (kind in ('checking', 'savings', 'card', 'loan', 'retirement', 'investment'));
