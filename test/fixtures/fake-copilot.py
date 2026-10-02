#!/usr/bin/env python3
"""A fake `copilot --headless --stdio` for the harness-provider-copilot tests.

It speaks the subset of GitHub Copilot CLI's server protocol (JSON-RPC
2.0 framed by Content-Length headers, SDK protocol version 3) that the
provider relies on: connect, auth.getStatus, models.list,
models.getBuiltInCatalog, account.getQuota, session.create,
session.resume, sessions.fork, session.send, session.abort,
session.detach, sessions.delete, session.tools.handlePendingToolCall and
session.permissions.handlePendingPermissionRequest, and the
session.event notifications of a turn.  Like the real CLI, one process
holds any number of sessions and stays alive between turns.

Behaviour is chosen by the prompt text:
  "call echo"   -> asks for the external tool `echo' with {"text": "ping"}
                   and answers after the harness has sent the result
  "permission"  -> asks permission for the custom tool first, then
                   streams the decision it got
  "hang"        -> streams "wait" and waits for session.abort (forever
                   with "hang ignore", to exercise the kill path)
  "die"         -> makes one model call, then exits with status 3
  "fail"        -> reports a session.error, then goes idle
  "long"        -> the model stops at its output limit
  "compact"     -> Copilot compacts the context first
  "subagent"    -> a sub-agent streams, fails and goes idle first
  "refuse"      -> session.send is answered with an error; no turn runs
Anything else streams the thinking "hmm", then the text "hello".  Each
model call reports 12 uncached input tokens, 2000 cached, 100 written to
the cache and 7 output tokens, and costs one AI credit (1e9 nano-AIU).

One turn runs at a time: a session.send read while a turn waits (for a
tool result, a permission or an abort) is answered once that turn is
over.  An abort read while a session runs no turn is a no-op, as in the
real CLI: the session's next turn does not see it.

The environment picks the situation:
  HARNESS_FAKE_COPILOT_AUTH=none     not logged in
  HARNESS_FAKE_COPILOT_PROTOCOL=N    report protocol version N
  HARNESS_FAKE_COPILOT_NO_CONNECT=1  an older CLI: no `connect', only `ping'
  HARNESS_FAKE_COPILOT_SILENT=1      read everything, answer nothing
  HARNESS_FAKE_COPILOT_LEGACY=1      premium request billing: no credit figures
  HARNESS_FAKE_COPILOT_EXHAUSTED=1   the allowance is used up, extra usage on
  HARNESS_FAKE_COPILOT_SLOW_CREATE=S wait S seconds before answering
                                     session.create
  HARNESS_FAKE_COPILOT_LOG=FILE      append one JSON line per request
                                     received (and one with the argv and
                                     the directory at start)
Session ids starting with "missing" cannot be resumed or forked; those
starting with "locked" are in use by another process, and so are the
forks of those starting with "brittle".
"""

import json
import os
import sys
import time
import uuid

AUTH = os.environ.get("HARNESS_FAKE_COPILOT_AUTH", "")
PROTOCOL = int(os.environ.get("HARNESS_FAKE_COPILOT_PROTOCOL", "3"))
NO_CONNECT = bool(os.environ.get("HARNESS_FAKE_COPILOT_NO_CONNECT"))
SILENT = bool(os.environ.get("HARNESS_FAKE_COPILOT_SILENT"))
LEGACY = bool(os.environ.get("HARNESS_FAKE_COPILOT_LEGACY"))
EXHAUSTED = bool(os.environ.get("HARNESS_FAKE_COPILOT_EXHAUSTED"))
SLOW_CREATE = float(os.environ.get("HARNESS_FAKE_COPILOT_SLOW_CREATE", "0"))
LOG = os.environ.get("HARNESS_FAKE_COPILOT_LOG")

STDIN = sys.stdin.buffer
STDOUT = sys.stdout.buffer


def log(obj):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(obj) + "\n")


def write(obj):
    body = json.dumps(obj).encode("utf-8")
    STDOUT.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    STDOUT.flush()


def read():
    """Return the next message from stdin, or None at end of input."""
    length = None
    while True:
        line = STDIN.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            if length is None:
                continue
            break
        name, _, value = line.decode("ascii").partition(":")
        if name.strip().lower() == "content-length":
            length = int(value.strip())
    body = STDIN.read(length)
    if len(body) < length:
        return None
    return json.loads(body.decode("utf-8"))


