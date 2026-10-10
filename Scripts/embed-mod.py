#!/usr/bin/env python3
"""Writes the mod's files into the Swift sources the app installs them from.

The app carries the companion mod (D66) as Swift raw strings, one file each;
`ModFilesSuite` holds the two copies to the same bytes. Run after editing
anything under `mod/` or `.claude-plugin/`:  python3 Scripts/embed-mod.py
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, 'Sources/LampBoardCore/Mod')

# name in Swift, file in the repository, Swift file, one-line doc
FILES = [
    ('register', 'mod/hooks/register.js', 'ModFilesRegister.swift', '`mod/hooks/register.js`, the hooks module: reports, permissions, the band, the governor.'),
    ('lamps', 'mod/hooks/lamps.js', 'ModFilesLamps.swift', '`mod/hooks/lamps.js`, the lamps pane of `/lamps` (D131).'),
    ('look', 'mod/hooks/look.js', 'ModFilesLook.swift', '`mod/hooks/look.js`, Claude Code\'s look (D134).'),
    ('inbox', 'mod/hooks/inbox.js', 'ModFilesInbox.swift', '`mod/hooks/inbox.js`, the Hub\'s signed commands (D152).'),
    ('ed25519', 'mod/hooks/ed25519.js', 'ModFilesEd25519.swift', '`mod/hooks/ed25519.js`, the signature check of the Hub\'s commands (D152).'),
]

def raw(text):
    if '"""#' in text or '\\#(' in text:
        sys.exit('a file holds """# or \\#(: it cannot be a #"""…"""# string')
    return '#"""\n' + text.rstrip('\n') + '\n"""#'

for name, path, swift, doc in FILES:
    text = open(os.path.join(ROOT, path), encoding='utf-8').read()
    body = f'import Foundation\n\nextension ModFiles {{\n\n    /// {doc}\n    /// Written by `Scripts/embed-mod.py` from the repository\'s copy: edit that one.\n    public static let {name} = {raw(text)}\n}}\n'
    open(os.path.join(CORE, swift), 'w', encoding='utf-8').write(body)

# ModFiles.swift: the manifest, the hooks file, the version and the list.
plugin = open(os.path.join(ROOT, 'mod/.claude-plugin/plugin.json'), encoding='utf-8').read()
version = json.loads(plugin)['version']
main = os.path.join(CORE, 'ModFiles.swift')
s = open(main, encoding='utf-8').read()
s = re.sub(r'public static let version = "[^"]+"', f'public static let version = "{version}"', s)
s = re.sub(r'public static let plugin = #""".*?"""#', lambda m: 'public static let plugin = ' + raw(plugin), s, flags=re.S)
s = re.sub(r'\n    public static let register = #""".*?"""#\n', '\n', s, flags=re.S)
listing = ''.join(f'            ("{path}", {name}),\n' for name, path, _, _ in FILES)
s = re.sub(r'(            \("mod/hooks/hooks.json", hooks\),\n)(?:            \("mod/hooks/[a-z0-9]+\.js", [a-z0-9]+\),\n)+', lambda m: m.group(1) + listing, s)
open(main, 'w', encoding='utf-8').write(s)
print('embedded', ', '.join(n for n, *_ in FILES), 'at version', version)
