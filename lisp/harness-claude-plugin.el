;;; harness-claude-plugin.el --- The Claude Code plugin through which the harness serves its tools  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; By default the harness serves its tools to the `claude' CLI as an SDK
;; MCP server called "harness": the CLI asks for them over the control
;; channel of its own standard input and output (harness-provider-claude.el).
;; To anything that watches the CLI -- the OpenTelemetry events a company
;; collects, say -- that is a server of an unusual kind (`sdk', which only
;; programs that embed the CLI register), named by nobody.  The
;; experimental plugin mode (`harness-provider-claude-plugin') serves the
;; tools the CLI has no counterpart of the usual way instead: as the MCP
;; server of a Claude Code plugin, which is how Claude Code is extended in
;; the ordinary course.  This library is the plugin and what it talks to.
;;
;; The plugin.  `harness-claude-plugin-write' writes a plugin called
;; `emacs-harness' into the state directory and the CLI is started with
;; `--plugin-dir' naming it.  Its manifest names it; its .mcp.json declares
;; one stdio server, `harness', which runs the relay beside it.  A plugin
;; cannot declare an `sdk' server (Claude Code refuses one: only the host
;; application registers those), and the tools of a stdio server are named
;; `mcp__plugin_emacs-harness_harness__TOOL' by the CLI.  The files do not
;; depend on the session, so one directory serves every CLI process; what
;; differs per process is its environment (below).
;;
;; The relay.  A stdio MCP server is a program that speaks newline
;; delimited JSON-RPC on its standard input and output.  The harness is a
;; running Emacs that cannot be that program, so the plugin's server is a
;; few lines of bash that connect to the harness (bash's /dev/tcp, else
;; nc), answer its authentication challenge with one line, and then copy
;; bytes both ways.  Nothing else: the protocol is spoken by the
;; harness, which is why the same code answers the SDK channel and this
;; one.
;;
;; The listener.  The harness listens on 127.0.0.1, one port for every
;; CLI process, for as long as there is one (it starts with the first
;; bridge and stops with the last).  The listener speaks first: it sends
;; its instance id (`harness-instance-id') and a fresh nonce.  The relay
;; checks the id against HARNESS_MCP_INSTANCE, the id of the harness
;; process that started it, and sends back the nonce and its token
;; (`HARNESS-MCP-AUTH 1 INSTANCE NONCE TOKEN').  A token is 256 random
;; bits derived from this instance's secret for one CLI process, made by
;; `harness-claude-plugin-open', passed to the process and through it to
;; the relay in its environment (HARNESS_MCP_PORT, HARNESS_MCP_INSTANCE
;; and HARNESS_MCP_TOKEN) -- never in a file, never on a command line.
;; The token binds the connection to that process's session, so a
;; connection reaches the tools of its own session and no other; a
;; listener whose instance id is not the one the relay was started by
;; never sees the token, and a wrong instance, a wrong token, a nonce
;; this connection did not get, a second connection with a token already
;; in use, or silence for ten seconds is closed.  Nothing the listener
;; receives is trusted beyond the answer: each line goes to the process's
;; receiver, the provider, which parses it as it parses the CLI's own
;; messages.  What the token gives is what the CLI's own tools already
;; have, the harness's tools of this session, each call decided by the
;; harness as any call is: the CLI's Bash inherits its environment, token
;; included, and could connect when the relay is not, which is no more
;; than the model can do anyway.  A process of the same user that can
;; read that environment or ptrace the CLI has the CLI's authority
;; already; docs/trust-model.md says so.
;;
;; Claude Code decides whether to load the plugin: an organisation can
;; forbid `--plugin-dir' (the managed setting disableSideloadFlags, with
;; which the CLI exits at once), and the provider then goes back to the SDK
;; server.  Nothing here changes Claude Code's permission rules or
;; settings.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-instance)

(defvar harness-state-directory)

;;;; The plugin

(defconst harness-claude-plugin-name "emacs-harness"
  "The name of the Claude Code plugin the harness writes.
Claude Code namespaces everything a plugin brings under it, so keep it
short: the API limits a tool name to 64 characters, and the CLI makes
one of `mcp__plugin_NAME_SERVER__TOOL'.  Names that begin with claude- or
anthropic- are reserved for Anthropic's own.")

(defconst harness-claude-plugin-server "harness"
  "The key of the plugin's MCP server in its .mcp.json.")

(defconst harness-claude-plugin-tool-prefix
  (format "mcp__plugin_%s_%s__" harness-claude-plugin-name harness-claude-plugin-server)
  "What the CLI puts before the name of a tool the plugin's server serves.")

(defconst harness-claude-plugin-server-label
  (format "plugin:%s:%s" harness-claude-plugin-name harness-claude-plugin-server)
  "How the CLI names the plugin's server in its status (`mcp_status').")

(defconst harness-claude-plugin--version "1.0.0"
  "The version in the manifest.
Change it with the files, so that anything that remembers a plugin by it
loads the new ones.")

(defconst harness-claude-plugin--relay-script
  "#!/bin/bash
# Relays the stdio MCP transport of Claude Code to the running Emacs agent
# harness, which serves the tools.  Written by the harness
# (lisp/harness-claude-plugin.el); the harness gives the CLI the port, the
# token of its session and the id of the harness instance in
# HARNESS_MCP_PORT, HARNESS_MCP_TOKEN and HARNESS_MCP_INSTANCE.
port=${HARNESS_MCP_PORT:-}
token=${HARNESS_MCP_TOKEN:-}
instance=${HARNESS_MCP_INSTANCE:-}
if [ -z \"$port\" ] || [ -z \"$token\" ] || [ -z \"$instance\" ]; then
  echo \"harness-mcp-relay: HARNESS_MCP_PORT, HARNESS_MCP_TOKEN and HARNESS_MCP_INSTANCE are not set; this plugin serves the Claude Code sessions the Emacs agent harness starts\" >&2
  exit 1
fi
# The harness says who it is before the token is sent: a listener that
# cannot name this instance is another program, and never gets it.
handshake() {
  local input=$1 output=$2 magic version who nonce answer
  if ! IFS=' ' read -r -t 10 -u \"$input\" magic version who nonce; then
    echo \"harness-mcp-relay: the harness sent no authentication challenge\" >&2
    return 1
  fi
  if [ \"$magic\" != \"HARNESS-MCP-AUTH\" ] || [ \"$version\" != \"1\" ]; then
    echo \"harness-mcp-relay: the harness sent no authentication challenge this relay knows\" >&2
    return 1
  fi
  if [ \"$who\" != \"$instance\" ]; then
    echo \"harness-mcp-relay: the listener is another harness instance ($who), not $instance\" >&2
    return 1
  fi
  printf 'HARNESS-MCP-AUTH 1 %s %s %s\\n' \"$instance\" \"$nonce\" \"$token\" >&\"$output\"
  if ! IFS=' ' read -r -t 10 -u \"$input\" magic version answer; then
    echo \"harness-mcp-relay: the harness did not answer this relay's credential\" >&2
    return 1
  fi
  if [ \"$magic\" != \"HARNESS-MCP-AUTH\" ] || [ \"$version\" != \"1\" ] || [ \"$answer\" != \"OK\" ]; then
    echo \"harness-mcp-relay: the harness refused this relay's credential\" >&2
    return 1
  fi
  return 0
}
if { exec 3<>\"/dev/tcp/127.0.0.1/$port\"; } 2>/dev/null; then
  handshake 3 3 || exit 1
  # The harness's answers to the CLI, in the background (it reads from the
  # connection, not from the /dev/null a background command gets).
  cat <&3 &
  reader=$!
  # The CLI's requests to the harness, until the CLI closes its end.
  cat >&3
  kill \"$reader\" 2>/dev/null
  exit 0
fi
# A bash without /dev/tcp: nc, if it can reach the harness at all.
if ! command -v nc >/dev/null 2>&1 || ! nc -z 127.0.0.1 \"$port\" 2>/dev/null; then
  echo \"harness-mcp-relay: cannot reach the harness on 127.0.0.1:$port\" >&2
  exit 1
fi
coproc RELAY { nc 127.0.0.1 \"$port\"; }
handshake \"${RELAY[0]}\" \"${RELAY[1]}\" || { kill \"$RELAY_PID\" 2>/dev/null; exit 1; }
cat <&\"${RELAY[0]}\" &
reader=$!
cat >&\"${RELAY[1]}\"
kill \"$reader\" 2>/dev/null
kill \"$RELAY_PID\" 2>/dev/null
exit 0
"
  "The relay, a bash script.
It connects to 127.0.0.1:$HARNESS_MCP_PORT, where the harness first
sends a challenge naming its instance id and a nonce, and answers it
with $HARNESS_MCP_INSTANCE, the nonce and $HARNESS_MCP_TOKEN.  It sends
the token only to a listener that proved it is the harness instance the
CLI was started by, and consumes the challenge and the harness's answer,
so the CLI sees nothing but MCP.  Then it copies standard input to the
connection and the connection to standard output.  bash's /dev/tcp does
it; a bash built without it falls back to nc, with the same handshake.
It ends when the CLI closes its end, and closes the connection with it;
it fails at once when the harness cannot be reached or refuses the
credential, rather than leave the CLI waiting for a server that is not
there.")

(defun harness-claude-plugin--manifest ()
  "Return the plugin's manifest, .claude-plugin/plugin.json, as JSON text."
  (concat (harness-json-encode-text
           (list :name harness-claude-plugin-name
                 :version harness-claude-plugin--version
                 :description "The tools of the Emacs agent harness, served by the running harness to the Claude Code sessions it starts."
                 :author (list :name "Emacs agent harness")
                 :license "GPL-3.0-or-later"))
          "\n"))

(defun harness-claude-plugin--mcp-config ()
  "Return the plugin's .mcp.json as JSON text.
One stdio server runs the relay with bash.  The port, the instance id
and the token are the CLI's own environment variables, which the CLI
passes on by expanding `${NAME}' in the server's `env' as it loads the
plugin."
  (concat (harness-json-encode-text
           (list :mcpServers
                 (list (intern (concat ":" harness-claude-plugin-server))
                       (list :command "bash"
                             :args (vector "${CLAUDE_PLUGIN_ROOT}/bin/harness-mcp-relay")
                             :env (list :HARNESS_MCP_PORT "${HARNESS_MCP_PORT}"
                                        :HARNESS_MCP_INSTANCE "${HARNESS_MCP_INSTANCE}"
                                        :HARNESS_MCP_TOKEN "${HARNESS_MCP_TOKEN}")))))
          "\n"))

(defun harness-claude-plugin-directory ()
  "Return the directory the plugin is written to: under the state directory."
  (expand-file-name (concat "claude-plugin/" harness-claude-plugin-name)
                    harness-state-directory))

(defun harness-claude-plugin--files ()
  "Return the plugin's files as (RELATIVE-NAME CONTENT MODE)."
  (list (list ".claude-plugin/plugin.json" (harness-claude-plugin--manifest) #o600)
        (list ".mcp.json" (harness-claude-plugin--mcp-config) #o600)
        (list "bin/harness-mcp-relay" harness-claude-plugin--relay-script #o700)))

(defun harness-claude-plugin--private-directory (dir)
  "Create DIR and the directories above it that are missing, for this user only."
  (let ((parent (file-name-directory (directory-file-name dir))))
    (unless (file-directory-p dir)
      (unless (file-directory-p parent)
        (harness-claude-plugin--private-directory parent))
      (make-directory dir)
      (set-file-modes dir #o700))))

(defun harness-claude-plugin--trusted-p (dir)
  "Non-nil when DIR is the user's own and no one else can write to it.
The plugin's relay runs with the user's rights whenever a session
starts, so a directory someone else could change is not used."
  (let ((attrs (file-attributes dir 'integer)))
    (and attrs
         (eq t (file-attribute-type attrs))
         (eql (file-attribute-user-id attrs) (user-uid))
         (zerop (logand #o022 (file-modes dir))))))

(defun harness-claude-plugin-write ()
  "Write the plugin's files, if they are not there as they should be.
Return the plugin's directory, for `--plugin-dir'.  The files are the
same for every session, so a directory that holds them already is left
alone, and one that differs is brought up to date file by file (a new
harness may have a new relay).  Signal an error when the directory
cannot be written or is not private to this user."
  (let ((dir (harness-claude-plugin-directory)))
    (harness-claude-plugin--private-directory dir)
    (unless (harness-claude-plugin--trusted-p dir)
      (error "The plugin directory %s is not private to this user" dir))
    (dolist (spec (harness-claude-plugin--files))
      (pcase-let* ((`(,name ,content ,mode) spec)
                   (path (expand-file-name name dir)))
        (harness-claude-plugin--private-directory (file-name-directory path))
        (unless (and (equal (harness-read-file path) content)
                     (eql (file-modes path) mode))
          (with-file-modes #o600
            (harness-write-file-atomically path content))
          (set-file-modes path mode))))
    dir))

;;;; The listener

(defconst harness-claude-plugin--greeting-seconds 10
  "Seconds a connection may stay silent before it has said who it is.")

(defconst harness-claude-plugin--max-line (* 64 1024 1024)
  "The longest line a connection may send, in characters.
A call's arguments are what is sent, a whole file at most; a connection
that sends more without a newline is closed.")

(defconst harness-claude-plugin--max-greeting 1024
  "The longest first line a connection may send, in characters.
It is the answer to the challenge -- the instance id, the nonce and a
token -- and nothing else until it has said who it is: more than this
without a newline closes the connection.")

(defconst harness-claude-plugin--challenge-prefix "HARNESS-MCP-AUTH"
  "What the listener's challenge and the relay's answer start with.")

(defconst harness-claude-plugin--challenge-version "1"
  "The version of the challenge protocol this harness speaks.")

(cl-defstruct (harness-claude-plugin-bridge
               (:constructor harness-claude-plugin--make-bridge)
               (:copier nil))
  "The way to one CLI process's relay."
  token      ; the secret that names this process
  receive    ; function (BRIDGE LINE) called for each line the relay sends
  closed     ; function (BRIDGE) called when the relay's connection goes, or nil
  conn)      ; the relay's connection, once it has said who it is

(defvar harness-claude-plugin--server nil
  "The listening process, or nil.")

(defvar harness-claude-plugin--bridges (make-hash-table :test 'equal)
  "Token -> `harness-claude-plugin-bridge', for the processes that may connect.")

(defun harness-claude-plugin--random-token ()
  "Return a new bridge token, derived from this harness instance's secret.
Every CLI process gets one of its own, so a relay reaches the session of
its own process and no other, and reading one tells nothing of the
instance token it came from."
  (harness-instance-credential (format "claude-plugin:%s" (harness-short-id 16))))

(defun harness-claude-plugin--token-p (line)
  "Non-nil when LINE looks like a token: the characters `base64url' writes.
An instance credential and the older opaque tokens both pass."
  (and (stringp line)
       (or (harness-instance-token-p line)
           (string-match-p "\\`[A-Za-z0-9_-]\\{20,128\\}\\'" line))))

(defun harness-claude-plugin--bridge-for-token (token)
  "Return the bridge TOKEN names, or nil.
Every token is compared, in time independent of where the two differ."
  (when (harness-claude-plugin--token-p token)
    (let (found)
      (maphash (lambda (candidate bridge)
                 (when (harness-instance-equal-p candidate token)
                   (setq found bridge)))
               harness-claude-plugin--bridges)
      found)))

(defun harness-claude-plugin--challenge (client)
  "Send CLIENT the listener's challenge, a nonce for its answer.
The listener names this harness instance in the clear, so the relay can
tell it from another program that took the port, and the nonce makes
an answer heard before useless in a second connection."
  (let ((nonce (harness-instance-random-string 16)))
    (process-put client 'harness-claude-plugin-nonce nonce)
    (process-send-string
     client (format "%s %s %s %s\n"
                    harness-claude-plugin--challenge-prefix
                    harness-claude-plugin--challenge-version
                    harness-instance-id nonce))))

(defun harness-claude-plugin--parse-greeting (line)
  "Return the plist a challenge answer LINE holds, or nil.
The plist has `:instance', `:nonce' and `:token'."
  (let ((fields (and (stringp line)
                     (split-string (string-trim-right line "\r") " " t))))
    (when (and (= (length fields) 5)
               (equal (nth 0 fields) harness-claude-plugin--challenge-prefix)
               (equal (nth 1 fields) harness-claude-plugin--challenge-version))
      (list :instance (nth 2 fields) :nonce (nth 3 fields) :token (nth 4 fields)))))

(defun harness-claude-plugin--deny (client reason)
  "Close CLIENT, a connection of the listener, for REASON.
The relay is told DENIED before the connection goes, when it can still
read, so its error says what happened rather than only that the harness
hung up."
  (harness-log 'warn "claude-plugin: %s; closing it" reason)
  (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
    (cancel-timer timer)
    (process-put client 'harness-claude-plugin-timer nil))
  (when (process-live-p client)
    (ignore-errors
      (process-send-string client (format "%s %s DENIED\n"
                                          harness-claude-plugin--challenge-prefix
                                          harness-claude-plugin--challenge-version)))
    ;; Let the refusal leave before the socket does.
    (run-at-time 0.05 nil (lambda () (harness-claude-plugin--drop client))))
  nil)

(defun harness-claude-plugin--drop (client)
  "Close CLIENT, a connection of the listener."
  (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
    (cancel-timer timer)
    (process-put client 'harness-claude-plugin-timer nil))
  (when (process-live-p client)
    (delete-process client)))

(defun harness-claude-plugin--greet (client line)
  "Bind CLIENT, which answered the challenge with LINE, to its bridge.
Return the bridge, or nil (and CLIENT is closed) when the answer is not
the shape this listener makes, names another harness instance, answers
a nonce this connection did not get, names no bridge of this instance,
or names one whose relay is already connected."
  (let* ((fields (harness-claude-plugin--parse-greeting line))
         (instance (plist-get fields :instance))
         (nonce (plist-get fields :nonce))
         (token (plist-get fields :token))
         (expected (process-get client 'harness-claude-plugin-nonce))
         (bridge (and fields (harness-claude-plugin--bridge-for-token token))))
    (cond
     ((null fields)
      (harness-claude-plugin--deny client "a connection did not answer the authentication challenge"))
     ((not (harness-instance-id-p instance))
      (harness-claude-plugin--deny client "a connection named no harness instance"))
     ((not (harness-instance-equal-p instance harness-instance-id))
      (harness-claude-plugin--deny
       client (format "a connection named another harness instance (%s), not %s"
                      instance harness-instance-id)))
     ((not (and (stringp expected) (harness-instance-equal-p expected nonce)))
      (harness-claude-plugin--deny client "a connection answered a nonce this listener did not send"))
     ((null bridge)
      (harness-claude-plugin--deny client "a connection did not name a session of the harness"))
     ((process-live-p (harness-claude-plugin-bridge-conn bridge))
      (harness-claude-plugin--deny client "a second relay for one session"))
     (t
      (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
        (cancel-timer timer)
        (process-put client 'harness-claude-plugin-timer nil))
      (process-put client 'harness-claude-plugin-bridge bridge)
      (setf (harness-claude-plugin-bridge-conn bridge) client)
      (process-send-string client (format "%s %s OK\n"
                                          harness-claude-plugin--challenge-prefix
                                          harness-claude-plugin--challenge-version))
      bridge))))

(defun harness-claude-plugin--deliver (bridge line)
  "Give LINE, which BRIDGE's relay sent, to the bridge's receiver."
  (unless (string-blank-p line)
    (condition-case err
        (funcall (harness-claude-plugin-bridge-receive bridge) bridge line)
      (error (harness-log 'warn "claude-plugin: a message of the relay failed: %s"
                          (harness-error-short-message err))))))

(defun harness-claude-plugin--filter (client chunk)
  "Handle CHUNK, what CLIENT sent: its challenge answer first, then JSON-RPC lines."
  (let ((pending (concat (or (process-get client 'harness-claude-plugin-pending) "") chunk))
        (bridge (process-get client 'harness-claude-plugin-bridge))
        (start 0)
        pos)
    (while (and (process-live-p client)
                (setq pos (string-search "\n" pending start)))
      (let ((line (substring pending start pos)))
        (setq start (1+ pos))
        (if bridge
            (harness-claude-plugin--deliver bridge line)
          (setq bridge (harness-claude-plugin--greet client line)))))
    (setq pending (substring pending start))
    (cond
     ((not (process-live-p client)) nil)
     ((> (length pending) (if bridge
                              harness-claude-plugin--max-line
                            harness-claude-plugin--max-greeting))
      (harness-log 'warn "claude-plugin: a line too long for a connection%s; closing it"
                   (if bridge "" " that has not said who it is"))
      (harness-claude-plugin--drop client))
     (t (process-put client 'harness-claude-plugin-pending pending)))))

(defun harness-claude-plugin--sentinel (client _event)
  "Note that CLIENT, a connection of the listener, may be gone."
  (unless (process-live-p client)
    (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
      (cancel-timer timer))
    (when-let* ((bridge (process-get client 'harness-claude-plugin-bridge)))
      (when (eq (harness-claude-plugin-bridge-conn bridge) client)
        (setf (harness-claude-plugin-bridge-conn bridge) nil)
        (when-let* ((closed (harness-claude-plugin-bridge-closed bridge)))
          (condition-case err
              (funcall closed bridge)
            (error (harness-log 'warn "claude-plugin: closing a bridge failed: %s"
                                (harness-error-short-message err)))))))))

(defun harness-claude-plugin--accepted (_server client _message)
  "Set CLIENT, a new connection of the listener, up to be greeted.
The listener speaks first: its challenge names this harness instance and
a nonce, and CLIENT has to answer both with a bridge's token before any
MCP line it sends is delivered."
  (set-process-query-on-exit-flag client nil)
  (set-process-coding-system client 'utf-8-unix 'utf-8-unix)
  (set-process-filter client #'harness-claude-plugin--filter)
  (set-process-sentinel client #'harness-claude-plugin--sentinel)
  (process-put client 'harness-claude-plugin-timer
               (run-at-time harness-claude-plugin--greeting-seconds nil
                            (lambda ()
                              (unless (process-get client 'harness-claude-plugin-bridge)
                                (harness-claude-plugin--drop client)))))
  (condition-case err
      (harness-claude-plugin--challenge client)
    (error (harness-log 'warn "claude-plugin: could not challenge a connection: %s"
                        (harness-error-short-message err))
           (harness-claude-plugin--drop client))))

(defun harness-claude-plugin--listen ()
  "Start listening on a port of 127.0.0.1 unless the listener runs.
Return the port."
  (unless (process-live-p harness-claude-plugin--server)
    (setq harness-claude-plugin--server
          (make-network-process :name "harness-claude-plugin" :server t
                                :family 'ipv4 :host "127.0.0.1" :service t
                                :coding 'utf-8-unix :noquery t
                                :filter #'harness-claude-plugin--filter
                                :sentinel #'harness-claude-plugin--sentinel
                                :log #'harness-claude-plugin--accepted))
    (harness-log 'info "claude-plugin: listening on 127.0.0.1:%s"
                 (process-contact harness-claude-plugin--server :service)))
  (harness-claude-plugin-port))

(defun harness-claude-plugin-port ()
  "Return the port the listener is on, or nil when it is not running."
  (and (process-live-p harness-claude-plugin--server)
       (let ((service (process-contact harness-claude-plugin--server :service)))
         (and (integerp service) service))))

;;;; Bridges

(defun harness-claude-plugin-open (receive &optional closed)
  "Make a bridge for one CLI process and return it, listening if need be.
RECEIVE is called as (RECEIVE BRIDGE LINE) with each line, a JSON-RPC
message, the process's relay sends; CLOSED, when given, as (CLOSED
BRIDGE) when the relay's connection ends.  Give the process
`harness-claude-plugin-environment', and close the bridge with
`harness-claude-plugin-close' when the process ends: the last bridge
closed stops the listener.  Signal an error when the listener cannot
start."
  (harness-claude-plugin--listen)
  (let ((bridge (harness-claude-plugin--make-bridge
                 :token (harness-claude-plugin--random-token)
                 :receive receive :closed closed)))
    (puthash (harness-claude-plugin-bridge-token bridge) bridge harness-claude-plugin--bridges)
    bridge))

(defun harness-claude-plugin-environment (bridge)
  "Return the environment entries that point BRIDGE's CLI process at the listener.
They are the port, the token of BRIDGE's process and the id of this
harness instance.  None is written to a file: the CLI process inherits
them, and its relay answers the listener's challenge with them."
  (list (format "HARNESS_MCP_PORT=%d" (harness-claude-plugin-port))
        (concat "HARNESS_MCP_INSTANCE=" harness-instance-id)
        (concat "HARNESS_MCP_TOKEN=" (harness-claude-plugin-bridge-token bridge))))

(defun harness-claude-plugin-connected-p (bridge)
  "Non-nil when BRIDGE's relay is connected."
  (process-live-p (harness-claude-plugin-bridge-conn bridge)))

(defun harness-claude-plugin-send (bridge message)
  "Send MESSAGE, JSON text, to BRIDGE's relay as one line.
Return non-nil when it was sent: nil when no relay is connected."
  (let ((conn (harness-claude-plugin-bridge-conn bridge)))
    (when (process-live-p conn)
      (harness-process-send conn (concat message "\n"))
      t)))

(defun harness-claude-plugin--unlisten ()
  "Stop listening, if the listener runs."
  (when (process-live-p harness-claude-plugin--server)
    (delete-process harness-claude-plugin--server)
    (harness-log 'info "claude-plugin: stopped listening"))
  (setq harness-claude-plugin--server nil))

(defun harness-claude-plugin-close (bridge)
  "End BRIDGE: forget its token and close its relay's connection.
Its `closed' function is not called.  The last bridge to go takes the
listener with it: nothing listens while no CLI process could connect."
  (remhash (harness-claude-plugin-bridge-token bridge) harness-claude-plugin--bridges)
  (let ((conn (harness-claude-plugin-bridge-conn bridge)))
    (setf (harness-claude-plugin-bridge-closed bridge) nil
          (harness-claude-plugin-bridge-conn bridge) nil)
    (when (processp conn)
      (process-put conn 'harness-claude-plugin-bridge nil)
      (harness-claude-plugin--drop conn)))
  (when (zerop (hash-table-count harness-claude-plugin--bridges))
    (harness-claude-plugin--unlisten)))

(defun harness-claude-plugin-stop ()
  "Close every bridge and stop listening."
  (maphash (lambda (_token bridge) (harness-claude-plugin-close bridge))
           (copy-hash-table harness-claude-plugin--bridges))
  (harness-claude-plugin--unlisten))

(provide 'harness-claude-plugin)
;;; harness-claude-plugin.el ends here
