// The relay's configuration, from the environment of the deployment.
//
// The APNs key (.p8) and the relay secrets exist only as encrypted environment
// variables of the Vercel project: never in this repository, never on a source
// machine. Key id and team id are not secret (they travel in every JWT header)
// but are personal, so they come from the environment too.

import { Secrets } from './capability.js';
import { privateKey } from './jwt.js';

export const REQUIRED = Object.freeze(['APNS_KEY_P8', 'APNS_KEY_ID', 'APNS_TEAM_ID', 'RELAY_SECRET_V1']);

/** The configuration, or the names of what is missing or unusable (never their values). */
export function readConfig(env = process.env) {
  const problems = [];
  for (const name of ['APNS_KEY_P8', 'APNS_KEY_ID', 'APNS_TEAM_ID']) {
    if (typeof env[name] !== 'string' || env[name].trim() === '') problems.push(name);
  }
  let key;
  if (!problems.includes('APNS_KEY_P8')) {
    try {
      // A value pasted through a form sometimes arrives with its newlines escaped.
      key = privateKey(env.APNS_KEY_P8.includes('\\n') ? env.APNS_KEY_P8.replace(/\\n/g, '\n') : env.APNS_KEY_P8);
      if (key.asymmetricKeyType !== 'ec') problems.push('APNS_KEY_P8');
    } catch {
      problems.push('APNS_KEY_P8');
    }
  }
  let secrets;
  try {
    secrets = Secrets.fromEnv(env);
  } catch {
    problems.push('RELAY_SECRET_V1');
  }
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  if (keyId && !/^[A-Z0-9]{10}$/.test(keyId)) problems.push('APNS_KEY_ID');
  if (teamId && !/^[A-Z0-9]{10}$/.test(teamId)) problems.push('APNS_TEAM_ID');
  const bundleId = (env.APNS_BUNDLE_ID || 'com.lampboard.ios').trim();
  if (!/^[A-Za-z0-9.-]{3,155}$/.test(bundleId)) problems.push('APNS_BUNDLE_ID');
  if (problems.length) return { ok: false, problems: [...new Set(problems)] };
  return { ok: true, key, keyId, teamId, bundleId, secrets };
}
