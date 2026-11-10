// finance-mcp: the household finance tools (build spec Block F), behind Supabase Auth's
// OAuth 2.1 server. The tools are in tools.ts, database access in db.ts.
//
// Deployed with verify_jwt = false on purpose. The platform check would answer a missing
// token with a bare 401, but an MCP client needs a 401 that carries a WWW-Authenticate
// header pointing at this server's metadata, or it can't find the sign-in. So this file
// checks the token itself: signature (the project's public keys), issuer, audience, expiry,
// that it was issued to an OAuth client, and that the user is on the allow list.

import { createRemoteJWKSet, errors as joseErrors, jwtVerify } from "npm:jose@6.2.16";
import { liveDb, plain, ToolError } from "./db.ts";
import { TOOLS } from "./tools.ts";

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
const FUNCTION_NAME = "finance-mcp";
const ISSUER = `${SUPABASE_URL}/auth/v1`;
const RESOURCE = `${SUPABASE_URL}/functions/v1/${FUNCTION_NAME}`;
const RESOURCE_METADATA_URL = `${RESOURCE}/.well-known/oauth-protected-resource`;
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`));

// Comma-separated emails, kept as a Supabase secret, not in the repo. Empty means nobody.
const ALLOWED_EMAILS = (Deno.env.get("FINANCE_ALLOWED_EMAILS") ?? "")
  .split(",")
  .map((e) => e.trim().toLowerCase())
  .filter(Boolean);

const SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];
const SERVER_INFO = { name: "finance-mcp", title: "Household finance", version: "1.0.0" };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, content-type, accept, mcp-protocol-version, mcp-session-id, last-event-id",
  "Access-Control-Expose-Headers": "www-authenticate, mcp-session-id",
};

type Caller = { userId: string; email: string; clientId: string; expiresAt: string };
type JsonRpc = { jsonrpc: "2.0"; id?: string | number | null; method?: string; params?: any };

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS, ...extra },
  });
}

function unauthorized(error: string, description: string) {
  // RFC 6750 and RFC 9728: tell the client where to find out how to sign in.
  const challenge =
    `Bearer resource_metadata="${RESOURCE_METADATA_URL}", ` +
    `error="${error}", error_description="${description.replace(/"/g, "'")}"`;
  return json({ error, error_description: description }, 401, { "WWW-Authenticate": challenge });
}

// Returns the caller, or a Response to send back as is.
async function authenticate(req: Request): Promise<Caller | Response> {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return unauthorized("invalid_request", "Sign in to use the finance server.");

  let payload: Record<string, unknown>;
  try {
    ({ payload } = await jwtVerify(match[1], JWKS, { issuer: ISSUER, audience: "authenticated" }));
  } catch (e) {
    const why = e instanceof joseErrors.JWTExpired ? "The sign-in has expired." : "The token isn't valid.";
    return unauthorized("invalid_token", why);
  }

  const clientId = typeof payload.client_id === "string" ? payload.client_id : "";
  if (!clientId) {
    // A plain Supabase session token (for example from the consent page) is not enough.
    return unauthorized("invalid_token", "This token wasn't issued to an OAuth client.");
  }

  const email = String(payload.email ?? "").toLowerCase();
  if (!email || !ALLOWED_EMAILS.includes(email)) {
    return json({ error: "insufficient_scope", error_description: "This account can't use the finance server." }, 403);
  }

  return {
    userId: String(payload.sub ?? ""),
    email,
    clientId,
    expiresAt: new Date(Number(payload.exp) * 1000).toISOString(),
  };
}

// Logs a call (F5). Best effort: a failed log never fails the tool.
async function logCall(tool: string, person: unknown, ok: boolean, error: string | null, ms: number) {
  try {
    await liveDb.act(async (tx) => {
      await tx`select actions.log_tool_call(${tool}, ${typeof person === "string" ? person : null}, ${ok}, ${error}, ${ms})`;
    });
  } catch (e) {
    console.error("tool call log failed", e);
  }
}

