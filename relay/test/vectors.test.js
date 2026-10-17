// The relay against what the Core really sends (relay/scripts/make-vectors.sh).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { earn, makeRelay, vectors } from './helpers.js';
import { ENVELOPE_MAX } from '../lib/validate.js';

test('the relay and the Core agree on the largest envelope', () => {
  assert.equal(ENVELOPE_MAX, vectors.envelopeMaxBytes);
});

test("the capability the relay issues has the Core's RelayCapability shape", async () => {
  const h = makeRelay();
  const cap = await earn(h);
  const core = vectors.capability;
  assert.deepEqual(Object.keys(cap).sort(), Object.keys(core).sort());
  for (const key of Object.keys(core)) assert.equal(typeof cap[key], typeof core[key], key);
  assert.equal(cap.version, core.version);
});

for (const vector of vectors.requests) {
  test(`the Core's ${vector.name} request is carried, envelope untouched`, async () => {
    const h = makeRelay();
    const request = vector.request;
    let cap;
    if (request.kind === 'liveactivity') {
      const device = await earn(h);
      const live = await h.post('/v1/capability/liveactivity', {
        cap: device.cap, token: device.token, environment: request.environment, liveActivityToken: request.token,
      });
      cap = live.body.cap;
    } else {
      cap = (await earn(h, request.token, request.environment)).cap;
    }
    h.apns.sent.length = 0;
    const sent = await h.post('/v1/push', { ...request, cap });
    assert.equal(sent.status, 200, JSON.stringify(sent.body));
    const apns = h.apns.sent[0];
    const wire = JSON.stringify(apns.payload);
    assert.ok(wire.includes(request.envelope), 'the envelope as the Core sealed it');
    for (const secret of vector.secrets) assert.ok(!wire.includes(secret), `"${secret}" is not in what APNs receives`);
    assert.equal(apns.headers['apns-priority'], String(request.priority));
  });
}

const expected = { 'plaintext-path': 422, 'too-large': 413, 'background-urgent': 400 };
for (const vector of vectors.refused) {
  test(`what the Core refuses to send (${vector.name}: ${vector.coreRefusal}) the relay refuses too`, async () => {
    const h = makeRelay();
    const cap = (await earn(h, vector.request.token, vector.request.environment)).cap;
    h.apns.sent.length = 0;
    const sent = await h.post('/v1/push', { ...vector.request, cap });
    assert.equal(sent.status, expected[vector.name], JSON.stringify(sent.body));
    assert.equal(sent.body.outcome, 'refused');
    assert.equal(h.apns.sent.length, 0, 'nothing reached APNs');
  });
}
