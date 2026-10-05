// LampBoard's companion mod: tells the LampBoard panel on this Mac what only
// the session knows — its context as Claude Code counts it, what it has cost,
// the account's rate-limit windows, where it draws and why it ended.
//
// It reads nothing of the conversation unless the person asks it a side question
// from the panel (below) — of a running tool only its name and
// the first line of its shell command or its file path, to say which one a
// stuck session is on; the panel masks what looks like a secret — writes
// nothing, runs nothing, and
// talks to one address: 127.0.0.1, on the port the panel wrote, with the token
// the panel wrote, both under ~/.lampboard.
// When the panel is not there it does nothing, silently: a session must never
// wait on, or hear about, a dashboard. The panel is found from HOME, never from
// LAMPBOARD_HOME, which a project's settings could point anywhere.
//
// One exception, asked for by the person: `/lampmaster <question>` sends the
// question they typed, and the session's folder, to the same address, and
// prints LampMaster's answer (D71).
//
// And one decision, when the person has switched it on in LampBoard: a call
// Claude Code would put to its permission dialog is put to the panel first,
// and the panel's allow or deny stands; unanswered in 55 seconds, or with the
// switch off, the dialog comes as it always did (D80). For that one the mod
// reads a second file the panel wrote, its permission key, sends it to nobody,
// and proves it holds it; the panel's answer counts only signed with it.
//
// And one question, asked by the person from the panel without disturbing the
// session (D82): a message in this session's box that starts with LampBoard's
// line, proven with that same key, is taken before the session sees it and
// answered with a fork over the conversation — no turn, nothing added to it —
// and only the answer goes to the panel. A message in that shape that is not
// proven is taken all the same and answered by nobody.
//
// And a band above the prompt (D84): what waits for the person in the other
// sessions — their names and one line each, as the panel's queue has them —
// drawn on the screen, never put into the conversation; a digit opens that one
// in the panel. Asked of the panel every few seconds, redrawn only on change.
//
// The colours of a row still come from LampBoard's hooks (decision D65); this
// adds only figures. Wire format: version 1 of LampBoardCore/Mod/ModReport.swift.

const VERSION = 1

// A permission decides what a session may run, so the panel that answers one
// is found from HOME and never from LAMPBOARD_HOME. A project's settings can set
// LAMPBOARD_HOME — to a folder of its own, with a key and a port of its
// choosing (a security review finding) — and cannot set HOME: measured on the
// test Mac, with a project's settings setting both, the mod read the attacker's
// LAMPBOARD_HOME and the real HOME.
async function realHome($) {
  try {
    const home = await $.env.get('HOME')
    return home && home.startsWith('/') && home !== '/' ? home : null
  } catch (_) {
    return null
  }
}

// A project's own settings can set environment variables for its sessions, so
// a cloned repository could point LAMPBOARD_HOME at itself and ship a port of
// its choosing — and receive every session's reports. So the panel is found
// from HOME alone, which a project's settings cannot set (measured on the test
// Mac); a test runs its sessions with HOME set to its fake home. And the
// address must answer as LampBoard before it is sent anything.
let confirmed = null

async function panel($) {
  try {
    const home = await realHome($)
    if (!home) return null
    const dir = `${home}/.lampboard`
    const token = (await $.fs.read(`${dir}/token`)).trim()
    const port = parseInt((await $.fs.read(`${dir}/port`)).trim(), 10)
    if (!/^[0-9a-f]{16,128}$/.test(token) || !(port >= 1024 && port < 65536)) return null
    const base = `http://127.0.0.1:${port}`
    if (confirmed !== base) {
      const health = await $.http.fetch(`${base}/health`)
      if (!health.ok || health.text.trim() !== 'lampboard') return null
      confirmed = base
    }
    return { base, url: `${base}/mod`, token }
  } catch (_) {
    return null
  }
}

