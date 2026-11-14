-- local-test: skip (live data: the household's bills)
--
-- James's tags for every bill, from the tagging sitting on 2026-11-14 (thread "Tag bills by
-- category and necessity"). This fills two new fields, so it's set on every version of each bill
-- rather than as a new version (as 20261114170100_card_bills_pay_down_cards did).
--
-- basic_necessity follows strategy/on-track.md: mortgage, utilities and all debt minimums and
-- payments count; subscriptions and flex spending don't. James also counted internet, phone, car
-- insurance and preschool, and left out pest control, CareCredit Payment Security, coffee ("we
-- could get cheap stuff") and the car wash. The extra debt payment line isn't a necessity either
-- ("extra payments are extra"); the ladder view only counts Food, Animals and Fuel.

update ref.bills b
   set category = t.category, basic_necessity = t.necessity
  from (values
    ('mortgage', 'housing', true),
    ('electric', 'utilities', true),
    ('water', 'utilities', true),
    ('garbage', 'utilities', true),
    ('internet', 'utilities', true),
    ('phone', 'utilities', true),
    ('pest', 'household', false),
    ('car-insurance', 'insurance', true),
    ('preschool', 'kids', true),
    ('payment-security', 'insurance', false),
    ('auto-loan', 'debt', true),
    ('onemain-1', 'debt', true),
    ('affirm-fridge', 'debt', true),
    ('affirm-dishwasher', 'debt', true),
    ('sunbit', 'debt', true),
    ('card-amazon-1525', 'debt', true),
    ('card-amazon-3328', 'debt', true),
    ('card-apple', 'debt', true),
    ('card-capone-platinum', 'debt', true),
    ('card-carecredit-james', 'debt', true),
    ('card-carecredit-katelyn', 'debt', true),
    ('card-chase-5804', 'debt', true),
    ('card-home-depot', 'debt', true),
    ('card-kohls-3609', 'debt', true),
    ('card-kohls-9708', 'debt', true),
    ('card-quicksilver-2509', 'debt', true),
    ('card-quicksilver-4407', 'debt', true),
    ('adobe', 'subscriptions', false),
    ('amazon-prime', 'subscriptions', false),
    ('anthropic', 'subscriptions', false),
    ('apple-10-79', 'subscriptions', false),
    ('apple-14-82', 'subscriptions', false),
    ('apple-39-99', 'subscriptions', false),
    ('apple-9-99-joint', 'insurance', false),
    ('disney-plus', 'subscriptions', false),
    ('era-subscription', 'subscriptions', false),
    ('netflix', 'subscriptions', false),
    ('spotify', 'subscriptions', false),
    ('weight-watchers', 'health', false),
    ('first-day', 'health', false),
    ('hiya-health', 'health', false),
    ('keurig', 'food', false),
    ('lulus-pine-log', 'car', false)
  ) as t(bill_key, category, necessity)
 where b.bill_key = t.bill_key;

update ref.bills set note = 'Unlimited car washes for a set monthly price; used often (James)'
 where bill_key = 'lulus-pine-log' and note is null;

select calc.refresh_all();