def quota_snapshots():
    premium = {
        "isUnlimitedEntitlement": False,
        "entitlementRequests": 1500,
        "usedRequests": 1500 if EXHAUSTED else 450,
        "usageAllowedWithExhaustedQuota": True,
        "remainingPercentage": 0.0 if EXHAUSTED else 70.0,
        "overage": 20 if EXHAUSTED else 0,
        "overageAllowedWithExhaustedQuota": True,
        "resetDate": "2026-11-01T00:00:00Z",
        "overageEntitlement": 5000,
    }
    if not LEGACY:
        premium["tokenBasedBilling"] = True
    unlimited = {"isUnlimitedEntitlement": True, "entitlementRequests": -1, "usedRequests": 0,
                 "usageAllowedWithExhaustedQuota": True, "remainingPercentage": 100.0,
                 "overage": 0, "overageAllowedWithExhaustedQuota": False}
    return {"premium_interactions": premium, "chat": dict(unlimited), "completions": dict(unlimited)}


MODELS = [
    {"id": "gpt-5.4", "name": "GPT-5.4",
     "capabilities": {"supports": {"vision": True, "toolCalls": True, "reasoningEffort": True},
                      "limits": {"max_prompt_tokens": 272000, "max_output_tokens": 128000,
                                 "max_context_window_tokens": 400000}},
     "policy": {"state": "enabled"},
     "billing": {"multiplier": 1,
                 "tokenPrices": {"inputPrice": 125, "outputPrice": 1000, "cacheReadPrice": 12.5,
                                 "batchSize": 1000000}},
     "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"],
     "defaultReasoningEffort": "medium"},
    {"id": "claude-sonnet-5", "name": "Claude Sonnet 5",
     "capabilities": {"supports": {"vision": True, "toolCalls": True, "reasoningEffort": True},
                      "limits": {"max_prompt_tokens": 168000, "max_output_tokens": 32000}},
     "policy": {"state": "enabled"},
     "billing": {"multiplier": 1,
                 "tokenPrices": {"inputPrice": 300, "outputPrice": 1500, "cacheReadPrice": 30,
                                 "cacheWritePrice": 375, "batchSize": 1000000}},
     "supportedReasoningEfforts": ["low", "medium", "high"]},
    {"id": "gpt-5-mini", "name": "GPT-5 mini",
     "capabilities": {"supports": {"vision": False, "toolCalls": True},
                      "limits": {"max_context_window_tokens": 128000, "max_output_tokens": 64000}},
     "policy": {"state": "enabled"},
     "billing": {"multiplier": 0}},
    {"id": "secret-model", "name": "Secret",
     "capabilities": {"supports": {"vision": False}, "limits": {"max_context_window_tokens": 1000}},
     "policy": {"state": "disabled"}},
]


