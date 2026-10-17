// The APNs provider token: valid ES256, shared between instances, renewed
// between 20 and 60 minutes (probe S-T counts the mints).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verify } from 'node:crypto';
import { earn, makeRelay, testKey, vectors } from './helpers.js';
import { RENEW_AFTER } from '../lib/jwt.js';

const turnDone = () => vectors.requests.find((r) => r.name === 'alert-turn-done').request;
const bearer = (sent) => sent.headers.authorization.replace(/^bearer /, '');

test('the JWT is ES256 with kid and iss, and verifies with the public key', async () => {
  const h = makeRelay();
  await earn(h);
  const jwt = bearer(h.apns.sent[0]);
  const [head, claims, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(head, 'base64url')), { alg: 'ES256', kid: 'TESTKEY001' });
  const body = JSON.parse(Buffer.from(claims, 'base64url'));
  assert.equal(body.iss, 'TESTTEAM01');
  assert.equal(body.iat, Math.floor(h.clock.now / 1000));
  assert.ok(verify('sha256', Buffer.from(`${head}.${claims}`), { key: testKey.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
});

test('one JWT for many pushes, and for a cold instance sharing the store', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  for (let i = 0; i < 5; i += 1) await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  const cold = makeRelay({ store: h.store, apns: h.apns });
  cold.clock.now = h.clock.now + 60_000;
  await cold.post('/v1/push', { ...turnDone(), cap: cap.cap });
  assert.equal(new Set(h.apns.sent.map(bearer)).size, 1);
  assert.equal((await h.get('/health')).body.jwt.mintsThisHour, 1);
});

test('renewed after 40 minutes, never before 20', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  const first = bearer(h.apns.sent[0]);
  h.clock.now += 20 * 60_000;
  await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  assert.equal(bearer(h.apns.sent.at(-1)), first, 'still the same at 20 minutes');
  h.clock.now += (RENEW_AFTER - 20 * 60 + 1) * 1000;
  await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  assert.notEqual(bearer(h.apns.sent.at(-1)), first, 'a new one past 40');
  assert.ok(RENEW_AFTER >= 20 * 60 && RENEW_AFTER < 60 * 60);
});

test('a JWT APNs calls expired is replaced once, and the push retried', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  h.apns.answer = (_request, n) => (n === 2 ? { status: 403, reason: 'ExpiredProviderToken' } : { status: 200 });
  const sent = await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  assert.equal(sent.status, 200);
  assert.notEqual(bearer(h.apns.sent[1]), bearer(h.apns.sent[2]));
});
