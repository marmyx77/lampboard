// Gate «Capacità»: without a valid capability the relay refuses (403).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { earn, env, makeRelay, secretV1, secretV2, token, vectors } from './helpers.js';

const alert = () => vectors.requests.find((r) => r.name === 'alert-turn-done').request;

test('a capability is earned by answering the silent push, and lets the app write to its token', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  assert.deepEqual(Object.keys(cap).sort(), ['cap', 'environment', 'token', 'version']);
  assert.equal(cap.token, token());
  const sent = await h.post('/v1/push', { ...alert(), cap: cap.cap, token: token() });
  assert.equal(sent.status, 200);
  assert.equal(sent.body.outcome, 'ok');
});

test('the challenge push is silent and carries only the nonce', async () => {
  const h = makeRelay();
  await h.post('/v1/challenge', { token: token(), environment: 'sandbox' });
  const push = h.apns.sent[0];
  assert.equal(push.headers['apns-push-type'], 'background');
  assert.equal(push.headers['apns-priority'], '5');
  assert.deepEqual(push.payload.aps, { 'content-available': 1 });
  assert.deepEqual(Object.keys(push.payload.lb.challenge).sort(), ['issuedAt', 'nonce']);
});

test('a forged capability is refused with 403', async () => {
  const h = makeRelay();
  const forged = await h.post('/v1/push', { ...alert(), cap: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', token: token() });
  assert.equal(forged.status, 403);
  assert.equal(h.apns.sent.length, 0, 'nothing reached APNs');
});

test("the Core's vector, whose capability no relay issued, is refused with 403", async () => {
  const h = makeRelay();
  const sent = await h.post('/v1/push', alert());
  assert.equal(sent.status, 403);
});

test("another token's capability is refused with 403", async () => {
  const h = makeRelay();
  const mine = await earn(h, token('ab'));
  h.apns.sent.length = 0;
  const theirs = await h.post('/v1/push', { ...alert(), cap: mine.cap, token: token('cd') });
  assert.equal(theirs.status, 403);
  assert.equal(h.apns.sent.length, 0);
});

test('a sandbox capability does not write to production', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  const sent = await h.post('/v1/push', { ...alert(), cap: cap.cap, token: token(), environment: 'production' });
  assert.equal(sent.status, 403);
});

test("another relay's capability (another secret) is refused", async () => {
  const other = makeRelay({ environment: env({ RELAY_SECRET_V1: secretV2 }) });
  const foreign = await earn(other);
  const h = makeRelay();
  const sent = await h.post('/v1/push', { ...alert(), cap: foreign.cap, token: token() });
  assert.equal(sent.status, 403);
});

test('a wrong, stale or borrowed nonce earns nothing', async () => {
  const h = makeRelay();
  await h.post('/v1/challenge', { token: token('ab'), environment: 'sandbox' });
  const { nonce, issuedAt } = h.apns.sent[0].payload.lb.challenge;
  const wrong = await h.post('/v1/capability', { token: token('ab'), environment: 'sandbox', nonce: 'x' + nonce.slice(1), issuedAt });
  assert.equal(wrong.status, 403);
  const borrowed = await h.post('/v1/capability', { token: token('cd'), environment: 'sandbox', nonce, issuedAt });
  assert.equal(borrowed.status, 403, "a nonce sent to one token does not earn another's capability");
  h.clock.now += 301_000;
  const stale = await h.post('/v1/capability', { token: token('ab'), environment: 'sandbox', nonce, issuedAt });
  assert.equal(stale.status, 403, 'five minutes is the limit');
});

test("a Live Activity capability writes only Live Activity pushes, a device's only the others", async () => {
  const h = makeRelay();
  const device = await earn(h);
  const liveToken = token('cd', 80);
  const live = await h.post('/v1/capability/liveactivity', { cap: device.cap, token: token(), environment: 'sandbox', liveActivityToken: liveToken });
  assert.equal(live.status, 200);
  assert.equal(live.body.token, liveToken);
  const la = vectors.requests.find((r) => r.name === 'liveactivity-counts').request;
  assert.equal((await h.post('/v1/push', { ...la, cap: live.body.cap, token: liveToken })).status, 200);
  assert.equal((await h.post('/v1/push', { ...alert(), cap: live.body.cap, token: liveToken })).status, 403, 'an activity capability does not write alerts');
  assert.equal((await h.post('/v1/push', { ...la, cap: device.cap, token: token() })).status, 403, 'a device capability does not write activities');
  const unvouched = await h.post('/v1/capability/liveactivity', { cap: 'bm9wZQ==', token: token(), environment: 'sandbox', liveActivityToken: liveToken });
  assert.equal(unvouched.status, 403, 'an activity token needs a device capability to vouch for it');
});

test('a secret can be rotated: the new one issues, the old one is still honoured', async () => {
  const before = makeRelay();
  const old = await earn(before);
  const after = makeRelay({ environment: env({ RELAY_SECRET_V2: secretV2 }) });
  assert.equal((await after.post('/v1/push', { ...alert(), cap: old.cap, token: token() })).status, 200);
  const fresh = await earn(after);
  assert.equal(fresh.version, 2);
  const dropped = makeRelay({ environment: env({ RELAY_SECRET_V1: secretV2 }) });
  assert.equal((await dropped.post('/v1/push', { ...alert(), cap: old.cap, token: token() })).status, 403, 'a secret removed is a capability revoked');
  assert.ok(secretV1 !== secretV2);
});
