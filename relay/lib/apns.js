// HTTP/2 to APNs, with `node:http2`.
//
// One session per environment and per instance, reused across requests while
// the instance lives: APNs is built for long-lived connections, and opening one
// per push costs a TLS handshake each time. A session that errs, receives a
// GOAWAY or closes is dropped, and the next push opens a new one.
//
// Errors are reported by code only. A Node error can carry the request's path,
// and the path holds the device token.

import http2 from 'node:http2';

export const HOSTS = Object.freeze({
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
});

const TIMEOUT_MS = 10_000;

export class APNsClient {
  /**
   * @param {object} [options]
   * @param {Record<string,string>} [options.origins] environment -> origin (tests point these at a local server)
   * @param {object} [options.connect] extra options for `http2.connect` (tests pass their CA)
   */
  constructor({ origins = HOSTS, connect = {} } = {}) {
    this.origins = origins;
    this.connectOptions = connect;
    this.sessions = new Map();
  }

  session(environment) {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const origin = this.origins[environment];
    if (!origin) throw Object.assign(new Error('unknown environment'), { code: 'ERR_RELAY_ENVIRONMENT' });
    const session = http2.connect(origin, this.connectOptions);
    const drop = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on('error', drop);
    session.on('goaway', drop);
    session.on('close', drop);
    // An idle session must not keep a finished invocation alive.
    session.unref();
    this.sessions.set(environment, session);
    return session;
  }

  /**
   * Sends one notification.
   * @returns {Promise<{status: number, reason?: string, apnsId?: string, ms: number}>}
   * Rejects only for the transport (`code` set), never with the token in the message.
   */
  send({ environment, token, headers, payload }) {
    const started = performance.now();
    return new Promise((resolve, reject) => {
      let session;
      try {
        session = this.session(environment);
      } catch (error) {
        reject(transport(error));
        return;
      }
      session.ref();
      const body = Buffer.from(JSON.stringify(payload));
      const request = session.request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        'content-type': 'application/json',
        'content-length': body.length,
        ...headers,
      });
      let status = 0;
      let apnsId;
      const chunks = [];
      const finish = (fn) => {
        clearTimeout(timer);
        if (!session.destroyed) session.unref();
        fn();
      };
      const timer = setTimeout(() => {
        request.close(http2.constants.NGHTTP2_CANCEL);
        finish(() => reject(Object.assign(new Error('APNs did not answer in time'), { code: 'ETIMEDOUT' })));
      }, TIMEOUT_MS);
      request.on('response', (head) => {
        status = Number(head[':status']);
        apnsId = head['apns-id'];
      });
      request.on('data', (chunk) => chunks.push(chunk));
      request.on('end', () => finish(() => {
        let reason;
        if (chunks.length) {
          try {
            reason = JSON.parse(Buffer.concat(chunks).toString('utf8')).reason;
          } catch {
            reason = undefined;
          }
        }
        resolve({ status, reason: typeof reason === 'string' ? reason : undefined, apnsId, ms: performance.now() - started });
      }));
      request.on('error', (error) => finish(() => reject(transport(error))));
      request.end(body);
    });
  }

  close() {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }
}

function transport(error) {
  // Only the code travels: the message may hold the path, and the path the token.
  return Object.assign(new Error('APNs could not be reached'), { code: error?.code || 'ERR_TRANSPORT' });
}
