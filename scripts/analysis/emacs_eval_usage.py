#!/usr/bin/env python3
"""Classify the stored calls of the removed ``emacs_eval`` tool.

``emacs_eval`` ran model-written Lisp in the user's own Emacs.  Before it was
removed (see docs/trust-model.md), what agents used it for was read out of the
stored transcripts; this script is that reading, kept so that it can be
repeated and its numbers checked.  The report is
docs/analysis/emacs-eval-usage-2026-10-23.md.

HOW THE INPUT IS MADE -- READ THIS FIRST
----------------------------------------
The harness state directory (~/.emacs.d/.local/cache/harness/) is not visible
to ``bash`` or to a script run from it, so this script cannot read the
transcripts itself.  The ``grep`` tool can: the call below writes one line per
call, and a result that large is saved by the harness under its ``outputs/``
directory, which the sandbox shows read-only.  Run

    grep (the tool) pattern  "kind":"tool-call","tool":"emacs_eval"
                     path     ~/.emacs.d/.local/cache/harness/sessions
                     glob     *.nodes.jsonl
                     case_sensitive true     max_results 3000

then give this script the path the tool reports ("The full output was saved
to ...").  Each input line is ``PATH:LINE: JSON``, the JSON of the node cut at
about 500 columns by the tool: the code of a call is the first thing in it, so
a call's first forms are almost always there, and a long call is cut.  The
script counts what it can see, says how many calls were cut, and reads a
second number for the features that matter (see ``FEATURES``) from the
tool's own totals when ``--full-line-counts`` is given.

WHAT IT DOES
------------
* Every call gets one *primary category*: the first of ``CATEGORIES`` whose
  rule matches the visible code, in that order, so the table adds up.
* Every call also gets the *features* it shows (a call may show several), so
  that a call that starts in a buffer and ends in a file write is counted
  under both.
* The ``harness-call`` methods agents named are tallied by name.
* Nothing is printed that could be a secret: paths are shortened to ``~/``,
  session ids, hosts, long tokens and the usual key prefixes are replaced
  (see ``sanitize``).  Only names of credential files are counted, never
  their contents, which this script never sees.

    python3 -I scripts/analysis/emacs_eval_usage.py OUTPUT_FILE [--json]
            [--examples CATEGORY[:N]] [--methods] [--self-test]
"""

import argparse
import collections
import datetime
import json
import os
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Reading the lines the grep tool wrote.

LINE_RE = re.compile(r"^(?P<path>[^\s:][^:]*\.nodes\.jsonl):(?P<line>\d+): (?P<json>\{.*)$")
CODE_START = '"input":{"code":"'
TRUNCATED_MARK = "[... omitted end of long line]"
SESSION_RE = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.nodes\.jsonl")

_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}


