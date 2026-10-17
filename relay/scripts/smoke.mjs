// The deployed relay, from outside: health, refusals, APNs reached, quota.
//
//   node scripts/smoke.mjs <base-url> [--tokens-out <file>] [--header 'name: value']
//
// No real device is needed. A random token is a token APNs has never issued:
// APNs answering BadDeviceToken proves the relay reached it over HTTP/2 with a
// JWT it accepted (a bad JWT is InvalidProviderToken, 403). The tokens used are
// written to --tokens-out, so that scripts/scan-logs.mjs can look for them in the
// deployment's logs afterwards.

import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const base = args[0]?.replace(/\/+$/, '');
if (!base) {
  console.error('usage: node scripts/smoke.mjs <base-url> [--tokens-out <file>] [--header "name: value"]');
  process.exit(2);
}
const option = (name) => {
  const at = args.indexOf(name);
  return at > 0 ? args[at + 1] : undefined;
};
const extraHeaders = {};
const header = option('--header');
if (header) {
  const [name, ...value] = header.split(':');
  extraHeaders[name.trim()] = value.join(':').trim();
}

let failures = 0;
const results = [];
function expect(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? '  ✓' : '  ✗'} ${name}${detail ? ` (${detail})` : ''}`);
  if (!ok) failures += 1;
}

async function call(method, path, body) {
  const started = performance.now();
  const response = await fetch(`${base}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...extraHeaders },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text.slice(0, 120) };
  }
  return { status: response.status, body: json, ms: Math.round(performance.now() - started), headers: response.headers };
}

const hex = () => randomBytes(32).toString('hex');
const tokens = [];
const fresh = () => {
  const t = hex();
  tokens.push(t);
  return t;
};

const health = await call('GET', '/health');
expect('/health answers 200', health.status === 200 && health.body.status === 'ok', `${health.status}, ${health.ms} ms`);
const mintsBefore = health.body.jwt?.mintsThisHour;

const forged = await call('POST', '/v1/push', {
  cap: randomBytes(32).toString('base64'), token: fresh(), environment: 'sandbox', kind: 'alert', priority: 5,
  envelope: randomBytes(120).toString('base64'),
});
expect('a forged capability is refused with 403', forged.status === 403, `${forged.status} ${forged.body.reason ?? ''}`);

const nonce = await call('POST', '/v1/capability', {
  token: fresh(), environment: 'sandbox', nonce: randomBytes(32).toString('base64url'), issuedAt: Math.floor(Date.now() / 1000),
});
expect('a made-up nonce earns no capability (403)', nonce.status === 403, `${nonce.status}`);

const readable = await call('POST', '/v1/push', {
  cap: randomBytes(32).toString('base64'), token: fresh(), environment: 'sandbox', kind: 'alert', priority: 5,
  envelope: Buffer.from('{"body":"Edit /Users/dev/project/Secret.swift"}').toString('base64'),
});
expect('an envelope in clear never reaches APNs (403 or 422)', readable.status === 403 || readable.status === 422, `${readable.status}`);

for (const environment of ['sandbox', 'production']) {
  const challenged = await call('POST', '/v1/challenge', { token: fresh(), environment });
  expect(`APNs ${environment} reached over HTTP/2 with an accepted JWT (BadDeviceToken)`,
    challenged.status === 400 && challenged.body.reason === 'BadDeviceToken',
    `${challenged.status} ${challenged.body.reason ?? ''}, ${challenged.ms} ms`);
}

// The per-token challenge quota: the relay will not ring one token in a loop.
const looped = fresh();
const statuses = [];
let quotaHit;
for (let i = 0; i < 12 && !quotaHit; i += 1) {
  const answer = await call('POST', '/v1/challenge', { token: looped, environment: 'sandbox' });
  statuses.push(answer.status);
  if (answer.status === 429) quotaHit = answer;
}
expect('over the quota: 429 with Retry-After', Boolean(quotaHit) && Number(quotaHit.headers.get('retry-after')) > 0,
  `statuses ${statuses.join(',')}`);

const after = await call('GET', '/health');
expect('/health still 200', after.status === 200, `JWT mints this hour ${mintsBefore} -> ${after.body.jwt?.mintsThisHour}, requests this month ${after.body.usage?.requests}`);

const out = option('--tokens-out');
if (out) writeFileSync(out, `${tokens.join('\n')}\n`, { mode: 0o600 });
console.log(failures ? `\n${failures} failed` : '\nall passed');
process.exit(failures ? 1 : 0);
