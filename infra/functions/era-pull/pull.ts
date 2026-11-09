// D1. One run of the pull, step by step. Era and the database are passed in, so the tests can
// fake both. Every run leaves a pull_runs row that says how it went.

import { EraAuthError, type EraClient } from "./era.ts";
import { list, mapAccount, mapBalance, mapRecurring, mapTransaction, MissingFieldError } from "./map.ts";

export interface Db {
  startPull(kind: string, windowStart: string | null, windowEnd: string | null): Promise<number>;
  finishPull(run: number, status: string, counts: Record<string, unknown>, error: string | null): Promise<void>;
  ingestAccounts(run: number, rows: unknown[]): Promise<number>;
  ingestBalances(run: number, rows: unknown[]): Promise<number>;
  ingestTransactions(run: number, rows: unknown[]): Promise<{ new: number; changed: number; unchanged: number }>;
  markRemoved(run: number, windowStart: string, windowEnd: string, accountIds: string[]): Promise<number>;
  replaceRecurring(run: number, rows: unknown[]): Promise<number>;
  // Block E's calc.refresh_all(run). Never throws for a calc error; says ok or not.
  refreshAll(run: number): Promise<{ ok: boolean; step?: string; error?: string }>;
}

export interface RunResult { run: number; status: "ok" | "partial" | "failed"; counts: Record<string, unknown>; error: string | null }

type Era = Pick<EraClient, "get" | "calls">;

const PAGE_SIZE = 100;

function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function monthEnd(monthStart: string): string {
  const d = new Date(`${monthStart}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1, 0);
  return d.toISOString().slice(0, 10);
}

// Today's date in New York, as YYYY-MM-DD.
export function todayEastern(now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(now);
}

async function pullAccounts(era: Era, db: Db, run: number, counts: Record<string, unknown>) {
  const body = await era.get("/banking/accounts", { includeExcluded: true, includeSevered: true });
  const accounts = list(body, "accounts", "the accounts response").map(mapAccount);
  counts.accounts = await db.ingestAccounts(run, accounts);
  return accounts;
}

// Reads every page of the window. Returns the ids of the accounts seen, for mark_removed.
async function pullTransactions(era: Era, db: Db, run: number, from: string, to: string, counts: Record<string, unknown>) {
  const tally = { new: 0, changed: 0, unchanged: 0 };
  let seen = 0;
  let pending = 0;
  for (let page = 1; ; page++) {
    const body = await era.get("/banking/transactions", {
      fromDate: from, toDate: to, page, pageSize: PAGE_SIZE, includePending: true,
      sortBy: "transactionDate", sortDirection: "asc",
    }) as Record<string, unknown>;
    const rows = list(body, "transactions", `transactions page ${page}`).map(mapTransaction);
    if (page === 1 && body.historyWindowApplied === true) {
      counts.history_window_floor = body.historyWindowFloorDate ?? null;
    }
    if (rows.length) {
      const r = await db.ingestTransactions(run, rows);
      tally.new += r.new; tally.changed += r.changed; tally.unchanged += r.unchanged;
      seen += rows.length;
      pending += rows.filter((t) => t.pending).length;
    }
    const p = body.pagination as Record<string, number> | undefined;
    const last = p?.totalPages !== undefined ? page >= p.totalPages : rows.length < PAGE_SIZE;
    if (last || rows.length === 0) break;
  }
  counts.transactions_seen = seen;
  counts.transactions_new = tally.new;
  counts.transactions_changed = tally.changed;
  counts.pending_seen = pending;
}

async function run(
  kind: "full" | "nightly" | "manual", era: Era, db: Db, from: string, to: string,
  opts: { balances: boolean; recurring: boolean; refresh: boolean },
): Promise<RunResult> {
  const id = await db.startPull(kind, from, to);
  const counts: Record<string, unknown> = {};
  const problems: string[] = [];
  try {
    const accounts = await pullAccounts(era, db, id, counts);

    if (opts.balances) {
      const balances = [];
      const failed: string[] = [];
      for (const a of accounts.filter((x) => x.supportsBalances)) {
        try {
          const b = await era.get(`/banking/accounts/${encodeURIComponent(a.id)}/balance`);
          balances.push(mapBalance(a.id, b as Record<string, unknown>));
        } catch (e) {
          if (e instanceof EraAuthError) throw e;
          failed.push(String((a.payload as Record<string, unknown>).name ?? a.id));
        }
      }
      counts.balances = await db.ingestBalances(id, balances);
      if (failed.length) {
        counts.balance_failures = failed;
        problems.push(`no balance for: ${failed.join(", ")}`);
      }
    }

    await pullTransactions(era, db, id, from, to, counts);
    counts.transactions_removed = await db.markRemoved(id, from, to, accounts.map((a) => a.id));

    if (opts.recurring) {
      const body = await era.get("/banking/recurring");
      const items = await Promise.all(list(body, "items", "the recurring response").map(mapRecurring));
      counts.recurring = await db.replaceRecurring(id, items);
    }

    if (opts.refresh) {
      // On failure the refresh writes its own error onto this run's row; the run becomes partial.
      try {
        const r = await db.refreshAll(id);
        if (!r.ok) counts.calc_failed = r.step ?? true;
      } catch (e) {
        counts.calc_failed = true;
        problems.push(`calc refresh failed: ${e instanceof Error ? e.message : e}`);
      }
    }

    counts.era_calls = era.calls;
    const status = problems.length || counts.calc_failed ? "partial" : "ok";
    const error = problems.length ? problems.join("; ") : null;
    await db.finishPull(id, status, counts, error);
    return { run: id, status, counts, error };
  } catch (e) {
    counts.era_calls = era.calls;
    let error: string;
    if (e instanceof EraAuthError) error = e.message;
    else if (e instanceof MissingFieldError) { error = e.message; counts.missing_field = e.field; }
    else error = e instanceof Error ? e.message : String(e);
    await db.finishPull(id, "failed", counts, error);
    return { run: id, status: "failed", counts, error };
  }
}

// D2. Every night: re-read the last 30 days, plus balances and recurring, then refresh calc.
export function runNightly(era: Era, db: Db, now = new Date(), kind: "nightly" | "manual" = "nightly") {
  const today = todayEastern(now);
  return run(kind, era, db, addDays(today, -30), today, { balances: true, recurring: true, refresh: true });
}

// D2. One month of the full history load. Transactions only (balances and recurring are
// "now" values, which the nightly run keeps).
export function runFullMonth(era: Era, db: Db, monthStart: string) {
  return run("full", era, db, monthStart, monthEnd(monthStart), { balances: false, recurring: false, refresh: false });
}
