"""Anthropic Messages fixture endpoint for Pi protocol captures."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['content-length'])))
        if self.headers.get('x-api-key') == 'fixture-invalid':
            self.send_response(401)
            self.send_header('content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
            return
        messages = body['messages']
        tool = 'Use the bash tool' in json.dumps(messages) and not any(b.get('type') == 'tool_result' for m in messages for b in m['content'] if isinstance(b, dict))
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.end_headers()
        def send(event, data):
            self.wfile.write(f'event: {event}\ndata: {json.dumps(data)}\n\n'.encode())
            self.wfile.flush()
        send('message_start', {'type':'message_start','message':{'id':'msg_fixture','type':'message','role':'assistant','model':body['model'],'content':[],'stop_reason':None,'usage':{'input_tokens':10,'output_tokens':1}}})
        if tool:
            send('content_block_start', {'type':'content_block_start','index':0,'content_block':{'type':'tool_use','id':'toolu_fixture','name':'bash','input':{}}})
            send('content_block_delta', {'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json':'{"command":"printf fixture-tool"}'}})
        else:
            send('content_block_start', {'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}})
            send('content_block_delta', {'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'fixture answer'}})
        send('content_block_stop', {'type':'content_block_stop','index':0})
        send('message_delta', {'type':'message_delta','delta':{'stop_reason':'tool_use' if tool else 'end_turn','stop_sequence':None},'usage':{'output_tokens':5}})
        send('message_stop', {'type':'message_stop'})

ThreadingHTTPServer(('0.0.0.0', 18973), Handler).serve_forever()
