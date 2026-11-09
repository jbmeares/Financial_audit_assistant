// Turns Era's JSON into the plain rows the raw.* functions take. This is the only file that
// knows Era's field names. A required field that is missing throws MissingFieldError, so a
// format change fails the run loudly instead of writing blanks.
//
// Field names follow Era's REST docs (era.app/docs/era-api, Oct 2026) and a live response
// checked on 2026-11-09 with the function's "shape" mode (see README.md, D0).

export class MissingFieldError extends Error {
  readonly field: string;
  constructor(field: string, what: string) {
    super(`Era format changed: ${what} is missing "${field}"`);
    this.field = field;
  }
}

type Obj = Record<string, unknown>;

function pick(o: Obj, names: string[]): unknown {
  for (const n of names) if (o[n] !== undefined && o[n] !== null) return o[n];
  return undefined;
}

function need(o: Obj, names: string[], what: string): unknown {
  const v = pick(o, names);
  if (v === undefined) throw new MissingFieldError(names[0], what);
  return v;
}

function num(v: unknown): number | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v === "object" && v !== null && "amount" in (v as Obj)) return num((v as Obj).amount);
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

export function list(body: unknown, key: string, what: string): Obj[] {
  const v = (body as Obj | null)?.[key];
  if (!Array.isArray(v)) throw new MissingFieldError(key, what);
  return v as Obj[];
}

export interface AccountRow { id: string; payload: Obj; supportsBalances: boolean }
export function mapAccount(a: Obj): AccountRow {
  const id = String(need(a, ["accountGroupKey"], "an account"));
  // visibility is "visible" (or null) for an account Era shows; anything else withholds the balance.
  const visible = a.visibility == null || a.visibility === "visible";
  return { id, payload: a, supportsBalances: a.supportsBalances !== false && visible };
}

export interface BalanceRow { account_id: string; current: number | null; available: number | null; as_of: string | null; payload: Obj }
export function mapBalance(accountId: string, b: Obj): BalanceRow {
  return {
    account_id: accountId,
    current: num(pick(b, ["currentBalance", "current"])),
    available: num(pick(b, ["availableBalance", "available"])),
    as_of: (pick(b, ["asOf", "as_of"]) as string | undefined) ?? null,
    payload: b,
  };
}

// Era reports money out as a negative amount, and also says so in isCashOutflow. Our raw
// column uses the same sign, so no flip. Checked on the first load (README.md, D0).
export const OUTFLOW_IS_NEGATIVE = true;

export interface TransactionRow {
  id: string; account_id: string; amount: number; occurred_on: string;
  pending: boolean; merchant: string | null; payload: Obj;
}
export function mapTransaction(t: Obj): TransactionRow {
  const id = String(need(t, ["id"], "a transaction"));
  const account_id = String(need(t, ["accountGroupKey", "accountId", "accountKey"], `transaction ${id}`));
  const raw = num(need(t, ["amount"], `transaction ${id}`));
  if (raw === null) throw new MissingFieldError("amount", `transaction ${id}`);
  const date = String(need(t, ["transactionDate", "date", "postedDate"], `transaction ${id}`)).slice(0, 10);
  const merchant = pick(t, ["merchantName", "merchant", "description", "name"]);
  return {
    id, account_id,
    amount: OUTFLOW_IS_NEGATIVE ? raw : -raw,
    occurred_on: date,
    pending: pick(t, ["isPending", "pending"]) === true,
    merchant: merchant == null ? null : String(merchant),
    payload: t,
  };
}

export interface RecurringRow { id: string; account_id: string | null; payload: Obj }
// Era's recurring items carry no id, so one is made from what identifies the series.
export async function mapRecurring(r: Obj): Promise<RecurringRow> {
  const merchant = String(need(r, ["merchant", "merchantName"], "a recurring item"));
  const basis = [merchant, r.frequency ?? "", r.type ?? "", pick(r, ["accountGroupKey"]) ?? "", num(r.estimatedAmount) ?? ""].join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(basis));
  const hex = [...new Uint8Array(digest)].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
  return { id: `rec_${hex}`, account_id: (pick(r, ["accountGroupKey"]) as string | undefined) ?? null, payload: r };
}
