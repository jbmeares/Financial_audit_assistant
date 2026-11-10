# update_bill

*Action.* Changes a bill by closing its current version and adding a new one, so history is kept. Also adds a new bill or ends one.

**Takes** `person`, `bill_key`, and:
- `changes`: any of `name`, `amount`, `amount_kind` (`fixed` or `variable`), `tolerance`, `due_day`, `account_key`, `autopay`, `cadence` (`monthly`, `quarterly`, `semiannual`, `annual`), `cadence_anchor`, `note`;
- optionally `effective_from` (default today) and `end: true` to end the bill.

A new bill needs every required field: name, amount, amount_kind, due_day, account_key, autopay and cadence.

**Returns** the new `ref.bills` row.

**When** follow [playbooks/new-bill.md](../playbooks/new-bill.md). A field nobody stated becomes an open question, never a guess ([rule 6](../constitution.md)).
