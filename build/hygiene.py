"""Check tracked working-tree content; exceptions match one path and exact text."""
import io
import ipaddress
import json
from pathlib import Path
import os
import re
import subprocess
import sys
import time
import tokenize

import yaml

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = 'build/hygiene_allowlist.json'
SOURCE_LIMIT = 65_536
FILE_LIMIT = 1_000_000
LARGE_ASSETS = {'assets/bee.gif'}
EDITORIAL = re.compile(
    r'\b(?:now|previously|no\s+longer|fixed|added|workaround|temporary|'
    r'for\s+now|hack|TODO|FIXME|XXX|legacy)\b', re.IGNORECASE)
# Private host and repository names stay outside the public tree: maintainers
# supply them through BEE_HYGIENE_PRIVATE_TERMS (comma-separated).
PRIVATE_TERMS_ENV = 'BEE_HYGIENE_PRIVATE_TERMS'
HOME = re.compile(r'/home/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*(?:/|\b)')
IPV4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
PRIVATE_NETS = tuple(ipaddress.ip_network(value) for value in
                     ('100.64.0.0/10', '10.0.0.0/8', '192.168.0.0/16'))
LUA_TOKENS = re.compile(
    r'(?P<block>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\])|(?P<comment>--[^\n]*)|'
    r'\[(?P<seq>=*)\[.*?\](?P=seq)\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
    re.DOTALL)
GO_TOKENS = re.compile(
    r'(?P<comment>//[^\n]*|/\*.*?\*/)|`[^`]*`|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
    re.DOTALL)
SHELL_TOKENS = re.compile(
    r'"(?:\\.|[^"\\])*"|\'[^\']*\'|\\.|(?P<comment>(?<![^\s;])\#[^\n]*)',
    re.DOTALL)


def mask_heredocs(text):
    """Preserve line positions while excluding shell here-document data."""
    result, pending = [], []
    for line in text.splitlines(keepends=True):
        if pending:
            delimiter, tabs = pending[0]
            if line.rstrip('\r\n').lstrip('\t' if tabs else '') == delimiter:
                pending.pop(0)
            result.append('\n' if line.endswith('\n') else '')
            continue
        result.append(line)
        quoted = [token.span() for token in SHELL_TOKENS.finditer(line)]
        for token in re.finditer(r"<<(-?)\s*(?:'([^']+)'|\"([^\"]+)\"|([\w]+))", line):
            if not any(start <= token.start() < end for start, end in quoted):
                pending.append((next(value for value in token.groups()[1:] if value), bool(token[1])))
    return ''.join(result)


def comments(path, text):
    """Yield line numbers and comment text, excluding quoted program data."""
    suffix = Path(path).suffix
    if Path(path).name == 'Makefile':
        for number, line in enumerate(text.splitlines(), 1):
            if line.startswith('\t'):
                for _, comment in comments('recipe.sh', line):
                    yield number, comment
            else:
                marker = re.search(r'(?<!\\)#', line)
                if marker:
                    yield number, line[marker.start():]
        return
    if suffix == '.py':
        try:
            for token in tokenize.generate_tokens(io.StringIO(text).readline):
                if token.type == tokenize.COMMENT:
                    yield token.start[0], token.string
        except (tokenize.TokenError, IndentationError):
            pass
        return
    if suffix in ('.yml', '.yaml'):
        chars = list(text)
        for token in yaml.scan(text, Loader=yaml.CLoader):
            if isinstance(token, yaml.tokens.ScalarToken):
                for index in range(token.start_mark.index, token.end_mark.index):
                    if chars[index] != '\n':
                        chars[index] = ' '
        masked = ''.join(chars)
        for number, (line, mask) in enumerate(zip(text.splitlines(), masked.splitlines()), 1):
            if '#' in mask:
                yield number, line[mask.index('#'):]
        return
    pattern = {'.lua': LUA_TOKENS, '.go': GO_TOKENS}.get(suffix, SHELL_TOKENS)
    if pattern is SHELL_TOKENS:
        text = mask_heredocs(text)
    line, position = 1, 0
    for token in pattern.finditer(text):
        line += text.count('\n', position, token.start())
        position = token.start()
        if token.lastgroup not in ('comment', 'block'):
            continue
        for offset, part in enumerate(token.group().splitlines()):
            yield line + offset, part.strip()


def lua_body(text):
    """Extract a whole comment line without accepting empty or nested comments."""
    body = re.sub(r'^--(?:\[=*\[)?\s*', '', text).strip()
    body = re.sub(r'\]=*\]$', '', body).strip()
    if not body or body.startswith('--') or body in (';', 'end', 'else', 'do', 'repeat'):
        return ''
    return body


def lua_statements(candidates):
    """Parse all candidate comments in one process, without executing source."""
    bodies = {comment: body for comment in candidates if (body := lua_body(comment))}
    if not bodies:
        return set()
    result = subprocess.run([str(ROOT / '.wippy/build/lua-parse')],
                            input=json.dumps(list(bodies.values())), text=True,
                            capture_output=True, check=True)
    parsed = json.loads(result.stdout)
    if (not isinstance(parsed, list) or len(parsed) != len(bodies)
            or any(type(value) is not bool for value in parsed)):
        raise ValueError('Lua parser returned an invalid batch result')
    return {comment for comment, valid in zip(bodies, parsed) if valid}


