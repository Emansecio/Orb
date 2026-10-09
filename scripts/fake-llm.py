#!/usr/bin/env python3
"""Fake OpenAI-compatible server for trying the app end to end without an API key.

    python3 scripts/fake-llm.py [port]        # default 8765
    python3 scripts/fake-llm.py 8765 --long   # first reply: ~2000 words of Markdown, one word every 15 ms

In Orb: Ajustes → Modelos → add the provider "Gateway próprio", URL http://127.0.0.1:8765/v1,
then "Atualizar modelos". Each prompt gets a short reply, a `run_command` call (so the
approval card shows up) and, after the tool result, a final answer quoting its first line.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LONG = "--long" in sys.argv


def long_reply(words=2000):
    """Inline Markdown paragraphs, for measuring the UI while a long reply streams."""
    vocabulary = ("o disco tem espaço livre suficiente para o backup e a pasta Downloads guarda arquivos "
                  "antigos que podem ir para o lixo depois de uma revisão rápida").split()
    out = []
    for i in range(words):
        word = vocabulary[i % len(vocabulary)]
        if i % 37 == 5:
            word = f"**{word}**"
        elif i % 53 == 11:
            word = f"`{word}`"
        out.append(word + ("\n\n" if i % 90 == 89 else " "))
    return out


def chunk(delta):
    return "data: " + json.dumps({"choices": [{"index": 0, "delta": delta}]}) + "\n\n"


def usage_chunk():
    """What a real server reports last: the prompt (part of it read from the cache) and the reply, so the Uso page has numbers."""
    usage = {"prompt_tokens": 1200, "completion_tokens": 30, "prompt_tokens_details": {"cached_tokens": 800}}
    return "data: " + json.dumps({"choices": [], "usage": usage}) + "\n\n"


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
            intro = long_reply() if LONG else ["Vou checar a versão do macOS e o disco. "]
            events = [chunk({"content": word}) for word in intro] + [
                chunk({"tool_calls": [call]}),
                chunk({"tool_calls": [{"index": 0, "function": {"arguments": args[:20]}}]}),
                chunk({"tool_calls": [{"index": 0, "function": {"arguments": args[20:]}}]})]
        for event in events + [usage_chunk(), "data: [DONE]\n\n"]:
            self.wfile.write(event.encode())
            self.wfile.flush()
            if LONG:
                time.sleep(0.015)

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
    numbers = [arg for arg in sys.argv[1:] if arg.isdigit()]
    port = int(numbers[0]) if numbers else 8765
    print(f"fake LLM em http://127.0.0.1:{port}/v1")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