class Fake:
    def __init__(self, argv):
        self.argv = argv
        self.sessions = {}      # id -> config
        self.pending = []       # messages read while a turn waited
        self.aborted = set()    # sessions asked to abort
        self.tool_results = {}  # requestId -> params
        self.permissions = {}   # requestId -> params
        self.counter = 0

    # -- plumbing ---------------------------------------------------------

    def next_message(self):
        if self.pending:
            return self.pending.pop(0)
        return read()

    def answer(self, msg, result):
        write({"jsonrpc": "2.0", "id": msg["id"], "result": result})

    def error(self, msg, code, message):
        write({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": code, "message": message}})

    def event(self, sid, kind, data, ephemeral=False, agent=None):
        self.counter += 1
        event = {"type": kind, "data": data, "id": "ev-%d" % self.counter,
                 "timestamp": "2026-10-01T12:00:00.000Z", "parentId": None}
        if ephemeral:
            event["ephemeral"] = True
        if agent:
            event["agentId"] = agent
        write({"jsonrpc": "2.0", "method": "session.event",
               "params": {"sessionId": sid, "event": event}})

    def wait(self, predicate):
        """Serve requests until PREDICATE holds.  session.send is deferred."""
        while not predicate():
            msg = read()
            if msg is None:
                sys.exit(0)
            if msg.get("method") == "session.send":
                self.pending.append(msg)
            else:
                self.handle(msg)

    # -- requests ---------------------------------------------------------

    def handle(self, msg):
        method = msg.get("method")
        params = msg.get("params") or {}
        if "id" not in msg:
            return
        log({"method": method, "params": params})
        if SILENT:
            return
        if method == "connect":
            if NO_CONNECT:
                self.error(msg, -32601, "Unhandled method connect")
            else:
                self.answer(msg, {"ok": True, "protocolVersion": PROTOCOL, "version": "9.9.9-fake",
                                  "taskKinds": ["agent", "shell"]})
        elif method == "ping":
            self.answer(msg, {"message": "pong", "timestamp": "2026-10-01T12:00:00Z",
                              "protocolVersion": PROTOCOL})
        elif method == "auth.getStatus":
            if AUTH == "none":
                self.answer(msg, {"isAuthenticated": False, "statusMessage": "Not authenticated"})
            else:
                self.answer(msg, {"isAuthenticated": True, "authType": "user",
                                  "host": "https://github.com", "login": "octocat",
                                  "statusMessage": "Logged in as octocat",
                                  "copilotPlan": "individual_pro"})
        elif method == "models.list":
            if AUTH == "none":
                self.error(msg, -32603, "Request models.list failed with message: Not authenticated. Please authenticate first.")
            else:
                self.answer(msg, {"models": MODELS})
        elif method == "models.getBuiltInCatalog":
            self.answer(msg, {"models": [{"id": "claude-sonnet-5"}, {"id": "gpt-5.4-mini"},
                                         {"id": "gemini-3.8-flash"}]})
        elif method == "account.getQuota":
            if AUTH == "none":
                self.error(msg, -32603, "Request account.getQuota failed with message: Not authenticated. Please authenticate first.")
            else:
                self.answer(msg, {"quotaSnapshots": quota_snapshots()})
        elif method == "session.create":
            sid = params.get("sessionId") or str(uuid.uuid4())
            if SLOW_CREATE:
                time.sleep(SLOW_CREATE)
            self.sessions[sid] = params
            self.answer(msg, self.opened(sid, params))
        elif method == "session.resume":
            sid = params.get("sessionId")
            if not sid or sid.startswith("missing"):
                self.error(msg, -32603, "Request session.resume failed with message: Failed to load session events: Session not found: %s" % sid)
            elif sid.startswith("locked"):
                self.error(msg, -32603, "Request session.resume failed with message: Session %s is in use by another process" % sid)
            else:
                self.sessions[sid] = params
                self.answer(msg, self.opened(sid, params))
        elif method == "sessions.fork":
            sid = params.get("sessionId")
            if not sid or sid.startswith("missing"):
                self.error(msg, -32603, "Request sessions.fork failed with message: Session not found: %s" % sid)
            else:
                prefix = "locked-fork-" if sid.startswith("brittle") else "fork-"
                self.answer(msg, {"sessionId": prefix + uuid.uuid4().hex[:8], "name": "hello (fork)"})
        elif method == "session.send":
            sid = params.get("sessionId")
            if sid not in self.sessions:
                self.error(msg, -32603, "Request session.send failed with message: Session not found for sessionId: %s" % sid)
            elif "refuse" in (params.get("prompt") or ""):
                self.error(msg, -32603, "Request session.send failed with message: the message was refused")
            else:
                self.answer(msg, {"messageId": str(uuid.uuid4())})
                self.turn(sid, params)
        elif method == "session.abort":
            self.aborted.add(params.get("sessionId"))
            self.answer(msg, {})
        elif method == "session.detach":
            self.sessions.pop(params.get("sessionId"), None)
            self.answer(msg, {"success": True})
        elif method == "sessions.delete":
            self.answer(msg, {})
        elif method == "session.tools.handlePendingToolCall":
            self.tool_results[params.get("requestId")] = params
            self.answer(msg, {"success": True})
        elif method == "session.permissions.handlePendingPermissionRequest":
            self.permissions[params.get("requestId")] = params
            self.answer(msg, {"success": True})
        else:
            self.error(msg, -32601, "Unhandled method %s" % method)

    def opened(self, sid, params):
        return {"sessionId": sid, "nativeSessionId": sid, "startTime": "2026-10-01T12:00:00.000Z",
                "isRemote": False, "mode": "interactive", "workspacePath": "/tmp/fake/" + sid,
                "capabilities": {"ui": {"elicitation": False}}, "modelState": {"modelId": params.get("model")}}

    # -- turns --------------------------------------------------------------

    def usage(self, sid, finish="stop"):
        data = {"model": self.sessions.get(sid, {}).get("model") or "fake",
                "inputTokens": 2112, "outputTokens": 7, "cacheReadTokens": 2000,
                "cacheWriteTokens": 100, "cost": 1.0, "finishReason": finish,
                "quotaSnapshots": quota_snapshots()}
        if not LEGACY:
            data["copilotUsage"] = {"totalNanoAiu": 1000000000, "tokenDetails": [
                {"tokenType": "input", "tokenCount": 12, "batchSize": 1000000, "costPerBatch": 125},
                {"tokenType": "cache_read", "tokenCount": 2000, "batchSize": 1000000, "costPerBatch": 12},
                {"tokenType": "cache_write", "tokenCount": 100, "batchSize": 1000000, "costPerBatch": 150},
                {"tokenType": "output", "tokenCount": 7, "batchSize": 1000000, "costPerBatch": 1000}]}
        self.event(sid, "assistant.usage", data, ephemeral=True)

    def idle(self, sid, aborted=False):
        self.aborted.discard(sid)
        data = {"mode": "interactive"}
        if aborted:
            data["aborted"] = True
        self.event(sid, "assistant.turn_end", {"turnId": "0"})
        self.event(sid, "session.idle", data, ephemeral=True)

    def turn(self, sid, params):
        text = params.get("prompt") or ""
        self.aborted.discard(sid)   # an abort from before the turn is moot
        self.event(sid, "user.message", {"content": text, "attachments": params.get("attachments") or []})
        self.event(sid, "assistant.turn_start", {"turnId": "0"})
        if "die" in text:
            self.usage(sid, "tool_calls")
            sys.stderr.write("fake-copilot: dying on request\n")
            sys.stderr.flush()
            sys.exit(3)
        if "subagent" in text:
            self.event(sid, "assistant.message_delta", {"messageId": "ms", "deltaContent": "sub"},
                       ephemeral=True, agent="agent-1")
            self.event(sid, "assistant.usage", {"model": "fake", "inputTokens": 50, "outputTokens": 5,
                                                "cost": 0.0}, ephemeral=True, agent="agent-1")
            self.event(sid, "session.error", {"errorType": "query", "message": "sub-agent trouble"},
                       agent="agent-1")
            self.event(sid, "session.idle", {"mode": "interactive"}, ephemeral=True, agent="agent-1")
        if "fail" in text:
            self.event(sid, "session.error", {"errorType": "quota", "message": "You have no AI credits left",
                                              "statusCode": 402})
            self.idle(sid)
            return
        if "hang" in text:
            self.event(sid, "assistant.message_delta", {"messageId": "m0", "deltaContent": "wait"},
                       ephemeral=True)
            if "ignore" in text:
                self.wait(lambda: False)
            self.wait(lambda: sid in self.aborted)
            self.event(sid, "abort", {"reason": "user initiated"})
            self.idle(sid, aborted=True)
            return
        if "compact" in text:
            self.event(sid, "session.compaction_start", {})
            self.event(sid, "session.compaction_complete", {"success": True, "preCompactionTokens": 150000,
                                                            "postCompactionTokens": 12000})
        if "permission" in text:
            self.event(sid, "permission.requested",
                       {"requestId": "perm-1",
                        "permissionRequest": {"kind": "custom-tool", "toolName": "echo",
                                              "toolDescription": "Echo", "args": {}}})
            self.wait(lambda: "perm-1" in self.permissions)
            decision = self.permissions["perm-1"].get("result", {}).get("kind", "?")
            self.event(sid, "assistant.message_delta", {"messageId": "mp", "deltaContent": decision + " "},
                       ephemeral=True)
        if "call echo" in text:
            self.event(sid, "assistant.message",
                       {"messageId": "m1", "content": "",
                        "toolRequests": [{"toolCallId": "call_fake_1", "name": "echo",
                                          "arguments": {"text": "ping"}, "type": "function"}]})
            self.usage(sid, "tool_calls")
            self.event(sid, "tool.execution_start", {"toolCallId": "call_fake_1", "toolName": "echo",
                                                     "arguments": {"text": "ping"}})
            self.event(sid, "external_tool.requested",
                       {"requestId": "req-1", "sessionId": sid, "toolCallId": "call_fake_1",
                        "toolName": "echo", "arguments": {"text": "ping"}})
            self.wait(lambda: "req-1" in self.tool_results or sid in self.aborted)
            if sid in self.aborted:
                self.event(sid, "external_tool.completed", {"requestId": "req-1"})
                self.event(sid, "abort", {"reason": "user initiated"})
                self.idle(sid, aborted=True)
                return
            result = self.tool_results.pop("req-1")
            self.event(sid, "external_tool.completed", {"requestId": "req-1"})
            self.event(sid, "tool.execution_complete",
                       {"toolCallId": "call_fake_1",
                        "success": result.get("result", {}).get("resultType") == "success",
                        "result": {"content": result.get("result", {}).get("textResultForLlm", "")}})
        self.event(sid, "assistant.reasoning_delta", {"reasoningId": "r1", "deltaContent": "hmm"},
                   ephemeral=True)
        self.event(sid, "assistant.reasoning", {"reasoningId": "r1", "content": "hmm"})
        for piece in ("hel", "lo"):
            self.event(sid, "assistant.message_delta", {"messageId": "m2", "deltaContent": piece},
                       ephemeral=True)
        self.event(sid, "assistant.message", {"messageId": "m2", "content": "hello"})
        self.usage(sid, "length" if "long" in text else "stop")
        self.event(sid, "session.usage_info", {"tokenLimit": 400000, "currentTokens": 2119,
                                               "messagesLength": 4}, ephemeral=True)
        self.idle(sid)

    # -- main loop ----------------------------------------------------------

    def run(self):
        log({"start": True, "argv": self.argv, "cwd": os.getcwd(),
             "node_debug": os.environ.get("NODE_DEBUG")})
        while True:
            msg = self.next_message()
            if msg is None:
                return
            self.handle(msg)


if __name__ == "__main__":
    Fake(sys.argv[1:]).run()
