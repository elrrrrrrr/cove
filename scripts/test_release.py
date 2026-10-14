import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('package_ipa', Path(__file__).with_name('package-ipa.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'archive/Products/Applications/Cove.app'
        self.app.mkdir(parents=True)
        self.info = {
            'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'CFBundleIdentifier': 'com.elr.easyreader.EasyReader',
            'CFBundleShortVersionString': '1.2.3',
            'CFBundleVersion': '42',
        }
        self.write_info()
        (self.app / 'Cove').write_bytes(b'fixture executable')
        (self.app / 'Cove').chmod(0o755)

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def package(self):
        return module.package(self.root / 'archive', self.root / 'output')

    def test_payload_identity_versions_permissions_and_checksum(self):
        ipa = self.package()
        self.assertEqual(ipa.name, 'Cove-1.2.3-unsigned.ipa')
        with zipfile.ZipFile(ipa) as archive:
            info = plistlib.loads(archive.read('Payload/Cove.app/Info.plist'))
            self.assertEqual(info, self.info)
            self.assertTrue(archive.getinfo('Payload/Cove.app/Cove').external_attr >> 16 & 0o111)
        self.assertEqual(ipa.with_name(ipa.name + '.sha256').read_text(),
                         f'{hashlib.sha256(ipa.read_bytes()).hexdigest()}  {ipa.name}\n')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.package()

    def test_rejects_simulator_build(self):
        self.info['CFBundleSupportedPlatforms'] = ['iPhoneSimulator']
        self.write_info()
        with self.assertRaisesRegex(ValueError, 'iPhoneOS'):
            self.package()

    def test_rejects_identity_change_and_invalid_version(self):
        for key, value in [('CFBundleIdentifier', 'another.app'), ('CFBundleShortVersionString', '../bad')]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    self.package()
                self.info[key] = original

    def test_rejects_signatures_profiles_and_private_seeds(self):
        for name in ['_CodeSignature/CodeResources', 'embedded.mobileprovision', 'Sites/private.site', 'BundledData/favorites.json']:
            with self.subTest(name=name):
                path = self.app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
                with self.assertRaises(ValueError):
                    self.package()
                path.unlink()
                if name.startswith('_CodeSignature/'):
                    path.parent.rmdir()

    def test_rejects_escaping_symlink(self):
        (self.app / 'escape').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.package()

    def test_rejects_multiple_apps(self):
        (self.app.parent / 'Other.app').mkdir()
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            self.package()


if __name__ == '__main__':
    unittest.main()
