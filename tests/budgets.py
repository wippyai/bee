"""Entry and suite deadlines derived from recorded execution cost."""
import argparse
import json
import math
from pathlib import Path

PATH = Path(__file__).with_name('budgets.json')


def load():
    return json.loads(PATH.read_text()) if PATH.exists() else {}


def ceiling(meta):
    value = meta.get('timeout') or '30s'
    return float(value.removesuffix('s'))


def entry(meta, identity, costs):
    limit = ceiling(meta)
    observed = costs.get(identity)
    return min(limit, max(5, math.ceil(observed * 2 + 5))) if observed is not None else limit


def suites(documents, selected, costs):
    totals = {}
    for document in documents:
        for item in document.get('entries', []):
            meta = item.get('meta', {})
            identity = document['namespace'] + ':' + item['name']
            if meta.get('type') == 'test' and identity in selected:
                suite = meta.get('suite', 'other')
                totals[suite] = totals.get(suite, 0) + costs.get(identity, ceiling(meta))
    return {suite: max(30, math.ceil(seconds * 2 + 30)) for suite, seconds in totals.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path, nargs='+')
    args = parser.parse_args()
    costs = {}
    for path in args.results:
        report = json.loads(path.read_text())
        if any(result['code'] for result in report['results']):
            parser.error(f'{path}: budgets require a passing run')
        for result in report['results']:
            for identity, elapsed in result['durations'].items():
                if not math.isfinite(elapsed) or elapsed < 0:
                    parser.error(f'{path}: invalid cost for {identity}')
                costs[identity] = max(costs.get(identity, 0), elapsed)
    PATH.write_text(json.dumps(dict(sorted(costs.items())), indent=2) + '\n')


if __name__ == '__main__':
    main()
