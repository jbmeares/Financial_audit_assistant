// The finance tools (build spec F2). Each read runs as assistant_read in a read-only
// transaction; each action calls exactly one named database function as assistant_act.
// Every call is logged (F5) by the caller in index.ts.

import { type Db, type Row, ToolError } from "./db.ts";
import { type Fetch, readContext } from "./context.ts";
import { cleanRule, eraErrorText, eraPost } from "./era.ts";

export interface Deps {
  db: Db;
  fetch?: Fetch;
  env: (name: string) => string | undefined;
  caller: { email: string; userId: string; clientId: string; expiresAt: string };
}

export interface ToolResult {
  result: unknown;
  /** One line put in front of the JSON, for the thing Claude should say first. */
  lead?: string;
}

type Args = Record<string, unknown>;
type Handler = (args: Args, deps: Deps) => Promise<ToolResult>;

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations: Record<string, boolean>;
  handler: Handler;
}

// ---------------------------------------------------------------- argument helpers

const PERSON = {
  type: "string",
  enum: ["james", "katelyn"],
  description: "Who this is for: the person you're talking to. Ask if it isn't clear (constitution rule 17).",
};

function str(args: Args, key: string, required = true): string | null {
  const v = args[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new ToolError(`${key} is required.`);
    return null;
  }
  if (typeof v !== "string") throw new ToolError(`${key} must be text.`);
  return v;
}

function num(args: Args, key: string, required = true): number | null {
  const v = args[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new ToolError(`${key} is required.`);
    return null;
  }
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) throw new ToolError(`${key} must be a number.`);
  return n;
}

function int(args: Args, key: string, required = true): number | null {
  const n = num(args, key, required);
  if (n !== null && !Number.isInteger(n)) throw new ToolError(`${key} must be a whole number.`);
  return n;
}

