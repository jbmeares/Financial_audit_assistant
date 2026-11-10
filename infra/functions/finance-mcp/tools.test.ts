// Tests every tool against a real Postgres built from infra/migrations (made-up data only).
// GitHub and Era are faked. Run with ./test, which builds the scratch database first.
//
//   SUPABASE_DB_URL  a connection as the non-superuser "postgres" role on a scratch database
//                    that has every migration applied and nothing else in it.

import { assert, assertEquals, assertMatch, assertRejects } from "jsr:@std/assert@1.0.13";
import postgres from "npm:postgres@3.4.7";
import { liveDb, ToolError } from "./db.ts";
import { checkPath } from "./context.ts";
import { type Deps, TOOLS } from "./tools.ts";

const url = Deno.env.get("SUPABASE_DB_URL");
if (!url) throw new Error("Set SUPABASE_DB_URL to the scratch test database (see ./test).");
const owner = postgres(url, { onnotice: () => {} });

type Call = { url: string; init?: RequestInit };
const calls: Call[] = [];
let fakeResponses: Array<() => Response> = [];

function fakeFetch(u: string, init?: RequestInit): Promise<Response> {
  calls.push({ url: u, init });
  const next = fakeResponses.shift();
  if (!next) throw new Error(`unexpected fetch to ${u}`);
  return Promise.resolve(next());
}

const env: Record<string, string> = {
  GITHUB_CONTEXT_TOKEN: "test-gh-token",
  ERA_READ_KEY: "test-read-key",
  ERA_WRITE_KEY: "test-write-key",
};
const deps: Deps = {
  db: liveDb,
  fetch: fakeFetch,
  env: (k) => env[k],
  caller: { email: "test@example.com", userId: "u", clientId: "c", expiresAt: "2026-11-10T00:00:00Z" },
};

async function call(name: string, args: Record<string, unknown> = {}) {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) throw new Error(`no tool ${name}`);
  return await tool.handler(args, deps);
}

async function refuses(name: string, args: Record<string, unknown>, like: RegExp) {
  const e = await assertRejects(() => call(name, args), ToolError);
  assertMatch(e.message, like);
}

// Made-up data, same shape as infra/tests/_fixture.sql. Written once as the owner.
await owner.unsafe(`
  insert into raw.pull_runs (kind, status, finished_at) values ('manual', 'ok', now());
  insert into raw.era_accounts (era_account_id, payload, content_hash) values ('test-acc', '{}', 'h');
  insert into raw.era_transactions (era_transaction_id, era_account_id, payload, content_hash, amount, occurred_on, pending, merchant)
  values ('test-tx-1', 'test-acc', '{}', 'h', -40.00, current_date - 2, false, 'TEST PHONE CO'),
         ('test-tx-2', 'test-acc', '{}', 'h', -25.00, current_date - 1, false, 'TEST STREAMING');
  insert into ref.accounts (account_key, era_account_id, name, owner, kind, role, valid_from)
  values ('test-checking', 'test-acc', 'Test checking', 'joint', 'checking', 'pays bills', '2026-01-01');
  insert into ref.bills (bill_key, name, amount, amount_kind, due_day, account_key, autopay, cadence, valid_from)
  values ('test-phone', 'Test phone', 40.00, 'fixed', 5, 'test-checking', true, 'monthly', '2026-01-01');
  insert into knowledge.proposed_matches (era_transaction_id, bill_key, due_month, score, reason, status)
  values ('test-tx-1', 'test-phone', date_trunc('month', current_date)::date, 90, 'test', 'pending'),
         ('test-tx-2', 'test-phone', date_trunc('month', current_date)::date, 75, 'test', 'pending');
  select calc.refresh_all();
`);

Deno.test("tools/list has every tool in the build spec", () => {
  const names = TOOLS.map((t) => t.name).sort();
  for (
    const n of [
      "get_briefing", "read_context", "query", "what_if", "confirm_match", "reject_match", "record_balance",
      "log_life_event", "update_bill", "void_entry", "log_question", "answer_question", "create_era_rule",
    ]
  ) assert(names.includes(n), `missing ${n}`);
  for (const t of TOOLS) assert(t.description.length > 40 && t.inputSchema.type === "object", t.name);
});

Deno.test("get_briefing returns the row and says how old the numbers are", async () => {
  const r = await call("get_briefing");
  const row = r.result as Record<string, unknown>;
  assert(["RED", "YELLOW", "GREEN"].includes(String(row.level)));
  assert("numbers_age_hours" in row);
  assertMatch(r.lead ?? "", /Numbers as of .* hours old/);
});

