// LampBoard's companion mod: tells the LampBoard panel on this Mac what only
// the session knows — its context as Claude Code counts it, what it has cost,
// the account's rate-limit windows, where it draws and why it ended.
//
// It reads nothing of the conversation — of a running tool only its name and
// the first line of its shell command or its file path, to say which one a
// stuck session is on; the panel masks what looks like a secret — writes
// nothing, runs nothing, and
// talks to one address: 127.0.0.1, on the port the panel wrote, with the token
// the panel wrote, both under ~/.lampboard (or $LAMPBOARD_HOME/.lampboard).
// When the panel is not there it does nothing, silently: a session must never
// wait on, or hear about, a dashboard.
//
// One exception, asked for by the person: `/lampmaster <question>` sends the
// question they typed, and the session's folder, to the same address, and
// prints LampMaster's answer (D71).
//
// The colours of a row still come from LampBoard's hooks (decision D65); this
// adds only figures. Wire format: version 1 of LampBoardCore/Mod/ModReport.swift.

const VERSION = 1

// A project's own settings can set environment variables for its sessions, so
// a cloned repository could point LAMPBOARD_HOME at itself and ship a port of
// its choosing. Hence: absolute homes only, no privileged ports, and the
// address must answer as LampBoard before it is sent anything.
let confirmed = null

async function panel($) {
  try {
    const override = await $.env.get('LAMPBOARD_HOME')
    const home = override && override.trim() ? override.trim() : await $.env.get('HOME')
    if (!home || !home.startsWith('/')) return null
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
    await post($, 'start', { surface: e.surface, interactive: e.isInteractive, model: await model($) })
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

  // `session.end` has 1.5 s in all: one short post, and no model lookup.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    await post($, 'end', { session: e.sessionId, reason: e.reason })
    return result
  })
}