async function post($, kind, fields) {
  try {
    const target = await panel($)
    if (!target) return
    const body = JSON.stringify({ v: VERSION, kind, session: await $.session.id(), ...fields })
    await $.http.fetch(target.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': target.token },
      body,
    })
  } catch (_) {
    // The panel is closed, restarting or older than this mod: nothing to do.
  }
}

// Whether the session runs on Claude Code's default configuration: then its
// rate-limit windows are those of the account the panel's allowance strip
// shows. Only whether the variable is set is sent, never its value.
async function config($) {
  try { return (await $.env.get('CLAUDE_CONFIG_DIR')) ? 'own' : 'default' } catch (_) { return undefined }
}

// The same allow-list the panel applies to a permission prompt: the first line
// of the shell command or which file, never a tool's free-form input. One line,
// so a heredoc's body never leaves; cut by characters, so no half of a pair.
function detailOf(e) {
  for (const key of ['command', 'file_path', 'path']) {
    if (typeof e[key] === 'string' && e[key]) return Array.from(e[key].split('\n')[0]).slice(0, 120).join('')
  }
  return undefined
}

async function model($) {
  try { return await $.session.model() } catch (_) { return undefined }
}

// HMAC-SHA256 by hand: the runtime offers `crypto.subtle.digest` and not the
// keyed functions (measured, 2.1.289). The panel checks and signs with the same.
const hex = (bytes) => Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('')
async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
}
async function hmac(key, message) {
  const encoder = new TextEncoder()
  let k = encoder.encode(key)
  if (k.length > 64) k = await sha256(k)
  const pad = (byte) => Uint8Array.from({ length: 64 }, (_, i) => (k[i] || 0) ^ byte)
  const m = encoder.encode(message)
  const inner = new Uint8Array(64 + m.length)
  inner.set(pad(0x36)); inner.set(m, 64)
  const outer = new Uint8Array(96)
  outer.set(pad(0x5c)); outer.set(await sha256(inner), 64)
  return hex(await sha256(outer))
}

