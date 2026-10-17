// 429 above the quota, told to the source with when to try again.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { earn, makeRelay, token, vectors } from './helpers.js';
import { LIMITS } from '../lib/quota.js';

const turnDone = () => vectors.requests.find((r) => r.name === 'alert-turn-done').request;
const permission = () => vectors.requests.find((r) => r.name === 'alert-permission').request;

test('alerts over the hourly quota get 429 with Retry-After, and APNs sees none of them', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  h.apns.sent.length = 0;
  for (let i = 0; i < LIMITS.alert; i += 1) {
    assert.equal((await h.post('/v1/push', { ...turnDone(), cap: cap.cap })).status, 200, `push ${i + 1}`);
  }
  const over = await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  assert.equal(over.status, 429);
  assert.equal(over.body.outcome, 'quota');
  assert.ok(Number(over.headers['retry-after']) > 0 && Number(over.headers['retry-after']) <= 3600);
  assert.equal(h.apns.sent.length, LIMITS.alert);
});

test('the quota is per capability: one token over it does not silence another', async () => {
  const h = makeRelay();
  const busy = await earn(h, token('ab'));
  const calm = await earn(h, token('cd'));
  for (let i = 0; i <= LIMITS.alert; i += 1) await h.post('/v1/push', { ...turnDone(), cap: busy.cap, token: token('ab') });
  assert.equal((await h.post('/v1/push', { ...turnDone(), cap: calm.cap, token: token('cd') })).status, 200);
});

test('the window resets on the hour', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  for (let i = 0; i <= LIMITS.alert; i += 1) await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  h.clock.now += 3600_000;
  assert.equal((await h.post('/v1/push', { ...turnDone(), cap: cap.cap })).status, 200);
});

test('priority 10 has its own, smaller quota', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  for (let i = 0; i < LIMITS.urgent; i += 1) assert.equal((await h.post('/v1/push', { ...permission(), cap: cap.cap })).status, 200);
  assert.equal((await h.post('/v1/push', { ...permission(), cap: cap.cap })).status, 429);
  assert.equal((await h.post('/v1/push', { ...turnDone(), cap: cap.cap })).status, 200, 'priority 5 still goes');
});

test('a forged capability spends nobody\'s quota', async () => {
  const h = makeRelay();
  for (let i = 0; i <= LIMITS.alert; i += 1) await h.post('/v1/push', { ...turnDone(), cap: 'Zm9yZ2Vk' });
  const cap = await earn(h);
  assert.equal((await h.post('/v1/push', { ...turnDone(), cap: cap.cap })).status, 200);
});

test('challenges are limited per token: the relay will not ring a phone in a loop', async () => {
  const h = makeRelay();
  for (let i = 0; i < LIMITS.challenge; i += 1) {
    assert.equal((await h.post('/v1/challenge', { token: token(), environment: 'sandbox' }, `192.0.2.${i + 1}`)).status, 202);
  }
  assert.equal((await h.post('/v1/challenge', { token: token(), environment: 'sandbox' }, '192.0.2.99')).status, 429);
});

test('two instances sharing the store count together', async () => {
  const first = makeRelay();
  const cap = await earn(first);
  const second = makeRelay({ store: first.store });
  for (let i = 0; i < LIMITS.alert; i += 1) {
    const h = i % 2 === 0 ? first : second;
    await h.post('/v1/push', { ...turnDone(), cap: cap.cap });
  }
  assert.equal((await second.post('/v1/push', { ...turnDone(), cap: cap.cap })).status, 429);
});
