# tools/

What each finance MCP tool does and when to use it. One file per tool.

**Goes here**
- What the tool returns or writes, its guards, and when to reach for it.
- Written after Block F, describing what was actually built.

**Doesn't go here**
- Conversation scripts. Those go in `playbooks/`.
- How the tools are implemented. That lives in `infra/functions/finance-mcp/`.

## The tools

The connector is "Household finance" on claude.ai, and `.mcp.json` in Claude Code. Both reach the same server.

| Tool | Kind | Use it for |
| --- | --- | --- |
| [get_briefing](get_briefing.md) | read | Today's picture. Start here |
| [query](query.md) | read | Detail: transactions, balances, bills, sums |
| [what_if](what_if.md) | read | "Can we afford…", "what if we pay extra…" |
| [read_context](read_context.md) | read | A file from this repo |
| [confirm_match](confirm_match.md) | action | A pending match is a bill payment |
| [reject_match](reject_match.md) | action | A pending match is wrong |
| [record_balance](record_balance.md) | action | Someone stated a balance |
| [log_life_event](log_life_event.md) | action | Something happened, with a date |
| [update_bill](update_bill.md) | action | A bill changed, is new or ended |
| [void_entry](void_entry.md) | action | Undo a wrong ledger entry |
| [log_question](log_question.md) | action | Park a question or new context |
| [answer_question](answer_question.md) | action | Close an open question |
| [create_era_rule](create_era_rule.md) | action | A cleanup rule in Era, preview first |
| [whoami](whoami.md) | read | Check the sign-in |

## True of every tool

- **Actions need a person**, `james` or `katelyn`: whoever you're talking to ([rule 17](../constitution.md)). Rule 20 (what Katelyn changes) is yours to keep; the tools don't enforce it.
- **One sentence on failure.** An error comes back as a plain sentence you can repeat. Nothing is half-written: each action is one database function in one transaction.
- **Repeats are harmless.** The same action with the same arguments within 10 minutes returns the first result instead of writing again.
- **If the database can't be reached**, every tool says so. Say you can't see the numbers; don't guess them ([rule 1](../constitution.md)).
- **Every call is logged** in `knowledge.tool_calls`: the tool, the person, ok or error, and how long it took.
