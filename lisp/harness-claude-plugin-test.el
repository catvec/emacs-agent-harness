;;; harness-claude-plugin-test.el --- The plugin the harness writes for Claude Code, and its relay  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The plugin's files, the listener the relay connects to and, through
;; the real relay script, what a CLI process's stdio MCP transport
;; reaches: its own session's bridge, and no other.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-claude-plugin)

(defmacro harness-claude-plugin-test--with-state (&rest body)
  "Run BODY with a state directory of its own and no listener left behind."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (unwind-protect (progn ,@body)
       (harness-claude-plugin-stop))))

(defun harness-claude-plugin-test--connect ()
  "Connect to the listener as a relay would; return the connection.
What the connection receives collects under the property `got'."
  (make-network-process
   :name "harness-claude-plugin-test" :host "127.0.0.1" :family 'ipv4
   :service (harness-claude-plugin-port) :coding 'utf-8-unix :noquery t
   :filter (lambda (proc chunk) (process-put proc 'got (concat (process-get proc 'got) chunk)))))

(defun harness-claude-plugin-test--got (conn)
  "Return what CONN has received so far."
  (or (process-get conn 'got) ""))

(defun harness-claude-plugin-test--read-line (conn)
  "Return the next line CONN received, without its newline, waiting up to 5s.
A connection that closes with nothing more gets nil."
  (let ((deadline (+ (float-time) 5)) line)
    (while (and (not line) (< (float-time) deadline))
      (let ((text (harness-claude-plugin-test--got conn)))
        (if-let* ((pos (string-search "\n" text)))
            (progn (setq line (substring text 0 pos))
                   (process-put conn 'got (substring text (1+ pos))))
          (unless (process-live-p conn)
            (setq deadline 0))
          (when (process-live-p conn) (accept-process-output nil 0.02)))))
    line))

(defun harness-claude-plugin-test--challenge (conn)
  "Read CONN's challenge; return it as a plist, or nil."
  (when-let* ((line (harness-claude-plugin-test--read-line conn))
              (fields (split-string line " " t)))
    (when (and (= (length fields) 4)
               (equal (nth 0 fields) "HARNESS-MCP-AUTH")
               (equal (nth 1 fields) "1"))
      (list :instance (nth 2 fields) :nonce (nth 3 fields)))))

(cl-defun harness-claude-plugin-test--accept (conn &key bridge instance token nonce)
  "Answer CONN's challenge and return the listener's answer line.
INSTANCE, NONCE and TOKEN default to this harness's, the challenge's and
BRIDGE's.  A test that wants a refusal passes its own."
  (let* ((challenge (and (null nonce) (harness-claude-plugin-test--challenge conn)))
         (instance (or instance harness-instance-id))
         (nonce (or nonce (plist-get challenge :nonce)))
         (token (or token (and bridge (harness-claude-plugin-bridge-token bridge)))))
    (process-send-string conn (format "HARNESS-MCP-AUTH 1 %s %s %s\n" instance nonce token))
    (harness-claude-plugin-test--read-line conn)))

(defun harness-claude-plugin-test--collecting-bridge ()
  "Open a bridge that keeps the lines it receives, newest first, in `lines'."
  (let* ((lines nil)
         (bridge (harness-claude-plugin-open (lambda (_bridge line) (push line lines)))))
    (cons bridge (lambda () lines))))

;;;; The plugin's files

(ert-deftest harness-claude-plugin-test-names ()
  "The CLI names the plugin's tools after the plugin and the server."
  (should (equal harness-claude-plugin-tool-prefix "mcp__plugin_emacs-harness_harness__"))
  (should (equal harness-claude-plugin-server-label "plugin:emacs-harness:harness"))
  ;; The API limits a tool name to 64 characters: room for the longest tool.
  (should (<= (+ (length harness-claude-plugin-tool-prefix) 24) 64))
  ;; Names starting like Anthropic's own are reserved.
  (should-not (string-match-p "\\`\\(claude\\|anthropic\\)" harness-claude-plugin-name)))

