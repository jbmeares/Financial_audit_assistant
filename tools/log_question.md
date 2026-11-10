# log_question

*Action.* Logs an open question for a person, or parks something learned on claude.ai that belongs in the repo.

**Takes** `person`, `question`, optionally `topic` and `kind` (`question`, the default, or `new_context`).

**Returns** the new `knowledge.open_questions` row.

**When** something is missing and can't be answered now ([rule 14](../constitution.md)), or on claude.ai when new context needs filing in the repo later ([rules 22 and 24](../constitution.md)). Check `knowledge.open_questions` first so nothing is asked twice.