// The same comparison whatever the guess: a proof is not found a byte at a time.
function same(a, b) {
  if (typeof a !== 'string' || a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

// A side question from the panel (D82), as PeerAsk in LampBoardCore writes it.
const ASK = /^LampBoard asks without disturbing \[v1 ([A-Za-z0-9-]{16,64}) ([0-9a-f]{64})\]:\n([\s\S]{1,2000})$/

async function answerQuietly($, nonce, proof, question) {
  try {
    const home = await realHome($)
    if (!home) return
    const key = (await $.fs.read(`${home}/.lampboard/check-key`)).trim()
    if (!/^[0-9a-f]{16,128}$/.test(key)) return
    const session = await $.session.id()
    if (!same(proof, await hmac(key, `fork:${nonce}:${session}:${question}`))) return
    const reply = await $.model.fork({ prompt: question })
    // The first post that carries words of the conversation: the port is asked
    // again whether it is LampBoard, not taken on an earlier answer.
    confirmed = null
    await post($, 'answer', reply.isAnswered ? { id: nonce, text: reply.text } : { id: nonce, reason: reply.reason })
  } catch (_) {
    // The panel waits a minute and says it heard nothing.
  }
}

// The band (D84): what the panel says waits elsewhere, kept between draws,
// per session — one process can hold several (the Claude app's chats) — with
// one clock each, stopped when that session ends.
const BAND_EVERY = 5000
const bands = new Map()

async function refreshBand($, session) {
  const state = bands.get(session)
  if (!state) return
  let text = '{"items":[],"v":1}'
  try {
    const target = await panel($)
    if (target) {
      const reply = await $.http.fetch(`${target.base}/mod/band`, {
        headers: { 'X-LampBoard-Token': target.token, 'X-LampBoard-Session': session },
      })
      if (reply.ok) text = reply.text
    }
  } catch (_) {
    // The panel is closed or restarting: nothing waits that it can show.
  }
  if (text === state.text) return
  try {
    const read = JSON.parse(text)
    if (read.v !== 1 || !Array.isArray(read.items)) return
    state.text = text
    state.items = read.items
    $.ui.invalidate('ui.render')
  } catch (_) {}
}

async function openInPanel($, session) {
  try {
    const target = await panel($)
    if (!target) return
    await $.http.fetch(`${target.base}/mod/band/open`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': target.token },
      body: JSON.stringify({ session }),
    })
  } catch (_) {}
}

// `/lampmaster <question>` (D71): the person's question to LampMaster, through
// the route the `lampmaster` MCP server uses, so the limits, the daily ceiling
// and the off switch are the same ones. The answer is shown to the person and
// is not handed to the model: it summarises other sessions' work, and what of
// it this session should act on is the person's call. The model has the MCP
// tools for its own questions.
const USAGE = 'Ask LampMaster what your other sessions know: /lampmaster <question>'
// Claude Code empties a box above 10,000 characters; LampBoard's answers stay
// near 2,000.
const MAX_ANSWER = 4000

async function ask($, question) {
  const target = await panel($)
  if (!target) return 'LampBoard is not running on this Mac, so LampMaster cannot answer.'
  try {
    const reply = await $.http.fetch(`${target.base}/lampmaster/tool`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': target.token },
      body: JSON.stringify({
        tool: 'ask_lampmaster',
        arguments: { question },
        session: await $.session.id(),
        cwd: await $.session.cwd(),
      }),
    })
    if (!reply.ok) return `LampBoard did not take the question (HTTP ${reply.status}).`
    const answer = JSON.parse(reply.text)
    if (typeof answer.text !== 'string' || !answer.text.trim()) return 'LampMaster gave no answer.'
    // LampBoard sends it clean already; the mod does not take a terminal's
    // safety on trust from whatever answered on that port. Line breaks stay.
    return Array.from(answer.text.trim().replace(/[\u0000-\u0009\u000B-\u001F\u007F-\u009F]/g, ''))
      .slice(0, MAX_ANSWER).join('')
  } catch (_) {
    return 'LampMaster could not be reached.'
  }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    try {
      // Immediate: a question about the other sessions does not depend on this
      // one's turn, and is most useful while that turn is still running.
      await $.command.register({ name: 'lampmaster', description: 'Ask LampMaster what your other sessions know', argumentHint: '<question>', immediate: true })
    } catch (_) {
      // An older Claude Code without commands: the MCP tools still answer.
    }
    await post($, 'start', { surface: e.surface, interactive: e.isInteractive, model: await model($), features: ['ask'] })
    // A band only where a person reads it, and one clock per session.
    const session = await $.session.id()
    if (e.isInteractive && !bands.has(session)) {
      bands.set(session, { text: '', items: [], clock: setInterval(() => { void refreshBand($, session) }, BAND_EVERY) })
      void refreshBand($, session)
    }
    return result
  })

  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    await post($, 'measure', {
      model: await model($),
      config: await config($),
      context: { tokens: e.context.tokens, window: e.context.window },
      rateLimits: e.rateLimits.map((r) => ({ kind: r.kind, percentUsed: r.percentUsed, resetsAt: r.resetsAt })),
      cost: e.cost ? { usd: e.cost.usd } : undefined,
    })
    return result
  })

  // Which tool runs, and since when, so the panel can tell a long build from a
  // command left waiting (5.7). The posts are not awaited: a tool call must
  // never wait on the panel, and they cannot throw.
  on('tool.call', async ($, e, next) => {
    const id = e.tool_use_id
    if (id) void post($, 'tool', { id, tool: e.tool, phase: 'start', detail: detailOf(e) })
    try {
      return await next(e)
    } finally {
      if (id) void post($, 'tool', { id, tool: e.tool, phase: 'end' })
    }
  })

  on('command.run', { command: 'lampmaster' }, async ($, e) => {
    // LampBoard cuts the question to its own limit; this only trims it.
    const question = (e.args || '').trim()
    if (!question) return { text: USAGE }
    // Claude Code prints the plugin's name before the text: no label of our own.
    return { text: await ask($, question) }
  })

  // Only what the engine would ask the person about, and only a real call: the
  // engine's allow and deny are never overturned, and a query is no question.
  // LampBoard answers `ask` at once while its switch is off.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (!verdict || verdict.decision !== 'ask' || !e.tool_use_id) return verdict
    try {
      const home = await realHome($)
      if (!home) return verdict
      // Not the token: every hook and report carries that to whatever answers
      // on the port, which while the panel is away could be anyone's listener.
      const key = (await $.fs.read(`${home}/.lampboard/check-key`)).trim()
      const port = parseInt((await $.fs.read(`${home}/.lampboard/port`)).trim(), 10)
      if (!/^[0-9a-f]{16,128}$/.test(key) || !(port >= 1024 && port < 65536)) return verdict
      const session = await $.session.id()
      const nonce = crypto.randomUUID()
      const reply = await $.http.fetch(`http://127.0.0.1:${port}/check`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-LampBoard-Nonce': nonce,
          'X-LampBoard-Proof': await hmac(key, `ask:${nonce}:${session}:${e.tool_use_id}`),
        },
        body: JSON.stringify({ v: VERSION, session, id: e.tool_use_id, tool: e.tool, detail: detailOf(e.input || {}) }),
      })
      // Only an answer signed with the key counts: a listener without it, on
      // a port the panel left, cannot say allow.
      const [decision, signature] = reply.ok ? reply.text.trim().split(' ') : []
      if (!signature || signature !== (await hmac(key, `answer:${nonce}:${decision}`))) return verdict
      if (decision === 'allow') return { decision: 'allow', reason: 'Allowed from LampBoard.' }
      if (decision === 'deny') return { decision: 'deny', reason: 'Denied from LampBoard.' }
    } catch (_) {
      // The panel is closed or restarting: the dialog, as without it.
    }
    return verdict
  })

  // Taken whether or not it is proven: a message that starts like this is never the
  // session's to read. The answer is not awaited: the delivery is not held.
  on('session.receive', async ($, e, next) => {
    const text = e.text || ''
    if (!text.startsWith('LampBoard asks without disturbing [')) return next(e)
    // Its line, but not its shape (cut, too long): taken all the same.
    const asked = ASK.exec(text)
    if (asked) void answerQuietly($, asked[1], asked[2], asked[3])
    return { consumed: 'lampboard-ask' }
  })

  // The band: nothing while nothing waits elsewhere, so the engine draws its own.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const state = bands.get(await $.session.id())
    const items = state ? state.items.slice(0, 3) : []
    if (items.length === 0 || (e.props && e.props.hasSurvey)) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    // One line whatever the width: each label gets its share of the columns.
    const columns = (e.props && e.props.bodyColumns) || 80
    const share = Math.max(12, Math.floor((columns - 14) / items.length) - 6)
    const fit = (label) => (Array.from(label).length <= share ? label : Array.from(label).slice(0, share - 1).join('') + '…')
    const children = [Text({ color: 'yellow', children: ['⚑ LampBoard · '] })]
    items.forEach((item, i) => {
      children.push(Button({
        key: `band-${i + 1}`, label: fit(`${item.title}: ${item.line}`), hotkey: String(i + 1), plain: true,
        onPress: async () => { await openInPanel($, item.session) },
      }))
      if (i < items.length - 1) children.push(Text({ dimColor: true, children: [' · '] }))
    })
    return Box({ flexDirection: 'row', children })
  })

  // `session.end` has 1.5 s in all: one short post, and no model lookup.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    const ending = bands.get(e.sessionId)
    if (ending) { clearInterval(ending.clock); bands.delete(e.sessionId) }
    await post($, 'end', { session: e.sessionId, reason: e.reason })
    return result
  })
}
