// The relay: four routes, no database, blind to what it carries (§2.8).
//
//   GET  /health                      what the sources read in `hello`
//   POST /v1/challenge                 {token, environment} -> a silent push with a nonce
//   POST /v1/capability                {token, environment, nonce, issuedAt} -> RelayCapability
//   POST /v1/capability/liveactivity   {cap, token, environment, liveActivityToken} -> RelayCapability
//   POST /v1/push                      RelayPushRequest -> {outcome}
//
// Every answer to a source carries an `outcome` the source can put in its
// `hello` (`V1RelayHealth`): ok, refused, quota, unreachable.

import * as capability from './capability.js';
import { PURPOSES } from './capability.js';
import * as check from './validate.js';
import { Invalid } from './validate.js';
import { forChallenge, forPush } from './payload.js';
import { ProviderTokens, RENEW_AFTER, mintsKey } from './jwt.js';
import { Counter } from './store.js';
import { LIMITS, Quotas } from './quota.js';
import { tokenTag } from './log.js';

export const VERSION = '1.0.0';
export const HOBBY_MONTHLY_INVOCATIONS = 1_000_000;

const USAGE_FLUSH_MS = 30_000;

function json(status, body, extra = {}) {
  return { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra }, body };
}

/** The status and outcome a source hears for an APNs answer. */
function fromAPNs(answer) {
  const { status, reason } = answer;
  if (status === 200) return json(200, { outcome: 'ok' });
  if (status === 410) return json(410, { outcome: 'refused', reason: reason ?? 'Unregistered' });
  if (status === 429) return json(429, { outcome: 'quota', reason: reason ?? 'TooManyRequests' });
  if (status >= 500) return json(503, { outcome: 'unreachable', reason: reason ?? 'APNs unavailable' });
  if (status === 403) return json(502, { outcome: 'refused', reason: reason ?? 'Forbidden' });
  return json(400, { outcome: 'refused', reason: reason ?? `APNs ${status}` });
}

