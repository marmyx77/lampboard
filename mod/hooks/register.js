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
    return { url: `${base}/mod`, token }
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

export function register(on) {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
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

  // `session.end` has 1.5 s in all: one short post, and no model lookup.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    await post($, 'end', { session: e.sessionId, reason: e.reason })
    return result
  })
}
