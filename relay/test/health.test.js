// /health: what a source reads in `hello`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { env, makeRelay, testKey } from './helpers.js';

test('health answers 200 with the usage and the JWT count, and no secret', async () => {
  const h = makeRelay();
  const answer = await h.get('/health');
  assert.equal(answer.status, 200);
  assert.equal(answer.body.status, 'ok');
  assert.equal(answer.body.service, 'lampboard-relay');
  assert.equal(answer.body.usage.hobbyMonthlyLimit, 1_000_000);
  assert.ok(answer.body.usage.requests >= 1);
  assert.equal(answer.body.jwt.mintsThisHour, 0);
  const text = JSON.stringify(answer.body);
  for (const secret of [env().RELAY_SECRET_V1, testKey.pem.split('\n')[1]]) assert.ok(!text.includes(secret));
});

test('a relay missing its key says which names are missing (never values), and refuses to push', async () => {
  const h = makeRelay({ environment: env({ APNS_KEY_P8: '', RELAY_SECRET_V1: 'c2hvcnQ=' }) });
  const answer = await h.get('/health');
  assert.equal(answer.status, 503);
  assert.deepEqual(answer.body.missing.sort(), ['APNS_KEY_P8', 'RELAY_SECRET_V1']);
  const push = await h.post('/v1/push', {});
  assert.equal(push.status, 503);
  assert.equal(push.body.outcome, 'unreachable');
});

test('unknown routes are 404, wrong methods 405, bodies over 8 KB 413', async () => {
  const h = makeRelay();
  assert.equal((await h.get('/v2/push')).status, 404);
  assert.equal((await h.get('/v1/push')).status, 405);
  assert.equal((await h.post('/v1/push', 'x'.repeat(9000))).status, 413);
  assert.equal((await h.post('/v1/push', 'not json')).status, 400);
});
