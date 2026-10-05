import Foundation

/// The companion mod's files, as the app writes them out to install it.
///
/// The app carries the mod rather than pointing Claude Code at GitHub: the mod
/// installed is then the one this version of the panel reads, word for word,
/// with no network and on a node as on the Mac (D66). The same files sit in the
/// repository under `mod/` and `.claude-plugin/`, which makes the repository a
/// marketplace too; `ModFilesSuite` holds the two copies to the same bytes.
public enum ModFiles {

    /// Bumped with any change to the files: the panel refreshes an installed
    /// mod whose version differs.
    public static let version = "1.11.0"

    /// Path inside the marketplace folder → content, each ending in a newline
    /// as the files in the repository do.
    public static var all: [(path: String, content: String)] {
        [
            (".claude-plugin/marketplace.json", marketplace),
            ("mod/.claude-plugin/plugin.json", plugin),
            ("mod/hooks/hooks.json", hooks),
            ("mod/hooks/register.js", register),
        ].map { ($0.0, $0.1 + "\n") }
    }

    public static let marketplace = #"""
{
  "name": "lampboard",
  "description": "LampBoard's own plugins, installed by the LampBoard app.",
  "owner": {
    "name": "LampBoard"
  },
  "plugins": [
    {
      "name": "lampboard",
      "source": "./mod",
      "description": "LampBoard's companion mod: context, cost and rate limits of each session, for the LampBoard panel."
    }
  ]
}
"""#

    public static let plugin = #"""
{
  "name": "lampboard",
  "version": "1.11.0",
  "description": "LampBoard's companion: tells the LampBoard panel on this Mac each session's context, cost and rate limits, asks LampMaster with /lampmaster, writes a handoff for another session with /handoff, answers the panel's side questions without a turn, hands each session the decisions pinned for its repository, and runs a session on the model the panel lowered it to until the window resets. Talks only to 127.0.0.1.",
  "author": { "name": "LampBoard" },
  "homepage": "https://github.com/marmyx77/lampboard",
  "license": "MIT"
}
"""#

    public static let hooks = #"""
{ "modules": ["./register.js"] }
"""#

    public static let register = #"""
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
// And a question Claude asks the person (D86), with the same switch: one
// question, one choice, two to four options, put to the panel first like a
// permission and answered with the option the person picked there; any other,
// or one unanswered in 55 seconds, gets the session's own dialog.
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
// And the decision board (D105): what the person pinned in LampBoard for this
// session's repository, handed to the model with the next prompt whenever it
// has changed, as context the person does not see — asked with the permission
// key and taken only signed with it, because these words enter the
// conversation. Nothing pinned, or no panel, and the prompt goes as typed.
//
// And the governor (G3): a session the person lowered one model in the panel,
// until the window resets, runs on that model — asked at the start of each turn,
// with the permission key, and taken only signed with it. Nothing lowered, no
// panel, or no signature: the session's own model, untouched.
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

// How many lines an edit or a write touches (D87), counted from the call's own
// input: numbers only leave the session, never the text.
function linesOf(tool, input) {
  // A final newline ends the last line; it does not start another.
  const count = (text) => (typeof text === 'string' && text.length ? text.replace(/\n$/, '').split('\n').length : 0)
  if (tool === 'Edit') return { removed: count(input.old_string), added: count(input.new_string) }
  if (tool === 'MultiEdit' && Array.isArray(input.edits)) {
    return input.edits.reduce((sum, edit) => ({
      removed: sum.removed + count(edit && edit.old_string), added: sum.added + count(edit && edit.new_string),
    }), { removed: 0, added: 0 })
  }
  if (tool === 'Write') return { removed: 0, added: count(input.content) }
  return undefined
}

// Whether a command goes on past the one line the card shows (D87): its
// second line or its 121st character is not read there, so the card says so.
function goesOn(input) {
  const command = typeof input.command === 'string' ? input.command.replace(/\n+$/, '') : ''
  return command.includes('\n') || Array.from(command).length > 120
}

// A question Claude asks (D86): put to the panel only in a shape a card can
// show — one question, one choice, two to four options — proven with the
// permission key like a permission, and answered only with a signed choice.
async function askPanel($, e) {
  try {
    const questions = e.questions || (e.input && e.input.questions) || []
    if (questions.length !== 1) return null
    const q = questions[0]
    const options = Array.isArray(q.options) ? q.options.map((o) => o && o.label) : []
    if (q.multiSelect || (q.kind && q.kind !== 'choice') || options.length < 2 || options.length > 4) return null
    if (!options.every((label) => typeof label === 'string' && label)) return null
    const home = await realHome($)
    if (!home) return null
    const key = (await $.fs.read(`${home}/.lampboard/check-key`)).trim()
    const port = parseInt((await $.fs.read(`${home}/.lampboard/port`)).trim(), 10)
    if (!/^[0-9a-f]{16,128}$/.test(key) || !(port >= 1024 && port < 65536)) return null
    const session = await $.session.id()
    const nonce = crypto.randomUUID()
    const reply = await $.http.fetch(`http://127.0.0.1:${port}/question`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-LampBoard-Nonce': nonce,
        'X-LampBoard-Proof': await hmac(key, `question:${nonce}:${session}:${e.tool_use_id}`),
      },
      body: JSON.stringify({ v: VERSION, session, id: e.tool_use_id, question: q.question, header: q.header, options }),
    })
    const [word, index, signature] = reply.ok ? reply.text.trim().split(' ') : []
    if (word !== 'choose' || !/^[0-3]$/.test(index || '')) return null
    if (!same(signature, await hmac(key, `choose:${nonce}:${index}`))) return null
    const label = options[Number(index)]
    if (label === undefined) return null
    return { result: { questions, answers: { [q.question]: label } } }
  } catch (_) {
    return null
  }
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

