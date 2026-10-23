"""Named synthetic capture states and a loopback-only canned answer, with no external AI calls."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import threading


def operation(name):
    if name not in ("meaning", "history", "review", "clean", "senseSelected"):
        raise ValueError("unknown UI demonstration: " + str(name))
    return "uiDemo." + name


@contextmanager
def answer_server():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            # Consume the synthetic request without retaining or logging it.
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            content = json.dumps({"outcome": "matched", "quotes": ["A round fruit"],
                                  "explanation": "Here, apple is the fruit the reader brought for lunch."})
            body = json.dumps({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:" + str(server.server_port) + "/v1"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
