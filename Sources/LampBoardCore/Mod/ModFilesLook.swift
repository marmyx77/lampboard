import Foundation

extension ModFiles {

    /// `mod/hooks/look.js`, Claude Code's look (D134): the transcript drawn like
    /// the VS Code panel, where LampBoard says so.
    public static let look = #"""
// The look (D134): inside LampBoard's live view, the transcript drawn as
// close to Claude Code's VS Code panel as a terminal allows. The person's
// prompts sit in rounded boxes; each tool call is one compact row (a status
// dot, the tool, its file or command, + and - counts for an edit); an edit's
// result is a diff in a rounded frame; a todo list is a checklist; the spinner
// says what the turn is doing in one plain word; the hint under the prompt
// ends with the model and how full the context is.
//
// Off unless LampBoard says on, for this session (Settings > Clicks & keys >
// Claude Code's look: in LampBoard's windows, everywhere, or off): the panel on
// this Mac is asked `GET /mod/look` (its token, this session's id) and must
// answer `{"v":1,"on":true}`. The answer is kept five seconds per session. Any
// other answer, no panel, a late one, a surface other than the terminal: the
// engine draws its own, untouched. It reads only what the engine is about to
// draw, sends nothing but the session's id, and writes nothing.
//
// Claude Code's check follows `$` only into functions declared in the same file,
// so the panel lookup is a copy of lamps.js's (HOME only, never LAMPBOARD_HOME;
// the address must answer as LampBoard first). Every hook here has a component
// matcher: the module graph may hold one hook per event without a matcher.

const TTL = 5000
const MISSES = 3
const WAIT = 1500
const SESSION_ID = /^[A-Za-z0-9-]{8,64}$/

// Glyphs, written as escapes: the source holds ASCII only.
const DOT = '\u25CF'
const ELBOW = '\u2514 '
const MINUS = '\u2212'
const ELLIPSIS = '\u2026'
const BOX_EMPTY = '\u2610'
const BOX_DONE = '\u2611'
const ARROW = '\u25B8'
const CROSS = '\u2715'
const MIDDOT = ' \u00B7 '

// How many diff lines a result shows before saying how many it left out.
const DIFF_LINES = 24
const WRITE_LINES = 12

// Tools whose row the look draws; any other keeps the engine's row.
const DRAWN = new Set(['Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Bash', 'Grep', 'Glob', 'LS',
  'WebFetch', 'WebSearch', 'TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'Skill', 'ToolSearch'])

// The task tools draw their own checklist line; their result row says nothing more.
const TASKS = new Set(['TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList'])

// What the spinner says, by what the turn is doing.
// Whose prompts are boxed: the person's, typed here or through an attach.
const TYPED = new Set(['composer', 'bridge', 'sdk', 'unclassified'])

const DOING = { thinking: 'Thinking', requesting: 'Waiting', responding: 'Writing', 'tool-input': 'Preparing', 'tool-use': 'Working' }

// One state per session: the panel's last answer, when it came, the folder
// paths are shown against, and the tool calls drawn inside an unfolded group.
const looks = new Map()

let confirmedLook = null

function bounded(promise) {
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('late')), WAIT) })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

async function lookPanel($) {
  try {
    const home = await $.env.get('HOME')
    if (!home || !home.startsWith('/') || home === '/') return null
    const token = (await $.fs.read(`${home}/.lampboard/token`)).trim()
    const port = parseInt((await $.fs.read(`${home}/.lampboard/port`)).trim(), 10)
    if (!/^[0-9a-f]{16,128}$/.test(token) || !(port >= 1024 && port < 65536)) return null
    const base = `http://127.0.0.1:${port}`
    if (confirmedLook !== base) {
      const health = await bounded($.http.fetch(`${base}/health`))
      if (!health.ok || health.text.trim() !== 'lampboard') return null
      confirmedLook = base
    }
    return { base, token }
  } catch (_) {
    return null
  }
}

