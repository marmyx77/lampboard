// Shared pieces of the relay's tests: a key, a configuration, a fake APNs, a
// logger that keeps what it was given.

import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { readConfig } from '../lib/config.js';
import { createLogger } from '../lib/log.js';
import { createRelay } from '../lib/relay.js';
import { MemoryStore } from '../lib/store.js';

export const vectors = JSON.parse(readFileSync(fileURLToPath(new URL('./vectors/core-vectors.json', import.meta.url)), 'utf8'));

// A P-256 key made for the tests: the shape of a .p8, nothing Apple knows.
const pair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
export const testKey = {
  pem: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }),
  publicKey: pair.publicKey,
};

export const secretV1 = randomBytes(32).toString('base64');
export const secretV2 = randomBytes(32).toString('base64');

export function env(extra = {}) {
  return {
    APNS_KEY_P8: testKey.pem,
    APNS_KEY_ID: 'TESTKEY001',
    APNS_TEAM_ID: 'TESTTEAM01',
    APNS_BUNDLE_ID: 'com.lampboard.ios',
    RELAY_SECRET_V1: secretV1,
    ...extra,
  };
}

/** An APNs that records what it was sent and answers as told. */
export class FakeAPNs {
  constructor(answer = () => ({ status: 200 })) {
    this.answer = answer;
    this.sent = [];
  }

  async send(request) {
    this.sent.push(request);
    return { ms: 1, ...this.answer(request, this.sent.length) };
  }
}

export function token(byte = 'ab', length = 64) {
  return byte.repeat(length / byte.length);
}

/** A relay over a fake APNs, a memory store, a settable clock and a logger that keeps every line. */
export function makeRelay({ environment = env(), apns = new FakeAPNs(), now = Date.UTC(2026, 9, 17, 12, 0, 0), store } = {}) {
  const clock = { now };
  const lines = [];
  const shared = store ?? new MemoryStore(() => clock.now);
  const relay = createRelay({
    config: readConfig(environment),
    apns,
    store: shared,
    logger: createLogger((line) => lines.push(line)),
    clock: () => clock.now,
  });
  const post = (path, body, address = '192.0.2.1') =>
    relay.handle({ method: 'POST', path, address, body: typeof body === 'string' ? body : JSON.stringify(body) });
  const get = (path) => relay.handle({ method: 'GET', path });
  return { relay, apns, clock, lines, store: shared, post, get };
}

/** Earns a device capability the way the app does: challenge, read the silent push, answer. */
export async function earn(harness, tok = token(), environment = 'sandbox') {
  const asked = await harness.post('/v1/challenge', { token: tok, environment });
  if (asked.status !== 202) throw new Error(`challenge answered ${asked.status}`);
  const push = harness.apns.sent.at(-1);
  const { nonce, issuedAt } = push.payload.lb.challenge;
  const answered = await harness.post('/v1/capability', { token: tok, environment, nonce, issuedAt });
  if (answered.status !== 200) throw new Error(`capability answered ${answered.status}`);
  return answered.body;
}
