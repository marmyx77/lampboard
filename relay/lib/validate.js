// The shape of what sources and apps send, checked before anything else.
//
// The relay reads no content, but it does check form: a token that is a token,
// an environment it knows, an envelope that is a sealed box of the allowed size.
// That last check is the relay's own half of the gate "The relay does not
// read": the Core refuses to send an envelope whose bytes carry what it was
// meant to hide (`RelayPushRequest.make`), and the relay refuses an envelope
// that does not look sealed, for a source that skipped the Core's check.

/** The largest envelope, in characters of its base64 text: the Core's `PushEnvelope.maxBytes`. */
export const ENVELOPE_MAX = 3 * 1024;

/** ChaCha20-Poly1305's nonce and tag: a sealed box is never shorter. */
const SEALED_MIN_BYTES = 12 + 16;

export const KINDS = Object.freeze(['alert', 'background', 'liveactivity']);
export const ENVIRONMENTS = Object.freeze(['sandbox', 'production']);

export class Invalid extends Error {
  constructor(reason, status = 400) {
    super(reason);
    this.reason = reason;
    this.status = status;
  }
}

/** The Core's `V1Validation.isHexToken`: even length, 64 to 400 hex digits. */
export function isToken(value) {
  return typeof value === 'string' && value.length >= 64 && value.length <= 400 && value.length % 2 === 0
    && /^[0-9a-fA-F]+$/.test(value);
}

export function token(value, field = 'token') {
  if (!isToken(value)) throw new Invalid(`${field} is not an APNs token`);
  return value.toLowerCase();
}

export function environment(value) {
  if (!ENVIRONMENTS.includes(value)) throw new Invalid('environment is not sandbox or production');
  return value;
}

/**
 * Whether these bytes read as text. A sealed box is indistinguishable from
 * random bytes, of which about 37% fall in printable ASCII; text, JSON or a path
 * is nearly all printable. The threshold sits far from both: random bytes reach
 * it with a chance of 3·10^-7 at the bare minimum of 28 bytes, and below 10^-21
 * at 100 bytes; the smallest real envelope (a `PushContent`) is over 150.
 */
export function looksReadable(bytes) {
  if (bytes.length === 0) return true;
  let printable = 0;
  for (const byte of bytes) {
    if ((byte >= 0x20 && byte <= 0x7e) || byte === 0x09 || byte === 0x0a || byte === 0x0d) printable += 1;
  }
  return printable / bytes.length >= 0.85;
}

/** The envelope, if it is a sealed box the relay may carry. */
export function envelope(value) {
  if (typeof value !== 'string' || value.length === 0) throw new Invalid('envelope is missing');
  if (value.length > ENVELOPE_MAX) throw new Invalid('envelope is over 3 KB', 413);
  if (value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Invalid('envelope is not base64');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length < SEALED_MIN_BYTES) throw new Invalid('envelope is too short to be sealed');
  if (looksReadable(bytes)) throw new Invalid('envelope is readable', 422);
  return value;
}

export function kind(value) {
  if (!KINDS.includes(value)) throw new Invalid('kind is not alert, background or liveactivity');
  return value;
}

/** Priority rules (§2.8, point 4): 10 or 5; a background push only at 5, as APNs requires. */
export function priority(value, forKind) {
  if (value !== 5 && value !== 10) throw new Invalid('priority is not 5 or 10');
  if (forKind === 'background' && value !== 5) throw new Invalid('a background push takes priority 5');
  return value;
}

/** A date the Core wrote (ISO 8601) or seconds since 1970; `undefined` when absent. */
export function optionalDate(value, field) {
  if (value === undefined || value === null) return undefined;
  let ms;
  if (typeof value === 'number' && Number.isFinite(value)) ms = value * 1000;
  else if (typeof value === 'string' && value.length <= 40) ms = Date.parse(value);
  if (!Number.isFinite(ms)) throw new Invalid(`${field} is not a date`);
  return Math.floor(ms / 1000);
}

/** A JSON body of at most `limit` bytes, as an object. */
export function body(text, limit = 8 * 1024) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > limit) throw new Invalid('body is too large', 413);
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Invalid('body is not JSON');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Invalid('body is not an object');
  return parsed;
}