// The decision board (D105): the version each session was last handed, so a
// board reaches a session once per change and not with every prompt. Recorded
// only once the prompt has entered with it, and forgotten when the session
// compacts or starts again, which can drop what it was handed.
const boards = new Map()
const BOARD_WAIT = 1500

async function boardContext($) {
  try {
    const target = await panel($)
    const home = await realHome($)
    if (!target || !home) return null
    const key = (await $.fs.read(`${home}/.lampboard/check-key`)).trim()
    if (!/^[0-9a-f]{16,128}$/.test(key)) return null
    const session = await $.session.id()
    const nonce = crypto.randomUUID()
    // A prompt never waits long on a dashboard: past this it goes as typed.
    let timer
    const late = new Promise((resolve) => { timer = setTimeout(() => resolve(null), BOARD_WAIT) })
    const reply = await Promise.race([late, $.http.fetch(`${target.base}/mod/decisions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-LampBoard-Token': target.token,
        'X-LampBoard-Nonce': nonce,
        'X-LampBoard-Proof': await hmac(key, `board:${nonce}:${session}`),
      },
      body: JSON.stringify({ v: VERSION, session }),
    })])
    clearTimeout(timer)
    const cut = reply && reply.ok ? reply.text.indexOf('\n') : -1
    if (cut < 0) return null
    const [word, version, signature] = reply.text.slice(0, cut).split(' ')
    const text = reply.text.slice(cut + 1)
    if (word !== 'board' || !/^([0-9a-f]{16}|-)$/.test(version || '')) return null
    if (!same(signature, await hmac(key, `pinned:${nonce}:${version}:${text}`))) return null
    // Never told and nothing pinned, or told this very version: nothing new.
    if (version === (boards.get(session) || '-')) return null
    return { session, version, text }
  } catch (_) {
    return null
  }
}

// The governor (G3): the answer each session is waiting for at its turn's start,
// asked before the turn goes on so that its first step already has it.
const governed = new Map()

async function governorModel($) {
  try {
    const target = await panel($)
    const home = await realHome($)
    if (!target || !home) return null
    const key = (await $.fs.read(`${home}/.lampboard/check-key`)).trim()
    if (!/^[0-9a-f]{16,128}$/.test(key)) return null
    const session = await $.session.id()
    const nonce = crypto.randomUUID()
    let timer
    const late = new Promise((resolve) => { timer = setTimeout(() => resolve(null), BOARD_WAIT) })
    const reply = await Promise.race([late, $.http.fetch(`${target.base}/mod/governor`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-LampBoard-Token': target.token,
        'X-LampBoard-Nonce': nonce,
        'X-LampBoard-Proof': await hmac(key, `governor:${nonce}:${session}`),
      },
      body: JSON.stringify({ v: VERSION, session }),
    })])
    clearTimeout(timer)
    const [word, chosen, signature] = reply && reply.ok ? reply.text.trim().split(' ') : []
    if (word !== 'model' || !/^(claude-[a-z0-9.-]{1,60}|-)$/.test(chosen || '')) return null
    if (!same(signature, await hmac(key, `governed:${nonce}:${chosen}`))) return null
    return chosen === '-' ? null : chosen
  } catch (_) {
    return null
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

// The baton (5.4, D91): this session writes what another needs — a fork over
// its own conversation, no turn — and LampBoard puts it in that session's
// composer, unsent. The question is LampBoardCore's Handoff.question, word for word.
const HANDOFF_USAGE = 'Write a handoff for another session: /handoff <session name>'
const HANDOFF_QUESTION = 'Another Claude Code session is taking over from you, or depends on your work. Write the handoff it will read before it starts: what you understood, what you decided and why, what is left to do, and the files you touched. Plain text, at most thirty lines, no secret values.'

async function handOver($, to) {
  if (!(await panel($))) return 'LampBoard is not running on this Mac: there is nowhere to hand over to.'
  try {
    // Proven with the permission key, never the token alone (D80): the token
    // travels with every hook, and would let anyone write in a composer.
    const home = await realHome($)
    const key = home ? (await $.fs.read(`${home}/.lampboard/check-key`)).trim() : ''
    if (!/^[0-9a-f]{16,128}$/.test(key)) return 'LampBoard has no key to prove the handoff with: update the panel.'
    const reply = await $.model.fork({ prompt: HANDOFF_QUESTION })
    if (!reply.isAnswered || !reply.text || !reply.text.trim()) return `No handoff written (${reply.reason || 'no answer'}).`
    // Words of the conversation: the port is asked again whether it is LampBoard.
    confirmed = null
    const target = await panel($)
    if (!target) return 'LampBoard went away while the handoff was written.'
    const text = Array.from(reply.text.trim()).slice(0, MAX_ANSWER).join('')
    const session = await $.session.id()
    const nonce = crypto.randomUUID()
    const answer = await $.http.fetch(`${target.base}/handoff`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-LampBoard-Token': target.token,
        'X-LampBoard-Nonce': nonce,
        'X-LampBoard-Proof': await hmac(key, `handoff:${nonce}:${session}:${to}:${text}`),
      },
      body: JSON.stringify({ v: VERSION, session, to, text }),
    })
    if (!answer.ok) return `LampBoard did not take the handoff (HTTP ${answer.status}).`
    // Shown to the person: no control, no direction-changing character.
    return Array.from(answer.text.trim().replace(/[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069]/g, ''))
      .slice(0, 400).join('')
  } catch (_) {
    return 'The handoff could not be written.'
  }
}

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
    try { boards.delete(await $.session.id()) } catch (_) {}
    try {
      // Immediate: a question about the other sessions does not depend on this
      // one's turn, and is most useful while that turn is still running.
      await $.command.register({ name: 'lampmaster', description: 'Ask LampMaster what your other sessions know', argumentHint: '<question>', immediate: true })
      await $.command.register({ name: 'handoff', description: 'Write a handoff for another session; it waits in its LampBoard composer', argumentHint: '<session>', immediate: true })
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
    // A question answered from the panel never reaches the dialog.
    if (e.tool === 'AskUserQuestion' && e.tool_use_id) {
      const answered = await askPanel($, e)
      if (answered) return answered
    }
    const id = e.tool_use_id
    if (id) void post($, 'tool', { id, tool: e.tool, phase: 'start', detail: detailOf(e) })
    try {
      return await next(e)
    } finally {
      if (id) void post($, 'tool', { id, tool: e.tool, phase: 'end' })
    }
  })

  on('command.run', { command: 'handoff' }, async ($, e) => {
    const to = (e.args || '').trim().replace(/^@/, '')
    if (!to || Array.from(to).length > 80) return { text: HANDOFF_USAGE }
    return { text: await handOver($, to) }
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
        body: JSON.stringify({
          v: VERSION, session, id: e.tool_use_id, tool: e.tool, detail: detailOf(e.input || {}),
          lines: linesOf(e.tool, e.input || {}), more: goesOn(e.input || {}),
        }),
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

  // Context on the way down, before the prompt enters: once it has, a block
  // attached is not read (the API's word).
  on('prompt.submit', async ($, e, next) => {
    const board = await boardContext($)
    const block = board && board.text
    const result = await next(block ? { ...e, context: [...(e.context || []), block] } : e)
    if (board && !result.drop) boards.set(board.session, board.version)
    return result
  })

  // The governor (G3): asked once a turn, applied to every step of it.
  on('turn.start', async ($, e, next) => {
    try { governed.set(await $.session.id(), governorModel($)) } catch (_) {}
    return next(e)
  })

  // A streaming event: its hook is an async generator, or it is dropped unseen.
  on('turn.step', async function* ($, e, next) {
    let lowered
    try { lowered = await governed.get(await $.session.id()) } catch (_) {}
    return yield* next(lowered && !e.agentId ? { ...e, model: lowered } : e)
  })

  // A compacted or restarted conversation may have lost what it was handed.
  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId) { try { boards.delete(await $.session.id()) } catch (_) {} }
    return result
  })

  // `session.end` has 1.5 s in all: one short post, and no model lookup.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    const ending = bands.get(e.sessionId)
    if (ending) { clearInterval(ending.clock); bands.delete(e.sessionId) }
    boards.delete(e.sessionId)
    governed.delete(e.sessionId)
    await post($, 'end', { session: e.sessionId, reason: e.reason })
    return result
  })
}
"""#
}
