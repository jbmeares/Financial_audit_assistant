# note_bill_cycle

*Action.* Changes one cycle of a bill without changing the bill: "holding it until the 20th", "this month it's $95", "no bill this month". The projection, the payday plan and the matcher use the note, and the next cycle is back to normal on its own. Before this, a one-month hold took three bill versions.

**Takes** `person`, `bill_key`, `due_on` (the cycle's normal due date, from `calc.bill_cycles`), `note` (why, in their words), and one of:
- `move_to`: the new date. Within the same month for a monthly bill (so it stays that month's payment); at most 14 days for a week-based one.
- `amount`: this cycle's amount.
- `skip: true`: no bill this cycle.

A note with none of the three puts the cycle back to normal.

**Returns** the new `ref.bill_cycle_notes` row. Notes are never changed or deleted; the latest for a cycle wins. `calc.bill_cycles.cycle_note` shows it.

**When** someone says a bill is different this one time. For a lasting change (a new amount every month, a new due day), use [update_bill](update_bill.md).

**Guards** a paid cycle can't be noted, a monthly cycle can't move into another month, and the date has to be the cycle's normal due date. Katelyn adds context but doesn't change bills ([rule 20](../constitution.md)).
