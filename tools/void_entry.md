# void_entry

*Action.* Cancels one ledger entry that was wrong. The original stays on record, marked void ([rule 5](../constitution.md)).

**Takes** `person`, `entry` (`payment`, `balance_statement` or `adjustment`), `entry_id`, and `reason` (required).

**Returns** the new `ledger.voids` row.

**When** a confirmation or a stated balance turns out to be wrong. Voiding a payment that came from a match also rejects that pairing, so it isn't proposed again.
