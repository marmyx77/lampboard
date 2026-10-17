// Quotas per capability, per hour (§2.8, point 5).
//
// The thresholds are written here, once. They are generous for a person and
// tight for a loop: a source sends on transitions only (a session turning amber,
// a question, a turn done), so even a busy machine with a dozen sessions stays
// well under them; a source stuck in a loop hits them within minutes and hears a
// 429, which it shows in its problems strip.
//
// A quota is counted against the token, after the capability is checked: no one
// without the capability can spend someone else's quota.

import { createHash } from 'node:crypto';

export const WINDOW_SECONDS = 3600;

export const LIMITS = Object.freeze({
  // per capability (token) per hour
  alert: 60,
  // of which at priority 10: a new permission question
  urgent: 20,
  background: 30,
  liveactivity: 120,
  // per token per hour: each one is a silent push the relay sends
  challenge: 6,
  // per client address per hour
  challengeByAddress: 30,
  capabilityByAddress: 60,
});

function hashed(value) {
  return createHash('sha256').update(String(value).toLowerCase()).digest('hex').slice(0, 24);
}

export class Quotas {
  constructor(counter, limits = LIMITS) {
    this.counter = counter;
    this.limits = limits;
  }

  /**
   * Counts one use of `bucket` for `subject`. Returns `null` when within the
   * limit, or the seconds until the window resets when over it.
   */
  async take(bucket, subject, now) {
    const limit = this.limits[bucket];
    if (!Number.isInteger(limit)) throw new Error(`no limit for ${bucket}`);
    const windowStart = Math.floor(now / 1000 / WINDOW_SECONDS) * WINDOW_SECONDS;
    const key = `q:${bucket}:${hashed(subject)}:${windowStart}`;
    const count = await this.counter.increment(key, WINDOW_SECONDS + 60, now);
    if (count > limit) return Math.max(1, windowStart + WINDOW_SECONDS - Math.floor(now / 1000));
    return null;
  }
}
