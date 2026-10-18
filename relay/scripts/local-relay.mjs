#!/usr/bin/env node
// The relay's own code on a port of this machine, for the checks that cannot
// reach APNs with a real device: lampd on a fake node posts to it, and what it
// would have sent APNs is written to a folder, one JSON file per push, for
// `simctl push` to deliver to a simulator (Apps/iOS/Scripts/push-e2e.sh).
//
//   node relay/scripts/local-relay.mjs --bind <address> --port <port> --dump <folder>
//
// Everything that decides is the deployed relay's: routes, capabilities,
// quotas, payloads, logs (lib/relay.js). Only APNs is replaced, by a recorder
// that answers 200, and the secrets are made for the run: a P-256 key Apple
// knows nothing of, a capability secret that is thrown away on exit. Nothing
// here can send a real notification.
//
// The dump holds tokens and envelopes, as APNs would receive them: it lives in
// a folder made for the run (0700), removed by the check.

import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { readConfig } from '../lib/config.js';
import { createLogger } from '../lib/log.js';
import { createRelay } from '../lib/relay.js';
import { MemoryStore } from '../lib/store.js';

function arg(name, fallback) {
  const at = process.argv.indexOf(name);
  return at >= 0 && at + 1 < process.argv.length ? process.argv[at + 1] : fallback;
}

const bind = arg('--bind', '127.0.0.1');
const port = Number(arg('--port', '18080'));
const dump = arg('--dump');
if (!dump) {
  console.error('local-relay: --dump <folder> is required');
  process.exit(2);
}
if (bind === '0.0.0.0' || bind === '::') {
  console.error('local-relay: refuses to listen on every address');
  process.exit(2);
}
mkdirSync(dump, { recursive: true, mode: 0o700 });
chmodSync(dump, 0o700);

const pair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const config = readConfig({
  APNS_KEY_P8: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }),
  APNS_KEY_ID: 'LOCALCHECK',
  APNS_TEAM_ID: 'LOCALCHECK',
  APNS_BUNDLE_ID: 'com.lampboard.ios',
  RELAY_SECRET_V1: randomBytes(32).toString('base64'),
});

let count = 0;
const recorder = {
  async send({ environment, token, headers, payload }) {
    count += 1;
    const file = join(dump, `${String(count).padStart(5, '0')}.json`);
    const { authorization: _jwt, ...kept } = headers;
    writeFileSync(file, JSON.stringify({ environment, token, headers: kept, payload }), { mode: 0o600 });
    return { status: 200, ms: 0 };
  },
};

const relay = createRelay({
  config,
  apns: recorder,
  store: new MemoryStore(),
  logger: createLogger((line) => process.stdout.write(line + '\n')),
});

createServer(async (request, response) => {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 9 * 1024) break;
  }
  const url = new URL(request.url, 'http://local');
  const answer = await relay.handle({
    method: request.method, path: url.pathname, address: request.socket.remoteAddress ?? 'unknown',
    body: request.method === 'POST' ? body : undefined,
  });
  response.writeHead(answer.status, answer.headers);
  response.end(JSON.stringify(answer.body));
}).listen(port, bind, () => {
  process.stdout.write(`local-relay: listening on http://${bind}:${port}, writing to ${dump}\n`);
});
