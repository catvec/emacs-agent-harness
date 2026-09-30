#!/usr/bin/env python3
"""A fake `claude` CLI for the harness-provider-claude tests.

It speaks the subset of the Claude Code stream-json protocol that the
provider relies on: the system/init banner, the SDK MCP handshake over
control requests, streamed assistant text, a hosted tool call served by
the harness, the tool-result echo, rate limit events and the final
result.  It stays alive between turns so the keep-alive path is tested,
and it honours an interrupt control request.

Behaviour is chosen by the prompt text:
  "call echo"  -> issues a tools/call for mcp__harness__echo first
  "hang"       -> starts a turn and waits for an interrupt (or forever
                  with "hang ignore", to exercise the kill path)
  "die"        -> exits mid-turn without a result
Anything else streams the text "hello" and finishes.

If HARNESS_FAKE_CLAUDE_ARGV names a file, a JSON object with the argv, the
cwd and the CLAUDECODE environment variable is written there.
"""

import json
import os
import sys
import uuid


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def read():
    """Return the next parsed stdin line, or None at EOF."""
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except ValueError:
            continue


def arg_value(argv, flag):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


class Fake:
    def __init__(self, argv):
        self.argv = argv
        self.queue = []
        self.rpc_id = 10
        self.tools = []
        resume = arg_value(argv, "--resume")
        if resume and "--fork-session" in argv:
            self.session_id = "forked-" + uuid.uuid4().hex[:8]
        elif resume:
            self.session_id = resume
        else:
            self.session_id = "fake-" + uuid.uuid4().hex[:8]
        self.model = arg_value(argv, "--model") or "fake-model"

    # -- plumbing ---------------------------------------------------------

    def next_message(self):
        if self.queue:
            return self.queue.pop(0)
        return read()

    def wait_control_response(self, request_id):
        """Read stdin until the control_response for REQUEST_ID arrives.

        Anything else that arrives meanwhile (typically the next user
        message) is queued for the main loop; reading stdin directly here
        keeps deferred messages from being re-read forever."""
        while True:
            msg = read()
            if msg is None:
                sys.exit(0)
            if msg.get("type") == "control_response" and \
               msg.get("response", {}).get("request_id") == request_id:
                return msg["response"]
            if msg.get("type") == "control_request" and \
               msg.get("request", {}).get("subtype") == "interrupt":
                # Answer interrupts immediately even while waiting.
                emit({"type": "control_response",
                      "response": {"subtype": "success",
                                   "request_id": msg["request_id"],
                                   "response": {}}})
                self.interrupted = True
                continue
            self.queue.append(msg)

    def mcp(self, message):
        """Send MESSAGE over the SDK MCP channel and return the JSON-RPC reply."""
        rid = "req-" + uuid.uuid4().hex[:8]
        emit({"type": "control_request", "request_id": rid,
              "request": {"subtype": "mcp_message", "server_name": "harness",
                          "message": message}})
        response = self.wait_control_response(rid)
        return response.get("response", {}).get("mcp_response")

    def handshake(self):
        self.rpc_id += 1
        init = self.mcp({"jsonrpc": "2.0", "id": self.rpc_id, "method": "initialize",
                         "params": {"protocolVersion": "2025-06-18",
                                    "capabilities": {},
                                    "clientInfo": {"name": "fake-claude", "version": "0"}}})
        assert init and init.get("result", {}).get("protocolVersion") == "2025-06-18", init
        ack = self.mcp({"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert ack is not None, "no reply to notifications/initialized"
        self.rpc_id += 1
        listed = self.mcp({"jsonrpc": "2.0", "id": self.rpc_id, "method": "tools/list"})
        self.tools = listed.get("result", {}).get("tools", [])

    # -- turns --------------------------------------------------------------

    def stream(self, event):
        emit({"type": "stream_event", "event": event, "session_id": self.session_id})

    def usage(self):
        return {"input_tokens": 12, "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 2000, "output_tokens": 7}

    def result(self, subtype="success", is_error=False, text="hello",
               stop_reason="end_turn"):
        emit({"type": "result", "subtype": subtype, "is_error": is_error,
              "duration_ms": 5, "num_turns": 1, "result": text,
              "session_id": self.session_id, "total_cost_usd": 0.01,
              "usage": self.usage(), "stop_reason": stop_reason})

    def turn(self, message):
        self.interrupted = False
        blocks = message.get("message", {}).get("content", [])
        if isinstance(blocks, str):
            text = blocks
        else:
            text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        self.stream({"type": "message_start",
                     "message": {"id": "msg_1", "type": "message", "role": "assistant",
                                 "model": self.model, "content": [],
                                 "usage": {"input_tokens": 12,
                                           "cache_creation_input_tokens": 100,
                                           "cache_read_input_tokens": 2000,
                                           "output_tokens": 0}}})
        if "die" in text:
            sys.stderr.write("fake-claude: dying on request\n")
            sys.stderr.flush()
            sys.exit(3)
        if "hang" in text:
            self.stream({"type": "content_block_start", "index": 0,
                         "content_block": {"type": "text", "text": ""}})
            self.stream({"type": "content_block_delta", "index": 0,
                         "delta": {"type": "text_delta", "text": "wait"}})
            ignore = "ignore" in text
            while True:
                msg = read()
                if msg is None:
                    sys.exit(0)
                if msg.get("type") == "control_request" and \
                   msg.get("request", {}).get("subtype") == "interrupt":
                    if ignore:
                        continue
                    emit({"type": "control_response",
                          "response": {"subtype": "success",
                                       "request_id": msg["request_id"],
                                       "response": {}}})
                    self.result(subtype="error_during_execution", is_error=True,
                                text="Request was aborted")
                    return
                self.queue.append(msg)
        if "call echo" in text:
            self.stream({"type": "content_block_start", "index": 0,
                         "content_block": {"type": "tool_use", "id": "toolu_fake_1",
                                           "name": "mcp__harness__echo", "input": {}}})
            self.stream({"type": "content_block_delta", "index": 0,
                         "delta": {"type": "input_json_delta",
                                   "partial_json": "{\"text\":\"ping\"}"}})
            self.stream({"type": "content_block_stop", "index": 0})
            emit({"type": "assistant", "session_id": self.session_id,
                  "message": {"id": "msg_1", "role": "assistant", "model": self.model,
                              "content": [{"type": "tool_use", "id": "toolu_fake_1",
                                           "name": "mcp__harness__echo",
                                           "input": {"text": "ping"}}],
                              "stop_reason": "tool_use", "usage": self.usage()}})
            self.rpc_id += 1
            reply = self.mcp({"jsonrpc": "2.0", "id": self.rpc_id, "method": "tools/call",
                              "params": {"name": "mcp__harness__echo",
                                         "arguments": {"text": "ping"}}})
            if self.interrupted:
                self.result(subtype="error_during_execution", is_error=True,
                            text="Request was aborted")
                return
            content = reply.get("result", {}).get("content", [])
            is_error = bool(reply.get("result", {}).get("isError"))
            emit({"type": "user", "session_id": self.session_id,
                  "message": {"role": "user",
                              "content": [{"type": "tool_result",
                                           "tool_use_id": "toolu_fake_1",
                                           "content": content,
                                           "is_error": is_error}]}})
        # Thinking block with empty text and only a signature, as the CLI sends.
        self.stream({"type": "content_block_start", "index": 1,
                     "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
        self.stream({"type": "content_block_delta", "index": 1,
                     "delta": {"type": "signature_delta", "signature": "sig"}})
        self.stream({"type": "content_block_stop", "index": 1})
        self.stream({"type": "content_block_start", "index": 2,
                     "content_block": {"type": "text", "text": ""}})
        for piece in ("hel", "lo"):
            self.stream({"type": "content_block_delta", "index": 2,
                         "delta": {"type": "text_delta", "text": piece}})
        self.stream({"type": "content_block_stop", "index": 2})
        self.stream({"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                     "usage": {"input_tokens": 12, "cache_creation_input_tokens": 100,
                               "cache_read_input_tokens": 2000, "output_tokens": 7}})
        self.stream({"type": "message_stop"})
        emit({"type": "assistant", "session_id": self.session_id,
              "message": {"id": "msg_2", "role": "assistant", "model": self.model,
                          "content": [{"type": "thinking", "thinking": "", "signature": "sig"},
                                      {"type": "text", "text": "hello"}],
                          "stop_reason": "end_turn", "usage": self.usage()}})
        emit({"type": "rate_limit_event",
              "rate_limit_info": {"unifiedWindows": {
                  "five_hour": {"utilization": 0.09, "resetsAt": 1800000000},
                  "seven_day": {"utilization": 0.42, "resetsAt": 1800500000}}}})
        self.result()

    # -- main loop ----------------------------------------------------------

    def run(self):
        path = os.environ.get("HARNESS_FAKE_CLAUDE_ARGV")
        if path:
            with open(path, "w") as f:
                json.dump({"argv": self.argv,
                           "cwd": os.getcwd(),
                           "claudecode": os.environ.get("CLAUDECODE")}, f)
        emit({"type": "system", "subtype": "init", "session_id": self.session_id,
              "model": self.model, "cwd": os.getcwd(), "tools": [],
              "mcp_servers": [{"name": "harness", "status": "connected"}],
              "permissionMode": "bypassPermissions"})
        while True:
            msg = self.next_message()
            if msg is None:
                return
            kind = msg.get("type")
            if kind == "control_request":
                sub = msg.get("request", {}).get("subtype")
                emit({"type": "control_response",
                      "response": {"subtype": "success",
                                   "request_id": msg.get("request_id"),
                                   "response": {}}})
                if sub == "initialize":
                    self.handshake()
            elif kind == "user":
                self.turn(msg)


if __name__ == "__main__":
    Fake(sys.argv[1:]).run()
