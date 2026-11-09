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

// Era pages with a sort key that isn't unique (the date), so a window bigger than one page can
// repeat one transaction and skip another across pages. So the window is split in half until
// each piece fits in one page. Only a single day with more than 100 transactions is paged, and
// then the count is checked. Returns whether every transaction Era counted was seen.
async function fetchWindow(
  era: Era, from: string, to: string, out: Map<string, ReturnType<typeof mapTransaction>>, counts: Record<string, unknown>,
): Promise<boolean> {
  const first = await era.get("/banking/transactions", {
    fromDate: from, toDate: to, page: 1, pageSize: PAGE_SIZE, includePending: true,
  }) as Record<string, unknown>;
  if (first.historyWindowApplied === true) counts.history_window_floor = first.historyWindowFloorDate ?? null;
  const total = Number((first.pagination as Record<string, unknown> | undefined)?.totalItems ?? NaN);
  const rows = list(first, "transactions", `transactions ${from}..${to}`).map(mapTransaction);

  if (Number.isFinite(total) && total > rows.length && from < to) {
    const mid = addDays(from, Math.floor((daysBetween(from, to)) / 2));
    const a = await fetchWindow(era, from, mid, out, counts);
    const b = await fetchWindow(era, addDays(mid, 1), to, out, counts);
    return a && b;
  }

  const before = out.size;
  for (const r of rows) out.set(r.id, r);
  const pages = Number((first.pagination as Record<string, unknown> | undefined)?.totalPages ?? 1);
  for (let page = 2; page <= pages; page++) {
    const body = await era.get("/banking/transactions", {
      fromDate: from, toDate: to, page, pageSize: PAGE_SIZE, includePending: true,
    });
    for (const r of list(body, "transactions", `transactions ${from} page ${page}`).map(mapTransaction)) out.set(r.id, r);
  }
  return !Number.isFinite(total) || out.size - before >= total;
}

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

// Reads the whole window, writes it, and says whether the read was complete.
async function pullTransactions(era: Era, db: Db, run: number, from: string, to: string, counts: Record<string, unknown>) {
  const seen = new Map<string, ReturnType<typeof mapTransaction>>();
  const complete = await fetchWindow(era, from, to, seen, counts);
  const rows = [...seen.values()];
  const tally = { new: 0, changed: 0, unchanged: 0 };
  for (let i = 0; i < rows.length; i += 500) {
    const r = await db.ingestTransactions(run, rows.slice(i, i + 500));
    tally.new += r.new; tally.changed += r.changed; tally.unchanged += r.unchanged;
  }
  counts.transactions_seen = rows.length;
  counts.transactions_new = tally.new;
  counts.transactions_changed = tally.changed;
  counts.pending_seen = rows.filter((t) => t.pending).length;
  return complete;
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

    // Only a complete read can say a transaction is gone.
    if (await pullTransactions(era, db, id, from, to, counts)) {
      counts.transactions_removed = await db.markRemoved(id, from, to, accounts.map((a) => a.id));
    } else {
      problems.push("Era's transaction count didn't match what was read, so nothing was marked removed");
    }

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
