#!/usr/bin/env python3
"""Restore the pinned MIT Rust Book EPUB and derive the plain TXT showcase."""
from pathlib import Path
from urllib.request import urlopen
import hashlib
import json
import zipfile
import io
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
source = json.loads((root / 'examples/showcase/rust-book-source.json').read_text())
local = root / 'examples/nas/files/Rust 学习指南.epub'
if local.exists() and hashlib.sha256(local.read_bytes()).hexdigest() == source['sha256']:
    data = local.read_bytes()
else:
    with urlopen(source['url'], timeout=30) as response:
        data = response.read(5 * 1024 * 1024 + 1)
if len(data) > 5 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != source['sha256']:
    raise ValueError('Pinned EPUB digest or download limit mismatch')
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    if archive.testzip() is not None or any(Path(n).is_absolute() or '..' in Path(n).parts for n in archive.namelist()):
        raise ValueError('Invalid EPUB archive')
(root / 'examples/nas/files/Rust 学习指南.epub').write_bytes(data)
print('Restored the original Rust Book EPUB; license is in examples/showcase/rust-book-LICENSE')

# Convert the pinned book to plain UTF-8 text. Chapter headings live in the TXT;
# Cove derives the table of contents at runtime, with no bundled chapter index.
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    ns = {'p': 'http://www.idpf.org/2007/opf', 'x': 'http://www.w3.org/1999/xhtml'}
    opf = ET.fromstring(archive.read('EPUB/content.opf'))
    manifest = {node.attrib['id']: node.attrib['href'] for node in opf.findall('.//p:item', ns)}
    chapters = []
    for node in opf.findall('.//p:itemref', ns):
        name = 'EPUB/' + manifest[node.attrib['idref']]
        if not name.startswith('EPUB/text/ch') or int(Path(name).stem[2:]) < 4:
            continue
        page = ET.fromstring(archive.read(name))
        body = page.find('x:body', ns)
        title = ''.join(body.find('.//x:h1', ns).itertext()).strip()
        content = []
        for element in body.iter():
            if element.tag.split('}')[-1] in ['p', 'pre', 'h2', 'h3']:
                content.append(''.join(element.itertext()).strip())
        chapters.append(f"第{len(chapters)+1}章 {title}\n\n" + '\n\n'.join(content))
    text = 'Rust 学习指南 · Rust Book 简体中文版\n来源：KaiserY/trpl-zh-cn · MIT 许可\n\n' + '\n\n'.join(chapters) + '\n'
    (root / 'examples/nas/files/Rust 学习指南.txt').write_text(text, encoding='utf-8')
    print(f'Exported {len(chapters)} chapter headings as plain TXT; no chapter index is bundled')
