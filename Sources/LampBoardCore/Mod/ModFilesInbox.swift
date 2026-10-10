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
// The sessions whose reply the panel follows live (D153), and what waits to go.
const streaming = new Set()
// The turn each session is stopping to make room for the Hub's message: that
// stop is no news, a new turn follows at once. By turn, since the turn ends
// after the abort has returned (measured, 10 October 2026).
const replacing = new Map()
const pending = new Map()
// Whether the followed session's own box holds a draft, as last told (D154):
// a yes or a no, never the words.
const drafting = new Map()
let trusted = null
const FLUSH_EVERY = 150
const TRUST_FOR = 10 * 60 * 1000
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
      if (args.mode === 'interrupt' && turn) {
        replacing.set(session, turn)
        await $.turn.abort({ turnId: turn })
      }
      await $.prompt.submit(args.asUser === 'true' ? { text, asUser: true } : { text })
    } else if (payload.op === 'abort') {
      const turn = running.get(session)
      if (turn) await $.turn.abort({ turnId: turn })
    } else if (payload.op === 'command') {
      if (!/^[a-z0-9][a-z0-9:_-]{0,63}$/.test(args.name || '')) throw new Error('command name')
      await $.command.run({ command: args.name, args: typeof args.args === 'string' ? args.args : '' })
    } else if (payload.op === 'stream') {
      if (args.on === 'true') {
        streaming.add(session)
        drafting.delete(session)
        void boxNow($, session)
        void facts($, session)
      } else {
        streaming.delete(session)
        drafting.delete(session)
      }
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

// The panel proves it holds the key before any of a reply's text goes to it: a
// process that took the port while the panel was away would get nothing (D153).
async function panelTrusted($, panel) {
  const now = await $.clock.now()
  if (trusted && trusted.base === panel.base && trusted.until > now) return true
  try {
    const nonce = crypto.randomUUID()
    const answer = await $.http.fetch(`${panel.base}/mod/hello`, {
      headers: { 'X-LampBoard-Token': panel.token, 'X-LampBoard-Nonce': nonce },
    })
    if (!answer.ok) return false
    const hello = JSON.parse(answer.text)
    if (typeof hello.sig !== 'string' || !/^[0-9a-f]{128}$/.test(hello.sig)) return false
    const ok = await verifyEd25519(new TextEncoder().encode('lampboard-hello:' + nonce), bytesOf(hello.sig), panel.pub)
    if (ok) trusted = { base: panel.base, until: now + TRUST_FOR }
    return ok
  } catch (_) {
    return false
  }
}

// What one step adds to the reply: its text, and a line for each tool it asks
// for, by name only — never a tool's input, never the thinking.
function observe(session, turnId, chunk) {
  if (!chunk || typeof chunk !== 'object') return
  let add = ''
  if (chunk.kind === 'text' && typeof chunk.text === 'string') add = chunk.text
  else if (chunk.kind === 'tool' && typeof chunk.name === 'string') add = '\n⏺ ' + chunk.name + '\n'
  if (!add) return
  const waiting = pending.get(session)
  if (waiting && waiting.turnId === turnId) waiting.text += add
  else pending.set(session, { turnId, text: add, at: 0 })
}

async function flush($, session, done) {
  const waiting = pending.get(session)
  if (!waiting || (!waiting.text && !done)) return
  pending.set(session, { turnId: waiting.turnId, text: '', at: Date.now() })
  try {
    const panel = await panelOf($)
    if (!panel || !(await panelTrusted($, panel))) return
    await $.http.fetch(`${panel.base}/mod/stream`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': panel.token },
      body: JSON.stringify({ v: VERSION, session, turnId: waiting.turnId, text: waiting.text.slice(0, 16000), done: !!done }),
    })
  } catch (_) {}
}

async function boxNow($, session) {
  try {
    const box = await $.prompt.read()
    await presence($, session, typeof box.text === 'string' && box.text.trim().length > 0)
  } catch (_) {}
}

