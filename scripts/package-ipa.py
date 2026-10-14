#!/usr/bin/env python3
"""Package an unsigned iPhoneOS archive; reject signed or private content."""
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def package(archive: Path, output: Path) -> Path:
    apps = list((archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('Expected exactly one application in archive')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Expected an iPhoneOS device build, not a simulator build')
    if info.get('CFBundleIdentifier') != 'com.elr.easyreader.EasyReader':
        raise ValueError('Unexpected application identity')
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid release version')
    for path in app.rglob('*'):
        if path.name in {'_CodeSignature', 'embedded.mobileprovision'}:
            raise ValueError('Archive must be built without signing')
        if path.suffix.lower() == '.site' or path.name == 'favorites.json':
            raise ValueError('Private presets must not enter a public IPA')
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise ValueError('Application symlink escapes the bundle')
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / f'Cove-{version}-unsigned.ipa'
    if ipa.exists():
        raise ValueError('Output IPA already exists; use an empty output directory')
    with tempfile.TemporaryDirectory(prefix='cove-payload-') as folder:
        payload = Path(folder) / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        subprocess.run(['/usr/bin/zip', '-q', '-r', '-y', str(ipa.resolve()), 'Payload'], cwd=folder, check=True)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (output / f'{ipa.name}.sha256').write_text(f'{digest}  {ipa.name}\n')
    return ipa


if __name__ == '__main__':
    print(package(Path(sys.argv[1]), Path(sys.argv[2])))
