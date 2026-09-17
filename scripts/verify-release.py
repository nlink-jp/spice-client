#!/usr/bin/env python3
"""Validate the final archive itself. Never infer trust from a neighboring .app."""
import argparse
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import tempfile
import zipfile


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def inspect_archive(archive):
    with zipfile.ZipFile(archive) as contents:
        require(contents.testzip() is None, 'Archive CRC check failed')
        names = contents.namelist()
        require(names and len(names) == len(set(names)), 'Empty or duplicate archive entries')
        for entry in contents.infolist():
            path = PurePosixPath(entry.filename)
            require(not path.is_absolute() and '..' not in path.parts, 'Unsafe archive path')
            require(path.parts[0] == 'Spice Client.app', 'Unexpected archive root')
            require(not stat.S_ISLNK(entry.external_attr >> 16), 'Unexpected archive symlink')
        require('Spice Client.app/Contents/Info.plist' in names, 'Missing application')


def verify(archive, version):
    inspect_archive(archive)
    with tempfile.TemporaryDirectory(prefix='spice-client-release-') as temporary:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), temporary], check=True)
        app = Path(temporary) / 'Spice Client.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == 'jp.nlink.spice-client', 'Wrong application identity')
        require(info['CFBundleShortVersionString'] == version, 'Wrong release version')
        for name in ('LICENSE', 'NOTICE.md', 'AppIcon.icns', 'Licenses/UPSTREAM.json',
                     'Licenses/SwiftSpice-MIT.txt', 'Licenses/THIRD_PARTY_NOTICES.md'):
            require((app / 'Contents/Resources' / name).is_file(), f'Missing resource: {name}')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', str(app)], check=True)
        subprocess.run([str(app / 'Contents/MacOS/SpiceClient'), '--resource-check'], check=True)
    print('Final archive identity, signature, notarization and Metal resources verified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('version')
    args = parser.parse_args()
    verify(args.archive.resolve(), args.version)
