# log_life_event

*Action.* Records the date, and the amount if someone said one, of something that happened: a repair, a loss, a windfall. Later reviews use it to see the reason behind a hard month ([rule 23](../constitution.md)).

**Takes** `person`, `occurred_on`, `title`, optionally `amount` and `story_path` (a file under `life/`).

**Returns** the new `knowledge.life_events` row.

**When** after responding to the person first ([rule 7](../constitution.md)). The story goes in a `life/` file (CLAUDE.md, "Editing this repo"); on claude.ai, park it with [log_question](log_question.md) as `new_context`.
