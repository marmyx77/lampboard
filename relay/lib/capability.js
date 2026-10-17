// Capabilities and the challenge that earns one, with no database (§2.8, point 1).
//
// A capability is `HMAC(relay secret, token ‖ environment ‖ version)`, with a
// purpose in the input so that one earned for a Live Activity token cannot
// write alerts. The relay never stores one: it checks a capability by computing
// it again. Whoever holds the token can earn its capability; whoever has a
// capability can write to that token and to no other.
//
// Earning it: the app asks for a challenge; the relay sends the token a silent
// push carrying a nonce; the app hands the nonce back. The nonce is itself an
// HMAC over the token, the environment and the time it was issued, so the relay
// keeps nothing between the two calls either.

import { createHmac, timingSafeEqual } from 'node:crypto';

export const PURPOSES = Object.freeze({ device: 'device', liveactivity: 'liveactivity' });

/** How long a challenge's nonce is good for, in seconds. */
export const CHALLENGE_LIFETIME = 300;

function mac(secret, text) {
  return createHmac('sha256', secret).update(text, 'utf8').digest();
}

function equal(a, b) {
  const left = Buffer.from(String(a), 'utf8');
  const right = Buffer.from(String(b), 'utf8');
  return left.length === right.length && timingSafeEqual(left, right);
}

function capInput({ version, purpose, environment, token }) {
  return `lampboard-relay-cap\n${version}\n${purpose}\n${environment}\n${token.toLowerCase()}`;
}

/**
 * The relay's secrets, by version. The highest version issues; every version
 * still configured is accepted, so a secret can be rotated without cutting off
 * the capabilities already handed out.
 */
export class Secrets {
  constructor(byVersion) {
    const entries = Object.entries(byVersion)
      .map(([version, secret]) => [Number(version), secret])
      .filter(([version, secret]) => Number.isInteger(version) && version > 0 && Buffer.isBuffer(secret) && secret.length >= 32)
      .sort((a, b) => b[0] - a[0]);
    if (entries.length === 0) throw new Error('no relay secret of at least 32 bytes');
    this.entries = entries;
  }

  get current() {
    return { version: this.entries[0][0], secret: this.entries[0][1] };
  }

  /** `RELAY_SECRET_V<n>` variables, base64, from `env`. */
  static fromEnv(env) {
    const byVersion = {};
    for (const [name, value] of Object.entries(env)) {
      const match = /^RELAY_SECRET_V([1-9][0-9]{0,3})$/.exec(name);
      if (match && typeof value === 'string' && value.trim()) byVersion[match[1]] = Buffer.from(value.trim(), 'base64');
    }
    return new Secrets(byVersion);
  }
}

/** The capability for `token`, issued with the current secret: the Core's `RelayCapability`. */
export function issue(secrets, { token, environment, purpose = PURPOSES.device }) {
  const { version, secret } = secrets.current;
  const cap = mac(secret, capInput({ version, purpose, environment, token })).toString('base64');
  return { cap, token: token.toLowerCase(), environment, version };
}

/** Whether `cap` is the capability of `token` for `purpose` under any configured secret. */
export function verify(secrets, { cap, token, environment, purpose = PURPOSES.device }) {
  if (typeof cap !== 'string' || cap.length === 0 || cap.length > 512) return false;
  let ok = false;
  // Every version is computed, whatever matched first: the time taken says nothing.
  for (const [version, secret] of secrets.entries) {
    const expected = mac(secret, capInput({ version, purpose, environment, token })).toString('base64');
    if (equal(expected, cap)) ok = true;
  }
  return ok;
}

function nonceFor(secret, { token, environment, issuedAt }) {
  return mac(secret, `lampboard-relay-challenge\n${environment}\n${token.toLowerCase()}\n${issuedAt}`).toString('base64url');
}

/** The nonce the challenge push carries. */
export function challenge(secrets, { token, environment, now }) {
  const issuedAt = Math.floor(now / 1000);
  return { nonce: nonceFor(secrets.current.secret, { token, environment, issuedAt }), issuedAt };
}

/** Whether `nonce` is the one sent to `token` at `issuedAt`, and still fresh at `now`. */
export function answers(secrets, { token, environment, nonce, issuedAt, now }) {
  if (typeof nonce !== 'string' || nonce.length === 0 || nonce.length > 128) return false;
  if (!Number.isInteger(issuedAt)) return false;
  const age = Math.floor(now / 1000) - issuedAt;
  if (age < -30 || age > CHALLENGE_LIFETIME) return false;
  let ok = false;
  for (const [, secret] of secrets.entries) {
    if (equal(nonceFor(secret, { token, environment, issuedAt }), nonce)) ok = true;
  }
  return ok;
}
