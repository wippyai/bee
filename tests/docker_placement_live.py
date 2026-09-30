"""Opt-in real Docker PTY and provider-turn acceptance; no credential output."""
from pathlib import Path
import argparse
import json
import os
import shutil
import socket
import subprocess
import sqlite3
import time
import yaml
import workspace

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ('claude', 'codex', 'agy', 'grok', 'muse', 'opencode')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--provider', choices=PROVIDERS, default='claude')
    parser.add_argument('--mode', choices=('window', 'session', 'restart'), default='window')
    parser.add_argument('--standalone', type=Path)
    args = parser.parse_args()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=True)
    network = 'bee-docker-proof-' + str(os.getpid())
    subprocess.run(['docker', 'network', 'create', '--label', 'bee.actor_ref=bee.docker-proof', network], check=True)
    try:
        net = json.loads(subprocess.check_output(['docker', 'network', 'inspect', network]))[0]
        interface = net['IPAM']['Config'][0]['Gateway']
        with socket.socket() as sock, workspace.fixture_workspace(unit_tests=False) as folder:
            sock.bind((interface, 0))
            address = interface + ':' + str(sock.getsockname()[1])
            sock.close()
            shutil.copytree(ROOT / 'tests/fixtures/docker_placement', folder / 'src/docker_proof')
            broker = folder / 'src/apps/broker.lua'
            broker.write_text(broker.read_text().replace('"Application did not become ready"', '"Application did not become ready: " .. tostring(item.failure_detail)'))
            def edit(file, name, change):
                path = folder / file
                doc = yaml.safe_load(path.read_text())
                entry = next(e for e in doc['entries'] if e['name'] == name)
                change(entry)
                path.write_text(yaml.safe_dump(doc, sort_keys=False))
            edit('src/_index.yaml', 'gateway_endpoint', lambda e: e['data'].update(address=address))
            edit('src/_index.yaml', 'gateway_listener', lambda e: e.update(addr=address))
            edit('src/_index.yaml', 'gateway_listener', lambda e: e['lifecycle'].update(auto_start=True))
            edit('modules/gateway/src/security/_index.yaml', 'readiness_policy', lambda e: e['policy'].update(expression=f'(action == "http_client.private_ip" && resource == "{interface}") || (action == "http_client.request" && resource == "http://{address}/ready")'))
            index = folder / 'src/docker_proof/_index.yaml'
            doc = yaml.safe_load(index.read_text())
            by_name = {e['name']: e for e in doc['entries']}
            profile = by_name['profile']['data']
            profile.update(image_ref=args.image, network=network)
            by_name['executor'].update(image=args.image, network_mode=network)
            by_name['interactive']['data']['image_ref'] = args.image
            by_name['expectation']['data'].update(provider=args.provider, mode='crash-start' if args.mode == 'restart' else args.mode, state=str(args.evidence))
            index.write_text(yaml.safe_dump(doc, sort_keys=False))
            def trust_project(e):
                for item in e['data']['file']['initialize']:
                    if item['path'] == '.claude/.claude.json':
                        item['content'] = json.dumps({'hasCompletedOnboarding': True, 'projects': {'/workspace': {'hasTrustDialogAccepted': True}}})
            edit('modules/driver-claude/src/_index.yaml', 'credential_format', trust_project)
            # The host owns these profiles; the drivers still name no executor.
            for provider in PROVIDERS:
                executable = shutil.which(provider)
                if not executable:
                    continue
                file = f'modules/driver-{provider}/src/_index.yaml'
                for name in (f'launch_policy_{provider}_window', f'launch_policy_{provider}_batch'):
                    def policy(e, provider=provider, executable=executable):
                        data = e['data']
                        data['executables'] = {provider: executable}
                        data.pop('executable_env', None)
                        data['placement_profiles'] = ['bee.docker.proof:profile']
                        data['required_cleanup'] = 'contained_tree'
                        data['required_exit_observation'] = 'independent'
                        data.pop('permission_exchange', None)
                        data['gateway_hooks'] = [] if args.mode != 'window' else data.get('gateway_hooks', [])
                        if args.mode != 'window':
                            data['gateway_tools'] = []
                        data.pop('hook_command_ref', None)
                        data.pop('environment_refs', None)
                        if provider == 'claude':
                            data.setdefault('environment', {}).update(ANTHROPIC_API_KEY='', CLAUDECODE='', DISABLE_AUTOUPDATER='1')
                        if provider == 'grok':
                            data.setdefault('environment', {})['GROK_FOLDER_TRUST'] = '0'
                    edit(file, name, policy)
            # Real HOME is only a broker source. Placement never inherits it.
            state = args.evidence.parent / 'state' / args.evidence.name
            state.mkdir(mode=0o700, exist_ok=True)
            placement = state / 'placement'
            placement.mkdir(mode=0o700, exist_ok=True)
            environment = workspace.database_environment(state, BEE_PLACEMENT_ROOT=str(placement))
            environment['BEE_DOCKER_EVIDENCE'] = str(args.evidence)
            environment['TMPDIR'] = str(ROOT / '.wippy/docker-work/tmp')
            for name in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_API_KEY', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CLAUDECODE'):
                environment.pop(name, None)
            command = [str(workspace.RUNTIME)]
            if args.standalone:
                # Explicit source replacements on the standalone's isolated deployment.
                config = folder / '.wippy.yaml'
                value = yaml.safe_load(config.read_text())
                value['workspace']['replacements']['bee/bee'] = str(folder)
                config.write_text(yaml.safe_dump(value, sort_keys=False))
                lock = folder / 'wippy.lock'
                value = yaml.safe_load(lock.read_text())
                value['modules'].insert(0, {'name': 'bee/bee', 'version': '0.1.0-dev', 'root': True})
                lock.write_text(yaml.safe_dump(value, sort_keys=False))
                module = folder / 'wippy.yaml'
                value = yaml.safe_load(module.read_text())
                value.pop('exclude_meta', None)
                value['directories'] = {'modules': '.wippy', 'src': './src'}
                value['exclude'] = ['modules/**', 'fixtures/**']
                module.write_text(yaml.safe_dump(value, sort_keys=False))
                command = [str(args.standalone.resolve()), '--state', str(state), 'wippy', '--config', str(config)]
            subprocess.run(command + ['lint', '--set', 'lua.type_system.enabled=true', '--set', 'lua.type_system.strict=true', '--ns', 'bee.docker.proof'], cwd=folder, env=environment, check=True, timeout=120)
            with (args.evidence / 'runtime.log').open('w') as output:
                result = subprocess.Popen(command + ['--console', 'run', 'docker-proof', '--host', 'bee:terminal'], cwd=folder, env=environment, stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 240
                try:
                    while result.poll() is None:
                        if time.monotonic() > deadline:
                            raise TimeoutError('provider proof exceeded its deadline')
                        ids = subprocess.check_output(['docker', 'ps', '-aq', '--no-trunc', '--filter', 'network=' + network], text=True).split()
                        for container_id in ids:
                            with (args.evidence / ('container-' + container_id[:12] + '.log')).open('w') as logs:
                                subprocess.run(['docker', 'logs', container_id], stdout=logs, stderr=subprocess.STDOUT, check=False)
                            with (args.evidence / ('processes-' + container_id[:12] + '.txt')).open('w') as processes:
                                subprocess.run(['docker', 'top', container_id, '-eo', 'pid,ppid,stat,comm'], stdout=processes, stderr=subprocess.STDOUT, check=False)
                        if args.mode == 'restart' and (args.evidence / 'started.json').exists():
                            with sqlite3.connect(state / 'placement.db') as database:
                                recorded = database.execute('SELECT placement_identity_json FROM bee_placement_attempts WHERE attempt_id = ?', ((args.evidence / 'attempt.txt').read_text(),)).fetchone()[0]
                            if recorded is None:
                                time.sleep(2)
                                continue
                            identity = json.loads(recorded)
                            ids = subprocess.check_output(['docker', 'ps', '-aq', '--no-trunc', '--filter', 'network=' + network], text=True).split()
                            assert len(ids) == 1, 'restart proof does not own exactly one container'
                            assert identity['backend_ref'] == ids[0], 'persisted container ID differs from daemon ID'
                            (args.evidence / 'killed-owner.json').write_text(json.dumps({'owner_pid': result.pid, 'container_id': ids[0], 'signal': 9}) + '\n')
                            result.kill()
                            break
                        time.sleep(2)
                finally:
                    if result.poll() is None:
                        result.kill()
                    result.wait()
            if args.mode == 'restart':
                assert (args.evidence / 'killed-owner.json').exists(), 'owner never reached the crash point'
                edit('src/docker_proof/_index.yaml', 'expectation', lambda e: e['data'].update(mode='crash-recover'))
                with (args.evidence / 'restart.log').open('w') as output:
                    result = subprocess.run(command + ['run', 'docker-proof', '--host', 'bee:terminal'], cwd=folder, env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=120)
                assert not subprocess.check_output(['docker', 'ps', '-aq', '--filter', 'network=' + network], text=True).split(), 'cancel/cleanup left a container'
            if result.returncode:
                raise RuntimeError('Docker provider acceptance failed; see ' + str(args.evidence / 'runtime.log'))
            assert not subprocess.check_output(['docker', 'ps', '-aq', '--filter', 'network=' + network], text=True).split(), 'provider acceptance left a container before fixture cleanup'
            print(args.provider + ' Docker ' + args.mode + ' passed', flush=True)
    finally:
        ids = subprocess.check_output(['docker', 'ps', '-aq', '--filter', 'network=' + network], text=True).split()
        for id in ids:
            with (args.evidence / ('container-' + id[:12] + '.log')).open('w') as output:
                subprocess.run(['docker', 'logs', id], stdout=output, stderr=subprocess.STDOUT, check=False)
            subprocess.run(['docker', 'rm', '-f', id], check=True)
        subprocess.run(['docker', 'network', 'rm', network], check=True)


if __name__ == '__main__':
    main()
