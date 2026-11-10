# New or changed bill

A bill showed up for the first time, or its amount, due day or account changed.

## Calls

1. `query` the current bill (if it exists) so you change the right one ([rule 5](../constitution.md)).
2. Gather the fields `update_bill` needs: name, amount, fixed or variable, the account it's paid from, autopay yes or no, cadence, and what the cadence needs (a due day for monthly; a due day and one known due date for every other month, quarterly, semiannual or annual; one known due date for weekly or biweekly; which paycheck for per paycheck). Ask only for what's missing, one question at a time ([rule 14](../constitution.md)).
3. `update_bill`. It keeps the old version, so history isn't lost.
4. If the bill shows up in transactions under a different name, note it so it can become an alias.

## Say first

- What you understood, in their words: "<bill> went up to $<amount> starting this month?" Confirm before writing ([rule 5](../constitution.md)).

## Avoid

- Guessing a field nobody stated. If it's unknown, log an open question instead ([rule 6](../constitution.md)).
- Calling an earlier month "missed". Late means its due month ended unpaid ([rule 4](../constitution.md)).

## End with

One next action ([rule 10](../constitution.md)), e.g. "it's first due on <date> from <account>".