async function askLook($, session) {
  try {
    const target = await lookPanel($)
    if (!target) return false
    const reply = await bounded($.http.fetch(`${target.base}/mod/look`, {
      headers: { 'X-LampBoard-Token': target.token, 'X-LampBoard-Session': session },
    }))
    if (!reply.ok) { confirmedLook = null; return null }
    const read = JSON.parse(reply.text)
    return Boolean(read && read.v === 1 && read.on === true)
  } catch (_) {
    confirmedLook = null
    return null
  }
}

// The session's state, the panel asked at most once per TTL. The first ask is
// awaited (bounded); a stale answer is used while a fresh one is fetched, and a
// change redraws every hooked site.
async function lookState($, e) {
  if (!e || e.surface !== 'terminal') return null
  try {
    const session = await $.session.id()
    if (!SESSION_ID.test(session)) return null
    let state = looks.get(session)
    if (!state) {
      state = { on: false, at: 0, misses: 0, pending: null, cwd: '', grouped: new Set(), tasks: new Map() }
      looks.set(session, state)
    }
    if (Date.now() - state.at >= TTL && !state.pending) {
      const first = state.at === 0
      state.pending = (async () => {
        const said = await askLook($, session)
        // No answer (a panel busy for a moment, or gone) keeps the last one,
        // three times at most: a stall must not flicker the look off and on.
        state.misses = said === null ? state.misses + 1 : 0
        const on = said === null ? (state.misses < MISSES && state.on) : said
        if (on && !state.cwd) { try { state.cwd = await $.session.cwd() } catch (_) {} }
        const changed = on !== state.on
        state.on = on
        state.at = Date.now()
        state.pending = null
        // The rows drawn before the first answer are drawn again with it.
        if (changed || (first && on)) { try { $.ui.invalidate('ui.render') } catch (_) {} }
      })()
    }
    // Until the first answer every row waits for it (bounded), not just the
    // one that asked.
    if (state.at === 0 && state.pending) await state.pending
    return state.on ? state : null
  } catch (_) {
    return null
  }
}

// Called from register.js's `session.end`, which has the id and no `$` here.
export function endLook(session) {
  looks.delete(session)
}

// Text that reaches the terminal: no control, bidi or invisible characters;
// tabs and line breaks kept only where asked.
function clean(text, keepLines) {
  const bad = keepLines
    ? /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF\u061C\u180E\uFFF9-\uFFFB]|[\u{E0000}-\u{E007F}]/gu
    : /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF\u061C\u180E\uFFF9-\uFFFB]|[\u{E0000}-\u{E007F}]/gu
  return String(text == null ? '' : text).replace(bad, keepLines ? '' : ' ')
}

function cut(text, room) {
  const chars = Array.from(text)
  if (room < 2) return ''
  return chars.length <= room ? text : chars.slice(0, room - 1).join('') + ELLIPSIS
}

// A path cut from its head, so the file's name survives.
function cutPath(text, room) {
  const chars = Array.from(text)
  if (room < 2) return ''
  return chars.length <= room ? text : ELLIPSIS + chars.slice(chars.length - room + 1).join('')
}

function relative(path, cwd) {
  if (typeof path !== 'string') return ''
  if (cwd && path.startsWith(cwd + '/')) return path.slice(cwd.length + 1)
  return path
}

const count = (text) => (typeof text === 'string' && text.length ? text.replace(/\n$/, '').split('\n').length : 0)

// The + and - of an edit: from the stored patch once there, else from the input.
function changesOf(tool, input, output) {
  const patch = output && Array.isArray(output.structuredPatch) ? output.structuredPatch : null
  if (patch && patch.length) {
    let added = 0
    let removed = 0
    for (const hunk of patch) {
      for (const line of hunk.lines || []) {
        if (line.startsWith('+')) added++
        else if (line.startsWith('-')) removed++
      }
    }
    return { added, removed }
  }
  if (tool === 'Edit') return { removed: count(input.old_string), added: count(input.new_string) }
  if (tool === 'MultiEdit' && Array.isArray(input.edits)) {
    return input.edits.reduce((sum, edit) => ({
      removed: sum.removed + count(edit && edit.old_string), added: sum.added + count(edit && edit.new_string),
    }), { removed: 0, added: 0 })
  }
  if (tool === 'Write') return { removed: 0, added: count(input.content) }
  return null
}

