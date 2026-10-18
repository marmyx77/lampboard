// The three kinds of push as APNs receives them, and the priority rules.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { earn, makeRelay, token, vectors } from './helpers.js';

const find = (name) => vectors.requests.find((r) => r.name === name).request;

async function liveHarness() {
  const h = makeRelay();
  const device = await earn(h);
  const live = await h.post('/v1/capability/liveactivity', {
    cap: device.cap, token: device.token, environment: 'sandbox', liveActivityToken: find('liveactivity-counts').token,
  });
  h.apns.sent.length = 0;
  return { h, device, cap: live.body.cap };
}

test('alert: topic is the bundle, push type alert, expiry 15 minutes', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  await h.post('/v1/push', { ...find('alert-permission'), cap: cap.cap });
  const { headers } = h.apns.sent.at(-1);
  assert.equal(headers['apns-topic'], 'com.lampboard.ios');
  assert.equal(headers['apns-push-type'], 'alert');
  assert.equal(headers['apns-priority'], '10');
  assert.equal(Number(headers['apns-expiration']), Math.floor(h.clock.now / 1000) + 900);
});

test('background: content-available only, priority 5, and a request at 10 is refused', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  h.apns.sent.length = 0;
  await h.post('/v1/push', { ...find('background-counts'), cap: cap.cap });
  const { headers, payload } = h.apns.sent.at(-1);
  assert.equal(headers['apns-push-type'], 'background');
  assert.equal(headers['apns-priority'], '5');
  assert.deepEqual(payload.aps, { 'content-available': 1 });
  assert.equal(payload.lb.e, find('background-counts').envelope);
  const urgent = await h.post('/v1/push', { ...find('background-counts'), cap: cap.cap, priority: 10 });
  assert.equal(urgent.status, 400);
  assert.equal(h.apns.sent.length, 1);
});

test('priority other than 5 or 10 is refused', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  assert.equal((await h.post('/v1/push', { ...find('alert-turn-done'), cap: cap.cap, priority: 1 })).status, 400);
});

test('liveactivity: its own topic, the envelope as content state, a stale date always', async () => {
  const { h, cap } = await liveHarness();
  // The Core always names a stale date (RelayPushRequest.make); a source
  // without it names none, and the relay puts its own.
  assert.ok(find('liveactivity-counts').staleDate, 'the Core names one');
  const { staleDate: _named, ...bare } = find('liveactivity-counts');
  await h.post('/v1/push', { ...bare, cap });
  const { headers, payload } = h.apns.sent.at(-1);
  const now = Math.floor(h.clock.now / 1000);
  assert.equal(headers['apns-topic'], 'com.lampboard.ios.push-type.liveactivity');
  assert.equal(headers['apns-push-type'], 'liveactivity');
  assert.equal(payload.aps.event, 'update');
  assert.equal(payload.aps.timestamp, now);
  assert.deepEqual(payload.aps['content-state'], { envelope: find('liveactivity-counts').envelope });
  assert.equal(payload.aps['stale-date'], now + 900, 'the default when the source names none');
});

test('liveactivity: a stale date the source names is kept, within eight hours', async () => {
  const { h, cap } = await liveHarness();
  const now = Math.floor(h.clock.now / 1000);
  await h.post('/v1/push', { ...find('liveactivity-counts'), cap, staleDate: new Date((now + 600) * 1000).toISOString() });
  assert.equal(h.apns.sent.at(-1).payload.aps['stale-date'], now + 600);
  await h.post('/v1/push', { ...find('liveactivity-counts'), cap, staleDate: now + 86400 });
  assert.equal(h.apns.sent.at(-1).payload.aps['stale-date'], now + 8 * 3600);
  await h.post('/v1/push', { ...find('liveactivity-counts'), cap, event: 'end', dismissalDate: now + 60 });
  assert.equal(h.apns.sent.at(-1).payload.aps.event, 'end');
  assert.equal(h.apns.sent.at(-1).payload.aps['dismissal-date'], now + 60);
  assert.equal(find('liveactivity-end').event, 'end', 'the Core writes the end as the relay reads it');
  assert.equal((await h.post('/v1/push', { ...find('liveactivity-end'), cap })).status, 200);
  assert.equal((await h.post('/v1/push', { ...find('liveactivity-counts'), cap, event: 'start' })).status, 400);
  assert.equal((await h.post('/v1/push', { ...find('liveactivity-counts'), cap, staleDate: 'tomorrow' })).status, 400);
});

test("fields a source adds are never forwarded", async () => {
  const h = makeRelay();
  const cap = await earn(h);
  await h.post('/v1/push', { ...find('alert-turn-done'), cap: cap.cap, title: 'project-alpha', aps: { alert: 'x' } });
  assert.ok(!JSON.stringify(h.apns.sent.at(-1).payload).includes('project-alpha'));
});

test('APNs answers become outcomes a source can show', async () => {
  const answers = [
    [{ status: 410, reason: 'Unregistered' }, 410, 'refused'],
    [{ status: 400, reason: 'BadDeviceToken' }, 400, 'refused'],
    [{ status: 429, reason: 'TooManyRequests' }, 429, 'quota'],
    [{ status: 503, reason: 'ServiceUnavailable' }, 503, 'unreachable'],
  ];
  for (const [answer, status, outcome] of answers) {
    const h = makeRelay();
    const cap = await earn(h);
    h.apns.answer = () => answer;
    const sent = await h.post('/v1/push', { ...find('alert-turn-done'), cap: cap.cap });
    assert.equal(sent.status, status, answer.reason);
    assert.equal(sent.body.outcome, outcome);
    assert.equal(sent.body.reason, answer.reason);
  }
});

test('APNs out of reach is "unreachable", without the transport\'s message', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  h.apns.send = async () => { throw Object.assign(new Error(`connect failed /3/device/${token()}`), { code: 'ECONNREFUSED' }); };
  const sent = await h.post('/v1/push', { ...find('alert-turn-done'), cap: cap.cap });
  assert.equal(sent.status, 503);
  assert.equal(sent.body.outcome, 'unreachable');
  assert.ok(!h.lines.join('').includes(token()));
});
