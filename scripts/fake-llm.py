#!/usr/bin/env python3
"""Fake OpenAI-compatible server for trying the app end to end without an API key.

    python3 scripts/fake-llm.py [port]        # default 8765

In OpenBot: Ajustes → Modelo → "Outro compatível com OpenAI", URL http://127.0.0.1:8765/v1,
then "Testar e buscar modelos". Each prompt gets a short reply, a `run_command` call (so the
approval card shows up) and, after the tool result, a final answer quoting its first line.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def chunk(delta):
    return "data: " + json.dumps({"choices": [{"index": 0, "delta": delta}]}) + "\n\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith("/models"):
            self.reply_json({"data": [{"id": "fake-model"}, {"id": "fake-model-mini"}]})
        else:
            self.send_error(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        last = (body.get("messages") or [{}])[-1]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if last.get("role") == "tool":
            first = (last.get("content") or "").strip().splitlines()
            events = [chunk({"content": word + " "}) for word in
                      ["Pronto.", "O", "comando", "respondeu:", f"`{first[0] if first else 'nada'}`."]]
        else:
            call = {"index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "run_command", "arguments": ""}}
            args = json.dumps({"command": "sw_vers -productVersion && df -h / | tail -1"})
            events = [chunk({"content": "Vou checar a versão do macOS e o disco. "}),
                      chunk({"tool_calls": [call]}),
                      chunk({"tool_calls": [{"index": 0, "function": {"arguments": args[:20]}}]}),
                      chunk({"tool_calls": [{"index": 0, "function": {"arguments": args[20:]}}]})]
        for event in events + ["data: [DONE]\n\n"]:
            self.wfile.write(event.encode())
            self.wfile.flush()

    def reply_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"fake LLM em http://127.0.0.1:{port}/v1")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
