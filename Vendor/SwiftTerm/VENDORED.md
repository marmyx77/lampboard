# SwiftTerm, vendored

The terminal emulator behind the live view (D129). It is the one piece of
LampBoard that was not written for it.

| | |
|---|---|
| Upstream | https://github.com/migueldeicaza/SwiftTerm |
| Release | `v1.20.0`, 18 August 2026 |
| Commit | `5d14406844143538cd8f8851d2d8a67c1fe443e5` |
| Licence | MIT, unmodified, in [LICENSE](LICENSE) |

## Why vendored, not fetched

- **The build stays offline and the same everywhere.** A SwiftPM dependency is
  fetched at build time, from a network the gate's Mac may not have, at a version
  `Package.resolved` would have to pin. This repository ignores that file.
- **Upstream's manifest does not build here.** It compiles a Metal shader, and the
  test Mac's Xcode has no Metal toolchain. The live view draws with Core Text,
  as SwiftTerm does by default, so the shader is left out instead.
- **What runs is what is read.** The sources sit in the tree, so a review or an
  audit reads the code that ships, and a local fix is a diff anyone can see.

## What was copied, and what was left out

Copied: every `.swift` file under upstream's `Sources/SwiftTerm`, except the two
folders below, with their directory layout kept.

Left out:

- `iOS/`: UIKit views. LampBoard is a Mac app. A phone companion would bring them back.
- `Documentation.docc/`: DocC articles, not code.
- `Apple/Metal/Shaders.metal`: the GPU renderer's shader (see above). The Swift
  half of that renderer is still here and is never switched on. Upstream already
  falls back to Core Text when the shader bundle is missing.
- Upstream's other targets: the fuzzer, `termcast`, benchmarks, tests and the
  build-info generator plugin.

Added: `SwiftTermBuildInfo.swift`, written by hand. Upstream generates it at build
time from git, and it carries the release's tag and commit above.

## Local patches

Each one is marked in the source with `Vendored patch <n>`.

1. `Buffer.swift`, `dump()`: a debug helper wrote to a folder in upstream's
   author's home directory. It now writes to the temporary directory. The function
   is never called by LampBoard. The change exists because this repository's
   gate refuses real home directories in any tracked file (docs/08-gates.md).
2. `AppleTerminalView.swift` and `MacTerminalView.swift`: `characterSpacing`, the
   width of a cell as a fraction of the font's advance, beside upstream's
   `lineSpacing` and applied the same way, in `computeFontDimensions`. It lets a
   fixed-width font be set tighter, closer to a proportional one (LampBoard D146).
   At 1, the default, nothing changes.
3. `MacTerminalView.swift`, `doCommand(by:)`: the Mac's text keys as Terminal and
   iTerm send them. With Option typing characters (LampBoard D138), Option-← and
   Option-→ came as `moveWordLeft:` and `moveWordRight:`, which upstream left
   unhandled, and Command-← and Command-→ were sent as word moves. Now:
   - Option-←/→ send `ESC b` and `ESC f`;
   - Option-Delete sends `ESC DEL`;
   - Command-←/→ send Ctrl-A and Ctrl-E;
   - Command-Delete sends Ctrl-U.
4. `MacTerminalView.swift`: drops. Upstream took none. A file dropped on the
   terminal is typed as its path, escaped as Terminal escapes it, so Claude Code
   takes a dropped image as the image. Text dropped, such as `@path` from the
   Hub's file tree, is typed as it is. Both go as a paste, so nothing runs until
   Enter.

## Updating

Copy the same set of files from a newer release, write `SwiftTermBuildInfo.swift`
again, re-apply the patches above (grep for `Vendored patch`), and update this
page's table. Then run the full gate. The live view's end-to-end cases are the
ones that prove the emulator still behaves.