async function callTool(name: string, args: unknown, caller: Caller) {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) {
    return { content: [{ type: "text", text: `There's no tool called ${name}.` }], isError: true };
  }
  const a = (args && typeof args === "object" && !Array.isArray(args) ? args : {}) as Record<string, unknown>;
  const started = Date.now();
  try {
    const { result, lead } = await tool.handler(a, { db: liveDb, env: (k) => Deno.env.get(k), caller });
    await logCall(name, a.person, true, null, Date.now() - started);
    const text = (lead ? lead + "\n\n" : "") + JSON.stringify(result, null, 2);
    const structured = result && typeof result === "object" && !Array.isArray(result) ? result : { result };
    return { content: [{ type: "text", text }], structuredContent: structured };
  } catch (e) {
    const message = e instanceof ToolError ? e.message : plain(e).message;
    if (!(e instanceof ToolError)) console.error(`tool ${name} failed`, e);
    await logCall(name, a.person, false, message, Date.now() - started);
    return { content: [{ type: "text", text: message }], isError: true };
  }
}

const INSTRUCTIONS = [
  "Household finance for James and Katelyn. The numbers come only from these tools; the words come from the repo through read_context.",
  "Start of every conversation: ask who you're talking to unless it's clear, then read_context(\"CLAUDE.md\"), read_context(\"constitution.md\") and read_context(\"people/<name>.md\"), then call get_briefing. Open with anything RED, then one line on what's due before the next income.",
  "Every number you say comes from a tool result in this conversation or from what a person said (rule 1). Do sums, date math and what-ifs with query or what_if, never in prose (rule 2).",
  "Action tools need person (james or katelyn). Never guess on a write: ask one short question if it's ambiguous (rule 5).",
].join(" ");

async function handleRpc(msg: JsonRpc, caller: Caller): Promise<object | null> {
  const isNotification = msg.id === undefined || msg.id === null;
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id: msg.id, result });
  const fail = (code: number, message: string) => ({ jsonrpc: "2.0", id: msg.id ?? null, error: { code, message } });

  if (msg?.jsonrpc !== "2.0" || typeof msg.method !== "string") return fail(-32600, "Invalid request");
  if (isNotification) return null; // notifications/initialized and friends need no answer

  switch (msg.method) {
    case "initialize": {
      const asked = msg.params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.includes(asked) ? asked : SUPPORTED_PROTOCOL_VERSIONS[0];
      return reply({
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({
        tools: TOOLS.map(({ name, title, description, inputSchema, annotations }) => ({ name, title, description, inputSchema, annotations })),
      });
    case "tools/call":
      return reply(await callTool(String(msg.params?.name ?? ""), msg.params?.arguments, caller));
    default:
      return fail(-32601, `Method not found: ${msg.method}`);
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Inside an Edge Function the path starts with the function name.
  const path = url.pathname.replace(new RegExp(`^/(functions/v1/)?${FUNCTION_NAME}`), "") || "/";

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  // RFC 9728 protected resource metadata. Public: it only says where to sign in.
  if (req.method === "GET" && path.startsWith("/.well-known/oauth-protected-resource")) {
    return json({
      resource: RESOURCE,
      authorization_servers: [ISSUER],
      bearer_methods_supported: ["header"],
      scopes_supported: ["email"],
      resource_name: "Household finance",
    });
  }

  if (path !== "/" && path !== "/mcp") return json({ error: "not_found" }, 404);

  const caller = await authenticate(req);
  if (caller instanceof Response) return caller;

  // Stateless server: no SSE stream, no sessions.
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, { Allow: "POST" });

  let body: JsonRpc | JsonRpc[];
  try {
    body = await req.json();
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }

  const replies = (await Promise.all((Array.isArray(body) ? body : [body]).map((m) => handleRpc(m, caller))))
    .filter((r) => r !== null);
  if (replies.length === 0) return new Response(null, { status: 202, headers: CORS });
  return json(Array.isArray(body) ? replies : replies[0]);
});