async function presence($, session, draft) {
  if (drafting.get(session) === draft) return
  drafting.set(session, draft)
  await tell($, { kind: 'presence', session, draft })
}

// What the composer offers for the session the Hub opens (D157): its commands,
// each a name and one short line, and where it draws (Remote Control adds
// `mobile`). The permission mode is not here: the hooks carry it (D139).
async function facts($, session) {
  try {
    const list = (await $.command.list()).slice(0, 300)
      .map((c) => ({ name: String(c.name).slice(0, 64), description: String(c.description || '').slice(0, 120) }))
    await tell($, { kind: 'commands', session, list })
  } catch (_) {}
  try {
    await tell($, { kind: 'surfaces', session, list: [...(await $.session.surfaces())].slice(0, 8) })
  } catch (_) {}
}

async function tell($, report) {
  try {
    const panel = await panelOf($)
    if (!panel) return
    await $.http.fetch(`${panel.base}/mod`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': panel.token },
      body: JSON.stringify({ v: VERSION, ...report }),
    })
  } catch (_) {}
}

async function stopped($, session, turnId) {
  try {
    const panel = await panelOf($)
    if (!panel) return
    await $.http.fetch(`${panel.base}/mod`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': panel.token },
      body: JSON.stringify({ v: VERSION, kind: 'stopped', session, turnId, at: await $.clock.now() }),
    })
  } catch (_) {}
}

export function endInbox(session) {
  const clock = clocks.get(session)
  if (clock) clearInterval(clock)
  clocks.delete(session)
  running.delete(session)
  replacing.delete(session)
  drafting.delete(session)
  overrides.delete(session)
  streaming.delete(session)
  pending.delete(session)
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
    if (!e.agentId) {
      const session = await $.session.id()
      running.set(session, e.turnId)
      // The person's Enter empties the box: the Hub hears it at the turn.
      if (streaming.has(session)) void boxNow($, session)
    }
    return next(e)
  })

  // The person typing in the session's own box, for the Hub's Send (D154).
  on('prompt.edit', async ($, e, next) => {
    const box = await next(e)
    try {
      const session = await $.session.id()
      if (streaming.has(session)) void presence($, session, typeof box?.text === 'string' && box.text.trim().length > 0)
    } catch (_) {}
    return box
  })

  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) {
      const session = await $.session.id()
      if (running.get(session) === e.turnId) running.delete(session)
      // No hook says a turn was stopped (D1's gap): the person's Esc or the
      // Hub's Stop would leave the lamp yellow. The panel takes it as a moment,
      // and anything the session said after it wins (D160).
      const replaced = replacing.get(session) === e.turnId
      if (replaced) replacing.delete(session)
      if (e.reason === 'aborted' && !replaced) void stopped($, session, e.turnId)
    }
    return next(e)
  })

  // The person's choice in the Hub, for this session only, on every request of
  // the main loop: never `/model` or `/config`, which write the default of every
  // session (measured, 10 October 2026). Registered after the governor's, so
  // it sees the governor's model and the person's choice wins.
  on('turn.step', { model: /./ }, async function* ($, e, next) {
    let session
    try { session = await $.session.id() } catch (_) {}
    const chosen = session ? overrides.get(session) : undefined
    const step = { ...e }
    if (chosen && !e.agentId) {
      if (chosen.model) step.model = chosen.model
      if (chosen.effort) step.effort = chosen.effort
    }
    // Followed live only for the session the panel has open, main loop only:
    // each piece passes on untouched, a copy of its text goes to the panel.
    if (!session || e.agentId || !streaming.has(session)) return yield* next(step)
    const stream = next(step)
    let item = await stream.next()
    while (!item.done) {
      observe(session, e.turnId, item.value)
      const waiting = pending.get(session)
      if (waiting && Date.now() - waiting.at > FLUSH_EVERY) void flush($, session, false)
      yield item.value
      item = await stream.next()
    }
    void flush($, session, true)
    return item.value
  })
}
"""#
}
