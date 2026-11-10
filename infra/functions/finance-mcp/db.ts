// Database access for the tools (F3).
//
// The function reaches Postgres through the SUPABASE_DB_URL every Edge Function is given.
// Each tool call runs in its own transaction and switches to the role that tool is allowed
// to use, before any of its SQL runs:
//
//   read tools   BEGIN READ ONLY, SET LOCAL ROLE assistant_read
//   action tools BEGIN, SET LOCAL ROLE assistant_act (which can only run the named actions)
//
// The SQL in this file is fixed and its inputs are bound parameters, so a tool's arguments
// can't change what runs. The one tool that takes SQL (query) hands it to mcp.run_query, a
// security definer function owned by assistant_read: Postgres refuses SET ROLE inside one,
// so the text can't climb back to this connection's own role.

import postgres from "npm:postgres@3.4.7";

export type Row = Record<string, unknown>;
export type Tx = postgres.TransactionSql;

export interface Db {
  read<T>(fn: (tx: Tx) => Promise<T>, timeoutMs?: number): Promise<T>;
  act<T>(fn: (tx: Tx) => Promise<T>, timeoutMs?: number): Promise<T>;
}

/** A plain sentence Claude can repeat as is. */
export class ToolError extends Error {}

let sql: postgres.Sql | null = null;

function connection(): postgres.Sql {
  if (sql) return sql;
  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) throw new ToolError("The finance server has no database address (SUPABASE_DB_URL), so I can't see the numbers.");
  sql = postgres(url, {
    prepare: false, // works through the transaction pooler too
    max: 3,
    idle_timeout: 20,
    connect_timeout: 10,
    onnotice: () => {},
  });
  return sql;
}

async function inRole<T>(
  role: "assistant_read" | "assistant_act",
  readOnly: boolean,
  timeoutMs: number,
  fn: (tx: Tx) => Promise<T>,
): Promise<T> {
  try {
    return (await connection().begin(readOnly ? "read only" : "read write", async (tx) => {
      await tx.unsafe(`set local statement_timeout = ${Math.round(timeoutMs)}`);
      await tx.unsafe(`set local role ${role}`);
      return await fn(tx);
    })) as T;
  } catch (e) {
    throw plain(e);
  }
}

export const liveDb: Db = {
  read: (fn, timeoutMs = 5000) => inRole("assistant_read", true, timeoutMs, fn),
  // Actions re-run the calculations, which takes longer than a read.
  act: (fn, timeoutMs = 30000) => inRole("assistant_act", false, timeoutMs, fn),
};

/** Turns a database error into one sentence (F4). */
export function plain(e: unknown): Error {
  if (e instanceof ToolError) return e;
  const err = e as { code?: string; message?: string; errno?: string };
  const code = err?.code ?? "";
  const message = String(err?.message ?? e);
  // Our own functions raise P0001 with a sentence meant for a person.
  if (code === "P0001") return new ToolError(message);
  if (code === "57014") return new ToolError("That took longer than the time limit and was stopped. Try a narrower query.");
  if (code === "42501") return new ToolError(`That isn't allowed for this tool: ${message}.`);
  if (code === "25006") return new ToolError("This tool only reads. Writes go through the named actions.");
  if (/^(42|22|23)/.test(code)) return new ToolError(`The database refused that: ${message}.`);
  if (/ECONNREFUSED|ENOTFOUND|ETIMEDOUT|CONNECT_TIMEOUT|CONNECTION_|getaddrinfo/i.test(code + " " + message)) {
    return new ToolError("I can't reach the finance database right now, so I can't see the numbers. Don't guess them.");
  }
  return new ToolError(`The finance database answered with an error: ${message}`);
}
