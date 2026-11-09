// Describes a JSON value without its contents: keys, types, the sign of numbers, and the value
// only for short enum-like fields (type, status, frequency...). Used by the "shape" mode to check
// Era's format without reading anyone's amounts, names or ids.
const ENUMISH = /(type|status|kind|frequency|cadence|currency|currencyCode|direction|subtype|scope|state|period|visibility|confidence)$/i;

export function shape(v: unknown, key = "", depth = 0): unknown {
  if (depth > 6) return "…";
  if (v === null) return "null";
  if (Array.isArray(v)) return v.length ? { count: v.length, first: shape(v[0], key, depth + 1) } : "[] empty";
  if (typeof v === "object") {
    const o: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) o[k] = shape(x, k, depth + 1);
    return o;
  }
  if (typeof v === "number") return v < 0 ? "number<0" : v > 0 ? "number>0" : "number=0";
  if (typeof v === "boolean") return `boolean:${v}`;
  if (typeof v === "string") {
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return "date";
    if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return "datetime";
    if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v) < 0 ? "numeric-string<0" : "numeric-string>=0";
    if (ENUMISH.test(key) && v.length < 40) return `enum:${v}`;
    const prefix = /^([a-z]{2,6}_)/.exec(v)?.[1];
    return prefix ? `key:${prefix}…` : `string(${v.length})`;
  }
  return typeof v;
}