// What a row names: the file, the command, the pattern, the address.
function targetOf(tool, input, cwd) {
  const inp = input || {}
  if (typeof inp.file_path === 'string') {
    let text = relative(inp.file_path, cwd)
    if (tool === 'Read' && (inp.offset || inp.limit)) {
      const from = Number(inp.offset) || 1
      text += inp.limit ? `:${from}-${from + Number(inp.limit) - 1}` : `:${from}`
    }
    return { text, isPath: true }
  }
  if (typeof inp.notebook_path === 'string') return { text: relative(inp.notebook_path, cwd), isPath: true }
  if (typeof inp.command === 'string') return { text: inp.command.split('\n')[0], isPath: false }
  if (typeof inp.pattern === 'string') {
    const where = typeof inp.path === 'string' ? `  in ${relative(inp.path, cwd)}` : ''
    return { text: inp.pattern + where, isPath: false }
  }
  if (typeof inp.path === 'string') return { text: relative(inp.path, cwd), isPath: true }
  for (const key of ['url', 'query', 'skill', 'description']) {
    if (typeof inp[key] === 'string') return { text: inp[key], isPath: false }
  }
  return { text: '', isPath: false }
}

// One dim line under a row: what the call came to.
function summaryOf(tool, output) {
  if (output == null) return ''
  if (typeof output === 'string') return output.split('\n')[0]
  if (tool === 'Read' && output.file) {
    const lines = output.file.numLines
    return typeof lines === 'number' ? `${lines} line${lines === 1 ? '' : 's'}` : ''
  }
  if (tool === 'Bash') {
    const out = String(output.stdout || output.stderr || '').replace(/\n+$/, '')
    if (!out) return 'no output'
    const lines = out.split('\n')
    return lines.length === 1 ? lines[0] : `${lines[0]}  (+${lines.length - 1} lines)`
  }
  if (Array.isArray(output.filenames)) return `${output.filenames.length} file${output.filenames.length === 1 ? '' : 's'}`
  if (typeof output.numFiles === 'number') return `${output.numFiles} file${output.numFiles === 1 ? '' : 's'}`
  if (Array.isArray(output.matches)) return `${output.matches.length} match${output.matches.length === 1 ? '' : 'es'}`
  return ''
}

function nameOf(tool) {
  const mcp = /^mcp__([^_]+(?:_[^_]+)*)__(.+)$/.exec(tool)
  return mcp ? `${mcp[1]}${MIDDOT}${mcp[2]}` : tool
}

function dotColor(p) {
  if (p.isInterrupted) return 'warning'
  if (p.isErrored) return 'error'
  if (p.isRunning) return 'subtle'
  return 'success'
}

// The row: a dot, the tool in bold, its target, an edit's counts.
function headerRow(t, p, cwd, columns) {
  const { Box, Text } = t
  const input = p.input || {}
  const name = clean(nameOf(String(p.tool)))
  const changes = changesOf(p.tool, input, p.output)
  const counts = changes ? `  +${changes.added} ${MINUS}${changes.removed}` : ''
  const target = targetOf(p.tool, input, cwd)
  const room = Math.max(8, columns - Array.from(name).length - Array.from(counts).length - 6)
  const shown = target.isPath ? cutPath(clean(target.text), room) : cut(clean(target.text), room)
  const children = [
    Text({ color: dotColor(p), children: [`${DOT} `] }),
    Text({ bold: true, children: [name] }),
  ]
  if (shown) children.push(Text({ color: target.isPath ? 'suggestion' : 'text', children: [`  ${shown}`] }))
  if (changes) {
    children.push(Text({ color: 'success', children: [`  +${changes.added}`] }))
    children.push(Text({ color: 'error', children: [` ${MINUS}${changes.removed}`] }))
  }
  if (p.isInterrupted) children.push(Text({ dimColor: true, children: ['  interrupted'] }))
  return Box({ flexDirection: 'row', children })
}

function summaryRow(t, text, columns) {
  const { Text } = t
  return Text({ dimColor: true, children: [`  ${ELBOW}${cut(clean(text), Math.max(8, columns - 6))}`] })
}