export function createRelay({ config, apns, store, logger, clock = () => Date.now() }) {
  const counter = new Counter(store);
  const quotas = new Quotas(counter);
  const tokens = config.ok
    ? new ProviderTokens({ key: config.key, keyId: config.keyId, teamId: config.teamId, store, counter })
    : null;
  const usage = { month: null, pending: 0, flushedAt: 0 };

  async function countUse(now) {
    const month = new Date(now).toISOString().slice(0, 7);
    if (usage.month !== month) Object.assign(usage, { month, pending: 0, flushedAt: 0 });
    usage.pending += 1;
    if (now - usage.flushedAt < USAGE_FLUSH_MS) return;
    const key = `usage:${month}`;
    const shared = Number(await store.get(key)) || 0;
    await store.set(key, shared + usage.pending, 40 * 24 * 3600);
    Object.assign(usage, { pending: 0, flushedAt: now });
  }

  async function overQuota(bucket, subject, now, note) {
    const retry = await quotas.take(bucket, subject, now);
    if (retry === null) return null;
    note.outcome = 'quota';
    return json(429, { outcome: 'quota', reason: `over the ${bucket} quota` }, { 'retry-after': String(retry) });
  }

  /** Sends through APNs with the shared JWT; a rejected token is replaced once. */
  async function deliver({ environment, token, built }, now, note) {
    let jwt = await tokens.current(now);
    note.jwt = jwt.source;
    let answer = await apns.send({ environment, token, headers: { ...built.headers, authorization: `bearer ${jwt.jwt}` }, payload: built.payload });
    if (answer.status === 403 && (answer.reason === 'ExpiredProviderToken' || answer.reason === 'InvalidProviderToken')) {
      jwt = await tokens.current(now, { refuse: jwt.jwt });
      note.jwt = jwt.source;
      answer = await apns.send({ environment, token, headers: { ...built.headers, authorization: `bearer ${jwt.jwt}` }, payload: built.payload });
    }
    note.apns = answer.status;
    note.reason = answer.reason;
    return answer;
  }

  async function health(now) {
    const body = { status: config.ok ? 'ok' : 'misconfigured', service: 'lampboard-relay', version: VERSION };
    if (!config.ok) return json(503, { ...body, missing: config.problems });
    const month = new Date(now).toISOString().slice(0, 7);
    const requests = (Number(await store.get(`usage:${month}`)) || 0) + (usage.month === month ? usage.pending : 0);
    return json(200, {
      ...body,
      environments: ['sandbox', 'production'],
      capabilityVersion: config.secrets.current.version,
      store: store.kind,
      jwt: { mintsThisHour: await counter.read(mintsKey(now)), ageSeconds: tokens.age(now), renewAfterSeconds: RENEW_AFTER },
      usage: { month, requests, hobbyMonthlyLimit: HOBBY_MONTHLY_INVOCATIONS },
      limits: LIMITS,
    });
  }

  async function challengeRoute(input, address, now, note) {
    const token = check.token(input.token);
    const environment = check.environment(input.environment);
    note.tok = tokenTag(token);
    note.env = environment;
    note.kind = 'challenge';
    const limited = await overQuota('challengeByAddress', address, now, note) ?? await overQuota('challenge', token, now, note);
    if (limited) return limited;
    const sent = capability.challenge(config.secrets, { token, environment, now });
    const answer = await deliver({ environment, token, built: forChallenge(sent, config.bundleId, now) }, now, note);
    if (answer.status === 200) return json(202, { outcome: 'ok' });
    return fromAPNs(answer);
  }

  async function capabilityRoute(input, address, now, note) {
    const token = check.token(input.token);
    const environment = check.environment(input.environment);
    note.tok = tokenTag(token);
    note.env = environment;
    const limited = await overQuota('capabilityByAddress', address, now, note);
    if (limited) return limited;
    const issuedAt = input.issuedAt;
    if (!capability.answers(config.secrets, { token, environment, nonce: input.nonce, issuedAt, now })) {
      throw new Invalid('the nonce is not the one sent to this token, or it is too old', 403);
    }
    return json(200, capability.issue(config.secrets, { token, environment, purpose: PURPOSES.device }));
  }

  async function liveActivityCapabilityRoute(input, address, now, note) {
    const token = check.token(input.token);
    const environment = check.environment(input.environment);
    const live = check.token(input.liveActivityToken, 'liveActivityToken');
    note.tok = tokenTag(token);
    note.env = environment;
    note.kind = 'liveactivity';
    const limited = await overQuota('capabilityByAddress', address, now, note);
    if (limited) return limited;
    // The device's capability vouches for the activity's token: an activity
    // token cannot answer a silent push, and only the app holding the device's
    // capability has one to name.
    if (!capability.verify(config.secrets, { cap: input.cap, token, environment, purpose: PURPOSES.device })) {
      throw new Invalid('capability does not belong to this token', 403);
    }
    return json(200, capability.issue(config.secrets, { token: live, environment, purpose: PURPOSES.liveactivity }));
  }

  async function pushRoute(input, now, note) {
    const token = check.token(input.token);
    const environment = check.environment(input.environment);
    const kind = check.kind(input.kind);
    note.tok = tokenTag(token);
    note.env = environment;
    note.kind = kind;
    const priority = check.priority(input.priority, kind);
    const purpose = kind === 'liveactivity' ? PURPOSES.liveactivity : PURPOSES.device;
    if (!capability.verify(config.secrets, { cap: input.cap, token, environment, purpose })) {
      throw new Invalid('capability does not belong to this token', 403);
    }
    const envelope = check.envelope(input.envelope);
    const push = { kind, priority, envelope };
    if (kind === 'liveactivity') {
      push.staleDate = check.optionalDate(input.staleDate, 'staleDate');
      push.dismissalDate = check.optionalDate(input.dismissalDate, 'dismissalDate');
      if (input.event !== undefined && input.event !== 'update' && input.event !== 'end') throw new Invalid('event is not update or end');
      push.event = input.event;
    }
    const limited = await overQuota(kind, token, now, note)
      ?? (kind === 'alert' && priority === 10 ? await overQuota('urgent', token, now, note) : null);
    if (limited) return limited;
    return fromAPNs(await deliver({ environment, token, built: forPush(push, config.bundleId, now) }, now, note));
  }

  const routes = {
    '/v1/challenge': challengeRoute,
    '/v1/capability': capabilityRoute,
    '/v1/capability/liveactivity': liveActivityCapabilityRoute,
    '/v1/push': (input, _address, now, note) => pushRoute(input, now, note),
  };

  /**
   * @param {{method: string, path: string, address?: string, body?: string}} request
   * @returns {Promise<{status: number, headers: object, body: object}>}
   */
  async function handle({ method, path, address = 'unknown', body }) {
    const started = clock();
    const route = path.replace(/\/+$/, '') || '/';
    const note = { route: route.slice(0, 40) };
    let response;
    try {
      await countUse(started);
      if (route === '/health' || route === '/') {
        response = method === 'GET' || method === 'HEAD' ? await health(started) : json(405, { outcome: 'refused', reason: 'method' }, { allow: 'GET' });
      } else if (!routes[route]) {
        response = json(404, { outcome: 'refused', reason: 'no such route' });
      } else if (method !== 'POST') {
        response = json(405, { outcome: 'refused', reason: 'method' }, { allow: 'POST' });
      } else if (!config.ok) {
        response = json(503, { outcome: 'unreachable', reason: 'relay is not configured' });
      } else {
        response = await routes[route](check.body(body ?? ''), address, started, note);
      }
    } catch (error) {
      if (error instanceof Invalid) {
        response = json(error.status, { outcome: 'refused', reason: error.reason });
      } else if (error && error.code) {
        // The transport to APNs: only the code is kept (lib/apns.js).
        note.reason = String(error.code).replace(/[^A-Za-z0-9_]/g, '').slice(0, 40);
        response = json(503, { outcome: 'unreachable', reason: 'APNs could not be reached' });
      } else {
        response = json(500, { outcome: 'unreachable', reason: 'internal error' });
      }
    }
    note.status = response.status;
    note.outcome = note.outcome ?? response.body.outcome ?? (response.status < 400 ? 'ok' : 'refused');
    note.ms = clock() - started;
    logger.event(note);
    return response;
  }

  return { handle };
}
