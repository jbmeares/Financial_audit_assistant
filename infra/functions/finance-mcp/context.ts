// read_context (D4): returns a Markdown file from the repo, or lists a folder, through a
// read-only fine-grained GitHub token (secret GITHUB_CONTEXT_TOKEN, build spec A5).
// Markdown only, and never anything under infra/.

import { ToolError } from "./db.ts";

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

const MAX_BYTES = 200_000;

export interface ContextOptions {
  token: string | undefined;
  repo: string; // owner/name
  ref: string; // branch
  fetch?: Fetch;
}

/** Normalises and checks a path. Returns "" for the repo root. */
export function checkPath(input: unknown): { path: string; isFolder: boolean } {
  let p = String(input ?? "").trim().replace(/\\/g, "/");
  p = p.replace(/^\.\//, "").replace(/^\/+/, "");
  const isFolder = p === "" || p.endsWith("/");
  p = p.replace(/\/+$/, "");
  const parts = p === "" ? [] : p.split("/");
  if (parts.some((s) => s === "" || s === "." || s === "..")) {
    throw new ToolError(`"${input}" isn't a plain repo path. Use a path like "people/james.md" or "life/".`);
  }
  if (parts[0]?.toLowerCase() === "infra" || parts.some((s) => s.startsWith("."))) {
    throw new ToolError("read_context doesn't read infra/ or hidden files. It reads the Markdown files that explain the household.");
  }
  if (!isFolder && !/\.md$/i.test(p)) {
    throw new ToolError(`read_context reads Markdown files only (.md). For a folder, end the path with "/", like "life/".`);
  }
  return { path: p, isFolder };
}

export async function readContext(rawPath: unknown, opts: ContextOptions) {
  const { path, isFolder } = checkPath(rawPath);
  if (!opts.token) {
    throw new ToolError(
      "read_context isn't set up yet: the GITHUB_CONTEXT_TOKEN secret is missing (build spec step A5). The repo files can't be read from here until James adds it.",
    );
  }
  const f = opts.fetch ?? fetch;
  const url = `https://api.github.com/repos/${opts.repo}/contents/${path.split("/").map(encodeURIComponent).join("/")}?ref=${encodeURIComponent(opts.ref)}`;
  let res: Response;
  try {
    res = await f(url, {
      headers: {
        Authorization: `Bearer ${opts.token}`,
        Accept: isFolder ? "application/vnd.github+json" : "application/vnd.github.raw+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "finance-mcp",
      },
    });
  } catch (e) {
    throw new ToolError(`GitHub couldn't be reached, so the repo file can't be read right now (${e}).`);
  }
  if (res.status === 404) {
    throw new ToolError(`There's no ${isFolder ? "folder" : "file"} at "${path || "/"}" in the repo. Try read_context("${path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : ""}") to see what's there.`);
  }
  if (res.status === 401 || res.status === 403) {
    throw new ToolError(
      `GitHub refused the read token (HTTP ${res.status}). It may have expired: the key rotation runbook covers making a new GITHUB_CONTEXT_TOKEN.`,
    );
  }
  if (!res.ok) throw new ToolError(`GitHub answered HTTP ${res.status} for "${path}".`);

  if (isFolder) {
    const items = (await res.json()) as Array<{ name: string; type: string }>;
    if (!Array.isArray(items)) throw new ToolError(`"${path}" is a file, not a folder. Leave off the trailing "/".`);
    const entries = items
      .filter((i) => !i.name.startsWith("."))
      .filter((i) => !(path === "" && i.name === "infra"))
      .filter((i) => i.type === "dir" || /\.md$/i.test(i.name))
      .map((i) => (i.type === "dir" ? `${i.name}/` : i.name))
      .sort();
    return { path: path ? `${path}/` : "/", entries };
  }

  const text = await res.text();
  if (text.length > MAX_BYTES) {
    return { path, truncated: true, content: text.slice(0, MAX_BYTES) };
  }
  return { path, content: text };
}
