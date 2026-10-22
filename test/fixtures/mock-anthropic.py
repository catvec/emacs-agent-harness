#!/usr/bin/env python3
"""A scripted stand-in for the Anthropic Messages API, for running the
real `claude' CLI offline (test/harness-provider-claude-real-cli-test.el).

  mock-anthropic.py --script SCRIPT.json --log REQUESTS.jsonl

It listens on a free port of 127.0.0.1 and prints "PORT n" on its first
line of output.  Point the CLI at it with ANTHROPIC_BASE_URL and a dummy
ANTHROPIC_API_KEY; nothing leaves the machine.

SCRIPT is a JSON list of steps.  A step is {"tool": NAME, "input": {...}}
\(the model calls a tool), {"tools": [{"tool": ..., "input": ...}, ...]}
\(several calls in one message) or {"text": "..."} (the model answers).
The step a request is answered with is the number of messages the model
has written so far in the conversation (a message with several calls
counts once), so the script advances as the CLI feeds results back and
goes on from one turn to the next; past its end the model says "script
finished".  A request
without tools (the CLI's own small helper calls) or for a Haiku model
gets a plain "ok".  Every request body is appended to REQUESTS as one
JSON line, so a test can read back which tools the CLI offered the model.
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

args = None
script = []


def count_replies(messages):
    """The number of messages the model has written so far in the conversation."""
    return sum(1 for m in messages if m.get("role") == "assistant")


def sse(event, data):
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()


def message_events(model, blocks, stop_reason):
    out = [sse("message_start", {"type": "message_start", "message": {
        "id": "msg_mock%d" % int(time.time() * 1000), "type": "message", "role": "assistant",
        "model": model, "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 10, "output_tokens": 1}}})]
    for i, b in enumerate(blocks):
        if b["type"] == "text":
            out.append(sse("content_block_start", {"type": "content_block_start", "index": i,
                                                   "content_block": {"type": "text", "text": ""}}))
            out.append(sse("content_block_delta", {"type": "content_block_delta", "index": i,
                                                   "delta": {"type": "text_delta", "text": b["text"]}}))
        else:
            out.append(sse("content_block_start", {"type": "content_block_start", "index": i,
                                                   "content_block": {"type": "tool_use", "id": b["id"],
                                                                     "name": b["name"], "input": {}}}))
            out.append(sse("content_block_delta", {"type": "content_block_delta", "index": i,
                                                   "delta": {"type": "input_json_delta",
                                                             "partial_json": json.dumps(b["input"])}}))
        out.append(sse("content_block_stop", {"type": "content_block_stop", "index": i}))
    out.append(sse("message_delta", {"type": "message_delta",
                                     "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                                     "usage": {"output_tokens": 20}}))
    out.append(sse("message_stop", {"type": "message_stop"}))
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def body(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    def reply_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply_json({"data": [], "has_more": False})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_POST(self):
        body = self.body()
        with open(args.log, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if self.path.startswith("/v1/messages/count_tokens"):
            return self.reply_json({"input_tokens": 100})
        if not self.path.startswith("/v1/messages"):
            return self.reply_json({})
        model = body.get("model", "claude-sonnet-5")
        scripted = bool(body.get("tools")) and "haiku" not in model
        blocks, stop = [{"type": "text", "text": "ok"}], "end_turn"
        if scripted:
            n = count_replies(body.get("messages") or [])
            step = script[n] if n < len(script) else {"text": "script finished"}
            if "tool" in step:
                step = {"tools": [step]}
            if "tools" in step:
                blocks = [{"type": "tool_use", "id": "toolu_mock%02d_%d" % (n, i),
                           "name": t["tool"], "input": t.get("input", {})}
                          for i, t in enumerate(step["tools"])]
                stop = "tool_use"
            else:
                blocks = [{"type": "text", "text": step["text"]}]
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            for chunk in message_events(model, blocks, stop):
                self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        else:
            self.reply_json({"id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                             "content": blocks, "stop_reason": stop, "stop_sequence": None,
                             "usage": {"input_tokens": 10, "output_tokens": 5}})


def main():
    global args, script
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    with open(args.script) as f:
        script = json.load(f)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print("PORT %d" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
