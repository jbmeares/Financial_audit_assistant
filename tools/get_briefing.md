# get_briefing

*Reads.* Today's picture, in one row: a RED, YELLOW or GREEN level, the next income date, and a list of items, RED first. The items cover overdraft risk (only through the next two paychecks; a dip that stays inside an account's overdraft buffer only before the next pay date), bills due before the next income, the payday plan from two days before a pay date through the pay date (it replaces the bills-due item then; see [playbooks/payday.md](../playbooks/payday.md)), pending matches, stale accounts, accounts still to connect or dropped by Era (from `calc.connection_status`), keys expiring within 30 days, failed pulls, open questions, and a budget item saying what each budget line has left (YELLOW once Shopping is empty after covering other lines; see [strategy/budget.md](../strategy/budget.md)).

**Takes** nothing.

**Returns** the `calc.briefing` row plus `numbers_age_hours` (since the last good pull), `briefing_age_hours` and `server_time`. The first line of the answer says how old the numbers are.

**When** at the start of every money conversation (CLAUDE.md, "Start of every session"). Open with anything RED, then one line on what's due before the next income, then one line on what the budget has left. With a `payday_plan` item, show the plan as one block instead of the due line.

**Guards** read-only. If no pull has finished, it says so instead of showing numbers as current ([rule 1](../constitution.md)).
