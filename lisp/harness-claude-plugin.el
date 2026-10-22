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
;; nc), say who they are with one line, and then copy bytes both ways.
;; Nothing else: the protocol is spoken by the harness, which is why the
;; same code answers the SDK channel and this one.
;;
;; The listener.  The harness listens on 127.0.0.1, one port for every
;; CLI process, for as long as there is one (it starts with the first
;; bridge and stops with the last), and a connection means nothing until
;; its first line is a token (`harness-claude-plugin-open') that names a
;; process the harness started: 256 random bits, made for one CLI
;; process and passed to it, and through it to the relay, in its
;; environment (HARNESS_MCP_PORT and HARNESS_MCP_TOKEN) -- never in a
;; file, never on a command line.  The token binds the connection to that
;; process's session, so a connection reaches the tools of its own
;; session and no other; a second connection with a token already in
;; use, a wrong token, or silence for ten seconds is closed.  Nothing the
;; listener receives is trusted beyond the token: each line goes to the
;; process's receiver, the provider, which parses it as it parses the
;; CLI's own messages.  What the token gives is what the CLI's own tools
;; already have, the harness's tools of this session, each call decided
;; by the harness as any call is: the CLI's Bash inherits its
;; environment, token included, and could connect when the relay is not,
;; which is no more than the model can do anyway.
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
# (lisp/harness-claude-plugin.el); the harness gives the CLI the port and
# the token of its session in HARNESS_MCP_PORT and HARNESS_MCP_TOKEN.
port=${HARNESS_MCP_PORT:-}
token=${HARNESS_MCP_TOKEN:-}
if [ -z \"$port\" ] || [ -z \"$token\" ]; then
  echo \"harness-mcp-relay: HARNESS_MCP_PORT and HARNESS_MCP_TOKEN are not set; this plugin serves the Claude Code sessions the Emacs agent harness starts\" >&2
  exit 1
fi
if { exec 3<>\"/dev/tcp/127.0.0.1/$port\"; } 2>/dev/null; then
  printf '%s\\n' \"$token\" >&3
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
{ printf '%s\\n' \"$token\"; cat; } | nc 127.0.0.1 \"$port\"
"
  "The relay, a bash script.
It connects to 127.0.0.1:$HARNESS_MCP_PORT, sends $HARNESS_MCP_TOKEN as
the first line and then copies standard input to the connection and the
connection to standard output.  bash's /dev/tcp does it; a bash built
without it falls back to nc.  It ends when the CLI closes its end, and
closes the connection with it; it fails at once when the harness cannot
be reached, rather than leave the CLI waiting for a server that is not
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
One stdio server runs the relay with bash.  The port and the token are
the CLI's own environment variables, which the CLI passes on by
expanding `${NAME}' in the server's `env' as it loads the plugin."
  (concat (harness-json-encode-text
           (list :mcpServers
                 (list (intern (concat ":" harness-claude-plugin-server))
                       (list :command "bash"
                             :args (vector "${CLAUDE_PLUGIN_ROOT}/bin/harness-mcp-relay")
                             :env (list :HARNESS_MCP_PORT "${HARNESS_MCP_PORT}"
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

(defconst harness-claude-plugin--max-greeting 512
  "The longest first line a connection may send, in characters.
It is a token, 43 characters, and nothing else until it has said who it
is: more than this without a newline closes the connection.")

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
  "Return a new token: 256 random bits, as text."
  (let ((bytes (or (condition-case nil
                       (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally "/dev/urandom" nil 0 32)
                         (and (= (buffer-size) 32) (buffer-string)))
                     (error nil))
                   (secure-hash 'sha256 (format "%s %s %s %s" (random t) (float-time)
                                                (emacs-pid) (current-time))
                                nil nil t))))
    (base64url-encode-string bytes t)))

(defun harness-claude-plugin--token-p (line)
  "Non-nil when LINE looks like a token: the characters `base64url' writes."
  (string-match-p "\\`[A-Za-z0-9_-]\\{20,128\\}\\'" line))

(defun harness-claude-plugin--drop (client)
  "Close CLIENT, a connection of the listener."
  (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
    (cancel-timer timer)
    (process-put client 'harness-claude-plugin-timer nil))
  (when (process-live-p client)
    (delete-process client)))

(defun harness-claude-plugin--greet (client line)
  "Bind CLIENT to the bridge whose token is LINE, its first line.
Return the bridge, or nil (and CLIENT is closed) when LINE names none or
the bridge has a relay already."
  (let* ((token (string-trim-right line "\r"))
         (bridge (and (harness-claude-plugin--token-p token)
                      (gethash token harness-claude-plugin--bridges))))
    (cond
     ((null bridge)
      (harness-log 'warn "claude-plugin: a connection did not name a session of the harness; closing it")
      (harness-claude-plugin--drop client)
      nil)
     ((process-live-p (harness-claude-plugin-bridge-conn bridge))
      (harness-log 'warn "claude-plugin: a second relay for one session; closing it")
      (harness-claude-plugin--drop client)
      nil)
     (t
      (when-let* ((timer (process-get client 'harness-claude-plugin-timer)))
        (cancel-timer timer)
        (process-put client 'harness-claude-plugin-timer nil))
      (process-put client 'harness-claude-plugin-bridge bridge)
      (setf (harness-claude-plugin-bridge-conn bridge) client)
      bridge))))

(defun harness-claude-plugin--deliver (bridge line)
  "Give LINE, which BRIDGE's relay sent, to the bridge's receiver."
  (unless (string-blank-p line)
    (condition-case err
        (funcall (harness-claude-plugin-bridge-receive bridge) bridge line)
      (error (harness-log 'warn "claude-plugin: a message of the relay failed: %s"
                          (harness-error-short-message err))))))

(defun harness-claude-plugin--filter (client chunk)
  "Handle CHUNK, what CLIENT sent: its token first, then JSON-RPC lines."
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
  "Set CLIENT, a new connection of the listener, up to be greeted."
  (set-process-query-on-exit-flag client nil)
  (set-process-coding-system client 'utf-8-unix 'utf-8-unix)
  (set-process-filter client #'harness-claude-plugin--filter)
  (set-process-sentinel client #'harness-claude-plugin--sentinel)
  (process-put client 'harness-claude-plugin-timer
               (run-at-time harness-claude-plugin--greeting-seconds nil
                            (lambda ()
                              (unless (process-get client 'harness-claude-plugin-bridge)
                                (harness-claude-plugin--drop client))))))

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
  "Return the environment entries that point BRIDGE's CLI process at the listener."
  (list (format "HARNESS_MCP_PORT=%d" (harness-claude-plugin-port))
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
