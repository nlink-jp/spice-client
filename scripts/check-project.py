#!/usr/bin/env python3
"""Check artifact provenance and portable documentation, without network access."""
import hashlib
import json
from pathlib import Path
import plistlib
import re


def require(condition, message):
    if not condition:
        raise AssertionError(message)

root = Path(__file__).resolve().parent.parent
upstream = json.loads((root / 'Vendor/UPSTREAM.json').read_text())
require(hashlib.sha256((root/'Vendor'/upstream['patch']).read_bytes()).hexdigest() == upstream['patch_sha256'], 'Vendor patch changed')
vendor = root / 'Vendor/SwiftSpice'
for name, expected in upstream['files_sha256'].items():
    path = vendor / name
    require(path.resolve().is_relative_to(vendor.resolve()), f'Escaping vendor link: {name}')
    require(hashlib.sha256(path.read_bytes()).hexdigest() == expected, f'Unrecorded vendor change: {name}')
for name, expected in upstream['symlinks'].items():
    require((vendor/name).is_symlink() and str((vendor/name).readlink()) == expected, f'Changed vendor link: {name}')
actual = {str(path.relative_to(vendor)) for path in vendor.rglob('*')
          if path.is_file() and not any(part in ('.build', '.swiftpm', '__pycache__', '.git') for part in path.relative_to(vendor).parts)}
require(actual == set(upstream['files_sha256']), 'Unexpected or missing vendor files')
for name, expected in upstream['native_sha256'].items():
    path = root / 'Vendor/SwiftSpice' / name
    require(hashlib.sha256(path.read_bytes()).hexdigest() == expected, f'Native artifact changed: {name}')
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
require(info['CFBundleIdentifier'] == 'jp.nlink.spice-client', 'Wrong application identity')
require(not any(key.startswith('SU') for key in info), 'Unexpected updater configuration')
for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
    require(info[key] == '${VERSION}',
            f'Info.plist {key} must carry the ${{VERSION}} placeholder; the version is git describe output written at build time')
for path in root.glob('Sources/**/*.swift'):
    # Three dotted numbers not adjoined by a fourth: 1.2.3 yes, 127.0.0.1 no.
    require(re.search(r'(?<![\d.])\d+\.\d+\.\d+(?![\d.])', path.read_text()) is None,
            f'Version literal in {path.relative_to(root)}; read CFBundleShortVersionString instead')
minimum = re.search(r'\.macOS\(\.v(\d+)\)', (root / 'Package.swift').read_text())
require(minimum is not None, 'No macOS deployment target in Package.swift')
require(info['LSMinimumSystemVersion'] == minimum.group(1) + '.0', 'Deployment target differs between Package.swift and Info.plist')
for path in root.glob('Integration/**/*'):
    if not path.is_file() or 'Artifacts' in path.parts:
        continue
    for reference in re.findall(r'docker\.io/[\w./-]+(?::[\w.-]+)?(?:@sha256:[0-9a-f]{64})?', path.read_text()):
        require('@sha256:' in reference, f'Unpinned image reference in {path.relative_to(root)}: {reference}')
for path in [root/'README.md', root/'README.ja.md', *root.glob('docs/**/*.md')]:
    text = path.read_text()
    require('/Users/' not in text, f'Non-portable path in {path.name}')
    for target in re.findall(r'\]\(([^)]+)\)', text):
        if '://' not in target and not target.startswith('#'):
            require((path.parent / target.split('#')[0]).exists(), f'Broken link: {target}')
print('Pinned vendor tree, native artifact hashes, app identity, and documentation links verified.')