def unescape(text):
    """Return TEXT with its JSON string escapes undone, leniently.

    The text may stop in the middle of an escape (the tool cut the line)."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            break
        e = text[i + 1]
        if e == "u":
            hexa = text[i + 2:i + 6]
            if len(hexa) == 4 and re.fullmatch(r"[0-9a-fA-F]{4}", hexa):
                cp = int(hexa, 16)
                i += 6
                # A surrogate pair is one character.
                if 0xD800 <= cp < 0xDC00 and text[i:i + 2] == "\\u":
                    low = text[i + 2:i + 6]
                    if re.fullmatch(r"[0-9a-fA-F]{4}", low) and 0xDC00 <= int(low, 16) < 0xE000:
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (int(low, 16) - 0xDC00)
                        i += 6
                out.append(chr(cp))
                continue
            break
        out.append(_ESCAPES.get(e, e))
        i += 2
    return "".join(out)


def code_of(json_text):
    """Return (CODE, COMPLETE) from the cut JSON of a call node.

    COMPLETE is false when the visible part ends inside the code."""
    start = json_text.find(CODE_START)
    if start < 0:
        return "", False
    i = start + len(CODE_START)
    j = i
    n = len(json_text)
    while j < n:
        c = json_text[j]
        if c == "\\":
            j += 2
            continue
        if c == '"':
            return unescape(json_text[i:j]), True
        j += 1
    visible = json_text[i:]
    cut = visible.find(TRUNCATED_MARK)
    if cut >= 0:
        visible = visible[:cut]
    return unescape(visible.rstrip()), False


CALL_ID_RE = re.compile(r'"call-id":"([^"]+)"')


def merge_copies(found):
    """Return FOUND, the calls of every line, with the copies of a call merged.

    A fork keeps a copy of the nodes of the session it forked from, so the
    same call (the same call-id) is a line of the fork's file too.  One
    call is kept, the most complete copy, with the model and the time any
    copy shows.  A session and the forks that share a call with it are one
    session from then on, named by the smallest of their ids."""
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    by_id = {}
    order = []
    for call in found:
        key = call["call_id"] or ("line", call["session"], call["line"])
        find(call["session"])
        if key not in by_id:
            by_id[key] = []
            order.append(key)
        by_id[key].append(call)
    for key in order:
        group = by_id[key]
        for other in group[1:]:
            parent[find(other["session"])] = find(group[0]["session"])
        for call in group:
            if call["origin"]:
                parent[find(call["origin"])] = find(group[0]["session"])
    families = {}
    for sid in list(parent):
        families.setdefault(find(sid), set()).add(sid)
    name = {root: min(members) for root, members in families.items()}
    merged = []
    for key in order:
        group = by_id[key]
        best = max(group, key=lambda c: (c["complete"], c["chars"]))
        call = dict(best)
        call["model"] = next((c["model"] for c in group if c["model"]), None)
        call["ts"] = next((c["ts"] for c in group if c["ts"]), None)
        call["copies"] = len(group)
        call["files"] = {c["session"] for c in group}
        call["session"] = name[find(best["session"])]
        merged.append(call)
    return merged


def parse(lines):
    """Return the calls the grep output LINES hold, as dicts.

    One call for each call-id (see `merge_copies`); `copies` says how many
    lines it was, `files` which session files they were in."""
    calls = []
    for raw in lines:
        raw = raw.rstrip("\n")
        m = LINE_RE.match(raw)
        if not m:
            continue
        js = m.group("json")
        code, complete = code_of(js)
        sid = SESSION_RE.search(m.group("path"))
        model = re.search(r'"meta":\{"model":"([^"]*)"', js)
        stamp = re.search(r'"session":"[0-9a-f-]{36}","ts":(1[78]\d{8}(?:\.\d+)?)', js)
        origin = re.search(r'"session":"([0-9a-f-]{36})"', js)
        call_id = CALL_ID_RE.search(js)
        calls.append({
            "session": sid.group(1) if sid else "?",
            "origin": origin.group(1) if origin else None,
            "call_id": call_id.group(1) if call_id else None,
            "line": int(m.group("line")),
            "code": code,
            "complete": complete,
            "model": model.group(1) if model else None,
            "ts": float(stamp.group(1)) if stamp else None,
            "chars": len(code),
        })
    return merge_copies(calls)


# --------------------------------------------------------------------------
# Sanitizing: nothing printed may carry a secret or name a person's projects.

_SANITIZERS = [
    (re.compile(r"/home/[^/\s\"']+/"), "~/"),
    (re.compile(r"/Users/[^/\s\"']+/"), "~/"),
    (re.compile(r"(?<=/documents/)[^/\s\"']+"), "<project>"),
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "<id>"),
    (re.compile(r"\b(?:ghp|gho|ghs|github_pat|sk|pk|xox[abprs]|AKIA|ASIA|AIza)[-_A-Za-z0-9]{12,}"), "<key>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.?[A-Za-z0-9_-]*"), "<jwt>"),
    (re.compile(r"-----BEGIN [A-Z ]+-----"), "<pem>"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "<ip>"),
    (re.compile(r"\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:zone|com|net|org|io|dev|app|cloud|local|lan|home)\b"),
     "<host>"),
    (re.compile(r"\b[A-Za-z0-9+/_=-]{32,}\b"), "<blob>"),
]


def sanitize(text):
    """Return TEXT with paths shortened and anything key-like replaced."""
    for rx, repl in _SANITIZERS:
        text = rx.sub(repl, text)
    return text


# --------------------------------------------------------------------------
# What a call does.  The rules read the visible code only.

def rx(*alts):
    return re.compile("|".join(alts))


CRED_FILES = rx(r"\.ssh\b", r"authinfo", r"\.netrc", r"k3s\.yaml", r"kubeconfig", r"\.kube\b",
                r"dockerconfig", r"\.docker/config", r"id_rsa", r"id_ed25519", r"\.aws\b",
                r"\.gnupg", r"\.pgpass", r"\.npmrc", r"\.pypirc", r"credentials\.(?:json|yaml|yml|toml)",
                r"secret[-_a-z]*\.(?:json|yaml|yml|el|txt)", r"\.password-store")
SECRET_WORDS = re.compile(r"\b(?:password|api[-_ ]?key|secret|token)\b", re.IGNORECASE)
PROCESS = rx(r"\(make-process\b", r"\(start-process\b", r"\(start-file-process\b", r"\(call-process\b",
             r"\(call-process-region\b", r"\(process-file\b", r"\(process-lines\b", r"\(shell-command",
             r"\(async-shell-command\b", r"\(shell-command-to-string\b", r"\(vterm-send",
             r"\(comint-send", r"\(term-send", r"\(get-process\b", r"\(delete-process\b",
             r"\(process-list\b", r"\(process-status\b", r"\(kill-process\b", r"\(interrupt-process\b",
             r"\(process-send-", r"\(accept-process-output\b")
# The forms of PROCESS that start a program (the others only look at one that runs).
PROCESS_START = rx(r"\(make-process\b", r"\(start-process\b", r"\(start-file-process\b", r"\(call-process\b",
                   r"\(call-process-region\b", r"\(process-file\b", r"\(process-lines\b", r"\(shell-command",
                   r"\(async-shell-command\b", r"\(shell-command-to-string\b")
_STR = r'"((?:[^"\\]|\\.)*)"'
_ARG = r'(?:"(?:[^"\\]|\\.)*"|[^\s"()]+|\((?:[^()]|\([^()]*\))*\))'
# (call-process "prog" ...), (process-lines "prog" ...), (process-file "prog" ...)
PROGRAM_FIRST = re.compile(r"\((?:call-process|process-lines|process-file)\s+" + _STR)
# (call-process-region START END "prog" ...)
PROGRAM_REGION = re.compile(r"\(call-process-region\s+" + _ARG + r"\s+" + _ARG + r"\s+" + _STR)
# (start-process NAME BUFFER "prog" ...)
PROGRAM_THIRD = re.compile(r"\((?:start-process|start-file-process)\s+" + _ARG + r"\s+" + _ARG + r"\s+" + _STR)
# (make-process ... :command '("prog" ...)) or :command (list "prog" ...)
PROGRAM_COMMAND = re.compile(r":command\s+(?:'\(|\(list\s+)\s*" + _STR)
# (shell-command-to-string "prog args | other"): the first word is the program
PROGRAM_SHELL = re.compile(r"\((?:shell-command-to-string|shell-command|async-shell-command)\s+" + _STR)
# The recipe scripts/analysis/extract_usage_data.py prints for gathering session data.
RECIPE = rx(r"\bhc-str\b", r"\bcli-str\b", r"gather_sessions_raw", r"usage-analysis", r"sessions_raw")
BUFFER_NAME = re.compile(r'\((?:with-current-buffer|get-buffer|get-buffer-create|switch-to-buffer|set-buffer|'
                         r'buffer-local-value\s+[^"]*|display-buffer|pop-to-buffer)\s+"((?:[^"\\]|\\.)*)"')
HARNESS_CALL = re.compile(r"\(harness-call(?:-async)?\s+(?:'|\(quote\s+)([A-Za-z0-9/_.:-]+)")
HARNESS_CALL_ANY = rx(r"\(harness-call(?:-async)?\b", r"\(funcall\s+#?'harness-call\b",
                      r"\(harness-run-command\b", r"\(harness-await\b")
FILE_MUTATION = rx(r"\(write-region\b", r"\(copy-file\b", r"\(rename-file\b", r"\(delete-file\b",
                   r"\(delete-directory\b", r"\(make-directory\b", r"\(set-file-modes\b",
                   r"\(with-temp-file\b", r"\(append-to-file\b", r"\(make-symbolic-link\b",
                   r"\(add-name-to-file\b", r"\(write-file\b", r"\(save-buffer\b", r"\(basic-save-buffer\b",
                   r"\(set-file-times\b", r"\(f-write", r"\(f-delete", r"\(f-touch")
UI = rx(r"\bharness-ui-", r"\bharness-chat-", r"\bharness-compose-", r"\bharness-pending-",
        r"\bharness-sessions-", r"\bharness-tasks-board", r"\(selected-window\b", r"\(window-",
        r"\(set-window-", r"\(switch-to-buffer\b", r"\(display-buffer\b", r"\(pop-to-buffer\b",
        r"\(redisplay\b", r"\(force-mode-line-update\b", r"\(recenter\b", r"\(face-attribute\b",
        r"\(set-face-", r"\(frame-", r"\(overlay", r"\(get-text-property\b", r"\(text-properties-at\b",
        r"\(propertize\b", r"\(posn-", r"\(line-pixel-height\b", r"\(font-", r"\(image-")
# A live buffer of the user's Emacs, named or listed.  A `with-temp-buffer'
# only builds a string or reads a file, and is not one.
BUFFER_OPS = rx(r'\((?:with-current-buffer|set-buffer|get-buffer|get-buffer-create|kill-buffer|display-buffer|'
                r'switch-to-buffer|pop-to-buffer|buffer-local-value\s+\S+)\s+"',
                r"\(buffer-list\b", r"\(buffer-name\b", r"\(buffer-file-name\b", r"\(current-buffer\b",
                r"\(buffer-live-p\b", r"#'buffer-name\b", r"\(with-current-buffer\s+(?:buf|buffer|b|(?:\(get-buffer))",
                r"\(erase-buffer\b", r"\(narrow-to-region\b")
INTROSPECT = rx(r"\(symbol-value\b", r"\(boundp\b", r"\(fboundp\b", r"\(featurep\b", r"\(documentation\b",
                r"\(describe-", r"\(symbol-function\b", r"\(symbol-file\b", r"\(find-function", r"\(help-function",
                r"\(macroexpand", r"\(apropos", r"\(func-arity\b", r"\(advice-", r"\(symbol-plist\b",
                r"\bload-path\b", r"\(emacs-version\b", r"\bsystem-type\b", r"\(getenv\b", r"\bemacs-version\b",
                r"\(default-value\b", r"\(local-variable-p\b", r"\(commandp\b", r"\(autoloadp\b",
                r"\(byte-code-function-p\b", r"\(subrp\b", r"\(native-comp-", r"\(indirect-function\b",
                r"\(where-is-internal\b", r"\(key-binding\b", r"\(called-interactively-p\b",
                r"\bfeatures\b", r"\bmajor-mode\b", r"\bminor-mode-alist\b", r"\(cl-loop for \S+ being")
# Changes the running Emacs rather than reading it: code defined or advised,
# hooks and timers set, a harness variable assigned, code loaded.
CHANGES_STATE = rx(r"\((?:setq-default|set-default|defun|defvar|defalias|fset|defmacro|defcustom|cl-defun)\b",
                   r"\((?:advice-add|advice-remove|add-hook|remove-hook|load|load-file|eval-buffer|eval-region)\b",
                   r"\((?:define-key|global-set-key|keymap-set|setopt|customize-set-variable)\b",
                   r"\((?:run-with-timer|run-at-time|run-with-idle-timer|cancel-timer|revert-buffer|kill-emacs)\b",
                   r"\(setq\s+harness-[a-z-]+", r"\(harness-reload\b")
HARNESS_SYM = re.compile(r"\bharness-(?!call\b|call-async\b|method-exists-p\b|await\b)[a-z0-9-]+")
FILE_READ = rx(r"\(insert-file-contents\b", r"\(file-exists-p\b", r"\(directory-files", r"\(file-attributes\b",
               r"\(file-truename\b", r"\(locate-file\b", r"\(file-readable-p\b", r"\(file-directory-p\b",
               r"\(file-regular-p\b", r"\(file-symlink-p\b", r"\(expand-file-name\b", r"\(file-name-",
               r"\(file-newer-than-file-p\b", r"\(find-file-noselect\b", r"\(directory-file-name\b",
               r"\(file-modes\b", r"\(file-size", r"\(f-read", r"\(f-exists", r"/proc/")
TIME = rx(r"\(current-time\b", r"\(format-time-string\b", r"\(float-time\b", r"\(time-subtract\b")

# Features: a call may show several.  Order is the order of the table.
FEATURES = [
    ("credential file named", CRED_FILES),
    ("changes the running Emacs", CHANGES_STATE),
    ("usage-analysis recipe", RECIPE),
    ("secret-ish word", SECRET_WORDS),
    ("starts, drives or inspects a process", PROCESS),
    ("harness-call", HARNESS_CALL_ANY),
    ("mutates files", FILE_MUTATION),
    ("UI / display internals", UI),
    ("buffer reads and edits", BUFFER_OPS),
    ("symbol / environment introspection", INTROSPECT),
    ("mentions harness-* symbols besides harness-call", HARNESS_SYM),
    ("reads files", FILE_READ),
]

# Primary categories, first match wins.
CATEGORIES = [
    ("credentials", "names a credential file", CRED_FILES),
    ("process", "starts, drives or inspects a process", PROCESS),
    ("analysis recipe", "gathers session data for the usage analysis", RECIPE),
    ("harness-call", "calls a harness method", HARNESS_CALL_ANY),
    ("file mutation", "writes, copies, renames or deletes files", FILE_MUTATION),
    ("ui poking", "reads or sets display and UI state", UI),
    ("buffers", "reads or edits buffers", BUFFER_OPS),
    ("introspection", "asks what a symbol, feature or variable is", INTROSPECT),
    ("harness internals", "reads other harness-* variables and functions", HARNESS_SYM),
    ("file reads", "reads files and directories", FILE_READ),
]
OTHER = ("other", "none of the above")


# --------------------------------------------------------------------------
# Variable reads: which variables a call looks at, and what it does to the value.

_NUMBER = re.compile(r"^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$")


def lisp_symbols(code):
    """The symbols of CODE as (name, kind, head): kind is fun, quoted, keyword, var or atom.

    A rough reader, enough to tell a variable from a function call or a quoted
    name without evaluating anything: `var` is an unquoted symbol that is not
    the first of its list; HEAD is the function of the innermost list it is in
    ("" when none).  Strings, comments and character literals are skipped."""
    i, n = 0, len(code)
    stack = []  # for each open paren: (is a quoted list, its head)
    pending = False
    first = False
    out = []
    while i < n:
        c = code[i]
        if c == ";":
            while i < n and code[i] != "\n":
                i += 1
        elif c == '"':
            i += 1
            while i < n and code[i] != '"':
                i += 2 if code[i] == "\\" else 1
            i += 1
            pending = first = False
        elif c == "?":
            i += 3 if code[i + 1:i + 2] == "\\" else 2
            pending = first = False
        elif c in "'`":
            pending = True
            i += 1
        elif c == "#":
            pending = pending or code[i + 1:i + 2] == "'"
            i += 2 if code[i + 1:i + 2] == "'" else 1
        elif c == ",":
            i += 2 if code[i + 1:i + 2] == "@" else 1
            pending = False
        elif c == "(":
            stack.append([pending or (stack[-1][0] if stack else False), ""])
            pending = False
            first = True
            i += 1
        elif c == ")":
            if stack:
                stack.pop()
            pending = first = False
            i += 1
        elif c in "[]" or c.isspace():
            first = first and c.isspace()
            i += 1
        else:
            j = i
            while j < n and not code[j].isspace() and code[j] not in "()[]\";'`,":
                j += 2 if code[j] == "\\" else 1
            token = code[i:j]
            i = j
            quoted = pending or (stack[-1][0] if stack else False)
            if _NUMBER.match(token) or token in ("nil", "t", "."):
                kind = "atom"
            elif token.startswith(":"):
                kind = "keyword"
            elif quoted:
                kind = "quoted"
            elif first:
                kind = "fun"
                stack[-1][1] = token
            else:
                kind = "var"
            out.append((token, kind, stack[-1][1] if stack and kind == "var" else ""))
            pending = first = False
    return out


# Forms that take the name of a variable, quoted.  The first group reads the
# value; the second only asks about the variable.
VALUE_FORMS = ("symbol-value", "default-value", "default-toplevel-value", "buffer-local-value")
ASK_FORMS = ("boundp", "default-boundp", "local-variable-p", "local-variable-if-set-p", "special-variable-p",
             "custom-variable-p", "get-variable-watchers", "documentation-property")
_NAMED_VARIABLE = re.compile(r"\((" + "|".join(re.escape(f) for f in VALUE_FORMS + ASK_FORMS) + r")\s+(?:'|\(quote\s+)([^\s()]+)")
# (get 'symbol 'property) and its kin: a symbol's property list is not a variable.
_PROPERTY_READ = re.compile(r"\((get|symbol-plist|function-get)\s+(?:'|\(quote\s+)([^\s()]+)(?:\s+(?:'|\(quote\s+)([^\s()]+))?")
# Variables of Emacs and its packages that the calls name without a harness- prefix.
GLOBALS = frozenset("""gcs-done gc-elapsed gc-cons-threshold gc-cons-percentage default-directory profiler-cpu-log
profiler-max-stack-depth profiler-log-size load-path features custom-file user-emacs-directory user-init-file
after-load-alist load-history timer-list timer-idle-list system-type major-mode tabulated-list-entries
server-socket-dir process-environment initial-environment exec-path emacs-version window-system
straight--recipe-cache straight--repo-cache straight-version doom-user-dir buffer-file-name
face-remapping-alist line-spacing minor-mode-list""".split())
# What a call does to a variable, by the function the variable is an argument of.
NAVIGATION = [
    ("count the elements", ("length", "hash-table-count", "seq-length", "safe-length", "proper-list-p")),
    ("take an element by position", ("nth", "elt", "aref", "car", "cdr", "cadr", "cddr", "nthcdr", "last", "car-safe",
                                     "seq-first", "seq-elt", "seq-rest", "cl-first", "cl-second")),
    ("look up a key", ("plist-get", "plist-member", "alist-get", "assq", "assoc", "gethash", "map-elt", "cl-getf",
                       "rassq", "assoc-string")),
    ("take a window of elements", ("seq-take", "seq-drop", "cl-subseq", "take", "butlast", "seq-subseq")),
    ("visit or filter the elements", ("mapcar", "mapc", "maphash", "mapconcat", "seq-filter", "seq-map", "seq-find",
                                      "seq-remove", "cl-remove-if", "cl-remove-if-not", "cl-find", "cl-find-if",
                                      "cl-loop", "dolist", "seq-do", "cl-some", "cl-every", "seq-some", "seq-count",
                                      "cl-count-if", "seq-reduce", "seq-sort", "sort", "cl-sort", "delq", "delete",
                                      "remove", "copy-sequence", "reverse", "nreverse", "append")),
    ("print or cut the text", ("format", "prin1-to-string", "pp-to-string", "pp", "substring", "truncate-string-to-width",
                               "princ", "message", "string-join", "string-trim")),
    ("ask what it is", ("type-of", "hash-table-p", "listp", "vectorp", "stringp", "recordp", "consp", "null", "not",
                        "and", "or", "if", "when", "unless", "cl-typep", "hash-table-keys", "hash-table-values",
                        "symbolp", "functionp", "bufferp", "integerp", "numberp", "eq", "equal", "eql", "memq",
                        "member", "cl-struct-slot-info", "cl-struct-slot-value")),
]


def variable_reads(code):
    """What CODE reads of variables: ({name: set of what is done}, {name asked about}).

    A variable is read by name (`symbol-value` and its kin), or by being a
    harness-* symbol or one of GLOBALS where a value is wanted.  What is done
    to it is the NAVIGATION class of the function it is an argument of, or
    `harness function` for one of the harness's own (an accessor, usually) and
    `other` for the rest."""
    reads = {}
    asked = set()
    for form, name in _NAMED_VARIABLE.findall(code):
        if form in VALUE_FORMS:
            reads.setdefault(name, set())
        else:
            asked.add(name)
    for name, kind, head in lisp_symbols(code):
        if kind != "var" or not (name.startswith("harness-") or name in GLOBALS):
            continue
        what = "bound or passed on"
        if head.startswith("harness-"):
            what = "harness function"
        else:
            for label, heads in NAVIGATION:
                if head in heads:
                    what = label
                    break
        reads.setdefault(name, set()).add(what)
    return reads, asked


def program_name(text):
    """The program a command string or path names: its first word, without directories."""
    words = text.split()
    while words and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[0]):  # leading VAR=value
        words.pop(0)
    return os.path.basename(words[0]) if words else ""


def programs_of(code):
    """The programs the call starts, in the order they appear (a name once per form)."""
    found = []
    for rule in (PROGRAM_FIRST, PROGRAM_REGION, PROGRAM_THIRD):
        found += [(m.start(), program_name(m.group(1))) for m in rule.finditer(code)]
    for m in re.finditer(r"\(make-process\b", code):
        c = PROGRAM_COMMAND.search(code, m.end(), m.end() + 800)
        if c:
            found.append((m.start(), program_name(c.group(1))))
    for m in PROGRAM_SHELL.finditer(code):
        found.append((m.start(), program_name(m.group(1).replace('\\"', '"'))))
    return [name for _pos, name in sorted(found) if name]


def classify(code):
    """Return (PRIMARY, FEATURE-NAMES, METHODS) for CODE."""
    feats = [name for name, r in FEATURES if r.search(code)]
    primary = OTHER[0]
    for name, _doc, r in CATEGORIES:
        if r.search(code):
            primary = name
            break
    methods = HARNESS_CALL.findall(code)
    return primary, feats, methods


def method_family(method):
    return method.split("/", 1)[0] if "/" in method else method


# What the calls that name the harness log did with it.
LOG_BUFFER = "*harness-log*"
LOG_SEARCH = re.compile(r"\((?:re-)?search-(?:forward|backward)\b|\bstring-match|\bkeep-lines\b|\bflush-lines\b"
                        r"|\bhow-many\b|\bcount-matches\b")
LOG_FROM_END = re.compile(r"\(goto-char \(point-max\)\)|\(- \(point-max\)|\(forward-line -\d+\)"
                          r"|\((?:re-)?search-backward\b")
LOG_TO_FILE = re.compile(r"\((?:write-region|copy-file)\b")

KNOWN_BUFFERS = ("*harness-log*", "*Messages*", "*scratch*", "*trace-output*", "*Warnings*", "*Backtrace*")


def generalize_buffer(name):
    """Return the kind of buffer NAME is, so that no title, host or path is printed."""
    name = unescape(name)
    if name in KNOWN_BUFFERS:
        return name
    if name.startswith("*harness: "):
        return "*harness: <title>* (a session's chat)"
    for prefix, kind in (("*harness sessions", "*harness sessions* (the session list)"),
                         ("*harness tasks", "*harness tasks: <project>* (the task board)"),
                         ("*harness settings", "*harness settings: <project>*"),
                         ("*harness worktrees", "*harness worktrees*"),
                         ("*harness", "*harness …* (another view of the harness)")):
        if name.startswith(prefix):
            return kind
    for prefix in ("vterm", "eat", "shell", "eshell", "term", "compilation"):
        if name.startswith("*" + prefix):
            return "*%s…* (a terminal)" % prefix
    if name.startswith("*") and name.endswith("*"):
        return "*<another special buffer>* (a process, demo or scratch buffer of the agent's own)"
    return "<a file or other buffer>"


# --------------------------------------------------------------------------
# The numbers.

def log_use(calls):
    """(calls, sessions) of the calls that name the harness log, and of those that did each thing to it."""
    log = [c for c in calls if LOG_BUFFER in c["code"]]

    def tally(test):
        hit = [c for c in log if test(c["code"])]
        return len(hit), len({c["session"] for c in hit})

    return {
        "named": tally(lambda t: True),
        "searched": tally(lambda t: bool(LOG_SEARCH.search(t))),
        "from_end": tally(lambda t: bool(LOG_FROM_END.search(t))),
        "searched_or_from_end": tally(lambda t: bool(LOG_SEARCH.search(t) or LOG_FROM_END.search(t))),
        "to_file": tally(lambda t: bool(LOG_TO_FILE.search(t))),
    }


def summarize(calls):
    total = len(calls)
    cut = sum(1 for c in calls if not c["complete"])
    sessions = collections.Counter(c["session"] for c in calls)
    models = collections.Counter((c["model"] or "?").split(":", 1)[0] for c in calls)
    days = collections.Counter()
    for c in calls:
        if c["ts"]:
            days[datetime.datetime.fromtimestamp(c["ts"], datetime.timezone.utc).strftime("%Y-%m-%d")] += 1
    primary = collections.Counter()
    features = collections.Counter()
    methods = collections.Counter()
    method_calls = collections.Counter()
    families = collections.Counter()
    cred_names = collections.Counter()
    var_calls = collections.defaultdict(collections.Counter)  # category -> {"read": n, "asked": n}
    var_names = collections.Counter()
    var_sessions = collections.defaultdict(set)
    var_ops = collections.Counter()
    var_op_calls = collections.defaultdict(set)
    property_calls = 0
    property_forms = collections.Counter()
    property_names = collections.Counter()
    programs = collections.Counter()
    program_sessions = collections.defaultdict(set)
    starts_unseen = 0
    inspect_only = 0
    buffers = collections.Counter()
    buffer_sessions = collections.defaultdict(set)
    primary_sessions = collections.defaultdict(set)
    method_sessions = collections.defaultdict(set)
    feature_sessions = collections.defaultdict(set)
    for c in calls:
        p, feats, ms = classify(c["code"])
        c["primary"], c["features"], c["methods"] = p, feats, ms
        primary[p] += 1
        primary_sessions[p].add(c["session"])
        for f in feats:
            features[f] += 1
            feature_sessions[f].add(c["session"])
        for name in set(BUFFER_NAME.findall(c["code"])):
            kind = generalize_buffer(name)
            buffers[kind] += 1
            buffer_sessions[kind].add(c["session"])
        for m in ms:
            methods[m] += 1
        for m in set(ms):
            method_calls[m] += 1
            method_sessions[m].add(c["session"])
            families[method_family(m)] += 1
        for m in CRED_FILES.finditer(c["code"]):
            cred_names[m.group(0).lstrip("\\")] += 1
        reads, asked = variable_reads(c["code"])
        c["variable_reads"] = reads
        if reads:
            var_calls[p]["read"] += 1
        if asked - set(reads):
            var_calls[p]["asked"] += 1
        for name, ops in reads.items():
            var_names[name] += 1
            var_sessions[name].add(c["session"])
            for op in ops:
                var_ops[op] += 1
            for op in ops:
                var_op_calls[op].add(id(c))
        props = _PROPERTY_READ.findall(c["code"])
        if props:
            property_calls += 1
            for form, _symbol, prop in props:
                property_forms[form] += 1
                if prop:
                    property_names[prop] += 1
        started = set(programs_of(c["code"]))
        for name in started:
            programs[name] += 1
            program_sessions[name].add(c["session"])
        if not started and PROCESS_START.search(c["code"]):
            starts_unseen += 1
        if p == "process" and not PROCESS_START.search(c["code"]):
            inspect_only += 1
    return {
        "calls": total,
        "lines": sum(c["copies"] for c in calls),
        "files": len(set().union(*(c["files"] for c in calls))) if calls else 0,
        "days": days,
        "cut": cut,
        "sessions": len(sessions),
        "top_sessions": sessions.most_common(8),
        "models": models.most_common(),
        "primary": primary,
        "features": features,
        "methods": methods,
        "method_calls": method_calls,
        "families": families,
        "credential_names": cred_names,
        "log": log_use(calls),
        "variable_calls": {k: dict(v) for k, v in var_calls.items()},
        "variable_names": var_names,
        "variable_sessions": {k: len(v) for k, v in var_sessions.items()},
        "variable_ops": {k: len(v) for k, v in var_op_calls.items()},
        "property_calls": property_calls,
        "property_forms": property_forms,
        "property_names": property_names,
        "programs": programs,
        "program_sessions": {k: len(v) for k, v in program_sessions.items()},
        "starts_unseen": starts_unseen,
        "inspect_only": inspect_only,
        "buffers": buffers,
        "buffer_sessions": {k: len(v) for k, v in buffer_sessions.items()},
        "primary_sessions": {k: len(v) for k, v in primary_sessions.items()},
        "method_sessions": {k: len(v) for k, v in method_sessions.items()},
        "feature_sessions": {k: len(v) for k, v in feature_sessions.items()},
        "median_chars": sorted(c["chars"] for c in calls)[total // 2] if total else 0,
    }


def percent(n, total):
    return "%.0f%%" % (100.0 * n / total) if total else "-"


def markdown(summary):
    t = summary["calls"]
    out = []
    out.append("%d calls in %d sessions (the grep output has %d lines in %d session files: forks keep copies "
               "of their parents' calls, and a call is counted once, a session with its forks once); "
               "%d of the calls (%s) are cut by the 500-column window of the grep tool "
               "(median visible code: %d characters)." % (
                   t, summary["sessions"], summary["lines"], summary["files"], summary["cut"],
                   percent(summary["cut"], t), summary["median_chars"]))
    if summary["days"]:
        days = sorted(summary["days"].items())
        out.append("")
        out.append("Where the window shows the time (%d calls): from %s to %s, on %d days; most in a day: %d (%s)." % (
            sum(summary["days"].values()), days[0][0], days[-1][0], len(days),
            max(n for _d, n in days), max(days, key=lambda kv: kv[1])[0]))
    shown = [(name, n) for name, n in summary["models"] if name != "?"]
    out.append("")
    out.append("Models, where the window shows one (%d calls): %s." % (
        sum(n for _name, n in shown), ", ".join("%s %d" % (name, n) for name, n in shown)))
    out.append("")
    out.append("| primary category | what | calls | share | sessions |")
    out.append("|---|---|---:|---:|---:|")
    docs = {name: doc for name, doc, _ in CATEGORIES}
    docs[OTHER[0]] = OTHER[1]
    order = [name for name, _d, _r in CATEGORIES] + [OTHER[0]]
    for name in order:
        n = summary["primary"].get(name, 0)
        out.append("| %s | %s | %d | %s | %d |" % (name, docs[name], n, percent(n, t),
                                                summary["primary_sessions"].get(name, 0)))
    out.append("")
    out.append("| feature (a call may show several) | calls | share | sessions |")
    out.append("|---|---:|---:|---:|")
    for name, _r in FEATURES:
        n = summary["features"].get(name, 0)
        out.append("| %s | %d | %s | %d |" % (name, n, percent(n, t), summary["feature_sessions"].get(name, 0)))
    return "\n".join(out)


def methods_markdown(summary):
    out = ["| harness-call method | calls naming it | sessions |", "|---|---:|---:|"]
    for m, n in summary["method_calls"].most_common():
        out.append("| `%s` | %d | %d |" % (m, n, summary["method_sessions"][m]))
    return "\n".join(out)


def buffers_markdown(summary):
    out = ["| buffer a call names | calls | sessions |", "|---|---:|---:|"]
    for kind, n in summary["buffers"].most_common():
        out.append("| `%s` | %d | %d |" % (kind, n, summary["buffer_sessions"][kind]))
    use = summary["log"]
    out.append("")
    out.append("Of the calls naming `%s` (%d calls, %d sessions): %d searched it for lines (%d sessions), "
               "%d read from its end (%d sessions), %d did either (%d sessions), %d wrote it to a file "
               "(%d sessions)." % ((LOG_BUFFER,) + use["named"] + use["searched"] + use["from_end"]
                                   + use["searched_or_from_end"] + use["to_file"]))
    return "\n".join(out)


def variables_markdown(summary, top=30):
    out = ["| category of the call | calls | read a variable's value | only asked about variables |",
           "|---|---:|---:|---:|"]
    docs = [name for name, _d, _r in CATEGORIES] + [OTHER[0]]
    all_read = all_asked = 0
    for name in docs:
        n = summary["primary"].get(name, 0)
        v = summary["variable_calls"].get(name, {})
        all_read += v.get("read", 0)
        all_asked += v.get("asked", 0)
        out.append("| %s | %d | %d | %d |" % (name, n, v.get("read", 0), v.get("asked", 0)))
    out.append("| all | %d | %d | %d |" % (summary["calls"], all_read, all_asked))
    out.append("")
    out.append("| variable read | calls | sessions |")
    out.append("|---|---:|---:|")
    for name, n in summary["variable_names"].most_common(top):
        out.append("| `%s` | %d | %d |" % (name, n, summary["variable_sessions"][name]))
    out.append("")
    out.append("%d variables in all." % len(summary["variable_names"]))
    out.append("")
    out.append("| what the call does with the variable (it may do several) | calls |")
    out.append("|---|---:|")
    for label, _heads in NAVIGATION + [("harness function", ()), ("bound or passed on", ())]:
        out.append("| %s | %d |" % (label, summary["variable_ops"].get(label, 0)))
    out.append("")
    props = summary["property_forms"]
    out.append("%d calls read a symbol's property (%s); properties named: %s." % (
        summary["property_calls"], ", ".join("%s %d" % kv for kv in props.most_common()) or "none",
        ", ".join("`%s` %d" % kv for kv in summary["property_names"].most_common(12)) or "none"))
    return "\n".join(out)


def programs_markdown(summary):
    out = ["| program a call starts | calls | sessions |", "|---|---:|---:|"]
    for name, n in summary["programs"].most_common():
        out.append("| `%s` | %d | %d |" % (name, n, summary["program_sessions"][name]))
    out.append("")
    out.append("%d more calls start a process whose program the window cuts off or a variable names; "
               "%d calls of the process category start nothing (they look at or delete a process that runs)." % (
                   summary["starts_unseen"], summary["inspect_only"]))
    return "\n".join(out)


def method_examples(calls, method, limit):
    shown = []
    for c in calls:
        if method in c.get("methods", []):
            first = " ".join(sanitize(c["code"]).split())
            shown.append(first[:200] + ("…" if len(first) > 200 else ""))
        if len(shown) >= limit:
            break
    return shown


def examples(calls, category, limit):
    shown = []
    for c in calls:
        if c.get("primary") == category:
            first = " ".join(sanitize(c["code"]).split())
            shown.append(first[:170] + ("…" if len(first) > 170 else ""))
        if len(shown) >= limit:
            break
    return shown


# --------------------------------------------------------------------------
# A check of the parser and the rules on a small fixture.

FIXTURE = r'''/home/u/.emacs.d/.local/cache/harness/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:10: {"kind":"tool-call","tool":"emacs_eval","call-id":"c1","input":{"code":"(harness-call 'session/list)"},"title":"Evaluate in Emacs: (harness-call 'session/list)","meta":{"model":"claude:sonnet"}}
/home/u/.emacs.d/.local/cache/harness/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:11: {"kind":"tool-call","tool":"emacs_eval","call-id":"c2","input":{"code":"(copy-file \"/home/u/documents/proj/k3s.yaml\" \"/tmp/x\" t)"},"title":"t"}
/home/u/.emacs.d/.local/cache/harness/sessions/cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:7: {"kind":"tool-call","tool":"emacs_eval","call-id":"c1","input":{"code":"(harness-call 'session/list)"},"title":"Evaluate in Emacs: (harness-call 'session/list)","meta":{"model":"claude:sonnet"}}
/home/u/.emacs.d/.local/cache/harness/sessions/bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:3: {"kind":"tool-call","tool":"emacs_eval","call-id":"c3","input":{"code":"(with-current-buffer \"*scratch*\"\n  (buffer-string))"},"title":"t","meta":{"model":"deepseek:flash"}}
/home/u/.emacs.d/.local/cache/harness/sessions/bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:4: {"kind":"tool-call","tool":"emacs_eval","call-id":"c4","input":{"code":"(list (fboundp 'car) (boundp 'load-path) \"café \\\"q\\\"\")"},"title":"t"}
/home/u/.emacs.d/.local/cache/harness/sessions/bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee.nodes.jsonl:5: {"kind":"tool-call","tool":"emacs_eval","call-id":"c5","input":{"code":"(let ((x 1)) (process-lines \"/opt/android-sdk/platform-tools/adb\" \"devices\") (harness-call 'worktree/remove \"/p\" \"/q\" t) and then it is cut here [... omitted end of long line]
'''


def distinct_calls(lines):
    """(lines, calls) of the call nodes among LINES, the output of one pattern's grep.

    The grep tool counts lines, and a fork keeps a copy of the lines of its
    parent, so the count of calls is the number of distinct call-ids."""
    found = [(LINE_RE.match(raw.rstrip("\n")), raw) for raw in lines]
    ids = []
    for m, _raw in found:
        if m:
            c = CALL_ID_RE.search(m.group("json"))
            ids.append(c.group(1) if c else (m.group("path"), m.group("line")))
    return len(ids), len(set(ids))


def self_test():
    calls = parse(FIXTURE.splitlines())
    assert len(calls) == 5, len(calls)  # c1 is in two files: a fork's copy is the same call
    s = summarize(calls)
    assert s["calls"] == 5 and s["lines"] == 6 and s["files"] == 3, s
    assert s["sessions"] == 2 and s["cut"] == 1, s  # the fork and its parent are one session
    p = [c["primary"] for c in calls]
    assert p == ["harness-call", "credentials", "buffers", "introspection", "process"], p
    assert calls[3]["code"].endswith(r'"café \"q\"")'), calls[3]["code"]
    assert dict(s["models"]) == {"claude": 1, "deepseek": 1, "?": 3}, s["models"]
    assert s["methods"]["session/list"] == 1 and s["methods"]["worktree/remove"] == 1, s["methods"]
    assert s["programs"]["adb"] == 1 and s["starts_unseen"] == 0, (s["programs"], s["starts_unseen"])
    assert s["log"]["named"] == (0, 0), s["log"]
    log_calls = [{"code": '(with-current-buffer "*harness-log*" (goto-char (point-max)) (search-backward "x" nil t))',
                  "session": "s1"},
                 {"code": '(with-current-buffer "*harness-log*" (buffer-size))', "session": "s2"},
                 {"code": '(with-current-buffer "*harness-log*" (write-region nil nil "/p"))', "session": "s2"}]
    u = log_use(log_calls)
    assert u["named"] == (3, 2) and u["searched"] == (1, 1) and u["from_end"] == (1, 1), u
    assert u["searched_or_from_end"] == (1, 1) and u["to_file"] == (1, 1), u
    assert programs_of('(start-process "n" nil "bash" "-c" "x") (make-process :name "m" :command \'("ssh" "h"))'
                       ' (shell-command-to-string "A=1 /usr/bin/find . | head")') == ["bash", "ssh", "find"]
    assert programs_of('(start-process "n" (get-buffer-create "b") "/bin/ls")') == ["ls"]
    assert programs_of('(start-process "n" b prog)') == []
    assert "k3s.yaml" in s["credential_names"], s["credential_names"]
    assert sanitize("/home/noah/documents/web/funkyboy.zone/k3s.yaml sk-abcdefghijklmnop12345 "
                    "deb67e06-aaef-44b0-bebc-3852f031d158 10.0.0.12") == \
        "~/documents/<project>/<host>/k3s.yaml <key> <id> <ip>", sanitize(
            "/home/noah/documents/web/funkyboy.zone/k3s.yaml sk-abcdefghijklmnop12345 "
            "deb67e06-aaef-44b0-bebc-3852f031d158 10.0.0.12")
    assert distinct_calls(FIXTURE.splitlines()) == (6, 5), distinct_calls(FIXTURE.splitlines())
    assert unescape(r'a\nb\"c\\dé😀') == 'a\nb"c\\dé😀'
    assert unescape("cut \\") == "cut "
    print("self-test ok")


# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("output", nargs="?", help="the file the grep tool saved")
    ap.add_argument("--json", action="store_true", help="print the numbers as JSON")
    ap.add_argument("--methods", action="store_true", help="print the harness-call methods table")
    ap.add_argument("--variables", action="store_true", help="print which variables the calls read, and how")
    ap.add_argument("--buffers", action="store_true", help="print the buffers the calls name")
    ap.add_argument("--method-examples", metavar="METHOD[:N]", action="append", default=[],
                    help="print N (default 4) sanitized first lines of calls naming a harness method")
    ap.add_argument("--extras", action="store_true",
                    help="print the credential file names, the programs and the session counts")
    ap.add_argument("--examples", metavar="CATEGORY[:N]", action="append", default=[],
                    help="print N (default 6) sanitized first lines of calls of a category")
    ap.add_argument("--distinct", action="store_true",
                    help="count lines and distinct calls in each file given, the output of one pattern's grep "
                         "(output FILE may be repeated: pass more after the first with --also)")
    ap.add_argument("--also", metavar="FILE", action="append", default=[],
                    help="more files for --distinct")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not args.output:
        ap.error("the file the grep tool saved is required")
    if args.distinct:
        for name in [args.output] + args.also:
            n, calls = distinct_calls(Path(name).read_text(encoding="utf-8", errors="replace").splitlines())
            print("%s: %d lines, %d distinct calls" % (name, n, calls))
        return 0
    lines = Path(args.output).read_text(encoding="utf-8", errors="replace").splitlines()
    calls = parse(lines)
    if not calls:
        print("no emacs_eval calls found in %s" % args.output, file=sys.stderr)
        return 1
    summary = summarize(calls)
    if args.json:
        printable = {k: (dict(v) if isinstance(v, collections.Counter) else v) for k, v in summary.items()}
        print(json.dumps(printable, indent=2, sort_keys=True))
        return 0
    print(markdown(summary))
    if args.methods:
        print()
        print(methods_markdown(summary))
    if args.buffers:
        print()
        print(buffers_markdown(summary))
    if args.variables:
        print()
        print(variables_markdown(summary))
    for spec in args.method_examples:
        name, _, n = spec.partition(":")
        print()
        print("## calls naming %s" % name)
        for line in method_examples(calls, name, int(n) if n else 4):
            print("-", line)
    if args.extras:
        print()
        print("credential file names:", dict(summary["credential_names"].most_common()))
        print()
        print(programs_markdown(summary))
        print()
        print("calls per session (top):", summary["top_sessions"])
    for spec in args.examples:
        name, _, n = spec.partition(":")
        print()
        print("## examples: %s" % name)
        for line in examples(calls, name, int(n) if n else 6):
            print("-", line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
