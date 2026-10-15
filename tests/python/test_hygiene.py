"""Repository hygiene rules distinguish comments, program data and domain exceptions."""
import os
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from lupa.lua54 import LuaRuntime
from build import hygiene


def address(*parts):
    return '.'.join(map(str, parts))


def home(user):
    return '/'.join(('', 'home', user, 'project'))


class HygieneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = LuaRuntime()

    def findings(self, path, text, allowed=()):
        data = text.encode() if isinstance(text, str) else text
        return hygiene.check_file(path, data, set(allowed), self.lua)

    def test_editorial_words_in_each_comment_language(self):
        for path, marker in [('a.lua', '--'), ('a.py', '#'), ('a.go', '//'),
                             ('a.sh', '#'), ('a.yml', '#'), ('a.yaml', '#'), ('Makefile', '#')]:
            for word in ('now', 'previously', 'no longer', 'fixed', 'added', 'workaround',
                         'temporary', 'for now', 'hack', 'TODO', 'FIXME', 'XXX', 'legacy'):
                with self.subTest(path=path, word=word):
                    matches = self.findings(path, '\n' + marker + ' ' + word + ' behavior\n')
                    self.assertEqual(len(matches), 1)
                    self.assertIn(path + ':2: editorial-comment:', matches[0])
            self.assertEqual(self.findings(path, marker + ' Validate the input.'), [])

    def test_comment_markers_in_strings_are_program_data(self):
        cases = {
            'a.lua': 'local s = "-- TODO"\nlocal t = [=[-- fixed]=]\n',
            'a.go': 'var s = "// TODO"\nvar t = `/* fixed */`\n',
            'a.py': 's = "# TODO"\nt = """# fixed\n# hack"""\n',
            'a.sh': 'echo "# TODO"\necho \'# fixed\'\necho word#hack\n',
            'Makefile': '\techo "# TODO"\n',
            'a.yml': 'text: "# TODO"\nscript: |\n  # fixed\n',
        }
        for path, text in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.findings(path, text), [])

    def test_shell_heredoc_body_is_data_and_following_comments_are_checked(self):
        text = "cat <<'TEXT'\n# TODO\nTEXT\n# FIXME\n"
        matches = self.findings('a.sh', text)
        self.assertEqual(len(matches), 1)
        self.assertIn('a.sh:4: editorial-comment:', matches[0])
        quoted = 'echo "<<EOF"\n# TODO\n'
        self.assertIn('a.sh:2: editorial-comment:', self.findings('a.sh', quoted)[0])
        self.assertIn('editorial-comment', self.findings('Makefile', 'A := value#TODO')[0])

    def test_inline_and_multiline_comments_have_source_lines(self):
        for path, text in [
            ('a.lua', 'local a = 1 -- TODO\n'),
            ('a.py', 'a = "# okay" # TODO\n'),
            ('a.go', 'var a = 1 // TODO\n'),
            ('a.sh', 'echo "ready" # TODO\n'),
            ('a.yml', 'text: "ready" # TODO\n'),
            ('Makefile', 'A := value # TODO\n'),
        ]:
            self.assertIn(':1: editorial-comment:', self.findings(path, text)[0])
        for path, text in [('a.lua', '--[=[\nTODO\n]=]'),
                           ('a.go', '/*\n * TODO\n */')]:
            self.assertIn(':2: editorial-comment:', self.findings(path, text)[0])

    def test_lua_statements_compile_without_execution(self):
        for statement in ('local value = 3', 'value = false', 'object.field = 1',
                          'return value', 'call()', 'receiver:run("x")',
                          'if ready then call() end', 'for i=1,3 do call(i) end',
                          'function run() return 1 end', 'error("must not execute")'):
            with self.subTest(statement=statement):
                self.assertIn(':2: commented-code:', self.findings('a.lua', '\n-- ' + statement)[0])
        for prose in ('local state can become available.', 'else is stale traffic.',
                      'function still executes under a scope.', 'terminal:status() observes completion.',
                      'meta.sync = RECEIVER. This selects the destination.', 'Validate input.', ''):
            self.assertEqual(self.findings('a.lua', '-- ' + prose), [])
        self.assertEqual(self.findings('a.lua', 'local value = 3\nreturn value'), [])
        self.assertEqual(self.findings('a.py', '# call()'), [])
        self.assertIn('commented-code', self.findings('a.lua', '--[[call()]]')[0])

    def test_private_network_boundaries_and_documentation_addresses(self):
        blocked = [(100, 64, 0, 0), (100, 127, 255, 255), (10, 0, 0, 0),
                   (10, 255, 255, 255), (192, 168, 0, 0), (192, 168, 255, 255)]
        public = [(100, 63, 255, 255), (100, 128, 0, 0), (11, 0, 0, 1),
                  (192, 167, 255, 255), (192, 169, 0, 0), (192, 0, 2, 1),
                  (198, 51, 100, 1), (203, 0, 113, 1), (127, 0, 0, 1)]
        for parts in blocked:
            self.assertIn(':2: private-reference:', self.findings('note.md', '\nhttps://' + address(*parts) + ':443')[0])
        for parts in public:
            self.assertEqual(self.findings('note.md', address(*parts)), [])
        self.assertEqual(self.findings('note.md', '10.0.0\n999.999.999.999'), [])

    def test_personal_paths_names_repositories_and_binary_content(self):
        names = ['acme-build', 'example-private']
        os.environ['BEE_HYGIENE_PRIVATE_TERMS'] = ','.join(names)
        self.addCleanup(os.environ.pop, 'BEE_HYGIENE_PRIVATE_TERMS', None)
        for name in names:
            for text in (name, 'https://github.com/example/' + name + '.git', name.upper()):
                self.assertIn('private-reference', self.findings('note.md', text)[0])
        self.assertIn('private-reference', self.findings('note.md', home('user'))[0])
        self.assertIn('private-reference', self.findings('fixture.bin', b'\x00' + home('user').encode())[0])
        self.assertIn('private-reference', self.findings(names[0] + '/note.md', '')[0])
        self.assertEqual(self.findings('note.md', '/work/project\nhttps://example.org\nacme-buildings'), [])

    def test_size_boundaries_and_the_single_asset_exception(self):
        for suffix in ('lua', 'py', 'go'):
            self.assertEqual(self.findings('a.' + suffix, b' ' * hygiene.SOURCE_LIMIT), [])
            self.assertIn('source-size', self.findings('a.' + suffix, b' ' * (hygiene.SOURCE_LIMIT + 1))[0])
        self.assertEqual(self.findings('a.bin', b'\0' * hygiene.FILE_LIMIT), [])
        self.assertIn('file-size', self.findings('a.bin', b'\0' * (hygiene.FILE_LIMIT + 1))[0])
        self.assertEqual(self.findings('assets/bee.gif', b'\0' * (hygiene.FILE_LIMIT + 1)), [])
        self.assertIn('file-size', self.findings('other/bee.gif', b'\0' * (hygiene.FILE_LIMIT + 1))[0])
        self.assertIn('source-size', self.findings('a.lua', b' ' * (hygiene.SOURCE_LIMIT + 1), [('a.lua', '')])[0])

    def test_source_size_exception_is_explicit_and_approvals_only(self):
        path = 'tests/lua/approvals/service_test.lua'
        data = b' ' * (hygiene.SOURCE_LIMIT + 1)
        self.assertTrue(self.findings(path, data))
        self.assertEqual(self.findings(path, data, [(path, 'source-size')]), [])
        self.assertTrue(self.findings('other.lua', data, [(path, 'source-size')]))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'build').mkdir()
            entry = dict(path=path, text='source-size', reason='approvals lane in flight')
            (root / hygiene.ALLOWLIST).write_text(json.dumps([entry]))
            self.assertEqual(hygiene.load_allowlist(root), {(path, 'source-size')})
            for change in ({'path': 'other.lua'}, {'reason': 'large source'}):
                (root / hygiene.ALLOWLIST).write_text(json.dumps([dict(entry, **change)]))
                with self.assertRaises(ValueError):
                    hygiene.load_allowlist(root)

    def test_allowlist_requires_exact_path_and_text(self):
        for text in ('-- fixed transport bound', '-- document()', address(100, 64, 0, 1)):
            allowed = [('a.lua', text)]
            self.assertEqual(self.findings('a.lua', text, allowed), [])
            self.assertTrue(self.findings('b.lua', text, allowed))
            changed = text + ('; other()' if text == '-- document()' else ' more')
            self.assertTrue(self.findings('a.lua', changed, allowed))

    def test_tracked_working_tree_content_and_stale_exceptions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'build').mkdir()
            (root / hygiene.ALLOWLIST).write_text('[]')
            (root / 'tracked.lua').write_text('-- Contract description\n')
            (root / 'untracked.lua').write_text('-- TODO\n')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', 'add', 'build', 'tracked.lua'], cwd=root, check=True)
            self.assertEqual(hygiene.scan(root), [])
            (root / 'tracked.lua').write_text('-- TODO\n')
            self.assertIn('tracked.lua:1:', hygiene.scan(root)[0])
            entry = {'path': 'tracked.lua', 'text': '-- TODO', 'reason': 'Domain fixture.'}
            (root / hygiene.ALLOWLIST).write_text(json.dumps([entry], indent=2) + '\n')
            self.assertEqual(hygiene.scan(root), [])
            (root / 'tracked.lua').write_text('local value = 1 -- TODO\n')
            self.assertEqual(hygiene.scan(root), [])
            (root / 'tracked.lua').write_text('-- Description\n')
            self.assertIn('stale-allowlist', hygiene.scan(root)[0])
            for bad in ({'path': 'x', 'text': 'x'}, dict(entry, reason=''), dict(entry, path='*.lua'), 42):
                (root / hygiene.ALLOWLIST).write_text(json.dumps([bad]))
                with self.assertRaises(ValueError):
                    hygiene.load_allowlist(root)

    def test_command_exit_status_and_diagnostics(self):
        for findings, expected in [([], 0), (['a.lua:2: commented-code: -- call()'], 1)]:
            output = io.StringIO()
            with patch.object(hygiene, 'scan', return_value=findings), contextlib.redirect_stdout(output):
                self.assertEqual(hygiene.main(), expected)
            self.assertIn('Hygiene:', output.getvalue())
            if findings:
                self.assertIn(findings[0], output.getvalue())

    def test_local_and_existing_ci_lint_include_hygiene(self):
        for target in ('lint', 'ci-lint'):
            output = subprocess.check_output(['make', '-n', target], cwd=hygiene.ROOT, text=True)
            self.assertIn('python3 -m build.hygiene', output)


if __name__ == '__main__':
    unittest.main()
