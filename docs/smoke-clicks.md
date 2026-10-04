# Live clicks, last checked

Written by `Scripts/smoke-clicks.sh`. Not a gate: it needs a screen, an
unlocked session and other people's applications running, so it cannot be a
condition for merging. It is the record that the README's `live` column
rests on.

- **When:** 2026-08-31 13:23
- **Build:** 0.2.2, signed by Developer ID Application: Marco Armellino (33Z4MPR4FF)
- **Mode:** live, windows really raised

| Slot | Row | Should lead to | Result | Window |
|---|---|---|---|---|
| 2 | Events app | an editor window | raised | status? — eventsapp — Claude Minimal |
| 4 | acme-site | an editor window | raised | review the project — acme-site — Claude Minimal |
| 5 | Virgilio | an editor window | raised | Progetto unificato in cl… — marmyx-virgilio — Claude Minimal |
| 6 | Clawd Light X | the ChatGPT app | raised | ChatGPT |
| 7 | AI literacy | an editor window | raised | Documentazione progetto … — ai-act-literacy — Claude Minimal |

**Not exercised**, because no session of that kind was running:

- a Remote-SSH window
- the Claude desktop app
- the terminal holding its tab

**Out of reach of this script**, because they sit past the ninth row and
`open` addresses slots. The panel's own click reaches them; nothing on the
command line does:

- Exit — an editor window
- acme-os-platform — an editor window
- turing — an editor window

Anything named above is something this run says nothing about.
