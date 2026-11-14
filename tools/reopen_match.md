# reopen_match

*Action.* Takes back a rejection that was a mistake. The match goes back to pending, so it can be confirmed with [confirm_match](confirm_match.md).

**Takes** `person`, `match_id` and `reason` (what was wrong about the rejection).

**Returns** the updated `knowledge.proposed_matches` row. Its note keeps the rejection on record: who rejected it, when, and why.

**When** the person says a rejection was wrong, for example their answer was misread. It won't reopen a match whose transaction is already matched or paid for another bill, or a proposal a build withdrew (those come back on their own).
