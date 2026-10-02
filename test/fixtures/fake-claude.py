#!/usr/bin/env python3
"""A fake `claude` CLI for the harness-provider-claude tests.

It speaks the subset of the Claude Code stream-json protocol that the
provider relies on: the system/init banner, the SDK MCP handshake over
control requests, streamed assistant text, a hosted tool call served by
the harness, the tool-result echo, rate limit events, usage reports
and the final result.  It stays alive between turns so the keep-alive
path is tested, and it honours an interrupt control request.

Behaviour is chosen by the prompt text:
  "call echo"  -> issues a tools/call for mcp__harness__echo first
  "call bash"  -> calls the built-in Bash tool first, as if extra
                  arguments had given the model built-in tools
  "search the web"
               -> searches for "emacs" with the built-in WebSearch tool
                  when --tools turns it on, else with the harness's
                  mcp__harness__web_search when the harness serves one,
                  else not at all
  "hang"       -> starts a turn and waits for an interrupt (or forever
                  with "hang ignore", to exercise the kill path)
  "die"        -> exits mid-turn without a result
Anything else streams the text "hello" and finishes.

These words add the gaps a real turn has, each as a pause (below) and
in this order, so one prompt can combine them:
  "compacting"  -> the CLI compacts first: a system/status message,
                   a pause, then the compact boundary
  "slow-start"  -> a pause before the model's first event
  "slow-tool"   -> the echo tool call's input streams in pieces, with a
                   pause in the middle (implies "call echo")
  "slow-think"  -> a pause inside the thinking block, which carries no
                   text: only a signature, as the real CLI sends it
  "slow-text"   -> the text streams as "Hel", a pause, then "lo"
  "paragraphs"  -> the text is "One." "\\n\\n" "Two.", the middle delta
                   being whitespace only

A pause waits for the file GATE.N when HARNESS_FAKE_CLAUDE_GATE=GATE,
N counting the process's pauses from 1, so a test can look at what the
harness shows during each gap and then release it; otherwise it sleeps
HARNESS_FAKE_CLAUDE_PAUSE seconds (default 1.5).

Tool calls pass the CLI's permission check first, decided by the
command line as the real CLI decides it: --permission-mode
bypassPermissions or a matching --allowedTools rule (a tool name,
mcp__SERVER, or mcp__SERVER__ followed by a glob) runs the call; else
--permission-prompt-tool stdio asks the harness with a can_use_tool
control request; else the call is denied with a permission_denied
system message.  A denied call gets an error tool result and is listed
in the result's permission_denials.  A permitted WebSearch call returns
search results the way the real tool words them; any other built-in
tool returns "ran TOOL".

Like the real CLI, each result's total_cost_usd is the running total
of the process: every turn adds 0.01, and --resume or --fork-session
starts from 0.05, the spend the session restores.

The environment picks the account:
  HARNESS_FAKE_CLAUDE_AUTH=subscription  a claude.ai Max login: the
      initialize answer names it, get_usage reports the plan's quota
      and rate_limit_event messages carry its windows
  HARNESS_FAKE_CLAUDE_AUTH=api           an API key: no quota, no
      rate limit events
  unset                                  an older CLI: no account in
      the initialize answer and no get_usage control request
  HARNESS_FAKE_CLAUDE_OVERAGE=1          rate limit events say the
      account is drawing on extra usage

The MCP handshake only runs when --mcp-config is given, so the
provider's quota probe (initialize and get_usage, then end of input)
works too.  If HARNESS_FAKE_CLAUDE_ARGV names a file, a JSON object
with the argv, the cwd and the CLAUDECODE environment variable is
written there.
"""

import json
import os
import sys
import time
import uuid

AUTH = os.environ.get("HARNESS_FAKE_CLAUDE_AUTH", "")
OVERAGE = bool(os.environ.get("HARNESS_FAKE_CLAUDE_OVERAGE"))
GATE = os.environ.get("HARNESS_FAKE_CLAUDE_GATE")
PAUSE = float(os.environ.get("HARNESS_FAKE_CLAUDE_PAUSE", "1.5"))
GATE_TIMEOUT = 60
TURN_COST = 0.01
RESTORED_COST = 0.05


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
    """The value of the last FLAG in ARGV, or None."""
    value = None
    for i, arg in enumerate(argv[:-1]):
        if arg == flag:
            value = argv[i + 1]
    return value


def allowed_tools(argv):
    """The allow rules of every --allowedTools flag in ARGV.

    The flag takes the arguments up to the next option, each a comma or
    space separated list of rules."""
    rules = []
    i = 0
    while i < len(argv):
        if argv[i] in ("--allowedTools", "--allowed-tools"):
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                rules.extend(argv[i].replace(",", " ").split())
                i += 1
        else:
            i += 1
    return rules


