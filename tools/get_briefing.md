# get_briefing

*Reads.* Today's picture, in one row: a RED, YELLOW or GREEN level, the next income date, and a list of items, RED first. The items cover overdraft risk before the next income, bills due before then, pending matches, stale accounts, keys expiring within 30 days, failed pulls and open questions.

**Takes** nothing.

**Returns** the `calc.briefing` row plus `numbers_age_hours` (since the last good pull), `briefing_age_hours` and `server_time`. The first line of the answer says how old the numbers are.

**When** at the start of every money conversation (CLAUDE.md, "Start of every session"). Open with anything RED, then one line on what's due before the next income.

**Guards** read-only. If no pull has finished, it says so instead of showing numbers as current ([rule 1](../constitution.md)).
