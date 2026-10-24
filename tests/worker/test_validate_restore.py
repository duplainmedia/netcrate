# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import csv
import tempfile
import unittest
import hashlib
from pathlib import Path
from validate_restore import validate_restore


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.media = self.root / 'originals'
        self.media.mkdir()
        (self.media / 'clip.mp4').write_bytes(b'original')
        self.manifest = self.root / 'hashes.csv'
        self.write_manifest()
        self.receipt = dict(RestoreDirectory=str(self.media), SHA256Manifest=str(self.manifest), Files=1)

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self, relative='clip.mp4'):
        with self.manifest.open('w', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=['RelativePath', 'Bytes', 'SHA256'])
            writer.writeheader()
            writer.writerow(dict(RelativePath=relative, Bytes=8, SHA256=hashlib.sha256(b'original').hexdigest()))

    def test_valid(self):
        self.assertEqual(len(validate_restore(self.receipt)), 1)

    def test_edit_rejected(self):
        (self.media / 'clip.mp4').write_bytes(b'altered!')
        with self.assertRaises(RuntimeError): validate_restore(self.receipt)

    def test_deletion_rejected(self):
        (self.media / 'clip.mp4').unlink()
        with self.assertRaises(RuntimeError): validate_restore(self.receipt)

    def test_extra_file_rejected(self):
        (self.media / 'extra.mov').write_bytes(b'extra')
        with self.assertRaises(RuntimeError): validate_restore(self.receipt)

    def test_traversal_rejected(self):
        self.write_manifest('../outside.mp4')
        with self.assertRaises(RuntimeError): validate_restore(self.receipt)


if __name__ == '__main__': unittest.main()
