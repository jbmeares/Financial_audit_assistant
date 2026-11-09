// Talks to Era's REST API. Spaces calls ~1.1 s apart (Era allows 60 a minute), waits out
// 429s using Retry-After (up to 5 tries) and retries 5xx 3 times before giving up.

export const ERA_BASE = "https://forge.era.app/api";

export class EraAuthError extends Error {
  constructor(status: number) {
    super(`auth: Era rejected the read key (HTTP ${status}). Rotate ERA_READ_KEY (see the key rotation runbook).`);
  }
}
export class EraError extends Error {}

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;
export type Sleep = (ms: number) => Promise<void>;

export interface EraClientOptions {
  key: string;
  fetch?: Fetch;
  sleep?: Sleep;
  spacingMs?: number;
  base?: string;
}

export class EraClient {
  calls = 0;
  private last = 0;
  private readonly f: Fetch;
  private readonly sleep: Sleep;
  private readonly spacing: number;
  private readonly base: string;

  private readonly opts: EraClientOptions;

  constructor(opts: EraClientOptions) {
    this.opts = opts;
    this.f = opts.fetch ?? fetch;
    this.sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.spacing = opts.spacingMs ?? 1100;
    this.base = opts.base ?? ERA_BASE;
  }

  async get(path: string, query: Record<string, string | number | boolean | undefined> = {}): Promise<unknown> {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) if (v !== undefined) qs.set(k, String(v));
    const url = `${this.base}${path}${qs.size ? `?${qs}` : ""}`;

    let rateTries = 0;
    let serverTries = 0;
    while (true) {
      const wait = this.last + this.spacing - Date.now();
      if (wait > 0) await this.sleep(wait);
      this.last = Date.now();
      this.calls++;

      let res: Response;
      try {
        res = await this.f(url, { headers: { "X-API-Key": this.opts.key, Accept: "application/json" } });
      } catch (e) {
        if (++serverTries > 3) throw new EraError(`Era unreachable on ${path}: ${e}`);
        await this.sleep(2000 * serverTries);
        continue;
      }

      if (res.status === 401 || res.status === 403) throw new EraAuthError(res.status);
      if (res.status === 429) {
        if (++rateTries > 5) throw new EraError(`Era kept rate-limiting ${path} after 5 waits`);
        const after = Number(res.headers.get("Retry-After"));
        await this.sleep((Number.isFinite(after) && after > 0 ? after : 5) * 1000);
        continue;
      }
      if (res.status >= 500) {
        if (++serverTries > 3) throw new EraError(`Era returned HTTP ${res.status} on ${path} after 3 retries`);
        await this.sleep(2000 * serverTries);
        continue;
      }
      if (!res.ok) {
        const body = (await res.text()).slice(0, 300);
        throw new EraError(`Era returned HTTP ${res.status} on ${path}: ${body}`);
      }
      return await res.json();
    }
  }
}
