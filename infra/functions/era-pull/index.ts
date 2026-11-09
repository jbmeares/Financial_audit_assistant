// era-pull: the nightly Era pull (Block D). Deployed as a Supabase Edge Function.
//
// POST body {"mode": ...}
//   nightly  from pg_cron at 04:00 and 05:00 UTC; only the one in New York's midnight hour runs
//   full     the history load: one month per run, newest first, as many as fit in ~100 s
//            ({"restartAt": "<ISO time>"} starts it over, ignoring full runs before that time)
//   manual   a nightly-style run on demand (refused if a run finished in the last 10 minutes)
//   health   200 if the last good pull is under 48 hours old, else 503 (the daily alert, I1)
//   shape    the field names and types of one record of each kind, with no values (D0)
//
// It connects with the function's own database URL and switches to the ingest role inside
// every transaction, so it can only write raw and run the calc refresh.

import postgres from "npm:postgres@3.4.5";
import { EraClient } from "./era.ts";
import { type Db, runFullMonth, runNightly } from "./pull.ts";
import { shape } from "./shape.ts";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 20, onnotice: () => {} });

// Runs one statement as ingest and returns the first column of the first row.
async function asIngest<T>(text: string, params: unknown[]): Promise<T> {
  return await sql.begin(async (tx) => {
    await tx`set local role ingest`;
    const rows = await tx.unsafe(text, params as never[]);
    return (rows[0] ? Object.values(rows[0])[0] : null) as T;
  }) as T;
}

const json = (v: unknown) => JSON.stringify(v);

const db: Db = {
  startPull: (k, s, e) => asIngest<string>("select raw.start_pull($1, $2::date, $3::date)", [k, s, e]).then(Number),
  finishPull: (r, st, c, err) => asIngest("select raw.finish_pull($1, $2, $3::text::jsonb, $4)", [r, st, json(c), err]).then(() => {}),
  ingestAccounts: (r, rows) => asIngest<number>("select raw.ingest_accounts($1, $2::text::jsonb)", [r, json(rows)]),
  ingestBalances: (r, rows) => asIngest<number>("select raw.ingest_balances($1, $2::text::jsonb)", [r, json(rows)]),
  ingestTransactions: (r, rows) => asIngest("select raw.ingest_transactions($1, $2::text::jsonb)", [r, json(rows)]),
  markRemoved: (r, s, e, ids) => asIngest<number>("select raw.mark_removed($1, $2::date, $3::date, $4::text[])", [r, s, e, ids]),
  replaceRecurring: (r, rows) => asIngest<number>("select raw.replace_recurring($1, $2::text::jsonb)", [r, json(rows)]),
  // Block E's refresh takes the run id and returns {"ok": ...}. Until that is applied, the
  // stub takes no arguments and returns nothing, so fall back to it.
  refreshAll: async (run) => {
    try {
      const r = await asIngest<{ ok: boolean; step?: string; error?: string } | null>("select calc.refresh_all($1::bigint)", [run]);
      return r ?? { ok: true };
    } catch (e) {
      if (!/function calc\.refresh_all\(bigint\) does not exist/.test(String(e))) throw e;
      await asIngest("select calc.refresh_all()", []);
      return { ok: true };
    }
  },
};

const respond = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const { mode = "nightly", force = false, restartAt = null } = await req.json().catch(() => ({}));

  if (mode === "health") {
    const age = await asIngest<number | null>(
      "select extract(epoch from now() - max(finished_at)) / 3600 from raw.pull_runs where status in ('ok', 'partial') and kind in ('nightly', 'manual')", []);
    const ok = age !== null && Number(age) < 48;
    return respond(ok ? 200 : 503, { ok, hours_since_last_good_pull: age === null ? null : Math.round(Number(age) * 10) / 10 });
  }

  const key = Deno.env.get("ERA_READ_KEY");
  if (!key) return respond(500, { error: "ERA_READ_KEY is not set" });
  const era = new EraClient({ key });

  try {
    if (mode === "shape") {
      const out: Record<string, unknown> = {};
      const accounts = await era.get("/banking/accounts") as { accounts?: { accountGroupKey?: string }[] };
      out.accounts = shape(accounts);
      const first = accounts.accounts?.[0]?.accountGroupKey;
      if (first) out.balance = shape(await era.get(`/banking/accounts/${encodeURIComponent(first)}/balance`));
      out.transactions = shape(await era.get("/banking/transactions", { page: 1, pageSize: 3, includePending: true }));
      out.recurring = shape(await era.get("/banking/recurring"));
      return respond(200, out);
    }

    if (mode === "nightly") {
      const midnight = await asIngest<boolean>("select raw.is_midnight_eastern()", []);
      if (!midnight && !force) return respond(200, { skipped: "not the midnight hour in New York" });
      return respond(200, await runNightly(era, db));
    }

    if (mode === "manual") {
      const recent = await asIngest<boolean>(
        "select exists (select 1 from raw.pull_runs where coalesce(finished_at, started_at) > now() - interval '10 minutes' and kind <> 'full')", []);
      if (recent) return respond(429, { error: "a pull ran in the last 10 minutes" });
      return respond(200, await runNightly(era, db, new Date(), "manual"));
    }

    if (mode === "full") {
      const started = Date.now();
      const results = [];
      while (Date.now() - started < 100_000) {
        // restartAt (an ISO time) runs the load again from the top, ignoring full runs before it.
        const month = await asIngest<string | null>(
          "select raw.next_full_month(p_after := coalesce($1::timestamptz, '-infinity'))::text", [restartAt]);
        if (!month) return respond(200, { complete: true, results });
        const r = await runFullMonth(era, db, month);
        results.push({ month, ...r });
        if (r.status === "failed") break;
      }
      return respond(200, { complete: false, results });
    }

    return respond(400, { error: `unknown mode ${mode}` });
  } catch (e) {
    // Reaches here only when the run couldn't even start (the lock, or the database is down).
    return respond(409, { error: e instanceof Error ? e.message : String(e) });
  }
});