def builtin_tools(argv):
    """The built-in tools the --tools flag of ARGV turns on (none for "")."""
    value = arg_value(argv, "--tools") or ""
    return value.replace(",", " ").split()


def web_search_results(query):
    """What the real WebSearch tool returns for QUERY, give or take."""
    links = [{"title": "GNU Emacs", "url": "https://www.gnu.org/software/emacs/"}]
    return ('Web search results for query: "%s"\n\nLinks: %s\n\n'
            "GNU Emacs is an extensible, customizable text editor." % (query, json.dumps(links)))


def rule_allows(rule, tool):
    """Whether the allow RULE covers TOOL.

    A rule names a tool, a whole MCP server (mcp__SERVER), or tools of
    one server by glob (mcp__SERVER__*); an unanchored glob such as
    mcp__* allows nothing."""
    if rule == tool:
        return True
    if not rule.startswith("mcp__"):
        return False
    server, sep, glob = rule[len("mcp__"):].partition("__")
    if not sep:
        return tool.startswith(rule + "__")
    return glob.endswith("*") and "*" not in server and tool.startswith(rule[:-1])


def account():
    """The `account' of the initialize answer, or None."""
    if AUTH == "subscription":
        return {"email": "user@example.com",
                "organization": "user@example.com's Organization",
                "subscriptionType": "Claude Max", "apiProvider": "firstParty"}
    if AUTH == "api":
        return {"tokenSource": "claude.ai", "apiKeySource": "ANTHROPIC_API_KEY",
                "apiProvider": "firstParty"}
    return None


def limit(kind, group, percent, resets, active, model=None):
    return {"kind": kind, "group": group, "percent": percent, "severity": "normal",
            "resets_at": resets, "is_active": active,
            "scope": ({"model": {"id": None, "display_name": model}, "surface": None}
                      if model else None)}


