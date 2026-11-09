// Tests for the pull with Era and the database faked: a normal night, a 429, a 401, a missing
// field, and a pending transaction that vanishes. Run: infra/functions/era-pull/test
import { test } from "node:test";
import assert from "node:assert/strict";
import { EraClient } from "./era.ts";
import { type Db, monthEnd, runFullMonth, runNightly, todayEastern } from "./pull.ts";
import { mapTransaction } from "./map.ts";

type Handler = (url: URL) => { status: number; body?: unknown; headers?: Record<string, string> };

function fakeEra(handler: Handler) {
  const seen: string[] = [];
  const sleeps: number[] = [];
  const fetch = async (url: string) => {
    const u = new URL(url);
    seen.push(u.pathname.replace("/api", "") + u.search);
    const r = handler(u);
    return new Response(r.body === undefined ? null : JSON.stringify(r.body), { status: r.status, headers: r.headers });
  };
  const client = new EraClient({ key: "test", fetch, sleep: async (ms) => { sleeps.push(ms); }, spacingMs: 0 });
  return { client, seen, sleeps };
}

// An in-memory stand-in for the raw.* functions, enough to check what the pull hands over.
function fakeDb() {
  const runs: Record<number, { kind: string; status: string; counts: Record<string, unknown>; error: string | null }> = {};
  const tx = new Map<string, { row: Record<string, unknown>; run: number; removed: boolean }>();
  let next = 1;
  let refreshed = 0;
  const db: Db = {
    async startPull(kind) { const id = next++; runs[id] = { kind, status: "running", counts: {}, error: null }; return id; },
    async finishPull(run, status, counts, error) { Object.assign(runs[run], { status, counts, error }); },
    async ingestAccounts(_r, rows) { return rows.length; },
    async ingestBalances(_r, rows) { return rows.length; },
    async ingestTransactions(run, rows) {
      let n = 0;
      for (const r of rows as Record<string, unknown>[]) {
        if (!tx.has(r.id as string)) n++;
        tx.set(r.id as string, { row: r, run, removed: false });
      }
      return { new: n, changed: 0, unchanged: rows.length - n };
    },
    async markRemoved(run, s, e) {
      let n = 0;
      for (const t of tx.values()) {
        const d = t.row.occurred_on as string;
        if (d >= s && d <= e && t.run !== run && !t.removed) { t.removed = true; n++; }
      }
      return n;
    },
    async replaceRecurring(_r, rows) { return rows.length; },
    async refreshAll() { refreshed++; return { ok: true }; },
  };
  return { db, runs, tx, get refreshed() { return refreshed; } };
}

const NOW = new Date("2026-11-10T05:10:00Z"); // 00:10 in New York
const TODAY = todayEastern(NOW);

const accounts = { accounts: [
  { accountGroupKey: "fag_chk", name: "Checking", supportsBalances: true, visibility: "visible" },
  { accountGroupKey: "fag_card", name: "Card", supportsBalances: true, visibility: null },
] };
const txn = (id: string, amount: number, date = TODAY, extra: Record<string, unknown> = {}) =>
  ({ id, accountGroupKey: "fag_chk", amount, transactionDate: date, merchantName: "Shop", ...extra });

function normalEra(transactions: unknown[], over: Partial<Record<string, Handler>> = {}): Handler {
  return (u) => {
    const p = u.pathname.replace("/api", "");
    for (const [k, h] of Object.entries(over)) if (p.startsWith(k)) return h!(u);
    if (p === "/banking/accounts") return { status: 200, body: accounts };
    if (p.endsWith("/balance")) return { status: 200, body: { currentBalance: 10, availableBalance: 9, asOf: "2026-11-09T12:00:00Z" } };
    if (p === "/banking/transactions") {
      const page = Number(u.searchParams.get("page"));
      const size = Number(u.searchParams.get("pageSize"));
      const items = transactions.slice((page - 1) * size, page * size);
      return { status: 200, body: { transactions: items, pagination: { currentPage: page, pageSize: size, totalItems: transactions.length, totalPages: Math.max(1, Math.ceil(transactions.length / size)) } } };
    }
    if (p === "/banking/recurring") return { status: 200, body: { items: [{ merchant: "Phone", frequency: "monthly", type: "bill", estimatedAmount: { amount: 50, currency: "USD" } }] } };
    return { status: 404 };
  };
}

test("a normal night pulls accounts, balances, every page of transactions and recurring", async () => {
  const many = Array.from({ length: 150 }, (_, i) => txn(`utgr_${i}`, -i - 1));
  const era = fakeEra(normalEra(many));
  const f = fakeDb();
  const r = await runNightly(era.client, f.db, NOW);
  assert.equal(r.status, "ok", r.error ?? "");
  assert.equal(r.counts.accounts, 2);
  assert.equal(r.counts.balances, 2);
  assert.equal(r.counts.transactions_seen, 150);
  assert.equal(r.counts.recurring, 1);
  assert.equal(f.refreshed, 1);
  assert.equal(f.runs[r.run].kind, "nightly");
  const pages = era.seen.filter((s) => s.startsWith("/banking/transactions"));
  assert.equal(pages.length, 2, "two pages of 100");
  assert.match(pages[0], /includePending=true/);
  assert.match(pages[0], /fromDate=2026-10-11&toDate=2026-11-10/, "the last 30 days, in New York dates");
});

