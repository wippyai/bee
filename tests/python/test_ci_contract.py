"""Exercise independent CI checks and the restore-only release workflow contract."""
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
from build import ci
from build import lua_seed

ROOT = Path(__file__).resolve().parents[2]


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
                record = json.dumps({'source_fingerprint': 'original'}).encode()
                entry = tarfile.TarInfo('.wippy/prepared.json')
                entry.size = len(record)
                output.addfile(entry, io.BytesIO(record))
            environment = root / 'environment'
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'PREPARED', archive), patch.object(ci, 'RECORD', root / '.wippy/prepared.json'), patch.object(ci, 'application_key', side_effect=['original', 'imported']), patch.dict(os.environ, {'GITHUB_ENV': str(environment)}, clear=True):
                ci.import_prepared()
                self.assertEqual(environment.read_text(), 'REVISION=prepared\n')

    def test_ci_tests_compose_without_lint_and_local_targets_still_check_fixtures(self):
        local = subprocess.check_output(['make', '--no-print-directory', '-n', 'test-shard', 'SHARD=1', 'CI_TESTS='], cwd=ROOT, text=True)
        self.assertIn('tests.runner.compose', local)
        self.assertIn('wippy lint', local)
        self.assertIn('unittest discover', local)
        remote = subprocess.check_output(['make', '--no-print-directory', '-n', 'test-shard', 'SHARD=1', 'CI_TESTS=1', 'TEST_CACHE_MODE=readonly'], cwd=ROOT, text=True)
        self.assertIn('tests.runner.compose', remote)
        self.assertIn('wippy install', remote)
        self.assertIn('--lua-cache-mode readonly', remote)
        self.assertNotIn('unittest discover', remote)
        self.assertNotIn('wippy lint', remote)
        self.assertNotIn('verify-prepared', remote)
        self.assertEqual(next(step['run'] for step in workflow('ci.yml')['jobs']['lint']['steps'] if step.get('name') == 'Python unit tests and corpus'), 'make ci-lint')

    def test_drivers_module_suites_run_in_their_own_harness_with_the_full_suite(self):
        commands = subprocess.check_output(['make', '--no-print-directory', '-n', 'test-drivers'], cwd=ROOT, text=True)
        harness = str(ROOT / 'drivers/test')
        self.assertIn(f'cd {harness} && ', commands)
        self.assertIn('wippy install', commands)
        self.assertIn('wippy lint', commands)
        self.assertIn('env -i ', commands)
        self.assertIn('wippy test', commands)
        self.assertIn('No tests found', commands)
        full = subprocess.check_output(['make', '--no-print-directory', '-n', 'test'], cwd=ROOT, text=True)
        self.assertIn(f'cd {harness} && ', full)
        self.assertIn('tests.runner.run', full)

    def test_profile_merge_rejects_other_sources_and_missing_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profiles = root / '.wippy/profiles'
            profiles.mkdir(parents=True)
            for name in ('strict', 'nonstrict', 'fixtures'):
                with tarfile.open(profiles / (name + '.tar'), 'w') as archive:
                    data = json.dumps({'profile': name, 'source_fingerprint': 'current' if name != 'fixtures' else 'old'}).encode()
                    entry = tarfile.TarInfo('.wippy/profile.json')
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'application_key', return_value='current'):
                with self.assertRaisesRegex(ValueError, 'fixtures'):
                    ci.merge_profiles()
                (profiles / 'fixtures.tar').unlink()
                with self.assertRaises(FileNotFoundError):
                    ci.merge_profiles()

    def test_seed_keeps_unchanged_entries_and_invalidates_changed_dependency_closures(self):
        entries = {
            'compile-a': {'entry_id': 'bee:a', 'source_hash': 'current', 'compile_fingerprint': 'a'},
            'old-a': {'entry_id': 'bee:a', 'source_hash': 'old', 'compile_fingerprint': 'old'},
            'compile-b': {'entry_id': 'bee:b', 'source_hash': 'b', 'compile_fingerprint': 'b',
                          'deps': [{'alias': 'a', 'id': 'bee:a', 'compile_fingerprint': 'a'}]},
            'old-b': {'entry_id': 'bee:b', 'source_hash': 'b', 'compile_fingerprint': 'old-b',
                      'deps': [{'alias': 'a', 'id': 'bee:a', 'compile_fingerprint': 'old'}]},
            'fixture': {'entry_id': 'bee.tests:a', 'source_hash': 'fixture', 'compile_fingerprint': 'fixture'},
        }
        selected = lua_seed.select_entries(entries, {'bee:a': {'source_hash': 'current', 'imports': {}}, 'bee:b': {'source_hash': 'b', 'imports': {'a': 'bee:a'}}}, {'bee:a', 'bee:b'})
        self.assertEqual(set(selected), {'compile-a', 'compile-b'})
        self.assertEqual(entries['old-a']['source_hash'], 'old')
        changed_imports = {'bee:a': {'source_hash': 'current', 'imports': {}},
                           'bee:b': {'source_hash': 'b', 'imports': {'renamed': 'bee:a'}}}
        self.assertEqual(set(lua_seed.select_entries(entries, changed_imports, {'bee:a', 'bee:b'})), {'compile-a'})

    def test_export_carries_generated_fixture_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ['tests/lua/threads/recovery.lua', 'tests/lua/threads/recovery_worker.lua',
                     'tests/lua/harness/host/_index.yaml']
            for name in names:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('generated fixture')
            archive = root / '.wippy/prepared.tar'
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'PREPARED', archive), patch.dict(os.environ, {}, clear=True):
                ci.export()
            with tarfile.open(archive) as output:
                for name in names:
                    self.assertEqual(output.extractfile(name).read(), b'generated fixture')

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
        self.assertEqual(len(caches), 3)
        self.assertTrue(all('/restore@' in step['uses'] for step in caches))
        self.assertNotIn('restore-keys', caches[0]['with'])
        self.assertEqual(caches[1]['with']['restore-keys'], '${{ steps.key.outputs.cache-prefix }}')
        self.assertEqual(caches[1]['with']['path'], '${{ steps.key.outputs.go-path }}')
        go = [step for step in steps if 'actions/setup-go@' in step.get('uses', '')]
        self.assertEqual(len(go), 1)
        self.assertFalse(go[0]['with']['cache'])
        self.assertTrue(any(step.get('run') == 'make tools' for step in steps))
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
        self.assertEqual(ci_jobs['prepare']['needs'], 'profiles')
        profiles = ci_jobs['profiles']
        self.assertNotIn('needs', profiles)
        self.assertEqual(profiles['strategy']['matrix']['profile'], ['strict', 'nonstrict', 'fixtures'])
        saves = [step for job in ci_jobs.values() for step in job['steps'] if 'actions/cache/save@' in step.get('uses', '') and 'Lua' in step.get('name', '')]
        self.assertEqual(len(saves), 1)
        self.assertEqual(saves[0]['with']['key'], '${{ steps.setup.outputs.lua-cache-key }}')
        for name in ('lint', 'boot', 'tests'):
            self.assertNotIn('needs', ci_jobs[name])
            self.assertEqual(ci_jobs[name]['runs-on'], 'ubuntu-24.04')
            self.assertFalse(any('actions/download-artifact@' in step.get('uses', '') for step in ci_jobs[name]['steps']))
            if name != 'lint':
                self.assertEqual(ci_jobs[name]['env']['TEST_CACHE_MODE'], 'readonly')
                self.assertEqual(ci_jobs[name]['env']['CI_TESTS'], '1')
        self.assertIn('profiles', ci_jobs['check']['needs'])
        self.assertIn('drivers', ci_jobs['check']['needs'])
        self.assertNotIn('needs', ci_jobs['drivers'])
        self.assertEqual([step['run'] for step in ci_jobs['drivers']['steps'] if 'run' in step], ['make test-drivers'])
        darwin = [row for row in release['build']['strategy']['matrix']['include'] if row['goos'] == 'darwin']
        self.assertEqual({row['goarch'] for row in darwin}, {'amd64', 'arm64'})
        commands = subprocess.check_output(['make', '--no-print-directory', '-n', 'release-compile'], cwd=ROOT, text=True)
        for forbidden in ('process_guard.py', 'tests.runner.run', 'tests.runner.boot', 'unittest', 'flock '):
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
