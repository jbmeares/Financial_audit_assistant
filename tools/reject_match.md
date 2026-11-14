# reject_match

*Action.* Dismisses a proposed match. The matcher never pairs that transaction and bill again. If the rejection was a mistake, [reopen_match](reopen_match.md) takes it back.

**Takes** `person`, `match_id`, optionally `reason`.

**Returns** the updated `knowledge.proposed_matches` row.

**When** the person says a pairing is wrong.