def private_names():
    terms = [term.strip() for term in os.environ.get(PRIVATE_TERMS_ENV, '').split(',') if term.strip()]
    if not terms:
        return None
    return re.compile(r'(?<![\w])(?:' + '|'.join(map(re.escape, terms)) + r')(?![\w])', re.IGNORECASE)


def private_reference(text):
    names = private_names()
    if (names and names.search(text)) or HOME.search(text):
        return True
    for match in IPV4.finditer(text):
        try:
            address = ipaddress.ip_address(match.group())
        except ValueError:
            continue
        if any(address in network for network in PRIVATE_NETS):
            return True
    return False


def load_allowlist(root):
    entries = json.loads((root / ALLOWLIST).read_text())
    if not isinstance(entries, list):
        raise ValueError('allowlist must be a list')
    allowed = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {'path', 'text', 'reason'} or not all(
                isinstance(value, str) and value.strip() and not any(c in value for c in '\r\n')
                for value in entry.values()):
            raise ValueError('each exception needs path, exact text and a one-line reason')
        path = Path(entry['path'])
        if path.is_absolute() or '..' in path.parts or any(c in entry['path'] for c in '*?['):
            raise ValueError('exception paths must be literal repository-relative paths')
        if entry['text'] == 'source-size' and (
                not entry['path'].startswith(('src/approvals/', 'tests/lua/approvals/'))
                or entry['reason'] != 'approvals lane in flight'):
            raise ValueError('source-size exceptions are restricted to the approvals lane')
        key = (entry['path'], entry['text'])
        if key in allowed:
            raise ValueError('duplicate exception: ' + entry['path'])
        allowed.add(key)
    return allowed


def check_file(path, data, allowed, lua):
    findings = []
    def report(line, rule, text):
        if (path, text.strip()) not in allowed:
            findings.append(f'{path}:{line}: {rule}: {text.strip()}')

    if len(data) > FILE_LIMIT and path not in LARGE_ASSETS:
        findings.append(f'{path}:1: file-size: {len(data)} bytes exceeds {FILE_LIMIT}')
    if (Path(path).suffix in ('.lua', '.py', '.go') and len(data) > SOURCE_LIMIT
            and (path, 'source-size') not in allowed):
        findings.append(f'{path}:1: source-size: {len(data)} bytes exceeds {SOURCE_LIMIT}')
    text = data.decode('utf-8', errors='replace')
    if private_reference(path):
        report(1, 'private-reference', path)
    exception_lines = {'"text": ' + json.dumps(exact, ensure_ascii=False) + ','
                       for _, exact in allowed} if path == ALLOWLIST else set()
    for number, line in enumerate(text.splitlines(), 1):
        serialized_exception = line.strip() in exception_lines
        if not serialized_exception and private_reference(line):
            report(number, 'private-reference', line)
    if Path(path).suffix in ('.lua', '.py', '.go', '.sh', '.yml', '.yaml') or Path(path).name == 'Makefile':
        for number, comment in comments(path, text):
            if EDITORIAL.search(comment):
                report(number, 'editorial-comment', comment)
            if path.endswith('.lua') and comment in lua:
                report(number, 'commented-code', comment)
    return findings


def scan(root):
    allowed = load_allowlist(root)
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    files = {}
    for path in filter(None, paths):
        file = root / path
        if not file.exists() and not file.is_symlink():
            continue
        files[path] = file.readlink().as_posix().encode() if file.is_symlink() else file.read_bytes()
    lua = lua_statements(comment for path, data in files.items() if path.endswith('.lua')
                         for _, comment in comments(path, data.decode('utf-8', errors='replace')))
    findings = []
    for path, data in files.items():
        findings.extend(check_file(path, data, allowed, lua))
    for path, exact in sorted(allowed):
        file = root / path
        present = False
        if path in paths and file.is_file():
            if exact == 'source-size':
                present = file.suffix in ('.lua', '.py', '.go') and file.stat().st_size > SOURCE_LIMIT
                if not present:
                    findings.append(f'{ALLOWLIST}:1: stale-allowlist: {path}: {exact}')
                continue
            text = file.read_text()
            present = exact in {line.strip() for line in text.splitlines()}
            if not present:
                present = exact in {comment for _, comment in comments(path, text)}
        if not present:
            findings.append(f'{ALLOWLIST}:1: stale-allowlist: {path}: {exact}')
    return findings


def main():
    started = time.monotonic()
    try:
        findings = scan(ROOT)
    except (OSError, ValueError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        print(f'{ALLOWLIST}:1: hygiene-configuration: {error}', file=sys.stderr)
        return 1
    for finding in findings:
        print(finding)
    print(f'Hygiene: {len(findings)} findings ({time.monotonic() - started:.2f}s)')
    return bool(findings)


if __name__ == '__main__':
    sys.exit(main())
