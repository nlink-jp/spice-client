"""Fail-closed archive checks without signing credentials or network access."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/verify-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

LOAD_COMMANDS = """Load command 9
      cmd LC_UUID
  cmdsize 24
     uuid 0C3D9F8A-0000-4000-8000-00000000SDK1
Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 26.0
      sdk 26.0
   ntools 1
     tool 3
  version 1100.0
Load command 11
      cmd LC_SOURCE_VERSION
  cmdsize 16
  version 0.0
"""


class ArchiveTests(unittest.TestCase):
    def test_rejects_empty_or_corrupt_archive(self):
        with tempfile.TemporaryDirectory() as work:
            archive = Path(work) / 'release.zip'
            for data in (b'', b'not a zip'):
                archive.write_bytes(data)
                with self.assertRaises(zipfile.BadZipFile):
                    release.inspect_archive(archive)

    def test_rejects_wrong_root_and_traversal(self):
        for name in ('Other.app/Contents/Info.plist', '../Spice Client.app/Contents/Info.plist',
                     'Spice Client.app/../../escape'):
            with tempfile.TemporaryDirectory() as work:
                archive = Path(work) / 'release.zip'
                with zipfile.ZipFile(archive, 'w') as contents:
                    contents.writestr(name, b'fixture')
                with self.assertRaises(AssertionError):
                    release.inspect_archive(archive)

    def test_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as work:
            archive = Path(work) / 'release.zip'
            with zipfile.ZipFile(archive, 'w') as contents:
                contents.writestr('Spice Client.app/Contents/Info.plist', b'fixture')
                link = zipfile.ZipInfo('Spice Client.app/Contents/link')
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                contents.writestr(link, '/etc')
            with self.assertRaises(AssertionError):
                release.inspect_archive(archive)


class LinkedSDKTests(unittest.TestCase):
    def test_reads_sdk_only_from_build_version_command(self):
        self.assertEqual(release.parse_linked_sdk(LOAD_COMMANDS), '26.0')
        self.assertIsNone(release.parse_linked_sdk(LOAD_COMMANDS.replace('LC_BUILD_VERSION', 'LC_VERSION_MIN_MACOSX')))
        self.assertIsNone(release.parse_linked_sdk(''))

    def test_rejects_binary_linked_against_a_different_sdk(self):
        with self.assertRaises(AssertionError):
            release.require_linked_sdk(Path('fixture'), '27.0', read=lambda _: '26.0')
        with self.assertRaises(AssertionError):
            release.require_linked_sdk(Path('fixture'), '27.0', read=lambda _: None)
        with self.assertRaises(AssertionError):
            release.require_linked_sdk(Path('fixture'), '', read=lambda _: '27.0')
        release.require_linked_sdk(Path('fixture'), '27.0', read=lambda _: '27.0')

    def test_installed_sdk_is_a_version_number(self):
        self.assertRegex(release.current_sdk(), r'^\d+\.\d+$')


if __name__ == '__main__':
    unittest.main()
