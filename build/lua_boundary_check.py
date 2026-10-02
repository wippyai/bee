# SPDX-License-Identifier: MIT
"""Reject Lua casts and any annotations in production and disposable fixtures."""
import ast
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKENS = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)


def code(source):
    return TOKENS.sub(lambda match: '\n' * match[0].count('\n'), source)


def embedded(path):
    source = path.read_text()
    if path.suffix == ".py":
        literals = [node.value for node in ast.walk(ast.parse(source))
                    if isinstance(node, ast.Constant) and isinstance(node.value, str)]
    else:
        literals = re.findall(r"`([^`]*?)`", source, re.S)
        for literal in re.findall(r'"(?:\\.|[^"\\])*"', source):
            try:
                literals.append(json.loads(literal))
            except ValueError:
                continue
    return "\n".join(value for value in literals
                     if re.search(r"local\s+(?:function\s+|[A-Za-z_]\w*\s*[=(])|function\s+[\w.:]+\s*\(|::\s*(?:\{|any\b)", value))


def scan(paths):
    casts, annotations = [], []
    for path in paths:
        source = code(path.read_text() if path.suffix == ".lua" else embedded(path))
        source = re.sub(r'::[A-Za-z_][A-Za-z0-9_]*::', '', source)
        for expression, result in [(r'::', casts), (r'\bany\b', annotations)]:
            for match in re.finditer(expression, source):
                result.append(f'{path.relative_to(ROOT)}:{source[:match.start()].count(chr(10)) + 1}')
    return casts, annotations


def main():
    failures = 0
    for label, paths in [('production', [*(ROOT / 'src').rglob('*.lua'), *(ROOT / 'modules').glob('*/src/**/*.lua')]),
                         ('fixtures', [*(ROOT / 'tests').rglob('*.lua'), *(ROOT / 'tests').rglob('*.py'), *(ROOT / 'tests').rglob('*.go')])]:
        casts, annotations = scan(paths)
        print(f'Lua boundary {label}: {len(casts)} casts, {len(annotations)} any tokens')
        for issue in casts + annotations:
            print(issue)
        failures += len(casts) + len(annotations)
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
