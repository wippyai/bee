"""Unchanged native inputs retain their local proxy version across packaging."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LocalNativeVersionTests(unittest.TestCase):
    def test_repeated_packaging_keeps_version_and_native_edits_change_it(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.wippy', prefix='local-version-test-') as temporary:
            root = Path(temporary)
            (root / 'build').mkdir()
            (root / 'native').mkdir()
            for name in ('local_native.sh', 'local_native_manifest.py'):
                shutil.copy2(ROOT / 'build' / name, root / 'build' / name)
            (root / 'native/go.mod').write_text('module github.com/wippyai/bee/native\n\ngo 1.27\n')
            (root / 'native/fixture.go').write_text('package fixture\n')
            (root / 'wippy.build.json').write_text(json.dumps({'native': [{'module': 'github.com/wippyai/bee/native', 'version': 'old'}]}))
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture'], check=True)
            def build():
                return subprocess.check_output([str(root / 'build/local_native.sh')], cwd=root,
                    env={**os.environ, 'TMPDIR': str(root)}, text=True).strip()
            first = build()
            time.sleep(1.1)
            self.assertEqual(build(), first)
            (root / 'native/fixture.go').write_text('package changed\n')
            self.assertNotEqual(build(), first)
