import importlib.util
from pathlib import Path
import unittest
import tempfile
import subprocess

spec = importlib.util.spec_from_file_location("export_repo", Path(__file__).with_name("export-public-repo.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ExportPolicyTests(unittest.TestCase):
    def test_private_and_generated_paths_are_never_exported(self):
        for path in ["sites/local.site", "data/favorites.json", "config/reference.swift",
                     "config/site-tests/cases.json", "config/site-tests/source/cover.bin",
                     "Nested/.env", ".env.production", "keys/signing.p8", "cert.p12",
                     "Nested/id_ed25519", ".netrc", "Nested/credentials.json",
                     "Other/EasyReader.xcodeproj/project.pbxproj", "private-copy.site", "Nested/PRIVATE.SITE"]:
            with self.subTest(path=path):
                self.assertFalse(module.allowed_path(Path(path)))

    def test_reserved_examples_and_code_remain_exportable(self):
        for path in ["examples/sites/demo.site", "examples/data/favorites.json",
                     "EasyReader/Tests/Fixtures/Sites/demo.site",
                     "EasyReader/Sources/EasyReader/Core/Resource.swift", ".env.example"]:
            with self.subTest(path=path):
                self.assertTrue(module.allowed_path(Path(path)))

    def test_private_key_and_token_markers_are_detected(self):
        self.assertTrue(any(p.search(b"-----BEGIN " + b"PRIVATE KEY-----") for p in module.TOKEN_PATTERNS))
        self.assertTrue(any(p.search(b"ghp_" + b"x" * 36) for p in module.TOKEN_PATTERNS))
        self.assertFalse(any(p.search(b"template-token") for p in module.TOKEN_PATTERNS))

    def test_export_excludes_private_content_and_preserves_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"; root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for name in ["main.swift", "sites/local.site", "data/favorites.json", ".env", "examples/sites/demo.site"]:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("fixture")
            destination = Path(directory) / "export"
            self.assertEqual(module.export(root, destination), 2)
            self.assertTrue((destination / "main.swift").exists())
            self.assertTrue((destination / "examples/sites/demo.site").exists())
            self.assertFalse((destination / "sites").exists())
            self.assertFalse((destination / ".env").exists())

    def test_export_rejects_credentials_before_creating_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"; root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "main.swift").write_text("safe code")
            (root / "settings.txt").write_bytes(b"ghp_" + b"x" * 36)
            destination = Path(directory) / "export"
            with self.assertRaisesRegex(ValueError, "Credential-like"):
                module.export(root, destination)
            self.assertFalse(destination.exists())

if __name__ == "__main__":
    unittest.main()
