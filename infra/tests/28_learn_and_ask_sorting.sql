\set ON_ERROR_STOP 1
\echo '== 28 learn-and-ask sorting: answers, merchant memory, the category map, guesses and questions'
begin;
\ir _helpers.sql
\ir _calc_fixture.sql

-- Made-up data on top of the calc fixture. 'pay' is biweekly from Jan 30.
insert into raw.era_accounts (era_account_id, payload, content_hash) values ('era-me', '{}', 'h');
insert into ref.accounts (account_key, era_account_id, name, owner, kind, valid_from) values
  ('me-personal', 'era-me', 'My personal', 'james', 'checking', '2026-01-01');

insert into ref.budget_lines (line_key, name, amount, period, income_key, borrows_from, tracked, sort,
                              personal_account_key, counts_from_personal, valid_from) values
  ('food', 'Food', 300.00, 'paycheck', 'pay', 'shopping', true, 1, null, true, '2026-01-01'),
  ('fun-me', 'My fun money', 50.00, 'paycheck', 'pay', null, true, 2, 'me-personal', true, '2026-01-01'),
  ('shopping', 'Shopping', 500.00, 'month', null, null, true, 3, null, false, '2026-01-01'),
  ('animals', 'Animals', 100.00, 'month', null, 'shopping', true, 4, null, true, '2026-01-01');

insert into ref.category_map (category_key, category_name, line_key, valid_from) values
  ('fcat_groc', 'Groceries', 'food', '2026-01-01'),
  ('fcat_shop', 'Shopping and gear', 'shopping', '2026-01-01'),
  ('fcat_pets', 'Pets', 'animals', '2026-01-01'),
  ('fcat_util', 'Utilities', null, '2026-01-01');

insert into ref.merchant_memory (pattern, line_key, follow_category, source, valid_from) values
  ('big club', 'food', false, 'seeded', '2026-01-01'),
  ('water co', null, false, 'seeded', '2026-01-01'),
  ('everything store', null, true, 'seeded', '2026-01-01'),
  ('pet barn', 'animals', false, 'seeded', '2026-01-01');

insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant) values
  -- Merchant memory beats Era's category.
  ('s-club',      'era-chk',  '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -60.00, '2026-02-14', false, 'Big Club'),
  -- A store number on the end still matches; a longer word doesn't.
  ('s-club-2',    'era-card', '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -10.00, '2026-02-14', false, 'BIG CLUB #4879'),
  ('s-clubhouse', 'era-chk',  '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -12.00, '2026-02-14', false, 'Big Clubhouse'),
  -- Follow Era's category: known, not a guess.
  ('s-ev-groc',   'era-chk',  '{"category": "Groceries", "categoryKey": "fcat_groc"}', 'h', -20.00, '2026-02-15', false, 'Everything Store'),
  ('s-ev-shop',   'era-chk',  '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -30.00, '2026-02-15', false, 'Everything Store'),
  -- New merchant, Era's category: a guess.
  ('s-new',       'era-chk',  '{"category": "Pets", "categoryKey": "fcat_pets"}', 'h', -25.00, '2026-02-16', false, 'Feed Shack'),
  ('s-new-2',     'era-card', '{"category": "Pets", "categoryKey": "fcat_pets"}', 'h', -15.00, '2026-02-17', false, 'Feed Shack'),
  -- No category Era sends that the map knows: nothing to go on.
  ('s-none',      'era-chk',  '{"category": "Mystery", "categoryKey": "fcat_mystery"}', 'h', -9.00, '2026-02-16', false, 'Odd Place'),
  -- Personal account: Shopping becomes fun money; Food and Animals stay; a known bill stays out.
  ('s-p-shop',    'era-me',   '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -11.00, '2026-02-16', false, 'Gadget Hut'),
  ('s-p-club',    'era-me',   '{"category": "Shopping and gear", "categoryKey": "fcat_shop"}', 'h', -13.00, '2026-02-16', false, 'Big Club'),
  ('s-p-pets',    'era-me',   '{"category": "Pets", "categoryKey": "fcat_pets"}', 'h', -14.00, '2026-02-16', false, 'Pet Barn'),
  ('s-p-water',   'era-me',   '{"category": "Utilities", "categoryKey": "fcat_util"}', 'h', -40.00, '2026-02-16', false, 'Water Co'),
  ('s-p-util',    'era-me',   '{"category": "Utilities", "categoryKey": "fcat_util"}', 'h', -16.00, '2026-02-16', false, 'Some Utility'),
  ('s-p-none',    'era-me',   '{"category": "Mystery", "categoryKey": "fcat_mystery"}', 'h', -7.00, '2026-02-16', false, 'Odd Place');

create temp view sorted as select * from calc.spending_sorted('2026-02-01', '2026-02-28');

select pg_temp.check((select line_key = 'food' and sorted_by = 'memory' and not guessed from sorted where era_transaction_id = 's-club'),
  'merchant memory beats Era''s category, and isn''t a guess');
select pg_temp.check((select line_key = 'food' from sorted where era_transaction_id = 's-club-2'),
  'a remembered merchant matches whatever the case, with a store number on the end');
select pg_temp.check((select line_key = 'shopping' and sorted_by = 'category' from sorted where era_transaction_id = 's-clubhouse'),
  'a remembered name doesn''t match inside a longer word');
select pg_temp.check((select line_key = 'food' and sorted_by = 'memory' and not guessed from sorted where era_transaction_id = 's-ev-groc')
                     and (select line_key = 'shopping' and not guessed from sorted where era_transaction_id = 's-ev-shop'),
  'a merchant that varies follows Era''s category, and isn''t a guess');
select pg_temp.check((select line_key = 'animals' and sorted_by = 'category' and guessed from sorted where era_transaction_id = 's-new'),
  'a new merchant gets its line from Era''s category, labeled a guess');
select pg_temp.check((select line_key is null and sorted_by = 'none' and guessed from sorted where era_transaction_id = 's-none'),
  'a category the map doesn''t know gives no line, labeled a guess');
select pg_temp.check((select line_key = 'fun-me' from sorted where era_transaction_id = 's-p-shop'),
  'from a Personal account, a Shopping purchase is that person''s fun money');
select pg_temp.check((select line_key = 'food' from sorted where era_transaction_id = 's-p-club')
                     and (select line_key = 'animals' from sorted where era_transaction_id = 's-p-pets'),
  'from a Personal account, Food and Animals still count as Food and Animals');
select pg_temp.check((select line_key is null from sorted where era_transaction_id = 's-p-water'),
  'a merchant remembered as a bill stays out of the budget even from a Personal account');
select pg_temp.check((select line_key = 'fun-me' from sorted where era_transaction_id = 's-p-util')
                     and (select line_key = 'fun-me' from sorted where era_transaction_id = 's-p-none'),
  'from a Personal account, anything else with no line is fun money');
select pg_temp.check((select line_key = 'food' from calc.budget_spending('2026-02-01', '2026-02-28') where era_transaction_id = 's-club'),
  'budget_spending gives the same lines');

-- Questions: one per guessed merchant, biggest first.
select pg_temp.check((select charges = 2 and total = 40 and guess_line = 'Animals' and why = 'Era calls it Pets'
                        from calc.sort_questions('2026-02-20') where merchant_key = 'feed shack'),
  'a guessed merchant is one question, however many charges');
select pg_temp.check(not exists (select 1 from calc.sort_questions('2026-02-20') where merchant_key in ('big club', 'everything store', 'pet barn')),
  'a remembered merchant isn''t asked about');
select pg_temp.check((select why = 'Era calls it Shopping and gear, from a Personal account' and guess_line = 'My fun money'
                        from calc.sort_questions('2026-02-20') where merchant_key = 'gadget hut'),
  'a question says when the account was the hint');
select pg_temp.check(not exists (select 1 from calc.sort_questions('2026-04-01')),
  'only the last 35 days are asked about');

-- Answers.
select actions.sort_spending('james', 'merchant', 'animals', 'Feed Shack');
select pg_temp.check((select line_key = 'animals' and sorted_by = 'memory' and not guessed
                        from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-new-2'),
  'an answer about a merchant is remembered for all its charges');
select pg_temp.check(not exists (select 1 from calc.sort_questions('2026-02-20') where merchant_key = 'feed shack'),
  'and it isn''t asked again');

select actions.sort_spending('james', 'one_charge', 'shopping', null, 's-club');
select pg_temp.check((select line_key = 'shopping' and sorted_by = 'you' from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-club')
                     and (select line_key = 'food' from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-club-2'),
  'a word on one charge beats memory, for that charge only');
select actions.sort_spending('james', 'one_charge', 'food', null, 's-club');
select pg_temp.check((select line_key = 'food' and sorted_by = 'you' from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-club'),
  'the latest word on a charge wins');
select actions.sort_spending('james', 'one_charge', 'shopping', null, 's-p-shop');
select pg_temp.check((select line_key = 'shopping' from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-p-shop'),
  'a word on one charge stands exactly as said, even from a Personal account');

select actions.sort_spending('katelyn', 'guess', 'shopping', 'Odd Place');
select pg_temp.check((select line_key = 'shopping' and sorted_by = 'guess' and guessed
                        from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-none'),
  'Claude''s guess fills in when the category gives nothing, still labeled a guess');
select pg_temp.check((select why like 'Claude guessed earlier%' from calc.sort_questions('2026-02-20') where merchant_key = 'odd place'),
  'and it''s still asked about');
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'guess', 'food', 'big club')$$,
  '%already said what%', 'a guess never replaces what someone said');

select actions.sort_spending('james', 'skip', null, 'Odd Place');
select pg_temp.check(not exists (select 1 from calc.sort_questions('2026-02-20') where merchant_key = 'odd place')
                     and (select guessed from calc.spending_sorted('2026-02-01', '2026-02-28') where era_transaction_id = 's-none'),
  'a skipped merchant isn''t asked again, and stays a guess');

select actions.sort_spending('james', 'merchant', 'varies', 'Gadget Hut');
select pg_temp.check((select follow_category and line_key is null and set_by = 'james' and source = 'answer'
                        from ref.current_merchant_memory where pattern = 'gadget hut'),
  '"varies" remembers to follow Era''s category');
select actions.sort_spending('james', 'merchant', 'none', 'Gadget Hut');
select pg_temp.check((select count(*) = 1 from ref.current_merchant_memory where pattern = 'gadget hut')
                     and (select line_key is null and not follow_category from ref.current_merchant_memory where pattern = 'gadget hut'),
  'a new answer about a merchant replaces the old one');

-- Refusals.
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'merchant', 'groceries', 'Feed Shack')$$,
  '%no budget line "groceries"%', 'an unknown line is refused');
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'merchant', null, 'Feed Shack')$$,
  '%Say which line%', 'an answer needs a line');
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'one_charge', 'food', null, 'no-such-tx')$$,
  '%no transaction%', 'an unknown transaction is refused');
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'one_charge', 'varies', null, 's-club')$$,
  '%only with kind merchant%', '"varies" is for merchants only');
select pg_temp.expect_error(null, $$select actions.sort_spending('james', 'merchant', 'food', 'ab')$$,
  '%at least 3 letters%', 'a merchant needs a real name');
select pg_temp.expect_error(null, $$select actions.sort_spending('someone', 'skip', null, 'Feed Shack')$$,
  '%', 'only james or katelyn can answer');
select pg_temp.expect_error(null, $$update knowledge.sort_answers set line_key = 'food'$$,
  '%never changed or deleted%', 'an answer is never changed');
select pg_temp.expect_error(null, $$delete from knowledge.sort_answers$$,
  '%never changed or deleted%', 'or deleted');

-- The briefing: the guessed part of each line, and one GREEN item with the questions.
select calc.refresh_all(null, '2026-02-20');
select pg_temp.check((select e ->> 'text' like '%Guessed so far, until someone confirms: %'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'budget'),
  'the budget item says how much is guessed');
select pg_temp.check((select e ->> 'level' = 'GREEN' and e ->> 'text' like '% to check at the next weekly check-in or payday: %'
                        from calc.briefing, jsonb_array_elements(items) e where e ->> 'kind' = 'sort_questions'),
  'the questions are one GREEN item, never a warning');

-- Access.
select pg_temp.check(pg_temp.as_role('assistant_read', 'select count(*) > 0 from calc.sort_questions(''2026-02-20'')') = 'true',
  'the assistant can read the questions');
select pg_temp.expect_error('assistant_read', $$insert into ref.merchant_memory (pattern, line_key, source) values ('xyz', null, 'seeded')$$,
  '%permission denied%', 'the assistant can''t write merchant memory directly');
select pg_temp.expect_error('assistant_read', $$select actions.sort_spending('james', 'skip', null, 'Feed Shack')$$,
  '%permission denied%', 'reads can''t answer');

rollback;
