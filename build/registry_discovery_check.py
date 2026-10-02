# SPDX-License-Identifier: MIT
"""Reject registry decisions derived from ID spelling; exceptions are exact expressions."""
import json
import re
from pathlib import Path
from lua_boundary_check import TOKENS

ROOT = Path(__file__).resolve().parents[1]
# Preserve quoted strings used as patterns, but ignore comments and long examples.
IGNORED = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]', re.S)
CALL = re.compile(r'(\(?[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\)?)\s*:\s*(match|find|sub|gsub)\s*\(')
STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')
IDENTITY = re.compile(r'(?:^|[._])(?:id|ref|target|entry|binding|namespace|component|destination|value|raw|owner|name|token|actor|checked|resource)(?:$|[._])')


def production_paths(root):
    return sorted([*(root / 'src').rglob('*.lua'), *(root / 'modules').glob('*/src/**/*.lua')])


def findings(source):
    source = TOKENS.sub(lambda match: match[0] if match[0].startswith(('"', "'")) else '\n' * match[0].count('\n'), source)
    masked = STRINGS.sub(lambda match: ' ' * len(match[0]), source)
    result = []

    def add(start, end):
        expression = re.sub(r'\s+', ' ', source[start:end]).strip()
        result.append({'line': source[:start].count('\n') + 1, 'expression': expression})

    for call in CALL.finditer(masked):
        start = call.end()
        depth, index, quote = 1, start, None
        while index < len(source) and depth:
            char = source[index]
            if quote:
                if char == '\\':
                    index += 1
                elif char == quote:
                    quote = None
            elif char in '\"\'':
                quote = char
            elif char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
            index += 1
        argument = source[start:index - 1]
        literals = [match[0][1:-1] for match in STRINGS.finditer(argument)]
        receiver, method = call[1].strip('()'), call[2]
        suspicious = False
        if method in {'match', 'find'} and literals and re.match(r'''\s*["']''', argument):
            pattern = literals[0]
            # Namespaced literal patterns, including non-Bee namespaces.
            suspicious = bool(re.search(r'^\^?[A-Za-z][A-Za-z0-9_-]*(?:%\.|\[\.\]|/|:|\.)', pattern))
            if IDENTITY.search(receiver):
                suspicious |= pattern in {'^([^:]+):', ':([^:]+)$', '^([^:]+):[^:]+$'}
                suspicious |= '%.binding:' in pattern
        if method == 'sub' and re.match(r'\s*1\s*,', argument):
            suffix = source[index:index + 100]
            suspicious = bool(IDENTITY.search(receiver) and re.search(r'#\s*[\w.]*(?:prefix|PREFIX)\b', argument))
            suspicious |= bool('namespace' in receiver.lower() and '#' in argument)
            suspicious |= bool(re.match(r'\s*[~=]=\s*["\'][A-Za-z][^"\']*[.:/]', suffix))
        if method == 'gsub' and literals and IDENTITY.search(receiver):
            suspicious = literals[0] == ':'
        if literals and re.match(r'^\^?(?:https?|sha256(?:-tree-v1)?|bs|bw|catalog|driver|provider|notifications|gitdir|refs|generated|localhost|docs|modules)(?:[:/%.]|\[)', literals[0]):
            suspicious = False
        if method in {'match', 'find'} and not IDENTITY.search(receiver) :
            suspicious = False
        if method == 'sub' and re.match(r'\s*[~=]=\s*["\'](?:sha256:|sha256[.]|sha256-tree-v1:|bs:|bw:)', source[index:index + 100]):
            suspicious = False
        if receiver in {'actor', 'actor_raw', 'caller_token', 'binding.subject'}:
            suspicious = False
        if method == 'sub' and 'sibling_prefix' in argument:
            suspicious = False
        if method == 'sub':
            prefix_ref = re.search(r'#\s*([\w.]+)', argument)
            declared = prefix_ref and re.search(re.escape(prefix_ref[1]) + r'''\s*=\s*["']([^"']+)["']''', source)
            if declared and declared[1].endswith('/'):
                suspicious = False
        if method == 'sub' and not IDENTITY.search(receiver):
            suspicious = False
        if suspicious:
            add(call.start(), index)
    for match in re.finditer(r'\b(?:\w*namespace\w*|\w*_ns)\s*\.\.\s*["\']:["\'](?:\s*\.\.\s*[\w.]+)?', source, re.I):
        add(match.start(), match.end())
    for match in re.finditer(r'\[\s*["\']\.(?:ns|namespace|name)["\']\s*\]\s*=\s*[^,}\n]+', source):
        add(match.start(), match.end())
    for literal in STRINGS.finditer(source):
        for decision in re.finditer(r'resource\s+matches\s+"(\^[^"\n]*:[^"\n]*)"', literal[0]):
            pattern = decision[1]
            if any(pattern.startswith(prefix) for prefix in ('^bee[.]application:', '^bs:', '^bw:')):
                continue  # Persisted actor/work wire formats, not registry entries.
            add(literal.start() + decision.start(), literal.start() + decision.end())
    return sorted(result, key=lambda item: (item['line'], item['expression']))


def unreviewed(path, issues, allowlist):
    for item in allowlist:
        if not item.get('reason') or not isinstance(item.get('count'), int) or item['count'] < 1 or set(item) != {'path', 'expression', 'reason', 'count'}:
            raise ValueError('discovery allowlist entries require an exact path, expression and review reason')
    allowed = {(item['path'], item['expression']) for item in allowlist}
    return [item for item in issues if (path, item['expression']) not in allowed]


def audit(root=ROOT):
    allowlist = json.loads((root / 'build/registry_discovery_allowlist.json').read_text())
    failures, used = [], {}
    for path in production_paths(root):
        relative = str(path.relative_to(root))
        issues = findings(path.read_text())
        for item in issues:
            key = (relative, item['expression'])
            used[key] = used.get(key, 0) + 1
        failures.extend(f"{relative}:{item['line']}: registry discovery by name: {item['expression']}"
                        for item in unreviewed(relative, issues, allowlist))
    for item in allowlist:
        if used.get((item['path'], item['expression']), 0) != item['count']:
            failures.append(f"changed discovery allowlist occurrence count: {item['path']}: {item['expression']}")
    return failures


def main():
    failures = audit()
    for issue in failures:
        print(issue)
    print(f'Registry discovery: {len(failures)} violations')
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
