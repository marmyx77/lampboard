import Foundation

extension ModFiles {

    /// `mod/hooks/lamps.js`, the lamps pane of `/lamps` (D131): a file of its
    /// own in the mod, and so here, beside `register`, rather than inside it.
    public static let lamps = #"""
// The lamps (D131): every session the LampBoard panel on this Mac shows, the
// ones that want something first, in a pane beside the conversation. Opened by
// /lamps and never by itself: a pane that opens unasked takes the width of
// somebody's work. It reads the panel's own `/sessions`, with the panel's token,
// and a row's button raises that session the way a click on its lamp does.
// `/lamps` itself is registered in register.js's `session.start`: the engine
// takes one hook per event, and follows `$` into no imported function.

const PANE = 'lampboard-lamps'
const EVERY = 3000
const WAIT = 2000
const MOST = 30

// The glossary of 1.1 (D128) and the panel's own colours.
const WORDS = { awaiting: 'needs you', failed: 'stopped', ready: 'done', working: 'working', waiting: 'paused', idle: 'resting' }
const COLOR = { awaiting: '#ff7319', failed: '#d93d3d', ready: '#33d96b', working: '#fabf29', waiting: '#6ba8fa', idle: '#9e9e9e' }
const ORDER = { awaiting: 0, failed: 1, ready: 2, working: 3, waiting: 4, idle: 5 }
// The rule the panel holds a session id to (`ModReport.isSessionId`).
const SESSION_ID = /^[A-Za-z0-9-]{8,64}$/

// One state per session: one hooks worker serves every session of the process,
// and a pane, its rows and its clock belong to the session that opened it.
const panes = new Map()

// The panel, found the way register.js finds it, and copied rather than shared:
// Claude Code's check follows `$` only into functions declared in the same file,
// and refuses a module that hands `$` to an imported one. HOME alone, never
// LAMPBOARD_HOME, which a cloned project's settings could point anywhere; and the
// address must answer as LampBoard before it is asked anything.
let confirmedLampBoard = null

// No call to the panel waits longer than this: a stuck panel must not hold a
// command or pile up refreshes.
function bounded(promise) {
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('late')), WAIT) })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

async function lampBoard($) {
  try {
    const home = await $.env.get('HOME')
    if (!home || !home.startsWith('/') || home === '/') return null
    const token = (await $.fs.read(`${home}/.lampboard/token`)).trim()
    const port = parseInt((await $.fs.read(`${home}/.lampboard/port`)).trim(), 10)
    if (!/^[0-9a-f]{16,128}$/.test(token) || !(port >= 1024 && port < 65536)) return null
    const base = `http://127.0.0.1:${port}`
    if (confirmedLampBoard !== base) {
      const health = await bounded($.http.fetch(`${base}/health`))
      if (!health.ok || health.text.trim() !== 'lampboard') return null
      confirmedLampBoard = base
    }
    return { base, token }
  } catch (_) {
    return null
  }
}

async function raise($, session) {
  try {
    const target = await lampBoard($)
    if (!target) { $.ui.toast('LampBoard is not answering.'); return }
    const reply = await bounded($.http.fetch(`${target.base}/mod/band/open`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-LampBoard-Token': target.token },
      body: JSON.stringify({ session }),
    }))
    if (!reply.ok) $.ui.toast('LampBoard could not bring that session forward.')
  } catch (_) {
    $.ui.toast('LampBoard is not answering.')
  }
}

// What a session calls itself reaches a terminal: one line, no control, format,
// bidi or invisible characters (a title can come from a cloned repository), cut.
function clean(text) {
  const flat = String(text).replace(/[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]|[\u{E0000}-\u{E007F}]/gu, ' ')
  return Array.from(flat).slice(0, 80).join('').trim()
}

