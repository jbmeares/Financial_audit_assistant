-- local-test: skip (household data, not schema)
-- James, 2026-11-11: his 401k and his Chase Self-Directed brokerage go on the connection list. Both are his.
insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, connection, valid_from) values
  ('james-401k', 'uagr_EL0fsdhHNiY', 'Lincoln 401(k)', 'james', 'retirement', 'Retirement savings', 'era', current_date),
  ('james-brokerage', 'uagr_K3ri4RiR47w', 'Chase Self-Directed 6663', 'james', 'investment', 'Brokerage account', 'era', current_date);
