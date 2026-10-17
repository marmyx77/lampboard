// The APNs provider token: an ES256 JWT, kept and shared (§2.8, point 7).
//
// APNs wants the token renewed no more often than every 20 minutes and refuses
// one older than 60 (TooManyProviderTokenUpdates, ExpiredProviderToken). A
// serverless function has many short-lived instances; each minting its own
// token on a cold start would renew far too often. So the token lives in the
// shared store, every instance takes it from there, and a new one is minted only
// when the shared one is past `RENEW_AFTER`. Every mint is counted per hour, and
// /health shows the count: that is probe S-T's measure.

import { createPrivateKey, sign } from 'node:crypto';

/** Seconds after which a token is replaced: inside APNs' 20-to-60-minute window. */
export const RENEW_AFTER = 40 * 60;

function base64url(value) {
  return Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
}

/** An ES256 JWT for `keyId` and `teamId`, issued at `iat` (seconds). */
export function mint({ key, keyId, teamId, iat }) {
  const head = base64url({ alg: 'ES256', kid: keyId });
  const claims = base64url({ iss: teamId, iat });
  const input = `${head}.${claims}`;
  const signature = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
  return `${input}.${signature.toString('base64url')}`;
}

export function privateKey(p8) {
  return createPrivateKey({ key: p8, format: 'pem' });
}

export class ProviderTokens {
  /**
   * @param {object} options
   * @param {import('node:crypto').KeyObject} options.key the .p8, parsed
   * @param {string} options.keyId
   * @param {string} options.teamId
   * @param {{get: Function, set: Function}} options.store shared store
   * @param {{increment: Function, read: Function}} options.counter
   */
  constructor({ key, keyId, teamId, store, counter }) {
    Object.assign(this, { key, keyId, teamId, store, counter });
    this.held = null;
    this.storeKey = `apns-jwt:${keyId}`;
  }

  /** The token to send, and where it came from: `memory`, `shared` or `minted`. */
  async current(now, { refuse } = {}) {
    const seconds = Math.floor(now / 1000);
    const fresh = (held) => held && typeof held.jwt === 'string' && Number.isInteger(held.iat)
      && seconds - held.iat < RENEW_AFTER && seconds - held.iat >= -60 && held.jwt !== refuse;
    if (fresh(this.held)) return { jwt: this.held.jwt, source: 'memory' };
    const shared = await this.store.get(this.storeKey);
    if (fresh(shared)) {
      this.held = shared;
      return { jwt: shared.jwt, source: 'shared' };
    }
    const held = { jwt: mint({ key: this.key, keyId: this.keyId, teamId: this.teamId, iat: seconds }), iat: seconds };
    this.held = held;
    await this.store.set(this.storeKey, held, 55 * 60);
    await this.counter.increment(mintsKey(now), 2 * 3600, now);
    return { jwt: held.jwt, source: 'minted' };
  }

  /** How old the token in hand is, in seconds, or null. */
  age(now) {
    return this.held ? Math.floor(now / 1000) - this.held.iat : null;
  }
}

/** The counter of tokens minted in the hour of `now`. */
export function mintsKey(now) {
  return `jwt-mints:${new Date(now).toISOString().slice(0, 13)}`;
}
