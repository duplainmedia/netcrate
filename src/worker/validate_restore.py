# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import csv
import hashlib
from pathlib import Path


def validate_restore(receipt):
    root = Path(receipt['RestoreDirectory']).resolve()
    manifest_path = Path(receipt.get('SHA256Manifest') or str(root) + '.verification/sha256.csv')
    with manifest_path.open(encoding='utf-8-sig', newline='') as handle:
        rows = list(csv.DictReader(handle))
    expected = {}
    for row in rows:
        relative = Path(row['RelativePath'])
        if relative.is_absolute() or '..' in relative.parts or ':' in str(relative):
            raise RuntimeError('Unsafe restore manifest path.')
        key = str(relative).casefold()
        if key in expected:
            raise RuntimeError('Duplicate restore manifest path.')
        expected[key] = row
    files = []
    for path in root.rglob('*'):
        if path.is_symlink() or path.is_junction():
            raise RuntimeError('Reparse restored path rejected.')
        if path.is_file():
            files.append(path)
    if len(files) != len(rows) or len(files) != receipt['Files']:
        raise RuntimeError('Restored file count changed since verification.')
    for path in files:
        row = expected.get(str(path.relative_to(root)).casefold())
        if row is None or path.stat().st_size != int(row['Bytes']):
            raise RuntimeError('Restored path or size changed since verification.')
        with path.open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        if digest.upper() != row['SHA256'].upper():
            raise RuntimeError('Restored content changed since verification.')
    return expected
