import Foundation

extension ModFiles {

    /// `mod/hooks/inbox.js`, the Hub's signed commands (D152).
    /// Written by `Scripts/embed-mod.py` from the repository's copy: edit that one.
    public static let inbox = #"""
// The Hub's commands (D152): signed by the panel, collected here, checked
// before a field is read, run once.
//
// The panel signs each command with its Ed25519 key, whose public half is
// ~/.lampboard/panel-key.pub; the permission key and the token are files any
// process of the user's can read, so neither may make a command. A command is
// for one session, within a minute of being made, and once.
import { verifyEd25519 } from './ed25519.js'

const VERSION = 1
const WAKE = 'LampBoard wake [v2]'
const COLLECT_EVERY = 15000
const WINDOW = 60000
const OPS = new Set(['submit', 'abort', 'command', 'model', 'effort', 'stream'])

const clocks = new Map()
const running = new Map()
const overrides = new Map()
let collecting = false

async function home($) {
  try {
    const value = await $.env.get('HOME')
    return value && value.startsWith('/') && value !== '/' ? value : null
  } catch (_) {
    return null
  }
}

// The panel as register.js finds it, from HOME alone (a project's settings can
// set LAMPBOARD_HOME, not HOME), and its public key.
async function panelOf($) {
  try {
    const h = await home($)
    if (!h) return null
    const dir = `${h}/.lampboard`
    const token = (await $.fs.read(`${dir}/token`)).trim()
    const port = parseInt((await $.fs.read(`${dir}/port`)).trim(), 10)
    const pub = (await $.fs.read(`${dir}/panel-key.pub`)).trim()
    if (!/^[0-9a-f]{16,128}$/.test(token) || !(port >= 1024 && port < 65536) || !/^[0-9a-f]{64}$/.test(pub)) return null
    return { base: `http://127.0.0.1:${port}`, token, pub: bytesOf(pub) }
  } catch (_) {
    return null
  }
}

function bytesOf(hex) {
  const out = new Uint8Array(hex.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

// The commands waiting for this session, each checked, each run once.
async function collect($) {
  if (collecting) return
  collecting = true
  try {
    const panel = await panelOf($)
    if (!panel) return
    const session = await $.session.id()
    const answer = await $.http.fetch(`${panel.base}/mod/inbox`, {
      headers: { 'X-LampBoard-Token': panel.token, 'X-LampBoard-Session': session },
    })
    if (!answer.ok) return
    const list = JSON.parse(answer.text)
    if (!Array.isArray(list)) return
    for (const envelope of list.slice(0, 50)) {
      const payload = await opened($, envelope, panel.pub, session)
      if (payload) await perform($, panel, payload)
    }
  } catch (_) {
    // The panel is closed or restarting: the next wake or round collects.
  } finally {
    collecting = false
  }
}

// The payload, if the panel's key signed these bytes for this session, now,
// and it was not taken before; nothing is read from it until then.
async function opened($, envelope, pub, session) {
  if (!envelope || typeof envelope.payload !== 'string' || typeof envelope.sig !== 'string') return null
  if (!/^[0-9a-f]{128}$/.test(envelope.sig) || envelope.payload.length > 70000) return null
  const valid = await verifyEd25519(new TextEncoder().encode(envelope.payload), bytesOf(envelope.sig), pub)
  if (!valid) return null
  let payload
  try { payload = JSON.parse(envelope.payload) } catch (_) { return null }
  if (!payload || payload.v !== 2 || payload.sid !== session || !OPS.has(payload.op)) return null
  if (typeof payload.nonce !== 'string' || !payload.nonce) return null
  const now = await $.clock.now()
  if (typeof payload.ts !== 'number' || Math.abs(payload.ts - now) > WINDOW) return null
  const seen = (await $.store.get('lampboard.seen')) || {}
  if (seen[payload.nonce]) return null
  const kept = {}
  for (const [nonce, at] of Object.entries(seen)) if (now - at < 2 * WINDOW) kept[nonce] = at
  kept[payload.nonce] = now
  await $.store.set('lampboard.seen', kept)
  return payload
}

async function perform($, panel, payload) {
  const session = payload.sid
  const args = payload.args || {}
  let ok = true
  let error
  try {
    if (payload.op === 'submit') {
      const text = typeof args.text === 'string' ? args.text : ''
      if (!text) throw new Error('empty')
      const turn = running.get(session)
      if (args.mode === 'interrupt' && turn) await $.turn.abort({ turnId: turn })
      await $.prompt.submit(args.asUser === 'true' ? { text, asUser: true } : { text })
    } else if (payload.op === 'abort') {
      const turn = running.get(session)
      if (turn) await $.turn.abort({ turnId: turn })
    } else if (payload.op === 'command') {
      if (!/^[a-z0-9][a-z0-9:_-]{0,63}$/.test(args.name || '')) throw new Error('command name')
      await $.command.run({ command: args.name, args: typeof args.args === 'string' ? args.args : '' })
    } else if (payload.op === 'model' || payload.op === 'effort') {
      const current = overrides.get(session) || {}
      const value = typeof args.value === 'string' && args.value ? args.value : undefined
      overrides.set(session, { ...current, [payload.op]: value })
    }
  } catch (err) {
    ok = false
    error = String((err && err.message) || err).slice(0, 200)
  }
  try {
    await $.http.fetch(`${panel.base}/mod`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': panel.token },
      body: JSON.stringify({ v: VERSION, kind: 'done', session, nonce: payload.nonce, op: payload.op, ok, error }),
    })
  } catch (_) {}
}

export function endInbox(session) {
  const clock = clocks.get(session)
  if (clock) clearInterval(clock)
  clocks.delete(session)
  running.delete(session)
  overrides.delete(session)
}

// register.js holds these events without a matcher, and Claude Code loads one
// unmatched hook per event and module: each here narrows on a field every event
// of its kind carries, so it sees them all and the module still loads.
export function registerInbox(on) {
  on('session.start', { cwd: /^\// }, async ($, e, next) => {
    const result = await next(e)
    const session = await $.session.id()
    if (!clocks.has(session)) {
      clocks.set(session, setInterval(() => { void collect($) }, COLLECT_EVERY))
      void collect($)
    }
    return result
  })

  // The panel's wake: never the session's to read, whatever follows the line.
  on('session.receive', { text: WAKE }, async ($, e, next) => {
    void collect($)
    return { consumed: 'lampboard-wake' }
  })

  on('turn.start', { turnId: /./ }, async ($, e, next) => {
    if (!e.agentId) running.set(await $.session.id(), e.turnId)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) {
      const session = await $.session.id()
      if (running.get(session) === e.turnId) running.delete(session)
    }
    return next(e)
  })

  // The person's choice in the Hub, for this session only, on every request of
  // the main loop: never `/model` or `/config`, which write the default of every
  // session (measured, 10 October 2026). Registered after the governor's, so
  // it sees the governor's model and the person's choice wins.
  on('turn.step', { model: /./ }, async function* ($, e, next) {
    let chosen
    try { chosen = overrides.get(await $.session.id()) } catch (_) {}
    if (!chosen || e.agentId) return yield* next(e)
    const step = { ...e }
    if (chosen.model) step.model = chosen.model
    if (chosen.effort) step.effort = chosen.effort
    return yield* next(step)
  })
}
"""#
}
