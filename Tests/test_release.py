"""Fail-closed archive checks without signing credentials or network access."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/verify-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


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


if __name__ == '__main__':
    unittest.main()
