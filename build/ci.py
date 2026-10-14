"""Make-owned CI fingerprints, prepared artifacts and release verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT / '.wippy/prepared.json'
PREPARED = ROOT / '.wippy/prepared.tar'


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def fingerprint(paths, extra=''):
    digest = hashlib.sha256(extra.encode())
    for path in sorted(set(paths)):
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def application_key():
    names = run('git', 'ls-files', 'src', 'modules', 'tests/lua', 'tests/fixtures/gateway_clock',
                'tests/fixtures/resource_clock', 'tests/fixtures/memory', 'tests/fixtures/harness/host.yaml',
                'tests/compose.py', 'tests/locked.py', 'tests/.wippy.yaml',
                'tests/wippy.lock', 'tests/requirements.txt', 'build/ci.py', 'build/prepare.py',
                'build/lua_seed.py', 'build/binary_identity.py', 'build/release_builder.py', 'build/tools.py', 'Makefile',
                'wippy.yaml', 'wippy.lock', '.wippy.yaml', 'resources').splitlines()
    paths = [ROOT / name for name in names if (ROOT / name).is_file()]
    manifest = json.loads((ROOT / 'wippy.build.json').read_text())
    for pack in manifest['application']['packs']:
        if pack['module'] == manifest['application']['module']:
            pack.pop('sha256', None)
    return fingerprint(paths, json.dumps(manifest, sort_keys=True, separators=(',', ':')))


def tools_outputs(target, host=None):
    if host is None:
        key = run('make', '--no-print-directory', 'tools-key')
    else:
        import tools
        manifest = json.loads((ROOT / 'wippy.build.json').read_text())
        builder = run('make', '--no-print-directory', 'builder-version')
        goos, goarch = host.split('/')
        platform = {'GOOS': goos, 'GOARCH': goarch, 'GOAMD64': 'v1' if goarch == 'amd64' else '',
                    'GOARM': '', 'CGO_ENABLED': '1', 'CC': 'gcc', 'CXX': 'g++'}
        key = tools.content_key(tools.inputs(manifest, builder, platform))
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
    manifest = json.loads((ROOT / 'wippy.build.json').read_text())
    inputs = [ROOT / name for name in ('build/tools.py', 'build/release_builder.py', 'native/go.sum')]
    targets = "darwin/amd64+arm64" if target.startswith("darwin/") else target
    bundle = fingerprint(inputs, key + targets)
    import tools
    platform = tools.platform_inputs() if host is None else platform
    system = {'linux': 'Linux', 'darwin': 'macOS'}[platform['GOOS']]
    architecture = {'amd64': 'x64', 'arm64': 'arm64'}[platform['GOARCH']]
    distro = '-ubuntu24' + ('-arm64' if architecture == 'arm64' else '') if system == 'Linux' else ''
    prefix = f'setup-go-{system}-{architecture}{distro}-go-{manifest["runtime"]["go"]}-'
    go_cache = Path.home() / ('Library/Caches/go-build' if system == 'macOS' else '.cache/go-build')
    return {'go': manifest['runtime']['go'], 'tools-key': key,
            'tools-path': str(cache / 'bee-tools' / key), 'lua-path': str(cache / 'bee-lua' / key),
            'runtime': manifest['runtime']['version'],
            'cache-key': prefix + bundle, 'cache-prefix': prefix,
            'go-path': str(Path.home() / 'go/pkg/mod') + '\n' + str(go_cache)}


def plan_warm():
    repository = os.environ['GITHUB_REPOSITORY']
    caches = json.loads(run('gh', 'api', '--paginate', '--slurp',
                           f'repos/{repository}/actions/caches?key=setup-go-&per_page=100'))
    refs = {'refs/heads/main', os.environ['GITHUB_REF']}
    available = {item['key'] for page in caches for item in page['actions_caches'] if item['ref'] in refs}
    rows = [] if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' else [('linux', 'amd64', 'ubuntu-24.04', 'linux/amd64'),
            ('darwin', 'arm64', 'macos-26', 'darwin/arm64')]
    missing = [{'goos': goos, 'goarch': goarch, 'runner': runner}
               for goos, goarch, runner, host in rows
               if tools_outputs(goos + '/' + goarch, host)['cache-key'] not in available]
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        print('matrix=' + json.dumps({'include': missing}), file=output)
        print('required=' + str(bool(missing)).lower(), file=output)
    print('Platforms needing pinned cache warmup: ' + json.dumps(missing))


def record_inputs():
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps({'source_fingerprint': application_key()}))


def verify_prepared():
    record = json.loads(RECORD.read_text())
    if record.get('consumer_fingerprint') != application_key():
        raise ValueError('prepared checks do not cover the current inputs; import their CI artifact')
    print('Application and fixture lint verified by preparation')


def export():
    PREPARED.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(PREPARED, 'w') as archive:
        for name in ('.wippy/release-module', '.wippy/vendor', '.wippy/lua-cache',
                     '.wippy/cache', '.wippy/prepared.json', 'tests/.wippy/composition', 'tests/.wippy/vendor',
                     'tests/lua', 'dist/bee.wapp', 'wippy.build.json', 'src/env/identity/_index.yaml'):
            path = Path(os.environ.get('LUA_CACHE', ROOT / name)) if name == '.wippy/lua-cache' else ROOT / name
            if path.exists():
                archive.add(path, arcname=name, filter=lambda item: None if item.name == '.wippy/cache/application.tar' else item)


    import shutil
    (ROOT / '.wippy/cache').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(PREPARED, ROOT / '.wippy/cache/application.tar')


def restore_prepared():
    import shutil
    shutil.copyfile(ROOT / '.wippy/cache/application.tar', PREPARED)


def import_prepared():
    with tarfile.open(PREPARED) as archive:
        record = json.load(archive.extractfile('.wippy/prepared.json'))
        if record['source_fingerprint'] != application_key():
            raise ValueError('prepared application does not match current source inputs')
        archive.extractall(ROOT, filter='data')
    record['consumer_fingerprint'] = application_key()
    RECORD.write_text(json.dumps(record))
    if os.environ.get('GITHUB_ENV'):
        identity = json.loads((ROOT / 'src/env/identity/_index.yaml').read_text())
        revision = next(entry['data']['source_revision'] for entry in identity['entries'] if entry['name'] == 'binary_identity')
        with open(os.environ['GITHUB_ENV'], 'a') as environment:
            print('REVISION=' + revision, file=environment)
            print('CI_PREPARED=1', file=environment)


def require_ci():
    sha = run('git', 'rev-parse', 'HEAD')
    repository = os.environ['GITHUB_REPOSITORY']
    runs = json.loads(run('gh', 'api', f'repos/{repository}/actions/workflows/ci.yml/runs?head_sha={sha}&status=success&per_page=100'))['workflow_runs']
    # Main CI is the trusted release gate. Manual dispatches prove the same path
    # without permitting a tag publication from a feature-branch CI run.
    expected_branch = os.environ.get('CI_PROOF_BRANCH', 'main')
    candidates = [item for item in runs if item['head_sha'] == sha and item['head_branch'] == expected_branch
                  and item['event'] in ('push', 'workflow_dispatch') and item['conclusion'] == 'success']
    if not candidates:
        raise ValueError(f'no successful ci.yml run on {expected_branch} at exact SHA {sha}')
    ci = max(candidates, key=lambda item: item['id'])
    artifacts = json.loads(run('gh', 'api', f'repos/{repository}/actions/runs/{ci["id"]}/artifacts?per_page=100'))['artifacts']
    name = 'bee-application-' + application_key()
    if not any(item['name'] == name and not item['expired'] for item in artifacts):
        raise ValueError('successful CI has no retained prepared application: ' + name)
    print(f'Accepted ci.yml run {ci["id"]} on {expected_branch} at {sha}')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        print(f'run-id={ci["id"]}\nartifact={name}', file=output)


def warm(target):
    manifest = json.loads((ROOT / 'wippy.build.json').read_text())
    directory = ROOT / '.wippy/warm'
    directory.mkdir(exist_ok=True)
    (directory / 'go.mod').write_bytes((ROOT / '.wippy/bin/wippy.go.mod').read_bytes())
    (directory / 'go.sum').write_bytes((ROOT / '.wippy/bin/wippy.go.sum').read_bytes())
    packages = [manifest['runtime']['module'] + '/cmd/app'] + [row['package'] for row in manifest['native']]
    targets = ['darwin/arm64', 'darwin/amd64'] if target.startswith('darwin/') else [target]
    for selected in targets:
        goos, goarch = selected.split('/')
        environment = dict(os.environ, GOOS=goos, GOARCH=goarch, CGO_ENABLED='1')
        subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-tags',
                        ','.join(manifest['runtime']['tags']), *sorted(set(packages))],
                       cwd=directory, env=environment, check=True)


def package(target, version):
    if not re.fullmatch(r'(linux|darwin)/(amd64|arm64)', target):
        raise ValueError('unsupported release target')
    target = target.replace('/', '-')
    archive = f'bee-{target}.tar.gz'
    subprocess.run(['.wippy/bin/wippy-builder', 'package', 'dist/bee', '-o', 'dist/' + archive], cwd=ROOT, check=True)
    pack = ROOT / 'dist/bee.wapp'
    digest = hashlib.sha256(pack.read_bytes()).hexdigest()
    (ROOT / f'dist/bee-{target}.wapp.sha256').write_text(f'{digest}  bee-{version}.wapp\n')
    archive_digest = hashlib.sha256((ROOT / 'dist' / archive).read_bytes()).hexdigest()
    (ROOT / f'dist/{archive}.sha256').write_text(f'{archive_digest}  {archive}\n')
    if target == 'linux-amd64':
        (ROOT / f'dist/bee-{version}.wapp').write_bytes(pack.read_bytes())
        (ROOT / f'dist/bee-{version}.wapp.sha256').write_text(f'{digest}  bee-{version}.wapp\n')


def verify_release():
    directory = ROOT / 'dist'
    proofs = list(directory.glob('bee-*.wapp.sha256'))
    if len(proofs) != 5:
        raise ValueError('release needs the pack checksum and all four platform pack proofs')
    for proof in proofs:
        digest, name = proof.read_text().strip().split()
        if Path(name).name != name or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError('embedded release pack checksum mismatch: ' + proof.name)


def publish(version):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?', version):
        raise ValueError('invalid release version')
    directory = ROOT / 'dist'
    assets = [str(path) for pattern in ('*.tar.gz', '*.tar.gz.sha256', '*.wapp') for path in sorted(directory.glob(pattern))]
    assets.append(str(directory / f'bee-{version}.wapp.sha256'))
    subprocess.run(['gh', 'release', 'create', 'v' + version, '--repo', os.environ['GITHUB_REPOSITORY'],
                    '--title', 'Bee ' + version, '--generate-notes', '--latest', *assets], check=True)


def rosetta():
    command = ['/usr/bin/arch', '-x86_64', '/usr/bin/uname', '-m']
    if subprocess.run(command, capture_output=True).returncode:
        subprocess.run(['sudo', '/usr/sbin/softwareupdate', '--install-rosetta', '--agree-to-license'], check=True)
    subprocess.run(command, check=True)


def gate():
    results = json.loads(os.environ['CHECK_RESULTS'])
    for name, result in results.items():
        print(name, result['result'])
    if any(result['result'] != 'success' and not (name == 'warm' and result['result'] == 'skipped'
                                                 and os.environ.get('WARM_REQUIRED') == 'false')
           for name, result in results.items()):
        raise ValueError('a required check failed, was cancelled, or was skipped')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('application-key', 'record-inputs', 'verify-prepared', 'tools-outputs', 'export', 'import', 'restore-prepared', 'require-ci', 'warm', 'package', 'gate', 'plan-warm', 'verify-release', 'publish', 'rosetta'))
    parser.add_argument('--target', default='linux/amd64')
    parser.add_argument('--version', default='0.2.0-dev')
    args = parser.parse_args()
    if args.command == 'application-key':
        print(application_key())
    elif args.command == 'tools-outputs':
        for name, value in tools_outputs(args.target).items():
            print(f'{name}<<BEE_OUTPUT\n{value}\nBEE_OUTPUT' if '\n' in value else f'{name}={value}')
    elif args.command == 'warm':
        warm(args.target)
    elif args.command == 'package':
        package(args.target, args.version)
    elif args.command == 'publish':
        publish(args.version)
    else:
        {'record-inputs': record_inputs, 'verify-prepared': verify_prepared, 'export': export, 'restore-prepared': restore_prepared, 'import': import_prepared, 'require-ci': require_ci, 'gate': gate, 'plan-warm': plan_warm, 'verify-release': verify_release, 'rosetta': rosetta}[args.command]()


if __name__ == '__main__':
    main()
