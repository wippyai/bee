"""Entry and suite deadlines derived from measured execution cost distributions.

Each entry keeps its recent passing costs. Its deadline is twice a high
percentile of them plus a fixed margin, never above the entry's declared
ceiling. An entry whose meta declares `latency: external` drives an external
runtime (Docker, a real CLI); its cost follows that runtime's latency tail, so
its budget needs more samples and reads the top of its own distribution. An
entry with too few samples keeps its declared ceiling.
"""
import argparse
import json
import math
from pathlib import Path

PATH = Path(__file__).parent / 'data/budgets.json'
CLASSES = {'internal': {'percentile': .95, 'samples': 5}, 'external': {'percentile': 1., 'samples': 10}}
RETAINED = 20


def load():
    return json.loads(PATH.read_text()) if PATH.exists() else {}


def ceiling(meta):
    value = meta.get('timeout') or '30s'
    return float(value.removesuffix('s'))


def latency(meta):
    value = meta.get('latency', 'internal')
    if value not in CLASSES:
        raise ValueError(f'unknown latency class {value!r}')
    return CLASSES[value]


def cost(meta, samples):
    """The class percentile of samples by nearest rank, or None below the class sample count."""
    policy = latency(meta)
    if not samples or len(samples) < policy['samples']:
        return None
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(policy['percentile'] * len(ordered)) - 1)]


def entry(meta, identity, costs):
    limit = ceiling(meta)
    observed = cost(meta, costs.get(identity))
    return min(limit, max(5, math.ceil(observed * 2 + 5))) if observed is not None else limit


def suites(documents, selected, costs):
    totals = {}
    for document in documents:
        for item in document.get('entries', []):
            meta = item.get('meta', {})
            identity = document['namespace'] + ':' + item['name']
            if meta.get('type') == 'test' and identity in selected:
                suite = meta.get('suite', 'other')
                observed = cost(meta, costs.get(identity))
                totals[suite] = totals.get(suite, 0) + (ceiling(meta) if observed is None else observed)
    return {suite: max(30, math.ceil(seconds * 2 + 30)) for suite, seconds in totals.items()}


def record(costs, reports):
    """Append each passing entry's cost, keeping the newest RETAINED samples.

    An entry the shard reports failed (an assertion, a timeout) contributes
    nothing: its cost is censored by the failure, not measured.
    """
    merged = {identity: list(samples) for identity, samples in costs.items()}
    for report in reports:
        for result in report['results']:
            failed = set(result['failed'])
            for identity, elapsed in result['durations'].items():
                if identity in failed:
                    continue
                if not math.isfinite(elapsed) or elapsed < 0:
                    raise ValueError(f'invalid cost for {identity}')
                merged.setdefault(identity, []).append(round(elapsed, 3))
    return {identity: samples[-RETAINED:] for identity, samples in sorted(merged.items())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path, nargs='+')
    args = parser.parse_args()
    reports = [json.loads(path.read_text()) for path in args.results]
    PATH.write_text(json.dumps(record(load(), reports), indent=2) + '\n')


if __name__ == '__main__':
    main()
