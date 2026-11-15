# Debt plan

James's order, from his interview on 2026-11-11. Balances, APRs, minimums and promo end dates live in `ref.current_debts`, not here.

## Order

1. **Promo balances first.** Any 0% or deferred-interest balance gets paid off before its promo ends, soonest end date first. One card can carry several promo parts, each with its own amount and end date (`ref.debt_buckets`, which also holds reduced-APR plans); the rest of its balance is at the regular APR (James, 2026-11-14, about CareCredit). "So we don't get screwed over by ourselves."
2. **Then avalanche.** Highest APR first, with as much as the budget can take.
3. **Free up money every pay cycle.** Release as much per paycheck as the household can handle, and send it to the current target. Each debt paid off adds its payment to the next one.

**The truck** is paid a fixed amount every Lincoln paycheck, more than its required monthly payment (James, 2026-11-14). The amounts are in `ref.debts` and the `auto-loan` bill. The payoff plan counts the per-paycheck amount, and when the truck is gone that money rolls to the next target.

**Holiday pause, Nov 2026 to Jan 2027** (James, 2026-11-15). The truck payment is skipped on the Nov 20, Dec 4, Dec 18 and Dec 31 Lincoln checks and starts again with the first January check, to leave room for Christmas gifts, Katelyn's birthday and some breathing room. Capital One showed the loan paid ahead, with the next payment due Jan 16, 2027. The pause is a gap between two versions of the `auto-loan` bill, and the payoff plan plans nothing on the truck for a month the bill is paused. The money stays in Joint: the Lincoln transfer to Bill Pay is smaller on the December checks (`ref.transfers`). Nov 20's transfer stays full, so that skipped payment covers Bill Pay's November shortfall.

The 401k loan is not in this plan. It's deducted from pay automatically ([goals.md](goals.md)).

**The loan from Katelyn's mom** sits outside the avalanche. It has no interest and no schedule, but James plans to pay it off with the tax refund or bonus in early 2027 (said 2026-11-11). "I hate owing people money."

The plan as it stands, with a payoff month for each debt, is `query` on `calc.debt_payoff_plan()` ([how it's worked out](../data/calculations.md)).

## Windfalls

Bonuses and tax refunds come around the start of each year. James puts them toward debt, or toward a large purchase they don't want to put on credit. Which one depends on the situation at the time, so ask him. Show both options with `what_if`.

## Cash floor

Right now: "don't go so negative that we can't pay for things." Extra payments never take a bank account below $0 before the next income, which matches what "on track" means today ([on-track.md](on-track.md)). The budget ([budget.md](budget.md)) doesn't replace it: the $0 floor stays as the backstop "until we start seeing progress" (James, 2026-11-14). Extra payments come from the budget's extra debt line, and only while the floor holds.

## What would change the plan

- One of the large purchases in [goals.md](goals.md) going ahead.
- A new promo balance, which goes to the front (step 1).
- A debt paid off: celebrate it, name the room it frees up and the next target ([rule 12](../constitution.md)).
