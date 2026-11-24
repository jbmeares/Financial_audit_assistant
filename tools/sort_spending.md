# sort_spending

*Action.* Records what a purchase or a merchant is for the budget, so the answer is remembered and the question never comes back ([rule 25](../constitution.md)).

**How a charge gets its line**, first match wins (`calc.spending_sorted`):

1. **Someone said so** about that one charge. It stands exactly as said.
2. **Merchant memory** (`ref.current_merchant_memory`): "Chewy is Animals", "Montmorenci is a bill", or "Amazon varies, so Era's category decides".
3. **Era's category**, through one short map by Era's category key (`ref.current_category_map`), so a rename in Era keeps working.
4. **Claude's guess**, saved with this tool, for a merchant Era's category can't place.

Steps 3 and 4 are guesses. Each guessed charge is labeled `guessed`, the briefing's budget item says how much of each line is guessed, and the `sort_questions` item lists each guessed merchant once (`calc.sort_questions()`).

The account is a hint, not a rule: from a Personal account, a purchase on Shopping or with no line counts as that person's fun money. Food, Fuel, Animals, Kids, Home and repairs, and Doctor and pharmacy count from any account. A merchant remembered as a bill stays out of the budget from any account.

**Takes** `person`, `kind`, and:

| `kind` | Also takes | Means |
| --- | --- | --- |
| `merchant` | `merchant`, `line` | What this merchant always is. `line` is a `line_key`, `none` (not budget spending, such as a bill) or `varies` (sells many kinds of things, so Era's category decides) |
| `one_charge` | `era_transaction_id`, `line` | Just this charge ("that Sam's charge was gas"). `line` is a `line_key` or `none` |
| `skip` | `merchant` | They don't know. It stays a guess and isn't asked about again |
| `guess` | `merchant`, `line` | Your own guess, for a merchant Era's category can't place. Still labeled a guess and still asked about. Never replaces what someone said |

Optionally `note`: why, in their words. `merchant` is the `merchant_key` from `calc.sort_questions`.

**Returns** the new `knowledge.sort_answers` row. Answers are a record: never changed or deleted. A newer answer wins.

**When** at the weekly check-in or on payday, after the rest of the routine: go through the `sort_questions` item, one merchant at a time, with the guess and why ("Tractor Supply, I'd put it in Animals. Right?"). Never as a warning, and never in the middle of an unrelated chat. Also any time someone says on their own what a charge was. No `log_note` needed for an answer saved here.

**Guards** an unknown line, transaction or kind is refused with a sentence. A guess can't replace what someone said. Never guess on a write ([rule 5](../constitution.md)): if the answer is unclear, ask one short question. Katelyn can answer too: saying what a purchase was is context, like answering an open question ([rule 20](../constitution.md)).
