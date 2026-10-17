// What APNs receives for each kind of push (§2.8, point 4).
//
// The relay adds what must be in clear for iOS to act at all, and nothing a
// person wrote:
// - alert: a placeholder ("A session is waiting") and `mutable-content`, so the
//   Notification Service Extension wakes, opens the envelope and writes the real
//   text. The extension sets the category and the interruption level from what it
//   opened, so an envelope that does not open shows no actions.
// - background: `content-available` only; the app reads the envelope.
// - liveactivity: the envelope as the activity's content state, which the
//   widget extension opens; a `stale-date` always, so a source that falls silent
//   shows as stale instead of as calm.
// The challenge push is the relay's own: a silent push with the nonce.

export const PLACEHOLDER = Object.freeze({ title: 'LampBoard', body: 'A session is waiting' });

/** How long APNs keeps trying a push the device cannot take now: the extension drops envelopes older than 15 minutes anyway. */
export const EXPIRATION_SECONDS = 15 * 60;

/** A Live Activity's stale date when the source names none, and the furthest one it may name. */
export const STALE_DEFAULT_SECONDS = 15 * 60;
export const STALE_MAX_SECONDS = 8 * 3600;

export function topics(bundleId) {
  return { app: bundleId, liveactivity: `${bundleId}.push-type.liveactivity` };
}

function headers({ type, topic, priority, nowSeconds }) {
  return {
    'apns-push-type': type,
    'apns-topic': topic,
    'apns-priority': String(priority),
    'apns-expiration': String(nowSeconds + EXPIRATION_SECONDS),
  };
}

/**
 * Headers and payload for a source's push.
 * @param {object} push the validated request
 * @param {string} bundleId
 * @param {number} now milliseconds
 */
export function forPush(push, bundleId, now) {
  const nowSeconds = Math.floor(now / 1000);
  const topic = topics(bundleId);
  switch (push.kind) {
    case 'alert':
      return {
        headers: headers({ type: 'alert', topic: topic.app, priority: push.priority, nowSeconds }),
        payload: {
          aps: { alert: { ...PLACEHOLDER }, sound: 'default', 'mutable-content': 1 },
          lb: { e: push.envelope },
        },
      };
    case 'background':
      return {
        headers: headers({ type: 'background', topic: topic.app, priority: 5, nowSeconds }),
        payload: { aps: { 'content-available': 1 }, lb: { e: push.envelope } },
      };
    case 'liveactivity': {
      const named = push.staleDate;
      const stale = named === undefined
        ? nowSeconds + STALE_DEFAULT_SECONDS
        : Math.min(Math.max(named, nowSeconds), nowSeconds + STALE_MAX_SECONDS);
      const aps = {
        timestamp: nowSeconds,
        event: push.event ?? 'update',
        'content-state': { envelope: push.envelope },
        'stale-date': stale,
      };
      if (aps.event === 'end' && push.dismissalDate !== undefined) aps['dismissal-date'] = push.dismissalDate;
      return {
        headers: headers({ type: 'liveactivity', topic: topic.liveactivity, priority: push.priority, nowSeconds }),
        payload: { aps },
      };
    }
    default:
      throw new Error('unknown kind');
  }
}

/** The relay's own silent push for a capability challenge. */
export function forChallenge({ nonce, issuedAt }, bundleId, now) {
  return {
    headers: headers({ type: 'background', topic: topics(bundleId).app, priority: 5, nowSeconds: Math.floor(now / 1000) }),
    payload: { aps: { 'content-available': 1 }, lb: { challenge: { nonce, issuedAt } } },
  };
}
