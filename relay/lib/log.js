// What the relay writes about a request, and nothing else.
//
// The relay sees device tokens, capabilities, challenge nonces and sealed
// envelopes. None of them may reach a log line: a log is read by whoever
// operates the platform, kept for days, and copied into dashboards (§2.8,
// point 6; gate "The relay does not read"). So a line is built from a closed
// list of fields, each of a closed shape, and a token appears only as the first
// eight hex characters of its SHA-256.

import { createHash } from 'node:crypto';

/** The first 8 hex characters of the token's SHA-256: enough to follow one device, never enough to reach it. */
export function tokenTag(token) {
  if (typeof token !== 'string' || token.length === 0) return undefined;
  return createHash('sha256').update(token.toLowerCase()).digest('hex').slice(0, 8);
}

// field -> test of its value. Anything else is dropped.
const FIELDS = {
  route: (v) => typeof v === 'string' && /^[a-z0-9./-]{1,40}$/.test(v),
  outcome: (v) => typeof v === 'string' && /^[a-z-]{1,20}$/.test(v),
  reason: (v) => typeof v === 'string' && /^[A-Za-z][A-Za-z0-9 _.-]{0,47}$/.test(v),
  kind: (v) => typeof v === 'string' && /^(alert|background|liveactivity|challenge)$/.test(v),
  env: (v) => v === 'sandbox' || v === 'production',
  status: (v) => Number.isInteger(v) && v >= 100 && v < 600,
  apns: (v) => Number.isInteger(v) && v >= 100 && v < 600,
  ms: (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v < 600000,
  tok: (v) => typeof v === 'string' && /^[0-9a-f]{8}$/.test(v),
  jwt: (v) => v === 'minted' || v === 'shared' || v === 'memory',
};

/** One log line as JSON, from the allowed fields only. */
export function formatLine(event) {
  const line = { t: 'relay' };
  for (const [key, ok] of Object.entries(FIELDS)) {
    if (event && Object.hasOwn(event, key) && ok(event[key])) {
      line[key] = key === 'ms' ? Math.round(event[key]) : event[key];
    }
  }
  return JSON.stringify(line);
}

/** A logger that writes allowed fields to `write` (standard output by default). */
export function createLogger(write = (text) => console.log(text)) {
  return { event: (event) => write(formatLine(event)) };
}

/**
 * The log scan: the secrets found in `text`. Each secret is looked for as it
 * is and, for tokens, in either case. Used by the tests over every line the
 * relay wrote, and by scripts/scan-logs.mjs over the deployment's logs.
 */
export function leaksIn(text, secrets) {
  const haystack = String(text);
  const lower = haystack.toLowerCase();
  return secrets.filter((secret) => {
    if (typeof secret !== 'string' || secret.length < 8) return false;
    // A long secret also leaks in part: its head or its tail is enough to find.
    const pieces = secret.length > 32 ? [secret, secret.slice(0, 24), secret.slice(-24)] : [secret];
    return pieces.some((piece) => haystack.includes(piece) || lower.includes(piece.toLowerCase()));
  });
}
