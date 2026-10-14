#!/usr/bin/env python3
"""Restore the pinned, MIT-licensed Rust Book EPUB used in the actual screenshots."""
from pathlib import Path
from urllib.request import urlopen
import hashlib
import json
import zipfile
import io

root = Path(__file__).resolve().parents[1]
source = json.loads((root / 'examples/showcase/rust-book-source.json').read_text())
with urlopen(source['url'], timeout=30) as response:
    data = response.read(5 * 1024 * 1024 + 1)
if len(data) > 5 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != source['sha256']:
    raise ValueError('Pinned EPUB digest or download limit mismatch')
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    if archive.testzip() is not None or any(Path(n).is_absolute() or '..' in Path(n).parts for n in archive.namelist()):
        raise ValueError('Invalid EPUB archive')
(root / 'examples/nas/files/Rust 学习指南.epub').write_bytes(data)
print('Restored the original Rust Book EPUB; license is in examples/showcase/rust-book-LICENSE')
