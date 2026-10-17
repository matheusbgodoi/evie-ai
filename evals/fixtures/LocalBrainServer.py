# A synthetic CLI for the production local-brain launcher boundary regression.
# The runner prepends the installed MLX venv's absolute Python shebang to a copy.
# It never loads a model, downloads data, or serves outside loopback.
import argparse
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import mlx.core as mx

parser = argparse.ArgumentParser()
parser.add_argument('--model', required=True)
parser.add_argument('--host', required=True, choices=['127.0.0.1'])
parser.add_argument('--port', required=True, type=int)
parser.add_argument('--max-kv-size', required=True, type=int)
parser.add_argument('--max-num-seqs', required=True, type=int)
parser.add_argument('--kv-bits', type=int)
parser.add_argument('--prefill-step-size', type=int)
options = parser.parse_args()
secret = os.environ['MLX_VLM_SERVER_API_KEY']
# set_cache_limit returns the prior limit. Read it without allocating a tensor.
cache_limit = mx.set_cache_limit(0)
mx.set_cache_limit(cache_limit)
snapshot = vars(options) | {'pid': os.getpid(), 'cache_limit_bytes': cache_limit}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        authorized = hmac.compare_digest(
            self.headers.get('Authorization', ''), 'Bearer ' + secret)
        status = 200 if authorized else 401
        body = json.dumps(snapshot if authorized else {'error': 'unauthorized'}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer((options.host, options.port), Handler).serve_forever()
