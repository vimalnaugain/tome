#!/usr/bin/env python3
"""Mock LLM server for Tome's recap tests.

Speaks both the Claude Messages API (/v1/messages) and the OpenAI-compatible
/chat/completions shape. Every request body is appended to a JSONL log so
tests can check what was sent (e.g. that no later-chapter text leaked).

usage: mock_llm.py PORT LOGFILE
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]


def recap_for(prompt):
    if "Write notes on this chapter" in prompt:
        return "- Notes for a chapter (mock).\n- Characters: Mara, Tobias."
    kind = "Quick refresher" if "quick refresher" in prompt else "Story so far"
    return (f"## {kind}\n\nMara Quill returned to **Gull's Reach** after a letter from her late grandmother. "
            "The lighthouse has gone dark and a stranger is watching.\n\n"
            "## Where you left off\n\nMara has just opened locker number seven.\n\n"
            "## Characters to remember\n\n- **Mara Quill**: the heroine.\n- **Tobias**: her nervous cousin.\n"
            "- **Elias Thorn**: an insurance investigator.\n\n"
            f"(mock: prompt was {len(prompt)} characters)")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        req = json.loads(body)
        entry = {"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": req}
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
        if self.path.endswith("/v1/messages"):
            if self.headers.get("x-api-key") != "test-key":
                return self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "bad key"}})
            prompt = req["messages"][0]["content"]
            out = {"id": "msg_mock", "type": "message", "role": "assistant", "model": req["model"],
                   "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": recap_for(prompt)}],
                   "stop_reason": "end_turn", "usage": {"input_tokens": len(prompt) // 4, "output_tokens": 100}}
            return self.reply(200, out)
        if self.path.endswith("/chat/completions"):
            prompt = req["messages"][-1]["content"]
            return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": recap_for(prompt)}}]})
        self.reply(404, {"error": {"message": "not found"}})

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
