"""Archive integrity must be checked before loading any native code."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from desktop_release_consumer import extract_library


class ReleaseArchiveTests(unittest.TestCase):
    def fixture(self, directory, symlink=False):
        archive = directory / 'release.tar.gz'
        data = b'released native library'
        with tarfile.open(archive, 'w:gz') as package:
            entry = tarfile.TarInfo('./windows/x64/library.dll')
            if symlink:
                entry.type = tarfile.SYMTYPE
                entry.linkname = '../../outside.dll'
                package.addfile(entry)
            else:
                entry.size = len(data)
                package.addfile(entry, io.BytesIO(data))
        checksum = directory / 'release.tar.gz.sha256'
        checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  release.tar.gz\n')
        return archive, checksum, data

    def test_extracts_the_checksummed_regular_member(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive, checksum, data = self.fixture(directory)
            target = directory / 'library.dll'
            extract_library(archive, checksum, 'windows/x64/library.dll', target)
            self.assertEqual(target.read_bytes(), data)

    def test_rejects_tampering_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive, checksum, _ = self.fixture(directory)
            archive.write_bytes(archive.read_bytes() + b'tampered')
            target = directory / 'library.dll'
            with self.assertRaisesRegex(ValueError, 'checksum'):
                extract_library(archive, checksum, 'windows/x64/library.dll', target)
            self.assertFalse(target.exists())

    def test_rejects_a_link_in_place_of_the_native_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive, checksum, _ = self.fixture(directory, symlink=True)
            target = directory / 'library.dll'
            with self.assertRaisesRegex(ValueError, 'regular'):
                extract_library(archive, checksum, 'windows/x64/library.dll', target)
            self.assertFalse(target.exists())


if __name__ == '__main__':
    unittest.main()