def rate_limits():
    """The plan's quota as the real get_usage reports it."""
    session_reset = "2026-10-01T09:39:59.819728+00:00"
    week_reset = "2026-10-03T13:59:59.819752+00:00"
    return {
        "five_hour": {"utilization": 8, "resets_at": session_reset},
        "seven_day": {"utilization": 57, "resets_at": week_reset},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "extra_usage": {"is_enabled": False, "monthly_limit": 5000, "used_credits": 0,
                        "utilization": 0, "currency": "USD", "decimal_places": 2,
                        "disabled_reason": "out_of_credits"},
        "limits": [limit("session", "session", 8, session_reset, False),
                   limit("weekly_all", "weekly", 57, week_reset, True),
                   limit("weekly_scoped", "weekly", 50, week_reset, False, "Fable")],
        "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
                  "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2},
                  "percent": 0, "severity": "normal", "enabled": False,
                  "disabled_reason": "out_of_credits"},
        "model_scoped": [{"display_name": "Fable", "utilization": 50, "resets_at": week_reset}],
    }


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
        self.total = RESTORED_COST if resume else 0.0
        self.needs_handshake = "--mcp-config" in argv
        self.permission_mode = arg_value(argv, "--permission-mode") or "default"
        self.allowed = allowed_tools(argv)
        self.builtin = builtin_tools(argv)
        self.prompt_tool = arg_value(argv, "--permission-prompt-tool")
        self.denials = []
        self.interrupted = False
        self.pauses = 0

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

    def answer(self, request_id, response):
        emit({"type": "control_response",
              "response": {"subtype": "success", "request_id": request_id,
                           "response": response}})

    def usage_report(self):
        """What get_usage answers: the session's spend and the plan's quota."""
        session = {"total_cost_usd": round(self.total, 6), "total_api_duration_ms": 0,
                   "total_duration_ms": 0, "total_lines_added": 0,
                   "total_lines_removed": 0, "model_usage": {}}
        if AUTH == "subscription":
            return {"session": session, "subscription_type": "max",
                    "rate_limits_available": True, "rate_limits": rate_limits()}
        return {"session": session, "subscription_type": None,
                "rate_limits_available": False, "rate_limits": None}

    def control(self, msg):
        """Answer a control request from the harness."""
        rid = msg.get("request_id")
        sub = msg.get("request", {}).get("subtype")
        if sub == "initialize":
            response = {"commands": [], "models": []}
            if account():
                response["account"] = account()
            self.answer(rid, response)
            if self.needs_handshake:
                self.handshake()
        elif sub == "get_usage":
            if AUTH:
                self.answer(rid, self.usage_report())
            else:
                emit({"type": "control_response",
                      "response": {"subtype": "error", "request_id": rid,
                                   "error": "Unsupported control request subtype: get_usage"}})
        else:
            self.answer(rid, {})

    # -- turns --------------------------------------------------------------

    def pause(self):
        """Wait out one gap of a turn: for the next gate file, or a while."""
        self.pauses += 1
        if not GATE:
            time.sleep(PAUSE)
            return
        path = "%s.%d" % (GATE, self.pauses)
        deadline = time.time() + GATE_TIMEOUT
        while not os.path.exists(path):
            if time.time() > deadline:
                sys.stderr.write("fake-claude: gave up waiting for %s\n" % path)
                sys.stderr.flush()
                return
            time.sleep(0.01)

    def stream(self, event):
        emit({"type": "stream_event", "event": event, "session_id": self.session_id})

    def usage(self):
        return {"input_tokens": 12, "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 2000, "output_tokens": 7}

    def result(self, subtype="success", is_error=False, text="hello",
               stop_reason="end_turn"):
        self.total += TURN_COST
        emit({"type": "result", "subtype": subtype, "is_error": is_error,
              "duration_ms": 5, "num_turns": 1, "result": text,
              "session_id": self.session_id, "total_cost_usd": round(self.total, 6),
              "usage": self.usage(), "stop_reason": stop_reason,
              "permission_denials": self.denials})

    def permit(self, tool, tool_input, tool_use_id):
        """Decide a call of TOOL as the CLI does.

        Return (True, INPUT) to run it with INPUT, or (False, MESSAGE)."""
        if self.permission_mode == "bypassPermissions" or \
           any(rule_allows(rule, tool) for rule in self.allowed):
            return True, tool_input
        if self.prompt_tool == "stdio":
            rid = "perm-" + uuid.uuid4().hex[:8]
            emit({"type": "control_request", "request_id": rid,
                  "request": {"subtype": "can_use_tool", "tool_name": tool,
                              "input": tool_input, "tool_use_id": tool_use_id,
                              "permission_suggestions": []}})
            answer = self.wait_control_response(rid).get("response") or {}
            if answer.get("behavior") == "allow":
                return True, answer.get("updatedInput", tool_input)
            return False, answer.get("message") or "Permission denied"
        message = ("Claude requested permissions to use %s, but you haven't granted it yet."
                   % tool)
        emit({"type": "system", "subtype": "permission_denied", "tool_name": tool,
              "tool_use_id": tool_use_id, "message": message,
              "session_id": self.session_id})
        return False, message

    def tool_use(self, tool, tool_input, tool_use_id, slow=False):
        """Have the model call TOOL, run it if permitted, and echo its result.

        With SLOW the input streams in pieces with a pause after the
        first, as when a model writes a large input.  Return False when
        an interrupt ended the turn meanwhile."""
        self.stream({"type": "content_block_start", "index": 0,
                     "content_block": {"type": "tool_use", "id": tool_use_id,
                                       "name": tool, "input": {}}})
        encoded = json.dumps(tool_input)
        if slow:
            cut = encoded.index(":") + 1
            pieces = [encoded[:cut], None, encoded[cut:cut + 4], encoded[cut + 4:]]
        else:
            pieces = [encoded]
        for piece in pieces:
            if piece is None:
                self.pause()
                continue
            self.stream({"type": "content_block_delta", "index": 0,
                         "delta": {"type": "input_json_delta", "partial_json": piece}})
        self.stream({"type": "content_block_stop", "index": 0})
        emit({"type": "assistant", "session_id": self.session_id,
              "message": {"id": "msg_1", "role": "assistant", "model": self.model,
                          "content": [{"type": "tool_use", "id": tool_use_id,
                                       "name": tool, "input": tool_input}],
                          "stop_reason": "tool_use", "usage": self.usage()}})
        permitted, value = self.permit(tool, tool_input, tool_use_id)
        if self.interrupted:
            return False
        if not permitted:
            self.denials.append({"tool_name": tool, "tool_use_id": tool_use_id,
                                 "tool_input": tool_input})
            content, is_error = value, True
        elif tool.startswith("mcp__harness__"):
            self.rpc_id += 1
            reply = self.mcp({"jsonrpc": "2.0", "id": self.rpc_id, "method": "tools/call",
                              "params": {"name": tool, "arguments": value}})
            if self.interrupted:
                return False
            content = reply.get("result", {}).get("content", [])
            is_error = bool(reply.get("result", {}).get("isError"))
        elif tool == "WebSearch":
            content, is_error = web_search_results(value.get("query", "")), False
        else:
            content, is_error = "ran %s" % tool, False
        emit({"type": "user", "session_id": self.session_id,
              "message": {"role": "user",
                          "content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                       "content": content, "is_error": is_error}]}})
        return True

    def rate_limit_event(self):
        if AUTH == "api":
            return
        emit({"type": "rate_limit_event",
              "rate_limit_info": {
                  "status": "allowed", "resetsAt": 1800000000, "rateLimitType": "five_hour",
                  "overageStatus": "allowed" if OVERAGE else "rejected",
                  "isUsingOverage": OVERAGE,
                  "unifiedWindows": {
                      "five_hour": {"utilization": 0.09, "resetsAt": 1800000000},
                      "seven_day": {"utilization": 0.42, "resetsAt": 1800500000}}},
              "session_id": self.session_id})

    def compact(self):
        """Compact the conversation the way the CLI announces it."""
        emit({"type": "system", "subtype": "status", "status": "compacting",
              "session_id": self.session_id})
        self.pause()
        emit({"type": "system", "subtype": "status", "status": None,
              "session_id": self.session_id})
        emit({"type": "system", "subtype": "compact_boundary", "session_id": self.session_id,
              "compact_metadata": {"trigger": "auto", "pre_tokens": 1000}})

    def turn(self, message):
        self.interrupted = False
        self.denials = []
        blocks = message.get("message", {}).get("content", [])
        if isinstance(blocks, str):
            text = blocks
        else:
            text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        emit({"type": "system", "subtype": "init", "session_id": self.session_id,
              "model": self.model, "cwd": os.getcwd(), "tools": [],
              "mcp_servers": [{"name": "harness", "status": "connected"}],
              "apiKeySource": "ANTHROPIC_API_KEY" if AUTH == "api" else "none",
              "permissionMode": self.permission_mode})
        if "compacting" in text:
            self.compact()
        if "slow-start" in text:
            self.pause()
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
        calls = []
        if "call echo" in text or "slow-tool" in text:
            calls.append(("mcp__harness__echo", {"text": "ping"}, "toolu_fake_1", "slow-tool" in text))
        if "call bash" in text:
            calls.append(("Bash", {"command": "ls"}, "toolu_fake_2", False))
        if "search the web" in text:
            # The model sees only the tools it was given.
            if "WebSearch" in self.builtin:
                calls.append(("WebSearch", {"query": "emacs"}, "toolu_fake_3", False))
            elif any(t.get("name") == "web_search" for t in self.tools):
                calls.append(("mcp__harness__web_search", {"query": "emacs"}, "toolu_fake_3", False))
        for tool, tool_input, tool_use_id, slow in calls:
            if not self.tool_use(tool, tool_input, tool_use_id, slow):
                self.result(subtype="error_during_execution", is_error=True,
                            text="Request was aborted")
                return
        # Thinking block with empty text and only a signature, as the CLI sends.
        self.stream({"type": "content_block_start", "index": 1,
                     "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
        if "slow-think" in text:
            self.pause()
        self.stream({"type": "content_block_delta", "index": 1,
                     "delta": {"type": "signature_delta", "signature": "sig"}})
        self.stream({"type": "content_block_stop", "index": 1})
        if "paragraphs" in text:
            pieces = ["One.", "\n\n", "Two."]
        elif "slow-text" in text:
            pieces = ["Hel", None, "lo"]
        else:
            pieces = ["hel", "lo"]
        self.stream({"type": "content_block_start", "index": 2,
                     "content_block": {"type": "text", "text": ""}})
        for piece in pieces:
            if piece is None:
                self.pause()
                continue
            self.stream({"type": "content_block_delta", "index": 2,
                         "delta": {"type": "text_delta", "text": piece}})
        self.stream({"type": "content_block_stop", "index": 2})
        reply = "".join(p for p in pieces if p is not None)
        self.stream({"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                     "usage": {"input_tokens": 12, "cache_creation_input_tokens": 100,
                               "cache_read_input_tokens": 2000, "output_tokens": 7}})
        self.stream({"type": "message_stop"})
        emit({"type": "assistant", "session_id": self.session_id,
              "message": {"id": "msg_2", "role": "assistant", "model": self.model,
                          "content": [{"type": "thinking", "thinking": "", "signature": "sig"},
                                      {"type": "text", "text": reply}],
                          "stop_reason": "end_turn", "usage": self.usage()}})
        self.rate_limit_event()
        self.result(text=reply)

    # -- main loop ----------------------------------------------------------

    def run(self):
        path = os.environ.get("HARNESS_FAKE_CLAUDE_ARGV")
        if path:
            with open(path, "w") as f:
                json.dump({"argv": self.argv,
                           "cwd": os.getcwd(),
                           "claudecode": os.environ.get("CLAUDECODE")}, f)
        while True:
            msg = self.next_message()
            if msg is None:
                return
            kind = msg.get("type")
            if kind == "control_request":
                self.control(msg)
            elif kind == "user":
                self.turn(msg)


if __name__ == "__main__":
    Fake(sys.argv[1:]).run()