Deno.test("query reads, caps rows and refuses writes and role changes", async () => {
  const r = await call("query", { sql: "select bill_key from ref.current_bills" });
  assertEquals((r.result as { rows: unknown[] }).rows, [{ bill_key: "test-phone" }]);

  const big = await call("query", { sql: "select g from generate_series(1, 600) g" });
  const res = big.result as { row_count: number; truncated: boolean };
  assertEquals([res.row_count, res.truncated], [500, true]);

  await refuses("query", { sql: "delete from ref.bills" }, /one SELECT/);
  await refuses("query", { sql: "select set_config('role', 'postgres', true)" }, /security-definer|isn't allowed/);
  await refuses("query", { sql: "select * from pg_authid" }, /isn't allowed|permission denied/);
  await refuses("query", { sql: "select pg_sleep(6)" }, /time limit/);
  await refuses("query", { sql: "select nope from nowhere" }, /database refused/);
});

Deno.test("what_if passes changes through and refuses unknown ones by name", async () => {
  const r = await call("what_if", {
    changes: { type: "one_off_expense", account_key: "test-checking", amount: 10, on: new Date().toISOString().slice(0, 10) },
  });
  assert(r.result && typeof r.result === "object");
  await refuses("what_if", { changes: { type: "lottery" } }, /lottery|type/i);
});

Deno.test("record_balance writes once and refuses an unknown person", async () => {
  const a = await call("record_balance", { person: "james", account_key: "test-checking", balance: 123.45, as_of: "2026-11-10T09:00:00-05:00" });
  const b = await call("record_balance", { person: "james", account_key: "test-checking", balance: 123.45, as_of: "2026-11-10T09:00:00-05:00" });
  assertEquals((a.result as { id: number }).id, (b.result as { id: number }).id);
  await refuses("record_balance", { person: "someone", account_key: "test-checking", balance: 1 }, /isn't a known person/);
  await refuses("record_balance", { person: "james", account_key: "test-checking" }, /balance is required/);
  await refuses("record_balance", { person: "james", account_key: "test-checking", balance: 1, extra: 1 }, /doesn't take: extra/);
});

Deno.test("confirm_match, reject_match and void_entry", async () => {
  const [m1] = await owner`select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-1'`;
  const [m2] = await owner`select id from knowledge.proposed_matches where era_transaction_id = 'test-tx-2'`;
  const paid = await call("confirm_match", { person: "james", match_id: Number(m1.id), alias: "TEST PHONE CO" });
  const payment = paid.result as { id: number; bill_key: string };
  assertEquals(payment.bill_key, "test-phone");

  const rejected = await call("reject_match", { person: "james", match_id: Number(m2.id), reason: "not the phone" });
  assertEquals((rejected.result as { status: string }).status, "rejected");

  await refuses("void_entry", { person: "james", entry: "payment", entry_id: payment.id }, /reason is required/);
  const v = await call("void_entry", { person: "james", entry: "payment", entry_id: payment.id, reason: "test void" });
  assert((v.result as { id: number }).id > 0);
  const [{ n }] = await owner`select count(*)::int as n from ledger.payments_effective where id = ${payment.id}`;
  assertEquals(n, 0);
});

Deno.test("update_bill, log_life_event, log_question and answer_question", async () => {
  const bill = await call("update_bill", { person: "james", bill_key: "test-phone", changes: { amount: 45 } });
  assertEquals(Number((bill.result as { amount: number }).amount), 45);
  await refuses("update_bill", { person: "james", bill_key: "test-new", changes: { name: "New" } }, /./);

  const ev = await call("log_life_event", { person: "katelyn", occurred_on: "2026-08-01", title: "Test event", amount: 100, story_path: "life/test.md" });
  assertEquals((ev.result as { entered_by: string }).entered_by, "katelyn");
  await refuses("log_life_event", { person: "james", occurred_on: "Aug 1", title: "x" }, /date like/);

  const q = await call("log_question", { person: "katelyn", question: "Test?", kind: "new_context" });
  const qid = (q.result as { id: number }).id;
  const a = await call("answer_question", { person: "james", question_id: qid, answer: "Yes" });
  assertEquals((a.result as { status: string }).status, "answered");
});

Deno.test("read_context reads Markdown, lists folders and refuses infra/", async () => {
  fakeResponses = [() => new Response("# Constitution\n", { status: 200 })];
  const r = await call("read_context", { path: "constitution.md" });
  assertEquals((r.result as { content: string }).content, "# Constitution\n");
  const last = calls.at(-1)!;
  assertMatch(last.url, /repos\/jbmeares\/financial_audit_assistant\/contents\/constitution\.md\?ref=main/);
  assertEquals((last.init?.headers as Record<string, string>).Authorization, "Bearer test-gh-token");

  fakeResponses = [() => Response.json([{ name: "infra", type: "dir" }, { name: "life", type: "dir" }, { name: "CLAUDE.md", type: "file" }, { name: "x.py", type: "file" }])];
  const root = await call("read_context", { path: "" });
  assertEquals((root.result as { entries: string[] }).entries, ["CLAUDE.md", "life/"]);

  fakeResponses = [() => new Response("", { status: 404 })];
  await refuses("read_context", { path: "people/nobody.md" }, /no file/);
  fakeResponses = [() => new Response("", { status: 401 })];
  await refuses("read_context", { path: "CLAUDE.md" }, /expired/);

  for (const bad of ["infra/README.md", "../secrets.md", "people/../infra/x.md", ".github/x.md", "data/x.sql"]) {
    let threw = false;
    try {
      checkPath(bad);
    } catch {
      threw = true;
    }
    assert(threw, `should refuse ${bad}`);
  }
  delete env.GITHUB_CONTEXT_TOKEN;
  await refuses("read_context", { path: "CLAUDE.md" }, /GITHUB_CONTEXT_TOKEN/);
  env.GITHUB_CONTEXT_TOKEN = "test-gh-token";
});

Deno.test("create_era_rule previews with the read key, then creates once with the write key", async () => {
  const rule = {
    ruleName: "Test rule",
    filters: [{ type: "merchant_match", pattern: "TEST", mode: "contains" }],
    actions: [{ type: "hide_transaction" }],
  };
  fakeResponses = [() => Response.json({ matchCount: 2, totalEvaluated: 50, sampleMatches: [{ groupKey: "utgr_1" }] })];
  const p = await call("create_era_rule", { person: "james", rule, summary: "Hide test" });
  const preview = p.result as { preview_id: string; match_count: number };
  assertEquals(preview.match_count, 2);
  const previewCall = calls.at(-1)!;
  assertMatch(previewCall.url, /\/banking\/rules\/preview$/);
  assertEquals((previewCall.init?.headers as Record<string, string>)["X-API-Key"], "test-read-key");

  fakeResponses = [() => Response.json({ rule: { id: "rule_test1" }, retroactiveStatus: null, affectedTransactionCount: 0 })];
  const c = await call("create_era_rule", { person: "james", preview_id: preview.preview_id });
  assertEquals((c.result as { era_rule_id: string }).era_rule_id, "rule_test1");
  const createCall = calls.at(-1)!;
  assertMatch(createCall.url, /\/banking\/rules$/);
  assertEquals((createCall.init?.headers as Record<string, string>)["X-API-Key"], "test-write-key");
  assertEquals(JSON.parse(String(createCall.init?.body)), rule);

  // A retried confirm sends nothing.
  await refuses("create_era_rule", { person: "james", preview_id: preview.preview_id }, /already created/);

  // Bad rules never reach Era.
  await refuses("create_era_rule", { person: "james", rule: { ...rule, ruleScope: "pattern" }, summary: "x" }, /doesn't send: ruleScope/);
  await refuses("create_era_rule", { person: "james", rule: { ...rule, actions: [{ type: "delete_everything" }] }, summary: "x" }, /Allowed/);

  // Era refusing the create is recorded, and the preview can't be retried.
  fakeResponses = [() => Response.json({ matchCount: 0, totalEvaluated: 50, sampleMatches: [] })];
  const p2 = await call("create_era_rule", { person: "james", rule, summary: "Again" });
  const id2 = (p2.result as { preview_id: string }).preview_id;
  fakeResponses = [() => Response.json({ statusCode: 400, message: "Bad rule", errors: { generalErrors: ["x"] } }, { status: 400 })];
  await refuses("create_era_rule", { person: "james", preview_id: id2 }, /wasn't created.*HTTP 400.*Bad rule/);
  const [row] = await owner`select status, error from knowledge.era_rule_previews where id = ${id2}`;
  assertEquals(row.status, "failed");
});

Deno.test("cleanup", async () => {
  await owner.end();
});
