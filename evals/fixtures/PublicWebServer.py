"""Offline HTTP transport fixture. Binds only loopback, never fetches a URL."""

import http.server
import gzip
import json
from pathlib import Path
import sys
import time

state = Path(sys.argv[1])
count = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        global count
        count += 1
        state.write_text(json.dumps({"path": self.path, "count": count}))
        if self.path == "/slow":
            time.sleep(10)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Set-Cookie", "fixture=must-not-persist")
        if self.path == "/overflow":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(1024):
                    self.wfile.write(b"400\r\n" + b"x" * 1024 + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        content = json.dumps({
            "host": self.headers.get("Host"), "cookie": self.headers.get("Cookie"),
            "authorization": self.headers.get("Authorization"),
            "accept_encoding": self.headers.get("Accept-Encoding"),
            "method": self.command, "body": body, "count": count,
        }).encode()
        if self.path in ("/gzip-text", "/gzip-bomb"):
            if self.path == "/gzip-bomb":
                content = b"x" * 100_000
            content = gzip.compress(content)
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        try:
            self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
