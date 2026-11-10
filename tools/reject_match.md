# reject_match

*Action.* Dismisses a proposed match for good. That transaction and bill are never paired again.

**Takes** `person`, `match_id`, optionally `reason`.

**Returns** the updated `knowledge.proposed_matches` row.

**When** the person says a pairing is wrong.
