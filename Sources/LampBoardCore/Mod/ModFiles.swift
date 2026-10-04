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
    public static let version = "1.1.0"

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
  "version": "1.1.0",
  "description": "LampBoard's companion: tells the LampBoard panel on this Mac each session's context, cost and rate limits. Talks only to 127.0.0.1.",
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
// It reads nothing of the conversation, writes nothing, runs nothing, and
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

  // `session.end` has 1.5 s in all: one short post, and no model lookup.
  on('session.end', async ($, e, next) => {
    const result = await next(e)
    await post($, 'end', { session: e.sessionId, reason: e.reason })
    return result
  })
}
"""#
}