async function refresh($, session) {
  const pane = panes.get(session)
  if (!pane || pane.busy) return
  pane.busy = true
  let text = ''
  try {
    const target = await lampBoard($)
    if (target) {
      const reply = await bounded($.http.fetch(`${target.base}/sessions`, { headers: { 'X-LampBoard-Token': target.token } }))
      if (reply.ok) text = reply.text
    }
  } catch (_) {
    text = ''
  } finally {
    pane.busy = false
  }
  if (text === pane.text) return
  pane.text = text
  pane.rows = []
  try {
    const read = text ? JSON.parse(text) : { sessions: [] }
    const seen = new Set()
    pane.rows = (Array.isArray(read.sessions) ? read.sessions : [])
      .filter((s) => s && typeof s.id === 'string' && SESSION_ID.test(s.id) && WORDS[s.status] && !seen.has(s.id) && seen.add(s.id))
      .map((s) => ({ id: s.id, status: s.status, name: clean(s.title || s.workspace || s.id) || s.id }))
      .sort((a, b) => ORDER[a.status] - ORDER[b.status] || a.name.localeCompare(b.name))
      .slice(0, MOST)
  } catch (_) {
    pane.rows = []
  }
  $.ui.invalidate('ui.render')
}

// Called from register.js's `session.end` (which has the id and takes no `$`
// here): a pane's clock does not outlive its session.
export function endLamps(session) {
  const pane = panes.get(session)
  if (pane && pane.clock) clearInterval(pane.clock)
  panes.delete(session)
}

export function registerLamps(on) {
  on('command.run', { command: 'lamps' }, async ($) => {
    const session = await $.session.id()
    try {
      await $.ui.open({ id: PANE, title: 'LampBoard' })
    } catch (_) {
      return { text: 'This layout has no room for a pane: run Claude Code full screen, as a background session always is.' }
    }
    const pane = panes.get(session) || { text: null, rows: [], clock: null, busy: false }
    panes.set(session, pane)
    if (!pane.clock) pane.clock = setInterval(() => { void refresh($, session) }, EVERY)
    void refresh($, session)
    return { text: 'The lamps are beside the conversation.' }
  })

  // Nobody looks at a closed pane: the panel is not asked again until it opens.
  on('ui.close', async ($, e, next) => {
    if (e.id === PANE) {
      try {
        const pane = panes.get(await $.session.id())
        if (pane && pane.clock) { clearInterval(pane.clock); pane.clock = null }
      } catch (_) {}
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const pane = panes.get(await $.session.id())
    if (!pane || pane.text === null) return Text({ dimColor: true, children: ['Asking LampBoard…'] })
    if (pane.rows.length === 0) return Text({ dimColor: true, children: ['No lamps: LampBoard is closed, or quiet.'] })
    const columns = (e.props && e.props.bodyColumns) || 40
    const room = Math.max(1, ((e.viewport && e.viewport.rows) || 24) - 3)
    // The dot, a hotkey's `1: `, a space and the longest word ("needs you").
    const width = Math.max(8, columns - 17)
    const name = (row) => (Array.from(row.name).length <= width ? row.name : Array.from(row.name).slice(0, width - 1).join('') + '…')
    const shown = pane.rows.slice(0, room)
    const children = shown.map((row, i) => Box({
      key: `lamp-${row.id}`,
      flexDirection: 'row',
      children: [
        Text({ color: COLOR[row.status], children: [row.status === 'idle' ? '○ ' : '● '] }),
        Button({
          key: `open-${row.id}`, label: name(row), plain: true,
          ...(i < 9 ? { hotkey: String(i + 1) } : {}),
          onPress: async () => { await raise($, row.id) },
        }),
        Text({ dimColor: true, children: [` ${WORDS[row.status]}`] }),
      ],
    }))
    if (pane.rows.length > shown.length) {
      children.push(Text({ key: 'more', dimColor: true, children: [`+${pane.rows.length - shown.length} more`] }))
    }
    return Box({ flexDirection: 'column', children })
  })
}
"""#
}
