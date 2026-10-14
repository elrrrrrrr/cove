#!/usr/bin/env python3
"""Exercise the public demo through HTTP and check its downloadable archive."""
import importlib.util
from pathlib import Path
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
import threading
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cove_examples', ROOT / 'scripts/serve-examples.py')
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class ExampleServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), demo.Handler)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.base = f'http://127.0.0.1:{cls.server.server_port}'
        cls.opener = build_opener(ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join()

    def fetch(self, path, headers=None):
        return self.opener.open(Request(self.base + path, headers=headers or {}), timeout=5)

    def test_search_category_and_next_page(self):
        with self.fetch('/videos/') as response:
            first = response.read().decode()
        self.assertEqual(first.count('class="media-card"'), 6)
        self.assertIn('rel="next" href="/videos/?page=2"', first)
        with self.fetch('/videos/?page=2') as response:
            second = response.read().decode()
        self.assertEqual(second.count('class="media-card"'), 2)
        self.assertNotIn('rel="next"', second)
        with self.fetch('/videos/?q=%E5%B1%B1%E8%B0%B7&tag=nature') as response:
            search = response.read().decode()
        self.assertEqual(search.count('class="media-card"'), 2)
        self.assertNotIn('/watch/city', search)

    def test_video_supports_bounded_range_requests(self):
        expected = (demo.ASSETS / 'demo.mp4').read_bytes()
        with self.fetch('/assets/demo.mp4', {'Range': 'bytes=8-39'}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers['Content-Range'], f'bytes 8-39/{len(expected)}')
            self.assertEqual(response.read(), expected[8:40])
        with self.assertRaises(HTTPError) as error:
            self.fetch('/assets/demo.mp4', {'Range': f'bytes={len(expected)}-'})
        self.assertEqual(error.exception.code, 416)

    def test_missing_assets_and_traversal_do_not_expose_repository(self):
        for path in ['/assets/../README.md', '/assets/%2e%2e/README.md', '/assets/missing.png', '/missing']:
            with self.assertRaises(HTTPError) as error:
                self.fetch(path)
            self.assertEqual(error.exception.code, 404)

    def test_offline_fixtures_match_served_content(self):
        cases = [('videos', '/videos/'), ('videos-next', '/videos/?page=2'),
                 ('videos-search', '/videos/?q=%E5%B1%B1%E8%B0%B7'), ('article', '/post/valley'),
                 ('comics', '/comics/'), ('comic', '/book/valley'), ('chapter', '/chapter/1'),
                 ('journal', '/journal/'), ('directory', '/directory/'), ('video', '/watch/valley')]
        for name, path in cases:
            with self.subTest(page=name), self.fetch(path) as response:
                self.assertEqual(response.read(), (ROOT / 'examples/local-demo/pages' / (name + '.html')).read_bytes())

    def test_nas_demo_archive_contains_real_images(self):
        with zipfile.ZipFile(ROOT / 'examples/nas/files/沿途绘本.cbz') as archive:
            self.assertEqual(len(archive.namelist()), 3)
            for name in archive.namelist():
                self.assertEqual(Path(name).name, name)
                self.assertTrue(archive.read(name).startswith(b'\x89PNG\r\n\x1a\n'))
            self.assertIsNone(archive.testzip())


if __name__ == '__main__':
    unittest.main()
