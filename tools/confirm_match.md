# confirm_match

*Action.* Turns a pending proposed match into a ledger payment, so the bill counts as paid for that month ([rule 4](../constitution.md)). It closes the other proposals for the same transaction and re-runs the numbers.

**Takes** `person`, `match_id` (`knowledge.proposed_matches.id`), and optionally `alias` (a name the bill shows up as, saved for future matching) and `note`.

**Returns** the new `ledger.payments` row.

**When** the person says yes to a pending match from the briefing. If two bills tied (status `ambiguous`), ask which one first ([rule 5](../constitution.md)).

**Undo** [void_entry](void_entry.md) with `entry: "payment"`.
