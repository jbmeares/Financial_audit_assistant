# The budget

Set with James on 2026-11-11. The amounts live in the database (`ref.current_budget_lines`); this file says how the budget works and why.

## Why the old one failed

The v2 envelopes were livable. "We have done it before." They failed because nobody checked them and nothing happened when a line ran over (James, 2026-11-11). Bill Pay was also short every month, so money in Joint looked spendable when a bill still needed it. That gap caused overdraft fees on Bill Pay through 2026.

## How it works

1. **Bill Pay covers the bills, automatically.** Fixed transfers from Joint to Bill Pay on each Lincoln payday and on VA day (`ref.current_transfers`). They're sized so Bill Pay covers every bill at its high month. Bills that swing (electric, water, internet, pest control, preschool) are planned at their 12-month high, so the low months leave a little extra in Bill Pay as its cushion. Three-paycheck months add to that cushion too.
2. **Joint is spending money.** Each Lincoln check leaves enough in Joint for two weeks of groceries and gas. VA on the 1st funds the monthly lines and the extra debt payment.
3. **Lines.** Food and Fuel reset each Lincoln payday. Fun money (one line each for James and Katelyn) is what's in each person's Personal account. It comes from each VA check, a set amount each, once a month (James, 2026-11-14, moved off the Lincoln checks so they cover Bill Pay, Food and Fuel). Shopping, Animals, Kids, Home and repairs, and Doctor and pharmacy reset on the 1st. Kids covers outings and activities for the girls, like Playland, and someday an activity for Amelia outside preschool once one is picked. Kid to Kid clothes stay in Shopping (James, 2026-11-22). The extra debt payment is what's left from VA after the other lines. It goes to the current target in [debt-plan.md](debt-plan.md). Any extra that doesn't go to debt is split between James's and Katelyn's Personal accounts (James, 2026-11-14).
4. **Running over.** A line that runs over borrows from Shopping (James's call). Once Shopping is empty too, spending stops until the next check. Fun money never borrows: "not a penny over, but zero interrogation under it."
5. **The daily check.** The briefing has a budget item every day, saying what each line has left. It turns YELLOW once Shopping is empty after covering the others. That item is the check nobody did before.

Food, Animals and Fuel keep those names, because the Level 3 Emergency Fund counts them as basic necessities ([on-track.md](on-track.md)).

## Which spending counts where

Sorting lives in the database, not in Era (James, 2026-11-24: option B, "learn and ask"). A purchase gets its line from the first of: someone's word on that charge, what the merchant is known to be, Era's category, or Claude's guess. The last two are guesses until someone confirms, and Claude asks about them once per merchant at the weekly check-in or on payday. Each answer is remembered, so a new situation never needs a new rule. How it works: [tools/sort_spending.md](../tools/sort_spending.md).

At the switch, merchant memory started from the old rules and every past merchant, and every past charge kept the line it had, so no number changed.

Spending counts by the transaction, not the account it came from (James, 2026-11-22: "too focused on accounts and not enough on transactions"). Bill Pay is for recurring bills, but people forget cards, so a purchase from Bill Pay counts the same as from Joint. Lowes Foods counts as Food and Chewy as Animals (Chewy stays on Bill Pay). Bills drop out on their own: a matched or proposed bill payment never counts against a line, and merchants that are always bills (water, preschool) are remembered as "not budget spending". Water comes as two charges, the bill plus a card fee. Both count with the bill.

Fun money is what's spent from a Personal account on things just for that person. The account is a hint: from a Personal account, a purchase that would be Shopping, or has no line, counts as fun money. Groceries, eating out (coffee included), gas, pets, the doctor and pharmacy, home and kids' outings bought from a Personal account count on their own lines instead, because sometimes the right card isn't at hand. Assume there was a reason and don't ask (James, 2026-11-16). Sam's Club, Costco and Walmart count as Food. Katelyn's checks from her Personal account stay fun money (decided 2026-11-15).

Sam's Club also sells the household's gas, and the bank data can't tell gas from groceries there. Sam's counts as Food; a Sam's charge that was gas gets a word on that one charge ("that Sam's charge was gas"), and it counts as Fuel. The plan to put all Sam's gas on James's Chase Freedom (James, 2026-11-14) is on hold: the card doesn't have enough credit available (James, 2026-11-22).

## When to revisit

- **January 2027.** Lincoln take-home should rise once the health plan moves to CHAMPVA. Redo the transfer split from the first January deposit. The December Lincoln transfers are smaller for the truck's holiday pause and go back to their normal amount with the first January check ([debt-plan.md](debt-plan.md)).
- **When a card is paid off.** Its minimum leaves the bills, so the Bill Pay transfers can drop or the extra debt line can grow.
- **When a line runs over two months in a row.** That's a pattern, not a one-off ([on-track.md](on-track.md)). Change the line or the habit, one fix at a time.

## How to ask about it

- What's left: `get_briefing` (budget item), or `query` on `calc.budget_status()`.
- What each paycheck funds and what's left of it: `query` on `calc.paycheck_plan()`.
- What counted against a line, and how it got there (`sorted_by`, `guessed`): `query` on `calc.spending_sorted(from, to)`.
- Guesses waiting for an answer: `query` on `calc.sort_questions()`.
- The whole plan on one page: the Budget Map (https://claude.ai/artifact/GAQ12uWHeCk57VsDjkRuGY). It reads the paycheck plan, bills, transfers, budget lines and cash projection live each time it opens, so it never needs rebuilding. For the account paychecks land in, it takes the budget lines out on each payday as if spent as planned.
- Changing an amount is a Claude Code job for now. On claude.ai, log it as an open question. Saying what a purchase or merchant is needs no build: `sort_spending`.
