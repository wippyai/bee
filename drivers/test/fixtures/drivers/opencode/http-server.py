# SPDX-License-Identifier: MIT
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
fault = sys.argv[2] if len(sys.argv) > 2 else None
messages = json.loads((root / 'messages.json').read_text())
events = (root / 'events.jsonl').read_text().splitlines()
session_id = messages[0]['info']['sessionID']
session = {'id': session_id}
started = threading.Event()
settled = threading.Event()
permission_replied = threading.Event()
rows = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value, status=200):
        body = b'' if status == 204 else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == fault:
            self.reply({'error': 'fixture refusal'}, 503)
        elif self.path == '/event':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            try:
                self.wfile.write(b'data: {"type":"server.connected","properties":{}}\n\n')
                self.wfile.flush()
                started.wait()
                for event in events:
                    self.wfile.write(('data: ' + event + '\n\n').encode())
                    self.wfile.flush()
                self.connection.recv(1)
            except (ConnectionError, OSError):
                pass
        elif self.path == '/session':
            self.reply([{'id': 'fixture-old-session'}, session])
        elif self.path == '/session/status':
            self.reply({})
        elif self.path == '/permission':
            self.reply([])
        elif self.path.endswith('/message'):
            self.reply(messages if started.is_set() else [])
        elif '/message/' in self.path:
            self.reply(next(message for message in messages if message['info']['id'] == self.path.rsplit('/', 1)[-1]))
        elif self.path == '/state':
            self.reply({'started': started.is_set()})
        elif self.path == '/captured':
            settled.wait(10)
            permission_replied.wait(10)
            self.reply({'hooks': rows, 'permission_replied': permission_replied.is_set()})
        else:
            self.reply({'error': self.path}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.path == '/session':
            if not isinstance(body, dict):
                self.reply({'error': 'session creation requires an object'}, 400)
            else:
                self.reply(session)
        elif self.path.endswith('/prompt_async'):
            self.reply(None, 204)
            started.set()
        elif self.path == '/hook/action-1':
            rows.append(body)
            if body['hook_event_name'] == 'PermissionRequest':
                self.reply({'hookSpecificOutput': {'decision': {'behavior': 'allow'}}})
            else:
                self.reply({})
            if body['hook_event_name'] == 'Stop':
                settled.set()
        elif self.path.startswith('/permission/') and self.path.endswith('/reply'):
            if body.get('reply') == 'once':
                permission_replied.set()
            self.reply(True)
        else:
            self.reply({'error': self.path}, 404)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:' + str(server.server_port), flush=True)
server.serve_forever()
