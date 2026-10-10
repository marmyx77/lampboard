# Clarc's chat kit, in part

The live view's chat (D147) draws a session's conversation with message views
from Clarc, a native Mac client for Claude Code, and reads the transcript with
its line decoder. Only those parts were taken.

| | |
|---|---|
| Upstream | https://github.com/ttnear/Clarc |
| Commit | `ba4c0d9f43165bb755f9d168ebfeb60fab19712d`, 20 August 2026 |
| Licence | Apache License 2.0, unmodified, in [LICENSE](LICENSE) |

## Why these parts, and why vendored

Clarc and the other Claude Code clients start a `claude` of their own and draw
it. LampBoard's chat draws a session that is already running somewhere else,
in tmux on another machine, say, reading its transcript and writing to it through its terminal.
What Clarc had that this needed, and had already shaken out on real
transcripts, was the drawing of a message and the reading of a transcript line.
They are vendored as SwiftTerm is, for the same reasons: an offline build, and
the code that ships sitting where a review reads it.

## What was taken

From `Packages/Sources/ClarcChatKit`: `MessageBubble`, `MarkdownView`,
`ToolResultView`, `ThinkingBlockView`, `BubbleStyle`, `TypingDotsView`.

From `Packages/Sources/ClarcCore`:
- the messages: `ChatMessage`, `JSONValue`, `Attachment`;
- reading a transcript: `CLISessionRecord`, `CLILineToBlocksMapper`, and
  `CLIMetaEnvelope` taken out of `CLISessionStore`;
- the look and its helpers: `ClaudeTheme`, `AppTheme`, `SyntaxHighlighter`,
  `ClipboardHelper`, `DurationFormatting`.

Left out: the rest of the app and its session store, the diff view and its
`git` helper (a path from a transcript is never handed to `git`), the message list (it needs
macOS 15; LampBoard runs from 14), the input bar, slash commands, the
attachment and web previews, and the localisations.

## Local changes

Every file carries a note at its top saying it was modified. In all of them, the
`import ClarcCore` line went (one module here) and `bundle: .module` went from
the localised strings (no resources here: the strings read in English). Beyond
that, each change is marked in the source with `Vendored patch <n>`:

1. `LampBoardSupport.swift`, new. LampBoard's stand-ins for what the views
   reach for in Clarc's app: `WindowState` and `ChatBridge` with only the
   members these views use, `InteractiveTerminalState`'s tool name, and Clarc's
   own `ToolCategory`, `PreviewFile` and line decoder (its ISO 8601 dates), copied
   whole. Forking and editing a message do nothing here.
2. `ToolResultView.swift`: a default argument read a main-actor colour, which
   this module's settings refuse; it is optional now and read in the body.
3. `MessageBubble.swift`: a question (`AskUserQuestion`) is drawn as a tool row.
   Its answer is given in the session's own dialog.
4. `MessageBubble.swift`: public, with a public initialiser, for LampBoard's chat.
5. `ClaudeTheme.swift`, `AppTheme.swift` and the views: messages are set in a
   family LampBoard chooses (`ThemeStore.messageFontFamily`, VS Code's chat font
   when this Mac has it), the system's otherwise. Monospaced text is unchanged.

The target builds in Swift 5 language mode with the main actor as its default
isolation, as upstream is written, and with its warnings suppressed: upstream's
warnings are upstream's.

## Updating

Copy the same files from a newer commit, put back the five patches and the
top-of-file notes, and run the gate: the chat's end-to-end case reads a
transcript written as Claude Code writes it.
