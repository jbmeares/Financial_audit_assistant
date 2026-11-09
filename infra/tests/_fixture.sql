-- Made-up data for the tests. None of these values are real.
insert into raw.pull_runs (kind, status, finished_at) values ('manual', 'ok', now());

insert into raw.era_accounts (era_account_id, payload, content_hash)
values ('test-acc', '{}', 'h');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
values ('test-tx-1', 'test-acc', '{}', 'h', -40.00, '2026-11-03', false, 'TEST PHONE CO'),
       ('test-tx-2', 'test-acc', '{}', 'h', -25.00, '2026-11-04', false, 'TEST STREAMING'),
       ('test-tx-in', 'test-acc', '{}', 'h', 500.00, '2026-11-01', false, 'TEST PAYROLL');

insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from)
values ('test-checking', 'test-acc', 'Test checking', 'joint', 'checking', 'pays bills', '2026-01-01');

insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
values ('test-phone', 'Test phone', 40.00, 'fixed', 5, 'test-checking', true, 'monthly', '2026-01-01'),
       ('test-stream', 'Test streaming', 25.00, 'fixed', 4, 'test-checking', true, 'monthly', '2026-01-01'),
       ('test-other', 'Test other', 25.00, 'fixed', 4, 'test-checking', false, 'monthly', '2026-01-01');

insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
values ('test-tx-1', 'test-phone', '2026-11-01', 90, 'test', 'pending'),
       ('test-tx-2', 'test-stream', '2026-11-01', 80, 'test', 'ambiguous'),
       ('test-tx-2', 'test-other', '2026-11-01', 80, 'test', 'ambiguous'),
       ('test-tx-in', 'test-phone', '2026-11-01', 70, 'test', 'pending');
