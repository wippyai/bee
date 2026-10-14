"""Exercise the single preparation and restore-only release workflow contract."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

import yaml
import ci

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / '.github/workflows' / name).read_text())


class CIContractTests(unittest.TestCase):
    def test_application_key_ignores_fixture_executables_and_tracks_composed_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {'src/app.lua': 'return 1', 'tests/fixtures/resource_clock/clock.lua': 'return 2',
                     'tests/fixtures/harness/host.yaml': 'host: fixture',
                     'tests/fixtures/harness/client.go': 'package main', 'README.md': 'docs',
                     'wippy.build.json': json.dumps({'application': {'module': 'bee/bee', 'packs': []}})}
            for name, content in files.items():
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            subprocess.run(['git', 'init', '--quiet'], cwd=root, check=True)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            def command(*args):
                return subprocess.check_output(args, cwd=root, text=True).strip()
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'run', side_effect=command):
                before = ci.application_key()
                (root / 'README.md').write_text('changed docs')
                (root / 'tests/fixtures/harness/client.go').write_text('changed executable')
                self.assertEqual(ci.application_key(), before)
                (root / 'tests/fixtures/resource_clock/clock.lua').write_text('return 3')
                self.assertNotEqual(ci.application_key(), before)

    def test_import_preserves_prepared_identity_in_ci_consumers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'prepared.tar'
            identity = json.dumps({'entries': [{'name': 'binary_identity', 'data': {'source_revision': 'prepared'}}]}).encode()
            with tarfile.open(archive, 'w') as output:
                entry = tarfile.TarInfo('src/env/identity/_index.yaml')
                entry.size = len(identity)
                output.addfile(entry, io.BytesIO(identity))
            environment = root / 'environment'
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'PREPARED', archive), patch.dict(os.environ, {'GITHUB_ENV': str(environment)}, clear=True):
                ci.import_prepared()
                self.assertEqual(environment.read_text(), 'REVISION=prepared\n')

    def test_application_key_tracks_content_without_commit_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'src').mkdir()
            source = root / 'src/app.lua'
            source.write_text('return 1')
            manifest = root / 'wippy.build.json'
            manifest.write_text(json.dumps({'application': {'module': 'bee/bee', 'packs': [
                {'module': 'bee/bee', 'sha256': 'old'}, {'module': 'wippy/test', 'sha256': 'pinned'}]}}))
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'run', return_value='src/app.lua') as command:
                before = ci.application_key()
                self.assertFalse(any('rev-parse' in call.args for call in command.call_args_list))
                self.assertEqual(ci.application_key(), before)
                manifest.write_text(manifest.read_text().replace('old', 'generated'))
                self.assertEqual(ci.application_key(), before)
                manifest.write_text(manifest.read_text().replace('pinned', 'changed'))
                self.assertNotEqual(ci.application_key(), before)
                source.write_text('return 2')
                self.assertNotEqual(ci.application_key(), before)

    def test_builder_pin_uses_make_and_honors_override(self):
        with patch.dict(os.environ, {'BUILDER_VERSION': 'reviewed-pin'}):
            self.assertEqual(ci.run('make', '--no-print-directory', 'builder-version'), 'reviewed-pin')

    def test_release_accepts_only_successful_ci_at_exact_sha_and_retained_artifact(self):
        sha = 'a' * 40
        artifact = 'bee-application-fingerprint'
        candidate = {'id': 12, 'head_sha': sha, 'head_branch': 'main', 'event': 'push', 'conclusion': 'success'}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            environment = {'GITHUB_REPOSITORY': 'wippyai/bee', 'GITHUB_OUTPUT': str(output)}
            for changes in ({'head_sha': 'b' * 40}, {'head_branch': 'feature/example'}, {'conclusion': 'failure'}, {'event': 'pull_request'}):
                row = dict(candidate, **changes)
                with patch.dict(os.environ, environment, clear=True), patch.object(ci, 'run', side_effect=[sha, json.dumps({'workflow_runs': [row]})]):
                    with self.assertRaisesRegex(ValueError, 'exact SHA'):
                        ci.require_ci()
            for expired in (True, False):
                replies = [sha, json.dumps({'workflow_runs': [candidate]}), json.dumps({'artifacts': [{'name': artifact, 'expired': expired}]})]
                with patch.dict(os.environ, environment, clear=True), patch.object(ci, 'application_key', return_value='fingerprint'), patch.object(ci, 'run', side_effect=replies), contextlib.redirect_stdout(io.StringIO()):
                    if expired:
                        with self.assertRaisesRegex(ValueError, 'retained prepared'):
                            ci.require_ci()
                    else:
                        ci.require_ci()
                        self.assertEqual(output.read_text(), 'run-id=12\nartifact=bee-application-fingerprint\n')

    def test_content_keys_cover_application_and_toolchain_inputs(self):
        key = ci.application_key()
        with patch.object(ci, 'run', wraps=ci.run) as command:
            self.assertEqual(ci.application_key(), key)
            paths = command.call_args_list[0].args
            self.assertIn('modules', paths)
            self.assertIn('tests/lua', paths)
        linux = ci.tools_outputs('linux/amd64')
        self.assertNotEqual(linux['cache-key'], ci.tools_outputs('linux/arm64')['cache-key'])
        self.assertEqual(linux['tools-key'], subprocess.check_output(['make', '--no-print-directory', 'tools-key'], cwd=ROOT, text=True).strip())

    def test_macos_cache_keys_match_for_both_targets_and_tag_versions(self):
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/heads/main', 'BEE_VERSION': 'v0.2.0-dev'}):
            expected = ci.tools_outputs('darwin/arm64', 'darwin/arm64')['cache-key']
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/tags/v0.2.1-alpha.7', 'BEE_VERSION': 'v0.2.1-alpha.7'}):
            for target in ('darwin/amd64', 'darwin/arm64'):
                self.assertEqual(ci.tools_outputs(target, 'darwin/arm64')['cache-key'], expected)

    def test_preparation_is_shared_and_release_never_saves_caches_or_runs_tests(self):
        action = yaml.safe_load((ROOT / '.github/actions/setup-bee/action.yml').read_text())
        steps = action['runs']['steps']
        caches = [step for step in steps if 'actions/cache' in step.get('uses', '')]
        self.assertEqual(len(caches), 2)
        self.assertTrue(all('/restore@' in step['uses'] for step in caches))
        self.assertNotIn('restore-keys', caches[0]['with'])
        self.assertEqual(caches[1]['with']['restore-keys'], '${{ steps.key.outputs.cache-prefix }}')
        self.assertEqual(caches[1]['with']['path'], '${{ steps.key.outputs.go-path }}')
        go = [step for step in steps if 'actions/setup-go@' in step.get('uses', '')]
        self.assertEqual(len(go), 1)
        self.assertFalse(go[0]['with']['cache'])
        self.assertEqual(steps[-1]['run'], 'make tools')
        release = workflow('release.yml')['jobs']
        self.assertEqual(set(release), {'prepare', 'build', 'release'})
        for job in release.values():
            for step in job['steps']:
                self.assertNotIn('/save@', step.get('uses', ''))
                for forbidden in ('make lint', 'make boot-check', 'make test', 'make ci-prepare'):
                    self.assertNotIn(forbidden, step.get('run', ''))
        prepare = release['prepare']['steps']
        self.assertIn('make ci-require', prepare[1]['run'])
        self.assertEqual(prepare[1]['env']['CI_PROOF_BRANCH'], "${{ github.event_name == 'workflow_dispatch' && inputs.dry_run && github.ref_name || 'main' }}")
        ci_jobs = workflow('ci.yml')['jobs']
        application = next(step for step in ci_jobs['prepare']['steps'] if step.get('id') == 'application')
        self.assertEqual(application['with']['path'].splitlines(), ['.wippy/cache', '${{ steps.setup.outputs.lua-path }}'])
        self.assertTrue(application['with']['key'].endswith('${{ steps.key.outputs.fingerprint }}'))
        self.assertNotIn('github.job', application['with']['key'])
        self.assertNotIn('strategy.job-index', application['with']['key'])
        for name in ('lint', 'boot', 'tests'):
            self.assertEqual(ci_jobs[name]['needs'], 'prepare')
            self.assertEqual(ci_jobs[name]['runs-on'], 'ubuntu-24.04')
            self.assertTrue(any(step.get('run') == 'make ci-import' for step in ci_jobs[name]['steps']))
        darwin = [row for row in release['build']['strategy']['matrix']['include'] if row['goos'] == 'darwin']
        self.assertEqual({row['goarch'] for row in darwin}, {'amd64', 'arm64'})
        commands = subprocess.check_output(['make', '--no-print-directory', '-n', 'release-compile'], cwd=ROOT, text=True)
        for forbidden in ('process_guard.py', 'tests/run.py', 'tests/boot.py', 'unittest', 'flock '):
            self.assertNotIn(forbidden, commands)
        self.assertIn('bee-release-builder build', commands)
        self.assertIn('python3 build/release_builder.py', commands)
        self.assertIn('verify_target.py', commands)

    def test_gate_rejects_skipped_cancelled_and_failed_checks(self):
        for status in ('failure', 'cancelled', 'skipped'):
            with patch.dict(os.environ, {'CHECK_RESULTS': json.dumps({'lint': {'result': status}})}), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(ValueError):
                    ci.gate()


if __name__ == '__main__':
    unittest.main()
