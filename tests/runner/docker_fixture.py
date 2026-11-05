"""Install selected Docker fixture images outside timed test entries, and remove
the containers a shard's node leaves when it ends."""
import http.client
import json
import os
import re
import socket
import subprocess
import time
from urllib.parse import quote

SOCKET = '/var/run/docker.sock'


class Connection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCKET)


def present(image):
    client = Connection('docker')
    try:
        client.request('GET', '/images/' + quote(image, safe='') + '/json')
        response = client.getresponse()
        body = response.read()
        if response.status == 200:
            return True
        if response.status == 404:
            return False
        raise RuntimeError(f'Docker fixture inspection HTTP {response.status}: {body.decode(errors="replace")}')
    finally:
        client.close()


def request(method, path):
    client = Connection('docker')
    try:
        client.request(method, path)
        response = client.getresponse()
        body = response.read()
        if response.status >= 300:
            raise RuntimeError(f'Docker HTTP {response.status} for {method} {path}: {body.decode(errors="replace")}')
        return json.loads(body) if body else None
    finally:
        client.close()


def teardown(root):
    """Remove the containers whose bind mounts lie under a shard root.

    A shard's node owns the containers of its attempts. A node that ends with
    an attempt in flight (an entry that timed out, a create that completed
    after its runner ended) leaves them behind, and no later boot of that node
    reconciles them, so the shard removes them when its node has exited.
    """
    prefix = os.path.join(str(root), '')
    removed = []
    for container in request('GET', '/containers/json?all=true') or []:
        if any(mount.get('Type') == 'bind' and os.path.join(mount.get('Source', ''), '').startswith(prefix)
               for mount in container.get('Mounts') or []):
            request('DELETE', '/containers/' + container['Id'] + '?force=true')
            removed.append(container['Id'])
    return removed


def required(documents, selected):
    """Whether a selected entry drives the Docker daemon."""
    return any(document['namespace'] + ':' + entry['name'] in selected
               and entry.get('meta', {}).get('type') == 'test'
               and 'docker_daemon' in entry['meta'].get('resources', [])
               for document in documents for entry in document.get('entries', []))


def images(documents, selected):
    found = set()
    for document in documents:
        entries = document.get('entries', [])
        if not any(document['namespace'] + ':' + entry['name'] in selected
                   and entry.get('meta', {}).get('type') == 'test'
                   and 'docker_daemon' in entry['meta'].get('resources', []) for entry in entries):
            continue
        for entry in entries:
            if entry.get('kind') == 'exec.docker' and entry.get('meta', {}).get('type') == 'test_support':
                image = entry['image']
                if not re.fullmatch(r'[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}', image):
                    raise ValueError('Docker fixture image must be digest-pinned: ' + image)
                found.add(image)
    return sorted(found)


def prepare(documents, selected):
    started = time.monotonic()
    fixtures = images(documents, selected)
    for image in fixtures:
        cached = present(image)
        print(f'Docker fixture {image}: {"cached" if cached else "pulling"}', flush=True)
        if not cached:
            subprocess.run(['docker', '--host', 'unix://' + SOCKET, 'pull', image], check=True)
    elapsed = time.monotonic() - started
    if fixtures:
        print(f'Docker fixture preparation: {elapsed:.3f}s', flush=True)
    return elapsed
