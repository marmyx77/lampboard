// Gate «Il relay non legge»: the relay carries only sealed envelopes, and its
// logs hold no token and no content.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { earn, makeRelay, token, vectors } from './helpers.js';
import { formatLine, leaksIn, tokenTag } from '../lib/log.js';
import { looksReadable } from '../lib/validate.js';

const alert = () => vectors.requests.find((r) => r.name === 'alert-permission').request;

test('an envelope carrying a path in clear is refused (422) and never reaches APNs', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  h.apns.sent.length = 0;
  const path = Buffer.from(JSON.stringify({ body: 'Edit /Users/dev/project/Sources/Secret.swift' })).toString('base64');
  const sent = await h.post('/v1/push', { ...alert(), cap: cap.cap, envelope: path });
  assert.equal(sent.status, 422);
  assert.equal(h.apns.sent.length, 0);
});

test('plain text is readable; sealed bytes are not', () => {
  assert.ok(looksReadable(Buffer.from('A session is asking to run a command in project-alpha')));
  for (let i = 0; i < 2000; i += 1) assert.ok(!looksReadable(randomBytes(64)), 'random bytes read as text');
  for (const vector of vectors.requests) assert.ok(!looksReadable(Buffer.from(vector.request.envelope, 'base64')), vector.name);
});

test('the alert APNs receives holds the placeholder, never the content', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  await h.post('/v1/push', { ...alert(), cap: cap.cap });
  const aps = h.apns.sent.at(-1).payload.aps;
  assert.deepEqual(aps.alert, { title: 'LampBoard', body: 'A session is waiting' });
  assert.equal(aps['mutable-content'], 1);
  assert.equal(aps.category, undefined, 'the extension sets the category once the envelope opens');
});

test('a log line keeps only the allowed fields, and a token only as an 8-character tag', () => {
  const tok = token();
  const line = formatLine({ route: '/v1/push', outcome: 'ok', token: tok, envelope: 'abc', cap: 'xyz', tok: tokenTag(tok), ms: 12.4, reason: tok });
  assert.deepEqual(JSON.parse(line), { t: 'relay', route: '/v1/push', outcome: 'ok', tok: tokenTag(tok), ms: 12 });
  assert.equal(tokenTag(tok).length, 8);
});

test('the log scan finds a token, whole or in part, in either case', () => {
  const tok = token('ab');
  assert.deepEqual(leaksIn(`{"token":"${tok.toUpperCase()}"}`, [tok]), [tok]);
  assert.deepEqual(leaksIn(`prefix ${tok.slice(0, 30)} suffix`, [tok]), [tok]);
  assert.deepEqual(leaksIn('{"tok":"1a2b3c4d"}', [tok]), []);
});

test('log scan: nothing secret in any line the relay wrote, over every route and every refusal', async () => {
  const h = makeRelay({ apns: undefined });
  const secrets = [];
  const t1 = token('ab');
  const t2 = token('cd');
  const live = token('ef', 80);
  secrets.push(t1, t2, live);
  const cap = await earn(h, t1);
  secrets.push(cap.cap);
  for (const sent of h.apns.sent) secrets.push(sent.payload.lb?.challenge?.nonce);
  const la = await h.post('/v1/capability/liveactivity', { cap: cap.cap, token: t1, environment: 'sandbox', liveActivityToken: live });
  secrets.push(la.body.cap);
  for (const vector of vectors.requests) {
    secrets.push(vector.request.envelope, ...vector.secrets);
    const useCap = vector.request.kind === 'liveactivity' ? la.body.cap : cap.cap;
    const useToken = vector.request.kind === 'liveactivity' ? live : t1;
    await h.post('/v1/push', { ...vector.request, cap: useCap, token: useToken });
  }
  for (const vector of vectors.refused) {
    secrets.push(vector.request.envelope);
    await h.post('/v1/push', { ...vector.request, cap: cap.cap, token: t1 });
  }
  await h.post('/v1/push', { ...alert(), cap: cap.cap, token: t2 });
  await h.post('/v1/push', { ...alert(), cap: 'Zm9yZ2Vk', token: t2 });
  await h.post('/v1/push', `{"token":"${t2}"`);
  await h.post('/v1/capability', { token: t2, environment: 'sandbox', nonce: 'bm9uY2U', issuedAt: 1 });
  await h.get('/health');
  assert.ok(h.lines.length >= 15, `${h.lines.length} lines written`);
  const leaks = leaksIn(h.lines.join('\n'), secrets.filter(Boolean));
  assert.deepEqual(leaks, [], 'a secret in the logs');
});

test('the answers to a source never echo a token or an envelope either', async () => {
  const h = makeRelay();
  const cap = await earn(h);
  const answers = [];
  for (const vector of vectors.refused) answers.push(await h.post('/v1/push', { ...vector.request, cap: cap.cap }));
  answers.push(await h.post('/v1/push', { ...alert(), cap: 'Zm9yZ2Vk' }));
  answers.push(await h.post('/v1/push', { ...alert(), token: 'not-a-token' }));
  const text = JSON.stringify(answers.map((a) => a.body));
  assert.deepEqual(leaksIn(text, [token(), cap.cap, ...vectors.refused.map((v) => v.request.envelope)]), []);
});
