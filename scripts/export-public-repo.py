#!/usr/bin/env python3
"""Export a working tree to a new repository, excluding private content and credentials."""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

PRIVATE_ROOTS = {"sites", "data", "config", "public-export"}
GENERATED = {".git", "DerivedData", "build", ".build", ".swiftpm", ".claude", "__pycache__"}
SECRET_EXTENSIONS = {".pem", ".key", ".p8", ".p12", ".pfx", ".keystore", ".mobileprovision"}
SECRET_NAMES = {"id_rsa", "id_ed25519", "credentials.json", ".credentials", ".netrc"}
TOKEN_PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{40,}\b"),
    re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}\b"),
]

def allowed_path(relative: Path) -> bool:
    parts = relative.parts
    if not parts or parts[0] in PRIVATE_ROOTS:
        return False
    if any(part in GENERATED or part.endswith(".xcodeproj") for part in parts):
        return False
    name = relative.name.lower()
    if name in SECRET_NAMES or relative.suffix.lower() in SECRET_EXTENSIONS:
        return False
    if name.startswith(".env") and name not in {".env.example", ".env.sample", ".env.template"}:
        return False
    if relative.suffix.lower() == ".site":
        return parts[:2] == ("examples", "sites") or parts[:4] == ("EasyReader", "Tests", "Fixtures", "Sites")
    return True

def export(root: Path, destination: Path) -> int:
    destination = destination.expanduser().resolve()
    if destination == root or root in destination.parents:
        raise ValueError("Choose a destination outside the development repository")
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("Destination must be empty; existing files are never overwritten")
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root, check=True, capture_output=True,
    ).stdout.decode().split("\0")
    selected = []
    for name in sorted(set(listed)):
        if not name:
            continue
        relative = Path(name)
        source = root / relative
        if not allowed_path(relative) or not source.is_file() or source.is_symlink():
            continue
        if source.stat().st_size <= 4 * 1024 * 1024:
            data = source.read_bytes()
            if any(pattern.search(data) for pattern in TOKEN_PATTERNS):
                raise ValueError(f"Credential-like content detected in {relative}; export stopped before copying")
        selected.append(relative)
    destination.mkdir(parents=True, exist_ok=True)
    for relative in selected:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    subprocess.run(["git", "init", "-b", "main", str(destination)], check=True, capture_output=True)
    return len(selected)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        count = export(Path(__file__).resolve().parents[1], args.destination)
    except ValueError as error:
        parser.error(str(error))
    print(f"Prepared {count} files in {args.destination}; original Git history is unchanged.")

if __name__ == "__main__":
    main()
