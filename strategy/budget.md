# The budget

Set with James on 2026-11-11. The amounts live in the database (`ref.current_budget_lines`); this file says how the budget works and why.

## Why the old one failed

The v2 envelopes were livable. "We have done it before." They failed because nobody checked them and nothing happened when a line ran over (James, 2026-11-11). Bill Pay was also short every month, so money in Joint looked spendable when a bill still needed it. That gap caused overdraft fees on Bill Pay through 2026.

## How it works

1. **Bill Pay covers the bills, automatically.** Fixed transfers from Joint to Bill Pay on each Lincoln payday and on VA day (`ref.current_transfers`). They're sized so Bill Pay covers every bill at its high month. Bills that swing (electric, water, internet, pest control, preschool) are planned at their 12-month high, so the low months leave a little extra in Bill Pay as its cushion. Three-paycheck months add to that cushion too.
2. **Joint is spending money.** Each Lincoln check leaves enough in Joint for two weeks of groceries and gas. VA on the 1st funds the monthly lines and the extra debt payment.
3. **Lines.** Food and Fuel reset each Lincoln payday. Fun money (one line each for James and Katelyn) is what's in each person's Personal account. It comes from each VA check, a set amount each, once a month (James, 2026-11-14, moved off the Lincoln checks so they cover Bill Pay, Food and Fuel). Shopping, Animals, Home and repairs, and Doctor and pharmacy reset on the 1st. The extra debt payment is what's left from VA after the other lines. It goes to the current target in [debt-plan.md](debt-plan.md). Any extra that doesn't go to debt is split between James's and Katelyn's Personal accounts (James, 2026-11-14).
4. **Running over.** A line that runs over borrows from Shopping (James's call). Once Shopping is empty too, spending stops until the next check. Fun money never borrows: "not a penny over, but zero interrogation under it."
5. **The daily check.** The briefing has a budget item every day, saying what each line has left. It turns YELLOW once Shopping is empty after covering the others. That item is the check nobody did before.

Food, Animals and Fuel keep those names, because the Level 3 Emergency Fund counts them as basic necessities ([on-track.md](on-track.md)).

## Which spending counts where

`ref.current_budget_rules` maps Era categories, merchants and accounts to lines. The most specific rule wins. Sam's Club, Costco and Walmart count as Food.

A purchase from Bill Pay counts the same as from Joint (James, 2026-11-22). Errands sometimes get paid from Bill Pay when the Joint card isn't at hand: "It happens." Lowes Foods counts as Food and Chewy as Animals (Chewy stays on Bill Pay). Bill payments don't count, because a matched or proposed bill payment never counts against a line. From Bill Pay, the catch-all categories (utilities, misc, subscriptions) count against nothing, since there they're bills that haven't matched yet. Water comes as two charges, the bill plus a card fee. Both count with the bill, never as spending.

Fun money is what's spent from a Personal account on things just for that person. Groceries, eating out (coffee included) and gas bought from a Personal account count as Food and Fuel instead, because sometimes the right card isn't at hand. Assume there was a reason and don't ask (James, 2026-11-16). That covers Era's Food, Eating out and Fuel categories (and their older names), plus Sam's Club, Costco and Walmart. Era's "Personal account purchases are Fun money" rule skips the same purchases, so they keep their own category there too. Katelyn's checks from her Personal account stay fun money (decided 2026-11-15). A catch-all sends other categories to Shopping, so nothing goes unseen.

**Open:** Sam's Club also sells the household's gas, and the bank data can't tell gas from groceries there. Plan: all Sam's gas goes on James's Chase Freedom (James, 2026-11-14), and a rule sends Sam's charges on that card to Fuel.

## When to revisit

- **January 2027.** Lincoln take-home should rise once the health plan moves to CHAMPVA. Redo the transfer split from the first January deposit. The December Lincoln transfers are smaller for the truck's holiday pause and go back to their normal amount with the first January check ([debt-plan.md](debt-plan.md)).
- **When a card is paid off.** Its minimum leaves the bills, so the Bill Pay transfers can drop or the extra debt line can grow.
- **When a line runs over two months in a row.** That's a pattern, not a one-off ([on-track.md](on-track.md)). Change the line or the habit, one fix at a time.

## How to ask about it

- What's left: `get_briefing` (budget item), or `query` on `calc.budget_status()`.
- What each paycheck funds and what's left of it: `query` on `calc.paycheck_plan()`.
- What counted against a line: `query` on `calc.budget_spending(from, to)`.
- The whole plan on one page: the Budget Map (https://claude.ai/artifact/GAQ12uWHeCk57VsDjkRuGY). It reads the paycheck plan, bills, transfers, budget lines and cash projection live each time it opens, so it never needs rebuilding. For the account paychecks land in, it takes the budget lines out on each payday as if spent as planned.
- Changing an amount or a rule is a Claude Code job for now. On claude.ai, log it as an open question.
