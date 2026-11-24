#!/usr/bin/env python3
"""Run AI transport checks against synthetic loopback responses; never uses real credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import threading
import time

errors = []
redirect_hits = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            if self.path == "/redirect-target":
                redirect_hits.append(True)
                self.send_error(500)
                return
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            model = body.get("model", "test-model")
            if model == "unauthorized":
                self.send_error(401)
                return
            if model == "redirect":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/redirect-target")
                self.end_headers()
                return
            if model == "empty":
                payload = b"data: [DONE]\n\n"
            elif self.path == "/v1/messages":
                assert self.headers["x-api-key"] == "synthetic-secret"
                assert self.headers["anthropic-version"] == "2023-06-01"
                assert body["system"] and body["max_tokens"] > 0
                payload = sse([{"type": "content_block_delta", "delta": {"text": "建议保留。"}}, {"type": "message_stop"}])
            elif self.path.startswith("/v1beta/models/"):
                assert self.headers["x-goog-api-key"] == "synthetic-secret"
                assert "key=" not in self.path
                assert body["systemInstruction"] and body["contents"][0]["role"] == "user"
                payload = sse([{"candidates": [{"content": {"parts": [{"text": "建议保留。"}]}}]}])
            elif self.path == "/api/chat":
                assert body["messages"][0]["role"] == "system"
                payload = (json.dumps({"message": {"content": "建议保留。"}, "done": True}, ensure_ascii=False) + "\n").encode()
            else:
                assert self.path == "/v1/chat/completions"
                assert body["messages"][0]["role"] == "system" and body["stream"] is True
                if model == "test-model":
                    assert self.headers["Authorization"] == "Bearer synthetic-secret"
                payload = sse([{"choices": [{"delta": {"content": "建议"}}]}, {"choices": [{"delta": {"content": "保留。"}}]}]) + b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson" if self.path == "/api/chat" else "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if model == "cancel":
                time.sleep(0.5)
            # Split inside UTF-8 characters and SSE fields to exercise the actual byte transport.
            for index in range(0, len(payload), 3):
                self.wfile.write(payload[index:index + 3])
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            errors.append(str(error))
            self.send_error(500)


def sse(events):
    return "".join("data: " + json.dumps(event, ensure_ascii=False) + "\n\n" for event in events).encode()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    result = subprocess.run(["swift", "run", "QingfengAITransportChecks", str(server.server_port)],
                            cwd=Path(__file__).resolve().parent.parent, timeout=90)
    if result.returncode or errors or redirect_hits:
        raise SystemExit(f"AI transport check failed: exit={result.returncode}, fixture_errors={errors}, redirect_hits={len(redirect_hits)}")
finally:
    server.shutdown()
    server.server_close()
