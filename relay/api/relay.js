// The one Vercel function. vercel.json sends every path here; lib/relay.js routes.
//
// Module scope lives as long as the instance: the configuration is read once,
// the HTTP/2 sessions to APNs and the JWT in hand are reused across requests.

import { APNsClient } from '../lib/apns.js';
import { readConfig } from '../lib/config.js';
import { createLogger } from '../lib/log.js';
import { createRelay } from '../lib/relay.js';
import { defaultStore } from '../lib/store.js';

const relay = defaultStore().then((store) => createRelay({
  config: readConfig(process.env),
  apns: new APNsClient(),
  store,
  logger: createLogger(),
}));

async function handle(request) {
  const url = new URL(request.url);
  const address = (request.headers.get('x-real-ip') || request.headers.get('x-forwarded-for') || 'unknown')
    .split(',')[0].trim().slice(0, 64);
  let body;
  if (request.method === 'POST') {
    const length = Number(request.headers.get('content-length') || 0);
    body = length > 8 * 1024 ? 'x'.repeat(8 * 1024 + 1) : await request.text();
  }
  const answer = await (await relay).handle({ method: request.method, path: url.pathname, address, body });
  return new Response(request.method === 'HEAD' ? null : JSON.stringify(answer.body), {
    status: answer.status,
    headers: answer.headers,
  });
}

export const GET = handle;
export const HEAD = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
