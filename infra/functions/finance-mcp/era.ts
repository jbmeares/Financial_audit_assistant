// create_era_rule talks to Era's REST API (https://forge.era.app/api).
//
//   preview  POST /banking/rules/preview  needs only banking:read, so it uses ERA_READ_KEY.
//            Era's docs: "Nothing is written, so banking:read is enough."
//   create   POST /banking/rules          needs banking:write, so it uses ERA_WRITE_KEY.
//            The write key is used for nothing else.
//
// Only transaction rules are allowed in v1 (no pattern rules), and only these fields pass
// through to Era, so a rule can't carry anything the preview didn't show.

import { ToolError } from "./db.ts";
import type { Fetch } from "./context.ts";

export const ERA_BASE = "https://forge.era.app/api";

const RULE_FIELDS = [
  "ruleName",
  "description",
  "priority",
  "filters",
  "actions",
  "isActive",
  "applyRetroactively",
  "appliesFrom",
  "appliesTo",
  "applicationScope",
  "group",
] as const;

const FILTER_TYPES = [
  "merchant_match", "description_match", "amount_range", "account_scope", "and", "or", "not",
  "category", "tag", "transaction_type", "date_temporal", "rule_was_applied",
];
const ACTION_TYPES = [
  "set_category", "add_tag", "remove_tag", "rename_merchant", "hide_transaction",
  "set_review_status", "update_description", "mark_transfer",
];

/** Checks a rule and returns only the fields Era should get. */
export function cleanRule(input: unknown): Record<string, unknown> {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new ToolError("The rule must be an object with ruleName, filters and actions, in Era's REST format.");
  }
  const rule = input as Record<string, unknown>;
  const unknown = Object.keys(rule).filter((k) => !(RULE_FIELDS as readonly string[]).includes(k));
  if (unknown.length) {
    throw new ToolError(`The rule has fields this tool doesn't send: ${unknown.join(", ")}. It sends: ${RULE_FIELDS.join(", ")}. Pattern rules aren't supported here.`);
  }
  if (typeof rule.ruleName !== "string" || !rule.ruleName.trim()) {
    throw new ToolError("The rule needs a ruleName.");
  }
  const checkList = (key: "filters" | "actions", allowed: string[]) => {
    const list = rule[key];
    if (!Array.isArray(list) || list.length === 0) throw new ToolError(`The rule needs at least one entry in ${key}.`);
    for (const [i, item] of list.entries()) {
      const type = (item as { type?: unknown })?.type;
      if (typeof type !== "string" || !allowed.includes(type)) {
        throw new ToolError(`${key}[${i}] has type "${String(type)}". Allowed: ${allowed.join(", ")}.`);
      }
    }
  };
  checkList("filters", FILTER_TYPES);
  checkList("actions", ACTION_TYPES);
  const out: Record<string, unknown> = {};
  for (const k of RULE_FIELDS) if (rule[k] !== undefined) out[k] = rule[k];
  return out;
}

export interface EraCallResult {
  ok: boolean;
  status: number;
  body: unknown;
}

export async function eraPost(path: string, key: string | undefined, keyName: string, body: unknown, f: Fetch = fetch, timeoutMs = 25000): Promise<EraCallResult> {
  if (!key) throw new ToolError(`The ${keyName} secret is missing, so Era can't be reached for this.`);
  let res: Response;
  try {
    res = await f(`${ERA_BASE}${path}`, {
      method: "POST",
      headers: { "X-API-Key": key, "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    return { ok: false, status: 0, body: { error: String(e) } };
  }
  const text = await res.text();
  let parsed: unknown = text;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch { /* keep the text */ }
  return { ok: res.ok, status: res.status, body: parsed };
}

/** One sentence describing an Era error response. */
export function eraErrorText(r: EraCallResult, keyName: string): string {
  if (r.status === 0) return `Era couldn't be reached (${(r.body as { error?: string })?.error ?? "no answer"}).`;
  if (r.status === 401) return `Era rejected ${keyName} (HTTP 401). The key may have expired: see the key rotation runbook.`;
  if (r.status === 403) return `Era refused: ${keyName} doesn't have the scope for this (HTTP 403).`;
  if (r.status === 429) return "Era is rate-limiting calls right now. Try again in a minute.";
  const b = r.body as Record<string, unknown> | string | null;
  let detail = "";
  if (b && typeof b === "object") {
    const errs = b.errors as Record<string, unknown> | undefined;
    const flat = errs ? Object.values(errs).flat().map(String) : [];
    detail = [b.message, b.title, b.detail, ...flat].filter((x) => typeof x === "string" && x).join(" ");
  } else if (typeof b === "string") {
    detail = b.slice(0, 300);
  }
  return `Era answered HTTP ${r.status}${detail ? `: ${detail}` : ""}.`;
}
