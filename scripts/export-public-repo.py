#!/usr/bin/env python3
"""Export the current working tree into a new repository, excluding local content."""
from pathlib import Path
import argparse
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=Path, help='A new, empty directory for the public repository')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
destination = args.destination.expanduser().resolve()
if destination == root or root in destination.parents:
    parser.error('Choose a destination outside the development repository')
if destination.exists() and any(destination.iterdir()):
    parser.error('Destination must be empty; existing files are never overwritten')
private_roots = {'sites', 'data', 'config', 'public-export'}
generated = {'.git', 'DerivedData', 'build', '.build', '.swiftpm', '.claude'}
files = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root,
                       check=True, capture_output=True).stdout.decode().split('\0')
destination.mkdir(parents=True, exist_ok=True)
count = 0
for name in sorted(set(files)):
    if not name:
        continue
    relative = Path(name)
    if relative.parts[0] in private_roots or any(part in generated or part.endswith('.xcodeproj') for part in relative.parts):
        continue
    source = root / relative
    if not source.is_file() or source.is_symlink():
        continue
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    count += 1
subprocess.run(['git', 'init', '-b', 'main', str(destination)], check=True, capture_output=True)
print(f'Prepared {count} files in {destination}; original Git history is unchanged.')