(ert-deftest harness-claude-plugin-test-writes-the-plugin ()
  "The plugin has a manifest, a stdio server in .mcp.json and an executable relay."
  (harness-claude-plugin-test--with-state
    (let* ((dir (harness-claude-plugin-write))
           (manifest (harness-json-parse (harness-read-file (expand-file-name ".claude-plugin/plugin.json" dir))))
           (mcp (harness-json-parse (harness-read-file (expand-file-name ".mcp.json" dir))))
           (server (plist-get (plist-get mcp :mcpServers) :harness))
           (relay (expand-file-name "bin/harness-mcp-relay" dir)))
      (should (equal dir (harness-claude-plugin-directory)))
      (should (string-prefix-p (file-name-as-directory harness-state-directory) dir))
      (should (equal (plist-get manifest :name) "emacs-harness"))
      (should (stringp (plist-get manifest :version)))
      ;; A plugin cannot declare an SDK server: this one is stdio, and a
      ;; plain command.
      (should (equal (plist-get server :command) "bash"))
      (should-not (plist-get server :type))
      (should (equal (plist-get server :args) '("${CLAUDE_PLUGIN_ROOT}/bin/harness-mcp-relay")))
      ;; The process's own environment carries the port and the token.
      (should (equal (plist-get (plist-get server :env) :HARNESS_MCP_PORT) "${HARNESS_MCP_PORT}"))
      (should (equal (plist-get (plist-get server :env) :HARNESS_MCP_INSTANCE) "${HARNESS_MCP_INSTANCE}"))
      (should (equal (plist-get (plist-get server :env) :HARNESS_MCP_TOKEN) "${HARNESS_MCP_TOKEN}"))
      ;; No secret is on disk.
      (should-not (string-match-p "HARNESS_MCP_TOKEN=\\|[A-Za-z0-9_-]\\{40\\}"
                                  (harness-read-file (expand-file-name ".mcp.json" dir))))
      (should (file-executable-p relay))
      (should (string-match-p "/dev/tcp/127\\.0\\.0\\.1/" (harness-read-file relay)))
      ;; A background command reads /dev/null unless told otherwise: the
      ;; one in the background reads the connection, the CLI's pipe is
      ;; the foreground one's.
      (should (string-match-p "^  cat <&3 &$" (harness-read-file relay)))
      (should (string-match-p "^  cat >&3$" (harness-read-file relay))))))

(ert-deftest harness-claude-plugin-test-write-leaves-current-files-alone ()
  "A directory that is up to date is not written again; an outdated file is."
  (harness-claude-plugin-test--with-state
   (let* ((dir (harness-claude-plugin-write))
          (mcp (expand-file-name ".mcp.json" dir)))
     ;; Give a rewrite a distinguishable timestamp without waiting for the clock.
     (set-file-times mcp (seconds-to-time (- (float-time) 60)))
     (let ((stamp (file-attribute-modification-time (file-attributes mcp))))
       (should (equal (harness-claude-plugin-write) dir))
       (should (equal (file-attribute-modification-time (file-attributes mcp)) stamp)))
     (with-temp-file mcp (insert "{}"))
     (harness-claude-plugin-write)
     (should (string-match-p "mcpServers" (harness-read-file mcp)))
     ;; Its mode is put back too.
     (set-file-modes (expand-file-name "bin/harness-mcp-relay" dir) #o644)
     (harness-claude-plugin-write)
     (should (file-executable-p (expand-file-name "bin/harness-mcp-relay" dir))))))

(ert-deftest harness-claude-plugin-test-private-directories ()
  "The plugin's directories are the user's own, and a shared one is not used."
  (harness-claude-plugin-test--with-state
    (let ((dir (harness-claude-plugin-write)))
      (should (zerop (logand #o077 (file-modes dir))))
      (should (zerop (logand #o077 (file-modes (expand-file-name "bin" dir)))))
      ;; Anyone could change what the CLI runs with the user's rights.
      (set-file-modes dir #o777)
      (should-error (harness-claude-plugin-write)))))

;;;; The listener

(ert-deftest harness-claude-plugin-test-bridge-round-trip ()
  "A relay that names its token reaches the bridge's receiver, and is answered."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (env (harness-claude-plugin-environment bridge))
                 (conn (harness-claude-plugin-test--connect)))
      (should (member (format "HARNESS_MCP_PORT=%d" (harness-claude-plugin-port)) env))
      (should (member (format "HARNESS_MCP_INSTANCE=%s" harness-instance-id) env))
      (should (cl-some (lambda (e) (string-prefix-p "HARNESS_MCP_TOKEN=" e)) env))
      (should-not (harness-claude-plugin-connected-p bridge))
      (should-not (harness-claude-plugin-send bridge "{}"))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept conn :bridge bridge)))
      (process-send-string conn "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n")
      (harness-test-wait (lambda () (funcall lines)) 5 "the line to arrive")
      (should (equal (funcall lines) '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")))
      (should (harness-claude-plugin-connected-p bridge))
      (should (harness-claude-plugin-send bridge "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"))
      (harness-test-wait (lambda () (string-match-p "\n" (harness-claude-plugin-test--got conn))) 5
                         "the answer")
      (should (equal (harness-claude-plugin-test--got conn)
                     "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n")))))

(ert-deftest harness-claude-plugin-test-lines-split-and-join ()
  "A message in pieces is one line, and two in one chunk are two."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (conn (harness-claude-plugin-test--connect)))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept conn :bridge bridge)))
      (process-send-string conn "{\"a\":")
      (sleep-for 0.1)
      (process-send-string conn "1}\n{\"b\":2}\n{\"c\":\"é✓\"}\n")
      (harness-test-wait (lambda () (= (length (funcall lines)) 3)) 5 "three lines")
      (should (equal (reverse (funcall lines)) '("{\"a\":1}" "{\"b\":2}" "{\"c\":\"é✓\"}"))))))

(ert-deftest harness-claude-plugin-test-wrong-token-is-closed ()
  "A connection that names no session of the harness is closed, with nothing delivered."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,_bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (conn (harness-claude-plugin-test--connect))
                 (challenge (harness-claude-plugin-test--challenge conn)))
      (should challenge)
      (process-send-string conn
                           (format "HARNESS-MCP-AUTH 1 %s %s not-a-token-of-this-harness-abcdefghijk\n{\"id\":1}\n"
                                   harness-instance-id (plist-get challenge :nonce)))
      (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close")
      (should-not (funcall lines)))
    ;; The token has to look like one before it is looked up.
    (let* ((conn (harness-claude-plugin-test--connect))
           (challenge (harness-claude-plugin-test--challenge conn)))
      (process-send-string conn (format "HARNESS-MCP-AUTH 1 %s %s short\n"
                                        harness-instance-id (plist-get challenge :nonce)))
      (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close"))))

(ert-deftest harness-claude-plugin-test-challenge-names-the-instance-and-a-nonce ()
  "A new connection is told which harness it reached, and gets a fresh nonce."
  (harness-claude-plugin-test--with-state
    (harness-claude-plugin-test--collecting-bridge)
    (let* ((one (harness-claude-plugin-test--connect))
           (a (harness-claude-plugin-test--challenge one))
           (two (harness-claude-plugin-test--connect))
           (b (harness-claude-plugin-test--challenge two)))
      (unwind-protect
          (progn
            (should (equal harness-instance-id (plist-get a :instance)))
            (should (equal harness-instance-id (plist-get b :instance)))
            (should (stringp (plist-get a :nonce)))
            (should (> (length (plist-get a :nonce)) 16))
            (should-not (equal (plist-get a :nonce) (plist-get b :nonce))))
        (delete-process one)
        (delete-process two)))))

(ert-deftest harness-claude-plugin-test-another-instance-is-refused ()
  "A connection that names another harness instance gets no bridge, whatever its token."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (conn (harness-claude-plugin-test--connect)))
      (should (equal "HARNESS-MCP-AUTH 1 DENIED"
                     (harness-claude-plugin-test--accept
                      conn :bridge bridge
                      :instance "hi1_anotherinstanceid000000")))
      (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close")
      (should-not (funcall lines))
      (should-not (harness-claude-plugin-connected-p bridge)))))

(ert-deftest harness-claude-plugin-test-a-replayed-nonce-is-refused ()
  "An answer heard on one connection is no answer on another."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (one (harness-claude-plugin-test--connect))
                 (first (harness-claude-plugin-test--challenge one))
                 (two (harness-claude-plugin-test--connect)))
      (ignore (harness-claude-plugin-test--challenge two))
      (should (equal "HARNESS-MCP-AUTH 1 DENIED"
                     (harness-claude-plugin-test--accept
                      two :bridge bridge :nonce (plist-get first :nonce))))
      (harness-test-wait (lambda () (not (process-live-p two))) 5 "the second connection to close")
      (should-not (funcall lines))
      (should-not (harness-claude-plugin-connected-p bridge))
      (delete-process one))))

(ert-deftest harness-claude-plugin-test-real-relay-refuses-another-instance ()
  "The relay sends no token to a listener whose instance id is not its own."
  (skip-unless (executable-find "bash"))
  (harness-claude-plugin-test--with-state
    (pcase-let* ((dir (harness-claude-plugin-write))
                 (`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (env (harness-claude-plugin-environment bridge))
                 (relay (harness-claude-plugin-test--run-relay
                         dir (append (list "HARNESS_MCP_INSTANCE=hi1_anotherinstanceid000000") env))))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (not (process-live-p relay))) 10 "the relay to stop")
            (should (= 1 (process-exit-status relay)))
            (accept-process-output nil 0.1)
            (with-current-buffer (process-get relay 'err-buffer)
              (should (string-match-p "another harness instance" (buffer-string))))
            (should-not (funcall lines))
            (should-not (harness-claude-plugin-connected-p bridge)))
        (when (process-live-p relay) (delete-process relay))
        (kill-buffer (process-get relay 'err-buffer))))))

(ert-deftest harness-claude-plugin-test-one-relay-per-bridge ()
  "A second connection with a token in use is closed; one after the first went is not."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (token (harness-claude-plugin-bridge-token bridge))
                 (first (harness-claude-plugin-test--connect)))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept first :bridge bridge)))
      (process-send-string first "{\"n\":1}\n")
      (harness-test-wait (lambda () (funcall lines)) 5 "the first line")
      (let ((second (harness-claude-plugin-test--connect)))
        (should (equal "HARNESS-MCP-AUTH 1 DENIED"
                       (harness-claude-plugin-test--accept second :bridge bridge :token token)))
        (harness-test-wait (lambda () (not (process-live-p second))) 5 "the second to close")
        (should (equal (funcall lines) '("{\"n\":1}")))
        (should (process-live-p first)))
      ;; The first relay goes (the CLI restarted its server): the next one is let in.
      (delete-process first)
      (harness-test-wait (lambda () (not (harness-claude-plugin-connected-p bridge))) 5
                         "the bridge to see the relay go")
      (let ((third (harness-claude-plugin-test--connect)))
        (should (equal "HARNESS-MCP-AUTH 1 OK"
                       (harness-claude-plugin-test--accept third :bridge bridge :token token)))
        (process-send-string third "{\"n\":3}\n")
        (harness-test-wait (lambda () (equal (car (funcall lines)) "{\"n\":3}")) 5 "the third line")))))

(ert-deftest harness-claude-plugin-test-bridges-are-apart ()
  "A relay reaches the receiver of its own token only."
  (harness-claude-plugin-test--with-state
    (pcase-let* ((`(,one . ,one-lines) (harness-claude-plugin-test--collecting-bridge))
                 (`(,two . ,two-lines) (harness-claude-plugin-test--collecting-bridge))
                 (conn (harness-claude-plugin-test--connect)))
      (should-not (equal (harness-claude-plugin-bridge-token one) (harness-claude-plugin-bridge-token two)))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept conn :bridge two)))
      (process-send-string conn "{\"for\":\"two\"}\n")
      (harness-test-wait (lambda () (funcall two-lines)) 5 "the line")
      (should (equal (funcall two-lines) '("{\"for\":\"two\"}")))
      (should-not (funcall one-lines))
      (should-not (harness-claude-plugin-connected-p one)))))

(ert-deftest harness-claude-plugin-test-silent-connection-is-closed ()
  "A connection that never says who it is does not stay."
  (harness-claude-plugin-test--with-state
    (let ((harness-claude-plugin--greeting-seconds 0.2))
      (harness-claude-plugin-test--collecting-bridge)
      (let ((conn (harness-claude-plugin-test--connect)))
        (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the silent connection to close")))))

(ert-deftest harness-claude-plugin-test-endless-line-is-closed ()
  "A connection that sends more than a line may hold, with no end to it, is closed."
  (harness-claude-plugin-test--with-state
    (let ((harness-claude-plugin--max-line 1000))
      (pcase-let* ((`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                   (conn (harness-claude-plugin-test--connect)))
        (should (equal "HARNESS-MCP-AUTH 1 OK"
                       (harness-claude-plugin-test--accept conn :bridge bridge)))
        (process-send-string conn (make-string 3000 ?x))
        (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close")
        (should-not (funcall lines))))))

(ert-deftest harness-claude-plugin-test-endless-greeting-is-closed ()
  "A connection that has not said who it is may not send more than a token's worth."
  (harness-claude-plugin-test--with-state
    (let ((conn (progn (harness-claude-plugin-test--collecting-bridge)
                       (harness-claude-plugin-test--connect))))
      (process-send-string conn (make-string 2000 ?x))
      (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close"))))

(ert-deftest harness-claude-plugin-test-close-ends-the-relay ()
  "Closing a bridge closes its connection and forgets its token."
  (harness-claude-plugin-test--with-state
    (let* ((closed 0)
           (bridge (harness-claude-plugin-open #'ignore (lambda (_b) (cl-incf closed))))
           (token (harness-claude-plugin-bridge-token bridge))
           (conn (harness-claude-plugin-test--connect)))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept conn :bridge bridge :token token)))
      (should (harness-claude-plugin-connected-p bridge))
      (harness-claude-plugin-close bridge)
      (harness-test-wait (lambda () (not (process-live-p conn))) 5 "the connection to close")
      ;; Closed by the harness, so the bridge's own function is not told.
      (should (zerop closed))
      ;; The last bridge to go takes the listener with it: nothing would connect.
      (should-not (harness-claude-plugin-port))
      (should-not (gethash token harness-claude-plugin--bridges))
      ;; A new bridge listens again, and does not know the old token.
      (let ((next (harness-claude-plugin-open #'ignore)))
        (should (integerp (harness-claude-plugin-port)))
        (let ((again (harness-claude-plugin-test--connect)))
          (should (equal "HARNESS-MCP-AUTH 1 DENIED"
                         (harness-claude-plugin-test--accept again :bridge next :token token)))
          (harness-test-wait (lambda () (not (process-live-p again))) 5 "the old token to be refused"))
        ;; And the new one's own token works.
        (let ((conn (harness-claude-plugin-test--connect)))
          (should (equal "HARNESS-MCP-AUTH 1 OK"
                         (harness-claude-plugin-test--accept conn :bridge next)))
          (harness-test-wait (lambda () (harness-claude-plugin-connected-p next)) 5 "the new relay"))))))

(ert-deftest harness-claude-plugin-test-relay-going-is-reported ()
  "The bridge's `closed' function hears that the relay's connection ended."
  (harness-claude-plugin-test--with-state
    (let* ((closed nil)
           (bridge (harness-claude-plugin-open #'ignore (lambda (b) (setq closed b))))
           (conn (harness-claude-plugin-test--connect)))
      (should (equal "HARNESS-MCP-AUTH 1 OK"
                     (harness-claude-plugin-test--accept conn :bridge bridge)))
      (should (harness-claude-plugin-connected-p bridge))
      (delete-process conn)
      (harness-test-wait (lambda () closed) 5 "the report")
      (should (eq closed bridge)))))

(ert-deftest harness-claude-plugin-test-stop ()
  "Stopping closes the listener and every bridge."
  (harness-claude-plugin-test--with-state
    (let ((bridge (harness-claude-plugin-open #'ignore)))
      (should (integerp (harness-claude-plugin-port)))
      (harness-claude-plugin-stop)
      (should-not (harness-claude-plugin-port))
      (should-not (gethash (harness-claude-plugin-bridge-token bridge) harness-claude-plugin--bridges)))))

;;;; The relay script

(defun harness-claude-plugin-test--run-relay (dir env)
  "Start the plugin's relay in DIR with ENV added; return the process.
Its standard output collects under the property `got', its standard
error under `err'."
  (let* ((process-environment (append env process-environment))
         (err (generate-new-buffer " *relay-err*" t))
         (proc (make-process :name "harness-test-relay"
                             :command (list "bash" (expand-file-name "bin/harness-mcp-relay" dir))
                             :connection-type 'pipe :coding 'utf-8-unix :noquery t
                             :stderr err
                             :filter (lambda (p chunk)
                                       (process-put p 'got (concat (process-get p 'got) chunk))))))
    (process-put proc 'err-buffer err)
    proc))

(ert-deftest harness-claude-plugin-test-real-relay ()
  "The relay script carries the CLI's stdio to the bridge, and the bridge's answers back."
  (skip-unless (executable-find "bash"))
  (harness-claude-plugin-test--with-state
    (pcase-let* ((dir (harness-claude-plugin-write))
                 (`(,bridge . ,lines) (harness-claude-plugin-test--collecting-bridge))
                 (relay (harness-claude-plugin-test--run-relay
                         dir (harness-claude-plugin-environment bridge))))
      (unwind-protect
          (progn
            (process-send-string relay "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\"}\n")
            (harness-test-wait (lambda () (funcall lines)) 10 "the relay's first message")
            (should (equal (funcall lines) '("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\"}")))
            (should (harness-claude-plugin-connected-p bridge))
            ;; Both ways, and a message bigger than a pipe's buffer.
            (let ((big (make-string 200000 ?y)))
              (harness-claude-plugin-send bridge (format "{\"big\":\"%s\"}" big))
              (harness-claude-plugin-send bridge "{\"after\":true}")
              (harness-test-wait (lambda () (string-suffix-p "{\"after\":true}\n" (or (process-get relay 'got) "")))
                                 10 "the answers")
              (should (equal (process-get relay 'got)
                             (format "{\"big\":\"%s\"}\n{\"after\":true}\n" big))))
            ;; The CLI closing its end ends the relay's.
            (process-send-eof relay)
            (harness-test-wait (lambda () (not (harness-claude-plugin-connected-p bridge))) 10
                               "the bridge to see the relay go"))
        (when (process-live-p relay) (delete-process relay))
        (kill-buffer (process-get relay 'err-buffer))))))

(ert-deftest harness-claude-plugin-test-relay-needs-its-environment ()
  "Without a port and a token the relay says so and fails."
  (skip-unless (executable-find "bash"))
  (harness-claude-plugin-test--with-state
    (let* ((dir (harness-claude-plugin-write))
           (relay (harness-claude-plugin-test--run-relay dir '("HARNESS_MCP_PORT=" "HARNESS_MCP_TOKEN="))))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (not (process-live-p relay))) 10 "the relay to stop")
            (should (= (process-exit-status relay) 1))
            (accept-process-output nil 0.1)
            (with-current-buffer (process-get relay 'err-buffer)
              (should (string-match-p "HARNESS_MCP_PORT, HARNESS_MCP_TOKEN and HARNESS_MCP_INSTANCE"
                                      (buffer-string)))))
        (kill-buffer (process-get relay 'err-buffer))))))

(ert-deftest harness-claude-plugin-test-relay-with-no-listener-fails ()
  "A relay whose harness is gone ends instead of hanging the CLI."
  (skip-unless (executable-find "bash"))
  (harness-claude-plugin-test--with-state
    (let* ((dir (harness-claude-plugin-write))
           (bridge (harness-claude-plugin-open #'ignore))
           (env (harness-claude-plugin-environment bridge)))
      (harness-claude-plugin-stop)
      (let ((relay (harness-claude-plugin-test--run-relay dir env)))
        (unwind-protect
            (progn
              (harness-test-wait (lambda () (not (process-live-p relay))) 10 "the relay to stop")
              (should-not (= (process-exit-status relay) 0)))
          (kill-buffer (process-get relay 'err-buffer)))))))

(provide 'harness-claude-plugin-test)
;;; harness-claude-plugin-test.el ends here
