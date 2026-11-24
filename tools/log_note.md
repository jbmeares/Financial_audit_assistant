# log_note

*Action.* Saves a note the moment something worth keeping happens in a chat, so James and the build sessions can learn from it without anyone pasting the chat across.

**Takes** `person` (who said it), `kind`, `said` (their words, or close), optionally `chat_answer` (what the chat had just said) and `topic`.

**Returns** the new `knowledge.chat_notes` row, with status `new`.

**When** there's no end-of-chat step. Note it as it happens, when the person:

| Kind | They… |
| --- | --- |
| `correction` | correct something the chat said |
| `decision` | state a decision plainly ("let's do it", "we're going with…"). A what-if, a leaning or a "maybe" isn't one, and never ask them to decide so there's something to note ([rule 10](../constitution.md)) |
| `fact` | say something new about the accounts, bills, income or plans (a card swap, a bill change) |
| `confusion` | say something the chat said was unclear |
| `feedback` | say how the chat is going, good or bad ("that worked well") |

Then say "Noted." in the reply, every time. Nothing is saved without the person seeing it.

**Not for** what another tool already saves: a dated event goes to [log_life_event](log_life_event.md), an open question or a story for a repo file to [log_question](log_question.md). A correction is always noted, even when [record_balance](record_balance.md) or another tool also saved the fix, because it shows where the chat went wrong. Katelyn can save notes ([rule 20](../constitution.md)).

**Review** happens in Claude Code: read `knowledge.chat_notes` where `status = 'new'`, act on each note, then set `status = 'reviewed'`, `reviewed_at = now()` and a `review_note` saying what was done. What was said can't be edited.