// TodoWrite as a checklist: done, doing, to do.
function todoCard(t, p, columns) {
  const { Box, Text } = t
  const todos = Array.isArray(p.input && p.input.todos) ? p.input.todos : []
  const done = todos.filter((x) => x && x.status === 'completed').length
  const rows = [Box({
    flexDirection: 'row',
    children: [
      Text({ color: dotColor(p), children: [`${DOT} `] }),
      Text({ bold: true, children: ['Todos'] }),
      Text({ dimColor: true, children: [`  ${done}/${todos.length} done`] }),
    ],
  })]
  const room = Math.max(8, columns - 8)
  todos.slice(0, 20).forEach((todo, i) => {
    if (!todo) return
    if (todo.status === 'completed') {
      rows.push(Text({ key: `todo-${i}`, dimColor: true, strikethrough: true, children: [`  ${BOX_DONE} ${cut(clean(todo.content), room)}`] }))
    } else if (todo.status === 'in_progress') {
      rows.push(Text({ key: `todo-${i}`, color: 'claude', bold: true, children: [`  ${ARROW} ${cut(clean(todo.activeForm || todo.content), room)}`] }))
    } else {
      rows.push(Text({ key: `todo-${i}`, children: [`  ${BOX_EMPTY} ${cut(clean(todo.content), room)}`] }))
    }
  })
  if (todos.length > 20) rows.push(Text({ dimColor: true, children: [`  +${todos.length - 20} more`] }))
  return Box({ flexDirection: 'column', children: rows })
}

// One checklist line for a task: done, doing, to do, dropped.
function taskLine(t, key, status, subject, room) {
  const { Text } = t
  const text = cut(clean(subject), room)
  if (status === 'completed') return Text({ key, dimColor: true, strikethrough: true, children: [`${BOX_DONE} ${text}`] })
  if (status === 'in_progress') return Text({ key, color: 'claude', bold: true, children: [`${ARROW} ${text}`] })
  if (status === 'deleted') return Text({ key, dimColor: true, children: [`${CROSS} ${text}`] })
  return Text({ key, children: [`${BOX_EMPTY} ${text}`] })
}

// TaskCreate, TaskUpdate, TaskList: the session's task list as the panel's
// checklist. A task's subject is learnt from its creation's result, drawn
// earlier in the same transcript; an update of one never seen says its number.
function taskCard(t, p, tasks, columns) {
  const { Box, Text } = t
  const input = p.input || {}
  const output = p.output && typeof p.output === 'object' ? p.output : {}
  const room = Math.max(8, columns - 6)
  const dot = Text({ color: dotColor(p), children: [`${DOT} `] })
  if (p.tool === 'TaskCreate') {
    if (output.task && output.task.id) tasks.set(String(output.task.id), { subject: output.task.subject || input.subject, activeForm: input.activeForm })
    return Box({ flexDirection: 'row', children: [dot, taskLine(t, 'task', 'pending', input.subject || '', room)] })
  }
  if (p.tool === 'TaskUpdate') {
    const id = String(input.taskId || '')
    const known = tasks.get(id) || {}
    if (input.subject) tasks.set(id, { ...known, subject: input.subject })
    const subject = input.subject || known.subject || `task ${id}`
    const status = input.status || 'pending'
    const shown = status === 'in_progress' ? (input.activeForm || known.activeForm || subject) : subject
    if (!input.status) return Box({ flexDirection: 'row', children: [dot, Text({ dimColor: true, children: [cut(`updated ${clean(subject)}`, room)] })] })
    return Box({ flexDirection: 'row', children: [dot, taskLine(t, 'task', status, shown, room)] })
  }
  const list = Array.isArray(output.tasks) ? output.tasks : []
  const done = list.filter((x) => x && x.status === 'completed').length
  const rows = [Box({ flexDirection: 'row', children: [dot, Text({ bold: true, children: ['Tasks'] }), Text({ dimColor: true, children: [`  ${done}/${list.length} done`] })] })]
  list.slice(0, 20).forEach((task, i) => {
    if (task) rows.push(Box({ key: `task-${i}`, paddingLeft: 2, children: [taskLine(t, `line-${i}`, task.status, task.subject, room - 2)] }))
  })
  return Box({ flexDirection: 'column', children: rows })
}