test("a 429 waits for Retry-After and tries again", async () => {
  let hits = 0;
  const era = fakeEra(normalEra([txn("utgr_1", -5)], {
    "/banking/recurring": () => (++hits === 1 ? { status: 429, headers: { "Retry-After": "7" } } : { status: 200, body: { items: [] } }),
  }));
  const r = await runNightly(era.client, fakeDb().db, NOW);
  assert.equal(r.status, "ok");
  assert.ok(era.sleeps.includes(7000), "waited 7 s");
});

test("a 401 stops the run and marks it failed with auth", async () => {
  const era = fakeEra(() => ({ status: 401 }));
  const f = fakeDb();
  const r = await runNightly(era.client, f.db, NOW);
  assert.equal(r.status, "failed");
  assert.match(r.error!, /^auth:/);
  assert.equal(era.seen.length, 1, "no further calls after a 401");
  assert.equal(f.runs[r.run].status, "failed");
});

test("Era 5xx is retried 3 times, then the run fails", async () => {
  const era = fakeEra(() => ({ status: 503 }));
  const r = await runNightly(era.client, fakeDb().db, NOW);
  assert.equal(r.status, "failed");
  assert.equal(era.seen.length, 4);
  assert.match(r.error!, /503/);
});

test("a missing required field fails the run and names the field", async () => {
  const era = fakeEra(normalEra([{ accountGroupKey: "fag_chk", amount: -1, transactionDate: TODAY }]));
  const f = fakeDb();
  const r = await runNightly(era.client, f.db, NOW);
  assert.equal(r.status, "failed");
  assert.equal(r.counts.missing_field, "id");
  assert.equal(f.tx.size, 0, "nothing written from that page");
});

test("a pending transaction that vanishes is marked removed, not deleted", async () => {
  const f = fakeDb();
  await runNightly(fakeEra(normalEra([txn("utgr_pend", -20, TODAY, { isPending: true })])).client, f.db, NOW);
  assert.equal(f.tx.get("utgr_pend")!.row.pending, true);
  const later = new Date(NOW.getTime() + 86_400_000);
  const r = await runNightly(fakeEra(normalEra([txn("utgr_posted", -20)])).client, f.db, later);
  assert.equal(r.counts.transactions_removed, 1);
  assert.equal(f.tx.get("utgr_pend")!.removed, true);
  assert.equal(f.tx.size, 2);
});

test("one account's balance failing makes the run partial and names it", async () => {
  const era = fakeEra(normalEra([], { "/banking/accounts/fag_card/balance": () => ({ status: 404 }) }));
  const r = await runNightly(era.client, fakeDb().db, NOW);
  assert.equal(r.status, "partial");
  assert.match(r.error!, /Card/);
  assert.equal(r.counts.balances, 1);
});

test("a calc refresh error keeps the pull but makes it partial", async () => {
  const f = fakeDb();
  f.db.refreshAll = async () => ({ ok: false, step: "matcher", error: "calc refresh failed in matcher: boom" });
  const r = await runNightly(fakeEra(normalEra([])).client, f.db, NOW);
  assert.equal(r.status, "partial");
  assert.equal(r.counts.calc_failed, "matcher", "the refresh wrote its own error on the row");
  f.db.refreshAll = async () => { throw new Error("connection lost"); };
  const r2 = await runNightly(fakeEra(normalEra([])).client, f.db, new Date(NOW.getTime() + 86_400_000));
  assert.equal(r2.status, "partial");
  assert.match(r2.error!, /calc refresh failed: connection lost/);
});

test("a full-load month reads only that month's transactions", async () => {
  const era = fakeEra(normalEra([txn("utgr_old", -3, "2025-02-14")]));
  const r = await runFullMonth(era.client, fakeDb().db, "2025-02-01");
  assert.equal(r.status, "ok");
  assert.ok(era.seen.some((s) => /fromDate=2025-02-01&toDate=2025-02-28/.test(s)));
  assert.ok(!era.seen.some((s) => s.includes("/balance") || s.includes("/recurring")));
});

test("mapping keeps Era's sign: money out is negative", () => {
  assert.equal(mapTransaction(txn("a", -6.25)).amount, -6.25);
  assert.equal(mapTransaction(txn("b", 1200)).amount, 1200);
  assert.equal(mapTransaction(txn("c", -1, "2026-11-01T10:00:00Z")).occurred_on, "2026-11-01");
});

test("dates: month ends and New York's today", () => {
  assert.equal(monthEnd("2024-02-01"), "2024-02-29");
  assert.equal(todayEastern(new Date("2026-11-10T04:30:00Z")), "2026-11-09");
});

test("shape hides values but keeps keys, types, signs and key prefixes", async () => {
  const { shape } = await import("./shape.ts");
  assert.deepEqual(shape({ groupKey: "utgr_abc", amount: -6.25, merchantName: "Coffee", isPending: false, type: "bill", d: "2026-11-01" }),
    { groupKey: "key:utgr_…", amount: "number<0", merchantName: "string(6)", isPending: "boolean:false", type: "enum:bill", d: "date" });
});
