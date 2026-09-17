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


def parse_linked_sdk(load_commands):
    """Return the sdk field of LC_BUILD_VERSION from `otool -l` output, or None."""
    inside = False
    for line in load_commands.splitlines():
        words = line.split()
        if len(words) >= 2 and words[0] == 'cmd':
            inside = words[1] == 'LC_BUILD_VERSION'
        elif inside and len(words) == 2 and words[0] == 'sdk':
            return words[1]
    return None


def linked_sdk(binary):
    output = subprocess.run(['otool', '-l', str(binary)], check=True, capture_output=True, text=True).stdout
    return parse_linked_sdk(output)


def current_sdk():
    return subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-version'],
                          check=True, capture_output=True, text=True).stdout.strip()


def require_linked_sdk(binary, expected, read=linked_sdk):
    """macOS draws an app linked against an older SDK with the previous window
    chrome; the Xcode 27 toolchain stamps the deployment target unless the link
    step names the SDK. Every other gate passes either way, so fail here."""
    require(expected, 'No expected macOS SDK version')
    actual = read(binary)
    require(actual == expected, f'Linked against macOS SDK {actual}, expected the current SDK {expected}')


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


def verify(archive, version, sdk):
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
        require_linked_sdk(app / 'Contents/MacOS/SpiceClient', sdk)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', str(app)], check=True)
        subprocess.run([str(app / 'Contents/MacOS/SpiceClient'), '--resource-check'], check=True)
        reported = subprocess.run([str(app / 'Contents/MacOS/SpiceClient'), '--version'],
                                  check=True, capture_output=True, text=True).stdout.strip()
        require(reported == f'Spice Client {version}', f'--version reported {reported!r}, expected {version!r}')
    print(f'Final archive identity, signature, notarization, Metal resources and linked SDK {sdk} verified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path, nargs='?')
    parser.add_argument('version', nargs='?')
    parser.add_argument('--linked-sdk', type=Path, metavar='BINARY',
                        help='only check that this binary is linked against the expected SDK')
    parser.add_argument('--sdk', help='expected macOS SDK version (default: the installed SDK)')
    args = parser.parse_args()
    expected = args.sdk or current_sdk()
    if args.linked_sdk is not None:
        parser.error('--linked-sdk takes no archive') if args.archive or args.version else None
        require_linked_sdk(args.linked_sdk.resolve(), expected)
        print(f'Linked against macOS SDK {expected}.')
    elif args.archive is None or args.version is None:
        parser.error('archive and version are required unless --linked-sdk is given')
    else:
        verify(args.archive.resolve(), args.version, expected)