function date(args: Args, key: string, required = true): string | null {
  const v = str(args, key, required);
  if (v !== null && !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw new ToolError(`${key} must be a date like 2026-11-10.`);
  return v;
}

function only(args: Args, allowed: string[]) {
  const extra = Object.keys(args).filter((k) => !allowed.includes(k));
  if (extra.length) throw new ToolError(`This tool doesn't take: ${extra.join(", ")}. It takes: ${allowed.join(", ") || "nothing"}.`);
}

/** A JSON argument. Sent as text and cast in SQL, so the driver can't encode it twice. */
class Json {
  constructor(readonly value: unknown) {}
}
const json = (v: unknown) => new Json(v);

/** Calls one named action and returns its row as JSON. */
async function action(db: Db, fn: string, args: unknown[]): Promise<Row> {
  const placeholders = args.map((a, i) => (a instanceof Json ? `$${i + 1}::text::jsonb` : `$${i + 1}`)).join(", ");
  const params = args.map((a) => (a instanceof Json ? JSON.stringify(a.value) : a));
  return await db.act(async (tx) => {
    const rows = await tx.unsafe(`select to_jsonb(r) as row from actions.${fn}(${placeholders}) r`, params as never[]);
    return rows[0]?.row as Row;
  });
}

const READ = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const WRITE = { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false };

// ---------------------------------------------------------------- the tools

export const TOOLS: Tool[] = [
  {
    name: "get_briefing",
    title: "Today's money picture",
    description:
      "Start here in every money conversation. Returns today's briefing: a RED, YELLOW or GREEN level, the next income date, and a list of items (overdraft risk, bills due before the next income, pending matches, stale accounts, keys expiring, failed pulls, open questions), RED first. Always says how old its numbers are: say that age when it matters, and never present old numbers as current. Open with anything RED, then one line on what's due before the next income.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: READ,
    handler: async (args, { db }) => {
      only(args, []);
      const row = await db.read(async (tx) => {
        const r = await tx`
          select to_jsonb(b) || jsonb_build_object(
                   'numbers_age_hours', round((extract(epoch from now() - b.numbers_as_of) / 3600)::numeric, 1),
                   'briefing_age_hours', round((extract(epoch from now() - b.generated_at) / 3600)::numeric, 1),
                   'server_time', now()) as row
            from calc.briefing b`;
        return r[0]?.row as Row | undefined;
      });
      if (!row) {
        return { result: null, lead: "There's no briefing yet: the calculations haven't run. Say you can't see the numbers yet." };
      }
      const age = row.numbers_as_of == null
        ? "No pull has finished yet, so these numbers have no as-of time."
        : `Numbers as of ${row.numbers_as_of} (${row.numbers_age_hours} hours old). Level ${row.level}.`;
      return { result: row, lead: age };
    },
  },
  {
    name: "query",
    title: "Look something up in the database",
    description:
      "Runs one read-only SELECT (or WITH ... SELECT) as assistant_read and returns the rows as JSON. Use it for detail the briefing doesn't show: transactions, balances, bills, matches, life events, open questions. Schemas: raw (what Era sent: era_transactions with amount negative = money out, occurred_on, merchant, pending; era_accounts; era_balances), ref (current_accounts, current_bills, current_bill_aliases, current_debts, current_income_sources, current_api_keys), ledger (payments_effective, balance_statements_effective), knowledge (proposed_matches, open_questions, life_events), calc (bill_cycles, cash_projection, account_balances, debt_snapshot, briefing). Always schema-qualify names. Limits: 5 seconds, at most 500 rows (truncated: true means there were more). read_context(\"data/schema.md\") explains every table. Do sums of more than two numbers here, not in prose (rule 2).",
    inputSchema: {
      type: "object",
      properties: {
        sql: { type: "string", description: "One SELECT statement. Writes are refused." },
        limit: { type: "integer", minimum: 1, maximum: 500, description: "Most rows to return. Default 500." },
      },
      required: ["sql"],
      additionalProperties: false,
    },
    annotations: READ,
    handler: async (args, { db }) => {
      only(args, ["sql", "limit"]);
      const sql = str(args, "sql")!;
      const limit = int(args, "limit", false) ?? 500;
      if (limit < 1 || limit > 500) throw new ToolError("limit is between 1 and 500.");
      const rows = await db.read(async (tx) => {
        const r = await tx`select mcp.run_query(${sql}, ${limit}) as rows`;
        return (r[0]?.rows ?? []) as Row[];
      });
      const truncated = rows.length > limit;
      const out = truncated ? rows.slice(0, limit) : rows;
      return {
        result: { row_count: out.length, truncated, rows: out },
        lead: truncated ? `Showing the first ${limit} rows; there are more. Narrow the query or aggregate.` : undefined,
      };
    },
  },
  {
    name: "what_if",
    title: "What happens if…",
    description:
      'Answers "can we afford…" and "what if we pay extra…" by re-running the 60-day projection with changes, and returns the difference from the normal projection: each account\'s lowest balance and its date, below-zero days, and debt payoff dates that move. Writes nothing. Pass one change or a list. Change types: {"type": "extra_payment", "debt_key", "amount", "on": "YYYY-MM-DD", "account_key", "monthly": true|false}, {"type": "skip_bill", "bill_key", "due_month": "YYYY-MM-01"}, {"type": "one_off_expense", "account_key", "amount", "on", "label"}, {"type": "income_change", "income_key", "amount", "from"}. Keys come from ref.current_* (use query). Never do this math in prose (rule 2).',
    inputSchema: {
      type: "object",
      properties: {
        changes: {
          description: "One change object, or a list of them.",
          anyOf: [{ type: "object" }, { type: "array", items: { type: "object" } }],
        },
      },
      required: ["changes"],
      additionalProperties: false,
    },
    annotations: READ,
    handler: async (args, { db }) => {
      only(args, ["changes"]);
      const changes = args.changes;
      if (changes === undefined || changes === null) throw new ToolError("changes is required.");
      const result = await db.read(async (tx) => {
        const r = await tx`select calc.what_if(${JSON.stringify(changes)}::text::jsonb) as result`;
        return r[0]?.result;
      }, 10000);
      return { result };
    },
  },
  {
    name: "read_context",
    title: "Read a repo file",
    description:
      'Returns a Markdown file from the household repo: the words behind the numbers. Start with "CLAUDE.md" (the map) and "constitution.md" (the rules), then "people/<name>.md" for whoever you\'re talking to. Other folders: life/, strategy/, playbooks/, tools/, data/schema.md, inbox/. End a path with "/" to list a folder, or pass "" for the top level. Markdown only; never infra/. On claude.ai the repo is read-only: park new context with log_question (kind "new_context").',
    inputSchema: {
      type: "object",
      properties: { path: { type: "string", description: 'For example "CLAUDE.md", "people/james.md" or "life/".' } },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: { ...READ, openWorldHint: true },
    handler: async (args, { env, fetch }) => {
      only(args, ["path"]);
      const result = await readContext(args.path ?? "", {
        token: env("GITHUB_CONTEXT_TOKEN"),
        repo: env("FINANCE_CONTEXT_REPO") ?? "jbmeares/financial_audit_assistant",
        ref: env("FINANCE_CONTEXT_REF") ?? "main",
        fetch,
      });
      return { result };
    },
  },
  {
    name: "confirm_match",
    title: "Confirm a bill payment",
    description:
      "Confirms a pending proposed match (knowledge.proposed_matches) as the payment of that bill for that month. This writes a ledger payment, which is what makes a bill paid (rule 4), closes other proposals for the same transaction, and re-runs the numbers. Only after the person says yes. If two bills tied (status ambiguous), ask which one first (rule 5). Optionally saves the transaction's merchant name as an alias so future matches score higher. A mistake is undone with void_entry, never erased.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        match_id: { type: "integer", description: "knowledge.proposed_matches.id" },
        alias: { type: "string", description: "Optional: a name this bill shows up as, to remember." },
        note: { type: "string" },
      },
      required: ["person", "match_id"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "match_id", "alias", "note"]);
      const row = await action(db, "confirm_match", [str(args, "person"), int(args, "match_id"), str(args, "alias", false), str(args, "note", false)]);
      return { result: row, lead: "Confirmed. The ledger payment is below." };
    },
  },
  {
    name: "reject_match",
    title: "Reject a proposed match",
    description:
      "Dismisses a proposed match for good: that transaction and bill are never paired again. Use when the person says a proposed pairing is wrong.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        match_id: { type: "integer", description: "knowledge.proposed_matches.id" },
        reason: { type: "string" },
      },
      required: ["person", "match_id"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "match_id", "reason"]);
      const row = await action(db, "reject_match", [str(args, "person"), int(args, "match_id"), str(args, "reason", false)]);
      return { result: row, lead: "Rejected. That pairing won't come back." };
    },
  },
  {
    name: "record_balance",
    title: "Record a balance someone told you",
    description:
      "Records a balance a person just stated for one account, then re-runs the projection. A stated balance beats Era's until Era reports a newer one (rule 3). If it differs from Era, mention that once, record it, and move on: don't ask again or read it back. account_key comes from ref.current_accounts. For a card or loan, give what is owed as stated.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        account_key: { type: "string", description: "ref.current_accounts.account_key" },
        balance: { type: "number" },
        as_of: { type: "string", description: "When the balance was true (ISO date-time). Default: now." },
        note: { type: "string" },
      },
      required: ["person", "account_key", "balance"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "account_key", "balance", "as_of", "note"]);
      const row = await action(db, "record_balance", [
        str(args, "person"), str(args, "account_key"), num(args, "balance"), str(args, "as_of", false), str(args, "note", false),
      ]);
      return { result: row, lead: "Recorded, and the numbers were re-run." };
    },
  },
  {
    name: "log_life_event",
    title: "Log a life event",
    description:
      "Records the date and dollar figure of something that happened (a repair, a loss, a windfall), so later reviews see the reason behind a hard month (rule 23). Respond to the person first (rule 7). The story itself belongs in a life/ file in the repo: give its path if there is one (story_path must start with life/ and end with .md). On claude.ai, also park the story with log_question kind new_context.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        occurred_on: { type: "string", description: "YYYY-MM-DD" },
        title: { type: "string" },
        amount: { type: "number", description: "Optional dollar figure, only if someone said it." },
        story_path: { type: "string", description: "Optional, like life/2026-q3.md" },
      },
      required: ["person", "occurred_on", "title"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "occurred_on", "title", "amount", "story_path"]);
      const row = await action(db, "log_life_event", [
        str(args, "person"), date(args, "occurred_on"), str(args, "title"), num(args, "amount", false), str(args, "story_path", false),
      ]);
      return { result: row };
    },
  },
  {
    name: "update_bill",
    title: "Change, add or end a bill",
    description:
      'Changes a bill by closing its current version and adding a new one from effective_from, so history is kept. Also adds a new bill (pass every required field) or ends one (end: true). changes can hold: name, amount, amount_kind ("fixed" or "variable"), tolerance (dollars), due_day (1-31), account_key (the account it\'s paid from), autopay (true/false), cadence ("monthly", "quarterly", "semiannual", "annual"), cadence_anchor (one known due date, needed unless monthly), note. A new bill needs name, amount, amount_kind, due_day, account_key, autopay and cadence: ask for any nobody stated, never guess (rule 6). Follow playbooks/new-bill.md.',
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        bill_key: { type: "string", description: "Short stable key, like \"phone\". A new key creates a new bill." },
        changes: { type: "object", description: "Only the fields that change (or all required fields for a new bill)." },
        effective_from: { type: "string", description: "YYYY-MM-DD. Default: today." },
        end: { type: "boolean", description: "true ends the bill from effective_from." },
      },
      required: ["person", "bill_key"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "bill_key", "changes", "effective_from", "end"]);
      const changes = args.changes ?? {};
      if (typeof changes !== "object" || Array.isArray(changes)) throw new ToolError("changes must be an object of fields.");
      if (args.end !== undefined && typeof args.end !== "boolean") throw new ToolError("end must be true or false.");
      const row = await action(db, "update_bill", [
        str(args, "person"), str(args, "bill_key"), json(changes), date(args, "effective_from", false), args.end ?? false,
      ]);
      return { result: row };
    },
  },
  {
    name: "void_entry",
    title: "Void a mistaken entry",
    description:
      "Cancels one ledger entry that was wrong, with a reason. The original stays on record (rule 5). entry is payment, balance_statement or adjustment. Voiding a payment that came from a confirmed match also rejects that pairing so it isn't proposed again.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        entry: { type: "string", enum: ["payment", "balance_statement", "adjustment"] },
        entry_id: { type: "integer", description: "The id of the row in ledger.payments, ledger.balance_statements or ledger.adjustments." },
        reason: { type: "string", description: "Required: why it's being voided." },
      },
      required: ["person", "entry", "entry_id", "reason"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "entry", "entry_id", "reason"]);
      const row = await action(db, "void_entry", [str(args, "person"), str(args, "entry"), int(args, "entry_id"), str(args, "reason")]);
      return { result: row, lead: "Voided. The original entry is kept, marked void." };
    },
  },
  {
    name: "log_question",
    title: "Park a question or new context",
    description:
      'Logs an open question for a person (kind "question"), or parks something learned on claude.ai that belongs in the repo (kind "new_context"), to be filed in the next Claude Code session (rules 22 and 24). Check knowledge.open_questions first so nothing is asked twice (rule 14).',
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        question: { type: "string", description: "The question, or the context to file, in plain words." },
        topic: { type: "string" },
        kind: { type: "string", enum: ["question", "new_context"], description: "Default question." },
      },
      required: ["person", "question"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "question", "topic", "kind"]);
      const row = await action(db, "log_question", [str(args, "person"), str(args, "question"), str(args, "topic", false), str(args, "kind", false) ?? "question"]);
      return { result: row };
    },
  },
  {
    name: "answer_question",
    title: "Answer an open question",
    description: "Records a person's answer to an open question (knowledge.open_questions) and closes it.",
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        question_id: { type: "integer" },
        answer: { type: "string" },
      },
      required: ["person", "question_id", "answer"],
      additionalProperties: false,
    },
    annotations: WRITE,
    handler: async (args, { db }) => {
      only(args, ["person", "question_id", "answer"]);
      const row = await action(db, "answer_question", [str(args, "person"), int(args, "question_id"), str(args, "answer")]);
      return { result: row };
    },
  },
  {
    name: "create_era_rule",
    title: "Create an Era cleanup rule",
    description:
      'Creates a transaction rule in Era (categorise, tag, rename, hide…) in two steps. Step 1, preview: pass person, rule and summary. Nothing is created: Era checks the filters against the last 90 days and you get the match count, sample matches and a preview_id. Show the person what it would match. Step 2, confirm: only after the person says yes, call again with person and preview_id (no rule). The stored rule is sent exactly as previewed, once; a preview expires after 30 minutes. rule uses Era\'s REST fields: ruleName, filters, actions, and optionally description, priority, isActive, applyRetroactively (Era\'s default is false), appliesFrom, appliesTo, applicationScope, group. Filter example: {"type": "merchant_match", "pattern": "Blue Bottle", "mode": "contains"}. Action examples: {"type": "set_category", "categoryKey": "fcat_…", "categoryDisplayName": "…"}, {"type": "add_tag", "tagKey": "…", "tagDisplayName": "…"}, {"type": "rename_merchant", "displayName": "…"}, {"type": "hide_transaction"}. Category and tag keys come from the Era connector. Pattern rules aren\'t supported.',
    inputSchema: {
      type: "object",
      properties: {
        person: PERSON,
        rule: { type: "object", description: "Step 1 only: the rule, in Era's REST format." },
        summary: { type: "string", description: "Step 1 only: one line saying what the rule does, in plain words." },
        preview_id: { type: "string", description: "Step 2 only: the preview_id from step 1." },
      },
      required: ["person"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    handler: async (args, deps) => {
      only(args, ["person", "rule", "summary", "preview_id"]);
      const person = str(args, "person")!;
      const previewId = str(args, "preview_id", false);
      if (previewId) {
        if (args.rule !== undefined || args.summary !== undefined) {
          throw new ToolError("Confirm takes only person and preview_id: the rule sent is the one stored with the preview.");
        }
        return await confirmEraRule(person, previewId, deps);
      }
      return await previewEraRule(person, args.rule, str(args, "summary")!, deps);
    },
  },
  {
    name: "whoami",
    title: "Who am I signed in as",
    description: "Says which account and which app this connection is signed in as, and when the sign-in expires. Reads no finance data.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: READ,
    handler: async (args, { caller }) => {
      only(args, []);
      return {
        result: {
          signed_in_as: caller.email,
          user_id: caller.userId,
          oauth_client_id: caller.clientId,
          token_expires_at: caller.expiresAt,
          server_time: new Date().toISOString(),
        },
      };
    },
  },
];

// ---------------------------------------------------------------- create_era_rule steps

async function previewEraRule(person: string, rawRule: unknown, summary: string, deps: Deps): Promise<ToolResult> {
  const rule = cleanRule(rawRule);
  const r = await eraPost("/banking/rules/preview", deps.env("ERA_READ_KEY"), "ERA_READ_KEY", { filters: rule.filters }, deps.fetch);
  if (!r.ok) throw new ToolError(`Era couldn't preview the rule, so nothing was saved. ${eraErrorText(r, "ERA_READ_KEY")}`);
  const body = (r.body ?? {}) as Record<string, unknown>;
  const staged = await action(deps.db, "stage_era_rule", [person, json(rule), summary]);
  const samples = Array.isArray(body.sampleMatches) ? body.sampleMatches.slice(0, 10) : [];
  return {
    lead: `Preview only: nothing was created in Era. It matches ${body.matchCount ?? "an unknown number of"} of the last ${body.totalEvaluated ?? "?"} transactions checked. Show the person, and confirm with preview_id ${staged.id} only after they say yes.`,
    result: {
      preview_id: staged.id,
      expires_at: staged.expires_at,
      summary,
      rule,
      match_count: body.matchCount ?? null,
      total_evaluated: body.totalEvaluated ?? null,
      sample_matches: samples,
    },
  };
}

async function confirmEraRule(person: string, previewId: string, deps: Deps): Promise<ToolResult> {
  if (!/^[0-9a-f-]{36}$/i.test(previewId)) throw new ToolError("That preview_id isn't one this tool gave out.");
  if (!deps.env("ERA_WRITE_KEY")) throw new ToolError("The ERA_WRITE_KEY secret is missing, so the rule can't be created.");
  const claimed = await action(deps.db, "claim_era_rule", [person, previewId]);
  const r = await eraPost("/banking/rules", deps.env("ERA_WRITE_KEY"), "ERA_WRITE_KEY", claimed.rule, deps.fetch);
  const body = (r.body ?? {}) as Record<string, unknown>;
  const ruleObj = (body.rule ?? {}) as Record<string, unknown>;
  const eraRuleId = typeof ruleObj.id === "string" ? ruleObj.id : null;
  if (r.ok) {
    await action(deps.db, "finish_era_rule", [previewId, true, eraRuleId, json(body), null]);
    return {
      lead: `Created in Era${eraRuleId ? ` as ${eraRuleId}` : ""}.`,
      result: {
        era_rule_id: eraRuleId,
        summary: claimed.summary,
        retroactive_status: body.retroactiveStatus ?? null,
        affected_transaction_count: body.affectedTransactionCount ?? null,
      },
    };
  }
  const why = r.status === 0
    ? `${eraErrorText(r, "ERA_WRITE_KEY")} It isn't known whether Era created the rule: check Era's rules list before trying again.`
    : eraErrorText(r, "ERA_WRITE_KEY");
  await action(deps.db, "finish_era_rule", [previewId, false, null, json(body ?? null), why]);
  throw new ToolError(`The rule wasn't created. ${why}`);
}
