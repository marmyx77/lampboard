# LampBoard push relay

The relay carries notifications from a LampBoard source (the Mac app, `lampd` on a
Linux machine) to Apple Push Notification service, for the iPhone and iPad app. It
holds the APNs key so that no source has to, and it is blind: what a notification
says travels in an envelope sealed between the source and the phone
(`PushEnvelope` in the Core), which the relay cannot open.

It runs as one Vercel function (`api/relay.js`), at `https://push.lampboard.site`.
There is no database.

## Routes

| route | body | answer |
|---|---|---|
| `GET /health` | — | `status`, capability version, JWT mints this hour, requests this month against the Hobby limit, quotas |
| `POST /v1/challenge` | `{token, environment}` | 202; the relay sends the token a silent push carrying `lb.challenge = {nonce, issuedAt}` |
| `POST /v1/capability` | `{token, environment, nonce, issuedAt}` | 200 with a `RelayCapability`: `{cap, token, environment, version}` |
| `POST /v1/capability/liveactivity` | `{cap, token, environment, liveActivityToken}` | 200 with a `RelayCapability` for the Live Activity token, vouched for by the device's |
| `POST /v1/push` | a `RelayPushRequest`: `{cap, token, environment, kind, priority, envelope}`; for `liveactivity` also `staleDate`, `event` (`update`, `end`), `dismissalDate` | `{outcome}`: `ok`, `refused`, `quota`, `unreachable` |

A capability is `HMAC(relay secret, version ‖ purpose ‖ environment ‖ token)`. The relay
checks one by computing it again; it is earned by proving possession of the token
(the nonce reaches only the device that holds it). A capability for a Live Activity
token writes only Live Activity pushes, and a device's only alerts and background
pushes.

## What APNs receives

- `alert`: `aps.alert` is the placeholder "A session is waiting", with
  `mutable-content`; the Notification Service Extension opens `lb.e` and writes the
  real text, category and interruption level.
- `background`: `content-available` and `lb.e`, always at priority 5.
- `liveactivity`: topic `com.lampboard.ios.push-type.liveactivity`; the envelope as
  `content-state.envelope`; a `stale-date` always (15 minutes when the source names
  none, never more than 8 hours).

## What it refuses

- a capability that is not the token's: 403;
- an envelope over 3 KB (413), not base64, shorter than a sealed box, or whose bytes
  read as text (422);
- a background push at priority 10, a priority other than 5 or 10: 400;
- over the hourly quota (`lib/quota.js`): 429 with `Retry-After`.

## Logs

One JSON line per request with route, outcome, kind, environment, status, APNs
status and reason, latency, and the first 8 hex characters of the token's SHA-256.
Never a token, a capability, a nonce or an envelope (`lib/log.js` keeps a closed
list of fields). `scripts/scan-logs.mjs` checks a deployment's logs for the tokens
a test used.

## Configuration

Encrypted environment variables of the Vercel project, never in this repository:

| name | what |
|---|---|
| `APNS_KEY_P8` | the APNs key, PEM (sensitive) |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | the key's id and the team's |
| `APNS_BUNDLE_ID` | the app's bundle id (default `com.lampboard.ios`) |
| `RELAY_SECRET_V1` (`_V2`, …) | the capability secrets, base64 of 32 random bytes or more (sensitive); the highest version issues, all are honoured |

Preview and production have different relay secrets: a capability earned from one
is refused by the other.

## Tests

```bash
cd relay
npm ci
npm test               # unit tests, with vectors written by the Core
scripts/bite.sh        # every gate, seen failing
scripts/make-vectors.sh  # regenerate test/vectors from the Core (docker, swift:6.4)
node scripts/smoke.mjs https://push.lampboard.site   # the deployed relay, from outside
```