// Hunks as a unified diff, cut to `most` lines; a cut hunk gets its header
// counted again from what is kept, so it still parses.
function diffSource(patch, most) {
  const parts = []
  let used = 0
  let left = 0
  for (const hunk of patch) {
    const lines = (hunk.lines || []).map((line) => clean(line, true).replace(/\n/g, ''))
    if (used >= most) { left += lines.length; continue }
    const kept = lines.slice(0, most - used)
    left += lines.length - kept.length
    used += kept.length
    const oldLines = kept.filter((l) => !l.startsWith('+') && !l.startsWith('\\')).length
    const newLines = kept.filter((l) => !l.startsWith('-') && !l.startsWith('\\')).length
    parts.push(`@@ -${hunk.oldStart},${oldLines} +${hunk.newStart},${newLines} @@\n${kept.join('\n')}`)
  }
  return { source: parts.join('\n'), left }
}

function diffCard(t, source, path, left) {
  const { Box, Text, Code } = t
  const children = [Code({ source, format: 'diff', path, wrap: 'truncate-end' })]
  if (left > 0) children.push(Text({ dimColor: true, children: [`${ELLIPSIS} ${left} more line${left === 1 ? '' : 's'}`] }))
  return Box({ flexDirection: 'column', marginLeft: 2, borderStyle: 'round', borderColor: 'subtle', paddingX: 1, children })
}

// An edit's or a write's result: its diff, framed, as the panel draws one.
function editResult(t, tool, output) {
  if (!output || typeof output !== 'object') return null
  const path = typeof output.filePath === 'string' ? output.filePath : undefined
  const patch = Array.isArray(output.structuredPatch) ? output.structuredPatch : []
  if (patch.length) {
    const { source, left } = diffSource(patch, tool === 'Write' ? WRITE_LINES : DIFF_LINES)
    return source ? diffCard(t, source, path, left) : null
  }
  if (tool === 'Write' && typeof output.content === 'string') {
    const lines = output.content.replace(/\n$/, '').split('\n')
    const { source, left } = diffSource([{ oldStart: 0, newStart: 1, lines: lines.map((l) => `+${l}`) }], WRITE_LINES)
    return diffCard(t, source, path, left)
  }
  return null
}

function modelName(model) {
  const bare = String(model || '').replace(/\[.*\]$/, '').replace(/^claude-/, '').replace(/-\d{8}$/, '')
  const m = /^([a-z]+)-(\d+)(?:-(\d+))?$/.exec(bare)
  if (m) return `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2]}${m[3] ? '.' + m[3] : ''}`
  return bare ? bare[0].toUpperCase() + bare.slice(1) : ''
}

