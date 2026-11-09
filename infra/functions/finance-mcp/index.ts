// finance-mcp, F0 spike: one tool behind Supabase Auth's OAuth 2.1 server.
//
// What it proves: claude.ai and Claude Code can discover the sign-in, send James through
// the consent page, and call a tool with the token Supabase issues. It reads no finance data.
//
// Deployed with verify_jwt = false on purpose. The platform check would answer a missing
// token with a bare 401, but an MCP client needs a 401 that carries a WWW-Authenticate
// header pointing at this server's metadata, or it can't find the sign-in. So this file
// checks the token itself: signature (the project's public keys), issuer, audience, expiry,
// that it was issued to an OAuth client, and that the user is on the allow list.

import { createRemoteJWKSet, errors as joseErrors, jwtVerify } from "npm:jose@6.2.16";

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
const SERVER_INFO = { name: "finance-mcp", version: "0.0.1-spike" };

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

const TOOLS = [
  {
    name: "whoami",
    title: "Who am I signed in as",
    description:
      "Test tool for the sign-in spike. Says which account and which app this connection is signed in as, and when the sign-in expires. Reads no finance data.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
];

function callTool(name: string, caller: Caller) {
  if (name !== "whoami") {
    return { content: [{ type: "text", text: `There's no tool called ${name}.` }], isError: true };
  }
  const result = {
    signed_in_as: caller.email,
    user_id: caller.userId,
    oauth_client_id: caller.clientId,
    token_expires_at: caller.expiresAt,
    server_time: new Date().toISOString(),
  };
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    structuredContent: result,
  };
}

function handleRpc(msg: JsonRpc, caller: Caller): object | null {
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
        instructions: "Household finance server. Spike build: only whoami exists so far.",
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools: TOOLS });
    case "tools/call":
      return reply(callTool(String(msg.params?.name ?? ""), caller));
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

  const replies = (Array.isArray(body) ? body : [body]).map((m) => handleRpc(m, caller)).filter((r) => r !== null);
  if (replies.length === 0) return new Response(null, { status: 202, headers: CORS });
  return json(Array.isArray(body) ? replies : replies[0]);
});
