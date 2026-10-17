// The real HTTP/2 client against a local HTTP/2 server standing in for APNs.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { APNsClient } from '../lib/apns.js';
import { token } from './helpers.js';

let server;
let origin;
let cert;
const seen = [];

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'relay-h2-'));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-days', '1',
    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem')],
  { stdio: 'ignore' });
  cert = readFileSync(join(dir, 'cert.pem'));
  const key = readFileSync(join(dir, 'key.pem'));
  rmSync(dir, { recursive: true });
  // allowHTTP1 false: a client that does not speak HTTP/2 is refused, as APNs refuses it.
  server = http2.createSecureServer({ key, cert, allowHTTP1: false });
  server.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      seen.push({ headers, body: JSON.parse(Buffer.concat(chunks).toString() || '{}'), protocol: stream.session.alpnProtocol });
      const deviceToken = headers[':path'].split('/').pop();
      if (deviceToken.startsWith('00')) {
        stream.respond({ ':status': 400, 'apns-id': 'id-1', 'content-type': 'application/json' });
        stream.end(JSON.stringify({ reason: 'BadDeviceToken' }));
      } else {
        stream.respond({ ':status': 200, 'apns-id': 'id-2' });
        stream.end();
      }
    });
  });
  await new Promise((resolve) => server.listen(0, 'localhost', resolve));
  origin = `https://localhost:${server.address().port}`;
});

after(() => server.close());

const client = () => new APNsClient({ origins: { sandbox: origin, production: origin }, connect: { ca: cert } });

test('a push goes out over HTTP/2 to /3/device/<token> with its headers and JSON body', async () => {
  const apns = client();
  const answer = await apns.send({
    environment: 'sandbox', token: token(),
    headers: { 'apns-topic': 'com.lampboard.ios', 'apns-push-type': 'alert', authorization: 'bearer x' },
    payload: { aps: { alert: { title: 'LampBoard', body: 'A session is waiting' } } },
  });
  apns.close();
  assert.equal(answer.status, 200);
  assert.equal(answer.apnsId, 'id-2');
  const request = seen.at(-1);
  assert.equal(request.protocol, 'h2');
  assert.equal(request.headers[':method'], 'POST');
  assert.equal(request.headers[':path'], `/3/device/${token()}`);
  assert.equal(request.headers['apns-topic'], 'com.lampboard.ios');
  assert.equal(request.body.aps.alert.body, 'A session is waiting');
});

test("APNs' reason is read from the body", async () => {
  const apns = client();
  const answer = await apns.send({ environment: 'sandbox', token: token('00'), headers: {}, payload: {} });
  apns.close();
  assert.deepEqual([answer.status, answer.reason], [400, 'BadDeviceToken']);
});

test('one session carries many pushes', async () => {
  const apns = client();
  const sessions = new Set();
  for (let i = 0; i < 5; i += 1) {
    await apns.send({ environment: 'sandbox', token: token(), headers: {}, payload: {} });
    sessions.add(apns.sessions.get('sandbox'));
  }
  apns.close();
  assert.equal(sessions.size, 1);
});

test('a transport failure rejects with a code and without the token', async () => {
  const apns = new APNsClient({ origins: { sandbox: 'https://localhost:1' } });
  await assert.rejects(apns.send({ environment: 'sandbox', token: token(), headers: {}, payload: {} }), (error) => {
    assert.ok(error.code);
    assert.ok(!error.message.includes(token()));
    return true;
  });
  apns.close();
});
