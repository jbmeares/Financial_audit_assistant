# create_era_rule

*Action.* Creates a transaction cleanup rule in Era (categorise, tag, rename, hide, flag, mark as transfer), in two steps.

**Step 1, preview.** Takes `person`, `rule` and `summary`. Era checks the filters against the last 90 days. Returns the match count, up to 10 sample matches and a `preview_id`. Nothing is created in Era.

**Step 2, confirm.** Only after the person says yes. Takes `person` and `preview_id`, nothing else. The stored rule is sent exactly as previewed, once. A preview expires after 30 minutes.

**The rule** uses Era's REST fields: `ruleName`, `filters`, `actions`, and optionally `description`, `priority`, `isActive`, `applyRetroactively` (Era's default is false), `appliesFrom`, `appliesTo`, `applicationScope`, `group`. For example:

```json
{"ruleName": "Coffee shops",
 "filters": [{"type": "merchant_match", "pattern": "Blue Bottle", "mode": "contains"}],
 "actions": [{"type": "set_category", "categoryKey": "fcat_…", "categoryDisplayName": "Coffee shops"}]}
```

Category and tag keys come from the Era connector.

**Guards**
- The preview uses the Era read key (Era's preview needs only `banking:read`). The create uses the Era write key, which nothing else uses.
- Transaction rules only, no pattern rules. Only the fields above are sent.
- A retried confirm sends nothing. If Era refused, the preview is marked failed and a new preview is needed. If Era couldn't be reached mid-send, it says so: check Era's rules list before trying again.
- Every preview and its outcome is kept in `knowledge.era_rule_previews`. The monthly review looks at rules created ([playbooks/monthly-review.md](../playbooks/monthly-review.md)).