function seconds(ms) {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

export function registerLook(on) {
  // The person's prompt in a rounded box, as the panel's bubble; other user
  // rows (notifications, peers) and the ctrl+o transcript keep the engine's.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    try {
      const p = e.props || {}
      if (p.isExpanded || (p.origin && !TYPED.has(p.origin.kind)) || p.task || p.from) return next(e)
      const state = await lookState($, e)
      if (!state) return next(e)
      const text = clean(p.text, true).replace(/\s+$/, '')
      if (!text) return next(e)
      const { Box, Text } = $.ui.resolve(e)
      return Box({
        flexDirection: 'row',
        marginTop: 1,
        children: [Box({ borderStyle: 'round', borderColor: 'subtle', paddingX: 1, flexShrink: 1, children: [Text({ children: [text] })] })],
      })
    } catch (_) {
      return next(e)
    }
  })

  // A run of reads and searches unfolds: each call is its own row, as in the
  // panel, and the rows it unfolds into are remembered for their summaries.
  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    try {
      const state = await lookState($, e)
      if (!state) return next(e)
      for (const call of (e.props && e.props.calls) || []) {
        if (call && call.tool_use_id) state.grouped.add(call.tool_use_id)
      }
      if (e.props.isExpanded) return next(e)
      return next({ ...e, props: { ...e.props, isExpanded: true } })
    } catch (_) {
      return next(e)
    }
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    try {
      const p = e.props || {}
      if (!DRAWN.has(String(p.tool))) return next(e)
      const state = await lookState($, e)
      if (!state) return next(e)
      const t = $.ui.resolve(e)
      const columns = (e.viewport && e.viewport.columns) || 80
      // A standalone row stands a line apart, as the engine's does; the rows of
      // an unfolded group sit together and carry their own result.
      const grouped = state.grouped.has(p.tool_use_id)
      const rows = []
      if (p.tool === 'TodoWrite') rows.push(todoCard(t, p, columns))
      else if (TASKS.has(p.tool)) rows.push(taskCard(t, p, state.tasks, columns))
      else rows.push(headerRow(t, p, state.cwd, columns))
      if (p.isErrored && !p.isInterrupted) {
        // The engine draws an errored call's text inside its own row, and raises
        // no result site for it: the row says it, in the error colour.
        const said = typeof p.output === 'string' ? p.output : summaryOf(p.tool, p.output)
        const lines = clean(said, true).replace(/<\/?tool_use_error>/g, '').trim().split('\n').filter(Boolean)
        lines.slice(0, 3).forEach((line, i) => rows.push(t.Text({
          key: `error-${i}`, color: 'error', children: [`  ${i === 0 ? ELBOW : '  '}${cut(line, Math.max(8, columns - 6))}`],
        })))
      } else if (grouped && !p.isRunning && !TASKS.has(p.tool)) {
        const summary = summaryOf(p.tool, p.output)
        if (summary) rows.push(summaryRow(t, summary, columns))
      }
      return t.Box({ flexDirection: 'column', marginTop: grouped ? 0 : 1, children: rows })
    } catch (_) {
      return next(e)
    }
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    try {
      const p = e.props || {}
      if (p.isErrored || !DRAWN.has(String(p.tool)) || p.tool === 'Bash') return next(e)
      const state = await lookState($, e)
      if (!state) return next(e)
      const t = $.ui.resolve(e)
      const columns = (e.viewport && e.viewport.columns) || 80
      if (TASKS.has(p.tool)) return t.Box({ flexDirection: 'column', children: [] })
      if (p.tool === 'Edit' || p.tool === 'MultiEdit' || p.tool === 'Write') {
        return editResult(t, p.tool, p.output) || next(e)
      }
      const summary = summaryOf(p.tool, p.output)
      return summary ? summaryRow(t, summary, columns) : next(e)
    } catch (_) {
      return next(e)
    }
  })

  // A calmer spinner: one plain word for what the turn does; the engine keeps
  // its glyph, the elapsed time and the tokens.
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    try {
      const p = e.props || {}
      if (p.message) return next(e)
      const state = await lookState($, e)
      if (!state) return next(e)
      return next({ ...e, props: { ...p, word: DOING[p.mode] || 'Working', suffix: ELLIPSIS } })
    } catch (_) {
      return next(e)
    }
  })

  // The line that closes a turn, quiet: how long it took, dim.
  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    try {
      const state = await lookState($, e)
      if (!state) return next(e)
      const { Text } = $.ui.resolve(e)
      return Text({ dimColor: true, children: [`  ${ELBOW}done in ${seconds(e.props.durationMs || 0)}`] })
    } catch (_) {
      return next(e)
    }
  })

  // The panel's footer: the model and the context's fill, after the engine's
  // own hint, whose pills stay live.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    try {
      const state = await lookState($, e)
      if (!state) return next(e)
      const parts = []
      try { parts.push(modelName(await $.session.model())) } catch (_) {}
      try {
        const usage = await $.session.usage()
        const percent = usage && usage.context ? usage.context.percent : undefined
        if (typeof percent === 'number') parts.push(`${percent}% context`)
      } catch (_) {}
      const tail = parts.filter(Boolean).join(MIDDOT)
      return tail ? next({ ...e, props: { ...e.props, tail } }) : next(e)
    } catch (_) {
      return next(e)
    }
  })
}
"""#
}
