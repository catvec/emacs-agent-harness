;;; harness-provider-copilot.el --- GitHub Copilot CLI as a completion provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives GitHub's `copilot' command line (GitHub Copilot CLI) as a
;; hosted completion provider, so Copilot subscribers can use their
;; plan's models (GPT, Claude, Gemini and others) from the harness
;; without an API key.  Copilot runs the agent loop; the harness serves
;; the tools.  Per harness session one long-lived CLI process is kept
;; across turns: the CLI keeps the conversation and the harness only
;; sends the new user content.
;;
;; Wire protocol.  `copilot --headless --stdio' is the CLI's server
;; mode, the one GitHub's Copilot SDKs drive: JSON-RPC 2.0 over stdin
;; and stdout, every message framed by a `Content-Length' header as in
;; LSP.  We use protocol version 3:
;;
;; - `connect' checks the protocol version and `auth.getStatus' that
;;   the CLI is logged in, before anything else is asked of it.
;; - `session.create' / `session.resume' open a Copilot session with
;;   the harness tools as external tools (`availableTools' lists only
;;   them, so every built-in tool such as bash or apply_patch is off),
;;   the harness system prompt in place of Copilot's (`systemMessage'
;;   mode replace), the model and the reasoning effort.  Resuming an
;;   open session again applies changed settings in place.
;; - `session.send' starts a turn; `session.event' notifications carry
;;   it: `assistant.message_delta' and `assistant.reasoning_delta'
;;   stream text and thinking, `external_tool.requested' asks the
;;   harness to run a tool, answered by `session.tools.handlePendingToolCall'
;;   through the `:respond' of a `tool-call' event, `assistant.usage'
;;   reports each model call, and `session.idle' ends the turn.
;; - `session.abort' cancels a turn, `sessions.fork' copies a session
;;   for `:fork', and a process can hold several sessions at once, so
;;   a side request on a fork of the conversation (the naming of a
;;   session) runs next to it without restarting anything.
;;
;; The Copilot session id is the provider state, so a harness session
;; resumes the same Copilot conversation after Emacs restarts.
;;
;; Billing.  Copilot plans include a monthly allowance; since June 2026
;; it is counted in AI credits ($0.01 each) at each model's token
;; prices, before that (and still for annual plans) in premium
;; requests.  The CLI reports what each call cost in nano AI units, so
;; a turn's usage says `:billing subscription' with `:cost' 0 and the
;; credits' dollar value as `:list-cost'.  Past the allowance, with
;; additional usage allowed, calls are billed: `:billing extra-usage'.
;; A call reported only in premium requests is priced from the model
;; catalogue's token prices instead.  `provider/quota' returns the
;; allowance from `account.getQuota'.
;;
;; The model catalogue comes from `models.list' (context window, image
;; input, reasoning efforts and token prices per model), asked of a
;; short-lived probe process when no session process runs.  Before
;; `copilot login' the CLI's built-in list of model ids stands in.
;;
;; Nothing here blocks: output is handled in a process filter, death in
;; a sentinel, timeouts by timers, and every answer by a callback.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

;;;; Customisation

(defcustom harness-provider-copilot-program
  (or (executable-find "copilot")
      (let ((local (expand-file-name "~/.local/bin/copilot")))
        (and (file-executable-p local) local))
      "copilot")
  "Path to GitHub's `copilot' command line program (GitHub Copilot CLI).
Version 1.0 or newer is needed.  It must be logged in (run `copilot
login' once in a terminal), or find a token in COPILOT_GITHUB_TOKEN,
GH_TOKEN or GITHUB_TOKEN."
  :type 'string :group 'harness)

(defcustom harness-provider-copilot-default-model "claude-sonnet-5"
  "Copilot model that the model id \"copilot:default\" stands for.
It is listed first in the catalogue.  Copilot's own model \"auto\" lets
Copilot choose a model for each request."
  :type 'string :group 'harness)

(defcustom harness-provider-copilot-extra-args nil
  "Extra command line arguments appended to every `copilot' invocation."
  :type '(repeat string) :group 'harness)

(defcustom harness-provider-copilot-interrupt-timeout 3
  "Seconds to wait after an abort before killing the CLI process."
  :type 'number :group 'harness)

(defcustom harness-provider-copilot-startup-timeout 30
  "Seconds a new CLI process has to answer before the provider gives up."
  :type 'number :group 'harness)

(defcustom harness-provider-copilot-quota-ttl 300
  "Seconds after which the plan's quota report counts as stale.
A stale report is fetched again when `provider/quota' is asked.  The
report makes no model call.  nil fetches it only when nothing is known."
  :type '(choice (const :tag "Only once" nil) number) :group 'harness)

;;;; Constants

(defconst harness-provider-copilot-protocol-version 3
  "Oldest SDK protocol version of the CLI that this provider speaks.
Newer CLIs are used too; the log says when one reports a newer version.")

(defconst harness-provider-copilot-capabilities
  '(:hosted-loop t :fork t :resume t :vision t :thinking t :quota t
    :compaction hosted :cost-reported t :billing t)
  "Capabilities of every Copilot model; the catalogue refines `:vision'.")

(defconst harness-provider-copilot--usd-per-nano-aiu 1e-11
  "Dollars per nano AI unit: an AI credit is 1e9 of them and costs $0.01.")

(defconst harness-provider-copilot--usd-per-credit 0.01
  "Dollars per AI credit.")

(defconst harness-provider-copilot--usd-per-premium-request 0.04
  "Dollars an additional premium request costs on the legacy billing.")

(defconst harness-provider-copilot--efforts
  '("none" "minimal" "low" "medium" "high" "xhigh" "max")
  "Copilot's reasoning effort levels, weakest first.")

(defconst harness-provider-copilot--client-name "emacs-agent-harness"
  "Name the CLI is told its sessions are opened by.")

;;;; State

(cl-defstruct (harness-provider-copilot-session
               (:constructor harness-provider-copilot--make-session)
               (:copier nil))
  "One CLI process serving one harness session, or a probe."
  id                 ; harness session id, or "probe"
  process            ; the CLI process, or a dead one
  stderr             ; stderr buffer
  (buffer "")        ; unparsed stdout bytes (unibyte)
  (next-id 0)        ; last JSON-RPC request id
  calls              ; alist of (RPC-ID . CALLBACK) awaiting an answer
  ready              ; promise of the auth status once the handshake is done
  auth               ; the CLI's auth.getStatus answer
  version            ; CLI version from the handshake
  host               ; TRAMP prefix the process runs on, or nil
  opened             ; alist of (COPILOT-ID . KEY): sessions open in the process
  busy               ; Copilot session ids with a turn in flight
  waiters            ; alist of (COPILOT-ID . CALLBACKS) waiting for idle
  aborts             ; alist of (COPILOT-ID . TIMER) for aborts in flight
  main               ; Copilot session id of the harness session's conversation
  ;; Per-turn state
  request            ; the current request plist, nil when idle
  on-event           ; the current :on-event callback
  active             ; non-nil while a turn is in flight
  cancelled          ; non-nil once cancel was requested for this turn
  target             ; Copilot session id the turn runs in
  side               ; non-nil when TARGET is a throwaway session (a side request)
  sent               ; non-nil once the turn's message went out
  streamed           ; message and reasoning ids that streamed deltas
  usage              ; usage summed over the turn's model calls
  error              ; the turn's error message, from session.error
  (generation 0)     ; counter that tells a turn's continuations apart
  probe              ; non-nil for a probe that serves no session
  users)             ; for a probe: requests still using it

(defvar harness-provider-copilot--sessions (make-hash-table :test 'equal)
  "Harness session id -> `harness-provider-copilot-session'.")

(defvar harness-provider-copilot--status nil
  "What the CLI last said about the account, in the shape `provider/quota' returns.")

(defvar harness-provider-copilot--probe nil
  "The running probe record, or nil.")

(defvar harness-provider-copilot--refresh nil
  "The quota request in flight as a promise, or nil.")

(defvar harness-provider-copilot--asked nil
  "When a quota report was last asked for, as a float time.")

(defvar harness-provider-copilot--catalogue (make-hash-table :test 'equal)
  "Model name -> model plist, from the last `models.list' answer.")

(defvar harness-provider-copilot--newer-protocol-noted nil
  "Non-nil once the log has said that the CLI speaks a newer protocol.")

(defun harness-provider-copilot--drop-stale-entries ()
  "Stop the CLI processes of records older than the current record layout.
A reload keeps live records; one made before slots were added has no
room for them, so its process stops and the session's next turn
resumes its Copilot session in a new one."
  (let ((size (length (harness-provider-copilot--make-session))))
    (maphash (lambda (id entry)
               (when (< (length entry) size)
                 (let ((proc (aref entry 2)) (stderr (aref entry 3)))
                   (when (process-live-p proc)
                     (set-process-sentinel proc #'ignore)
                     (set-process-filter proc #'ignore)
                     (delete-process proc))
                   (when (buffer-live-p stderr) (kill-buffer stderr)))
                 (remhash id harness-provider-copilot--sessions)))
             harness-provider-copilot--sessions)))

(harness-provider-copilot--drop-stale-entries)

;;;; Small helpers

(defun harness-provider-copilot--compact (plist)
  "Return PLIST without the keys whose value is nil."
  (let (out)
    (cl-loop for (k v) on plist by #'cddr
             when v do (setq out (append out (list k v))))
    out))

(defun harness-provider-copilot--time (value)
  "Return VALUE, epoch seconds or an ISO 8601 string, as a float time, or nil."
  (cond ((numberp value) (float value))
        ((and (stringp value) (not (string-empty-p value)))
         (condition-case nil (float-time (parse-iso8601-time-string value)) (error nil)))))

(defun harness-provider-copilot--stderr-tail (entry)
  "Return the last few lines of ENTRY's stderr, or an empty string."
  (let ((buf (harness-provider-copilot-session-stderr entry)))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 1500)) (point-max))))
      "")))

(defun harness-provider-copilot--environment ()
  "Return the environment for a CLI process.
NODE_DEBUG goes: its traces would land on stdout, the protocol stream."
  (cl-remove-if (lambda (e) (string-prefix-p "NODE_DEBUG=" e)) process-environment))

(defun harness-provider-copilot--missing-message ()
  "Return the error message for a `copilot' program that cannot be found."
  (format "GitHub Copilot CLI not found (`%s'): install it with `npm install -g @github/copilot' \
and run `copilot login' once, or set `harness-provider-copilot-program'"
          harness-provider-copilot-program))

(defun harness-provider-copilot--login-message (auth)
  "Return the error message for the CLI's AUTH status when it is not logged in."
  (format "GitHub Copilot CLI is not logged in%s: run `copilot login' in a terminal, \
or set COPILOT_GITHUB_TOKEN, GH_TOKEN or GITHUB_TOKEN, then try again"
          (let ((status (plist-get auth :statusMessage)))
            (if (and (stringp status) (not (string-empty-p status))
                     (not (string-match-p "\\`not authenticated\\'" status)))
                (format " (%s)" status)
              ""))))

(defun harness-provider-copilot--rpc-message (method error)
  "Return a readable message for the JSON-RPC ERROR answering METHOD.
ERROR is the error plist of the answer, a string saying why no answer
came, or `restart' when the process was stopped on purpose."
  (let ((msg (cond ((stringp error) error)
                   ((eq error 'restart) "the copilot process was stopped")
                   ((consp error) (format "%s" (or (plist-get error :message) error)))
                   (t (format "%s" error)))))
    (when (string-match "\\`Request [^ ]+ failed with message: " msg)
      (setq msg (substring msg (match-end 0))))
    (format "Copilot %s failed: %s" method msg)))

;;;; Framing

(defun harness-provider-copilot-frame (object)
  "Return OBJECT as one framed JSON-RPC message, a unibyte string."
  (let ((body (encode-coding-string (harness-json-encode object) 'utf-8 t)))
    (concat (string-to-unibyte (format "Content-Length: %d\r\n\r\n" (length body))) body)))

(defun harness-provider-copilot-read-frames (data)
  "Split DATA, unibyte output of the CLI, into messages.
Return (BODIES . REST): the complete message bodies in order, decoded
as UTF-8, and the bytes of an incomplete message left over.  Header
blocks without a Content-Length are dropped with anything before them."
  (let ((data (if (multibyte-string-p data) (encode-coding-string data 'utf-8 t) data))
        (start 0) (bodies nil) (done nil) (case-fold-search t))
    (while (not done)
      (let ((header-end (string-search "\r\n\r\n" data start)))
        (if (null header-end)
            (setq done t)
          (let* ((header (substring data start header-end))
                 (size (and (string-match "content-length:[ \t]*\\([0-9]+\\)" header)
                            (string-to-number (match-string 1 header))))
                 (body-start (+ header-end 4)))
            (cond
             ((null size)
              (harness-log 'debug "provider-copilot: dropped output %S" (harness-truncate-end header 200))
              (setq start body-start))
             ((> (+ body-start size) (length data)) (setq done t))
             (t
              (push (decode-coding-string (substring data body-start (+ body-start size)) 'utf-8) bodies)
              (setq start (+ body-start size))))))))
    (cons (nreverse bodies) (substring data start))))

(defun harness-provider-copilot--send (entry object)
  "Write OBJECT as one framed message to ENTRY's process; non-nil when sent."
  (let ((proc (harness-provider-copilot-session-process entry)))
    (if (process-live-p proc)
        (condition-case err
            (progn (process-send-string proc (harness-provider-copilot-frame object)) t)
          (error (harness-log 'warn "provider-copilot: writing to %s failed: %s"
                              (harness-provider-copilot-session-id entry) (harness-error-message err))
                 nil))
      (harness-log 'debug "provider-copilot: cannot write to the dead process of %s"
                   (harness-provider-copilot-session-id entry))
      nil)))

;;;; JSON-RPC

(defun harness-provider-copilot--rpc (entry method params &optional callback)
  "Send request METHOD with PARAMS to ENTRY's CLI and return its id.
CALLBACK, when given, is called with (RESULT ERROR) once the answer
arrives; ERROR is the JSON-RPC error plist, a string when the process
went away first, or `restart' when it was stopped on purpose."
  (let ((id (cl-incf (harness-provider-copilot-session-next-id entry))))
    (when callback
      (push (cons id callback) (harness-provider-copilot-session-calls entry)))
    (unless (harness-provider-copilot--send
             entry (list :jsonrpc "2.0" :id id :method method :params (or params :empty)))
      (when (assq id (harness-provider-copilot-session-calls entry))
        (setf (harness-provider-copilot-session-calls entry)
              (assq-delete-all id (harness-provider-copilot-session-calls entry)))
        (harness-run-soon callback nil "the copilot process is not running")))
    id))

(define-error 'harness-provider-copilot-restart "The copilot process was stopped")

(defun harness-provider-copilot--call (entry method params)
  "Return a promise of the result of METHOD with PARAMS on ENTRY's CLI.
It is rejected with a readable message when the CLI answers an error,
and with `harness-provider-copilot-restart' when the process is stopped
on purpose before it answers."
  (let ((promise (harness-make-promise)))
    (harness-provider-copilot--rpc
     entry method params
     (lambda (result error)
       (cond ((eq error 'restart) (harness-reject promise '(harness-provider-copilot-restart)))
             (error (harness-reject promise (list 'error (harness-provider-copilot--rpc-message method error))))
             (t (harness-resolve promise result)))))
    promise))

(defun harness-provider-copilot--answer (entry id result &optional error)
  "Answer the CLI's request ID on ENTRY with RESULT.
ERROR, when given, is (CODE . MESSAGE) to answer with instead."
  (harness-provider-copilot--send
   entry (if error
             (list :jsonrpc "2.0" :id id :error (list :code (car error) :message (cdr error)))
           (list :jsonrpc "2.0" :id id :result (or result :empty)))))

(defun harness-provider-copilot--fail-calls (entry reason)
  "Fail every call and idle waiter of ENTRY with REASON.
REASON is a string saying why the process went away, or `restart' when
it was stopped on purpose."
  (let ((calls (harness-provider-copilot-session-calls entry))
        (waiters (harness-provider-copilot-session-waiters entry)))
    (setf (harness-provider-copilot-session-calls entry) nil
          (harness-provider-copilot-session-waiters entry) nil)
    (dolist (call (nreverse calls))
      (condition-case err (funcall (cdr call) nil reason)
        (error (harness-log 'error "provider-copilot: failing a call: %S" err))))
    (dolist (w waiters)
      (dolist (fn (reverse (cdr w)))
        (condition-case err (funcall fn reason)
          (error (harness-log 'error "provider-copilot: failing a waiter: %S" err)))))))

;;;; Process

(defun harness-provider-copilot--command ()
  "Return the command line of a CLI process."
  (append (list harness-provider-copilot-program "--headless" "--no-auto-update" "--stdio")
          harness-provider-copilot-extra-args))

(defun harness-provider-copilot--spawn (entry directory)
  "Start a CLI process for ENTRY in DIRECTORY and begin its handshake.
Signal an error with a readable message when the program is missing."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (process-environment (harness-provider-copilot--environment))
         (stderr (generate-new-buffer " *harness-copilot-stderr*" t))
         (proc (condition-case err
                   (make-process
                    :name (format "harness-copilot-%s" (harness-provider-copilot-session-id entry))
                    :command (harness-provider-copilot--command)
                    :coding 'binary
                    :connection-type 'pipe
                    :noquery t
                    :file-handler t
                    :stderr stderr
                    :filter (lambda (p chunk) (harness-provider-copilot--filter entry p chunk))
                    :sentinel (lambda (p e) (harness-provider-copilot--sentinel entry p e)))
                 (file-missing
                  (kill-buffer stderr)
                  (error "%s" (harness-provider-copilot--missing-message)))
                 (error (kill-buffer stderr) (signal (car err) (cdr err))))))
    (when-let* ((ep (get-buffer-process stderr)))
      (set-process-query-on-exit-flag ep nil)
      (set-process-sentinel ep #'ignore))
    (setf (harness-provider-copilot-session-process entry) proc
          (harness-provider-copilot-session-stderr entry) stderr
          (harness-provider-copilot-session-buffer entry) ""
          (harness-provider-copilot-session-calls entry) nil
          (harness-provider-copilot-session-auth entry) nil
          (harness-provider-copilot-session-version entry) nil
          (harness-provider-copilot-session-host entry) (file-remote-p default-directory)
          (harness-provider-copilot-session-opened entry) nil
          (harness-provider-copilot-session-busy entry) nil
          (harness-provider-copilot-session-waiters entry) nil
          (harness-provider-copilot-session-aborts entry) nil)
    (harness-log 'info "provider-copilot: spawned for %s in %s"
                 (harness-provider-copilot-session-id entry) default-directory)
    (setf (harness-provider-copilot-session-ready entry)
          (harness-provider-copilot--handshake entry proc))
    proc))

(defun harness-provider-copilot--protocol-problem (result)
  "Return why the CLI that answered RESULT cannot serve, or nil.
RESULT is the answer to connect, or to ping from older CLIs."
  (let ((version (plist-get result :protocolVersion)))
    (cond
     ((not (and (numberp version) (>= version harness-provider-copilot-protocol-version)))
      (format "copilot %s speaks protocol %s; the harness needs %s or newer: update it with `copilot update' or `npm install -g @github/copilot'"
              (or (plist-get result :version) "?") (or version "?")
              harness-provider-copilot-protocol-version))
     ((> version harness-provider-copilot-protocol-version)
      (unless harness-provider-copilot--newer-protocol-noted
        (setq harness-provider-copilot--newer-protocol-noted t)
        (harness-log 'warn "provider-copilot: copilot %s speaks protocol %s, newer than %s; trying it"
                     (plist-get result :version) version harness-provider-copilot-protocol-version))
      nil))))

(defun harness-provider-copilot--handshake (entry proc)
  "Return a promise of the auth status of ENTRY's new process PROC.
It is rejected when the CLI speaks too old a protocol, dies, or does
not answer within `harness-provider-copilot-startup-timeout'."
  (let* ((promise (harness-make-promise))
         (timer nil)
         (fail (lambda (message)
                 (when timer (cancel-timer timer))
                 (unless (harness-promise-settled-p promise)
                   (harness-reject promise (list 'error message)))))
         (why (lambda (method error)
                (if (stringp error)
                    (harness-provider-copilot--exit-message entry)
                  (harness-provider-copilot--rpc-message method error))))
         (authenticate
          (lambda (result)
            (if-let* ((problem (harness-provider-copilot--protocol-problem result)))
                (progn (funcall fail problem)
                       (harness-provider-copilot--kill entry))
              (setf (harness-provider-copilot-session-version entry) (plist-get result :version))
              (harness-provider-copilot--rpc
               entry "auth.getStatus" nil
               (lambda (auth error)
                 (if error
                     (funcall fail (funcall why "auth.getStatus" error))
                   (when timer (cancel-timer timer))
                   (setf (harness-provider-copilot-session-auth entry) auth)
                   (harness-provider-copilot--handle-auth auth)
                   (harness-resolve promise auth))))))))
    (setq timer
          (run-at-time harness-provider-copilot-startup-timeout nil
                       (lambda ()
                         (unless (harness-promise-settled-p promise)
                           (let ((tail (harness-provider-copilot--stderr-tail entry)))
                             (funcall fail (format "copilot did not answer within %ss; it must be GitHub Copilot CLI 1.0 or newer%s"
                                                   harness-provider-copilot-startup-timeout
                                                   (if (string-empty-p tail) "" (concat ": " tail)))))
                           (when (eq proc (harness-provider-copilot-session-process entry))
                             (harness-provider-copilot--kill entry))))))
    (harness-provider-copilot--rpc
     entry "connect" nil
     (lambda (result error)
       (cond
        ((null error) (funcall authenticate result))
        ((or (stringp error) (eq error 'restart)) (funcall fail (funcall why "connect" error)))
        ;; CLIs from before `connect' answer `ping' with their version.
        (t (harness-provider-copilot--rpc
            entry "ping" nil
            (lambda (result error)
              (if error
                  (funcall fail (funcall why "ping" error))
                (funcall authenticate result))))))))
    promise))

(defun harness-provider-copilot--exit-message (entry)
  "Return the message for ENTRY's CLI going away during a request."
  (let ((proc (harness-provider-copilot-session-process entry))
        (tail (harness-provider-copilot--stderr-tail entry)))
    (format "copilot exited%s%s"
            (if (and (processp proc) (not (process-live-p proc)))
                (format " with status %s" (process-exit-status proc))
              "")
            (if (string-empty-p tail) "" (concat ": " tail)))))

(defun harness-provider-copilot--kill (entry &optional reason)
  "Kill ENTRY's process and its stderr buffer, failing what waits on it.
A turn whose message the process already had ends: cancelled when it
was being cancelled, else with REASON as its error.  A turn still on
its way to the process starts again in a new one."
  (let ((proc (harness-provider-copilot-session-process entry))
        (buf (harness-provider-copilot-session-stderr entry)))
    (when (processp proc)
      (set-process-sentinel proc #'ignore)
      (set-process-filter proc #'ignore)
      (when (process-live-p proc) (delete-process proc)))
    (when (buffer-live-p buf) (kill-buffer buf))
    (dolist (a (harness-provider-copilot-session-aborts entry))
      (cancel-timer (cdr a)))
    (setf (harness-provider-copilot-session-process entry) nil
          (harness-provider-copilot-session-stderr entry) nil
          (harness-provider-copilot-session-buffer entry) ""
          (harness-provider-copilot-session-opened entry) nil
          (harness-provider-copilot-session-busy entry) nil
          (harness-provider-copilot-session-aborts entry) nil)
    (when (and (harness-provider-copilot-session-active entry)
               (harness-provider-copilot-session-sent entry))
      (harness-provider-copilot--finish
       entry (if (harness-provider-copilot-session-cancelled entry)
                 '(:type done :stop-reason cancelled)
               (list :type 'done :stop-reason 'error
                     :error (or reason "the copilot process was stopped")))))
    (harness-provider-copilot--fail-calls entry 'restart)))

(defun harness-provider-copilot--filter (entry proc chunk)
  "Handle CHUNK of PROC's stdout for ENTRY: every complete message in it."
  (when (eq proc (harness-provider-copilot-session-process entry))
    (pcase-let ((`(,bodies . ,rest)
                 (harness-provider-copilot-read-frames
                  (concat (harness-provider-copilot-session-buffer entry) chunk))))
      ;; Output that never forms a message must not pile up forever.
      (setf (harness-provider-copilot-session-buffer entry)
            (if (> (length rest) 4000000) "" rest))
      (while (and bodies (eq proc (harness-provider-copilot-session-process entry)))
        (let ((body (pop bodies)))
          (condition-case err
              (when-let* ((msg (harness-json-parse body)))
                (harness-provider-copilot--dispatch entry msg))
            (error (harness-log 'error "provider-copilot: bad message %s: %S"
                                (harness-truncate-end body 300) err))))))))

(defun harness-provider-copilot--sentinel (entry proc _event)
  "Handle the death of ENTRY's process PROC."
  (unless (process-live-p proc)
    (when (eq proc (harness-provider-copilot-session-process entry))
      (let ((message (harness-provider-copilot--exit-message entry)))
        (harness-log 'info "provider-copilot: process for %s exited %s"
                     (harness-provider-copilot-session-id entry) (process-exit-status proc))
        (dolist (a (harness-provider-copilot-session-aborts entry))
          (cancel-timer (cdr a)))
        (setf (harness-provider-copilot-session-opened entry) nil
              (harness-provider-copilot-session-busy entry) nil
              (harness-provider-copilot-session-aborts entry) nil)
        (harness-provider-copilot--fail-calls entry message)
        (harness-provider-copilot--finish
         entry
         (if (harness-provider-copilot-session-cancelled entry)
             '(:type done :stop-reason cancelled)
           (list :type 'done :stop-reason 'error :error message)))
        (let ((buf (harness-provider-copilot-session-stderr entry)))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (setf (harness-provider-copilot-session-stderr entry) nil)
        (when (harness-provider-copilot-session-probe entry)
          (harness-provider-copilot--probe-gone entry))))))

;;;; Messages in

(defun harness-provider-copilot--dispatch (entry msg)
  "Handle one parsed message MSG from ENTRY's CLI."
  (let ((id (plist-get msg :id))
        (method (plist-get msg :method)))
    (cond
     ((and method id)
      ;; Requests from the CLI.  None is expected with the session
      ;; options used here; an error answer keeps the CLI from waiting.
      (harness-log 'debug "provider-copilot: unexpected request %s" method)
      (harness-provider-copilot--answer entry id nil (cons -32601 (format "%s is not supported by this client" method))))
     (method
      (pcase method
        ("session.event"
         (let ((params (plist-get msg :params)))
           (harness-provider-copilot--handle-event
            entry (plist-get params :sessionId) (plist-get params :event))))
        (_ nil)))
     (id
      (let ((call (assq id (harness-provider-copilot-session-calls entry))))
        (when call
          (setf (harness-provider-copilot-session-calls entry)
                (delq call (harness-provider-copilot-session-calls entry)))
          (funcall (cdr call) (plist-get msg :result) (plist-get msg :error))))))))

(defun harness-provider-copilot--current-p (entry sid)
  "Non-nil when Copilot session SID runs ENTRY's current turn."
  (and (harness-provider-copilot-session-active entry)
       (harness-provider-copilot-session-sent entry)
       (equal sid (harness-provider-copilot-session-target entry))))

(defun harness-provider-copilot--emit (entry event)
  "Deliver EVENT to the current turn's callback on ENTRY."
  (let ((fn (harness-provider-copilot-session-on-event entry)))
    (when (and fn (harness-provider-copilot-session-active entry))
      (funcall fn event))))

(defun harness-provider-copilot--handle-event (entry sid event)
  "Handle EVENT of Copilot session SID on ENTRY."
  (let ((type (plist-get event :type))
        (data (plist-get event :data))
        (agent (plist-get event :agentId)))
    (pcase type
      ("session.idle" (harness-provider-copilot--on-idle entry sid data))
      ("external_tool.requested" (harness-provider-copilot--tool-request entry sid data))
      ("permission.requested" (harness-provider-copilot--permission-request entry sid data))
      (_
       (when (harness-provider-copilot--current-p entry sid)
         (harness-provider-copilot--turn-event entry type data agent))))))

(defun harness-provider-copilot--streamed (entry id)
  "Remember that message or reasoning ID streamed deltas in ENTRY's turn."
  (when (and id (not (member id (harness-provider-copilot-session-streamed entry))))
    (push id (harness-provider-copilot-session-streamed entry))))

(defun harness-provider-copilot--turn-event (entry type data agent)
  "Handle an event of TYPE with DATA in ENTRY's current turn.
AGENT is the sub-agent the event comes from, nil for the main agent."
  (pcase type
    ("assistant.message_delta"
     (unless agent
       (let ((text (plist-get data :deltaContent)))
         (harness-provider-copilot--streamed entry (plist-get data :messageId))
         (when (and (stringp text) (not (string-empty-p text)))
           (harness-provider-copilot--emit entry (list :type 'text :delta text))))))
    ("assistant.reasoning_delta"
     (unless agent
       (let ((text (plist-get data :deltaContent)))
         (harness-provider-copilot--streamed entry (plist-get data :reasoningId))
         (when (and (stringp text) (not (string-empty-p text)))
           (harness-provider-copilot--emit entry (list :type 'thinking :delta text))))))
    ;; Complete messages repeat what streamed; they count only when nothing did.
    ("assistant.reasoning"
     (unless (or agent (member (plist-get data :reasoningId)
                               (harness-provider-copilot-session-streamed entry)))
       (let ((text (plist-get data :content)))
         (unless (harness-string-blank-p text)
           (harness-provider-copilot--emit entry (list :type 'thinking :delta text))))))
    ("assistant.message"
     (unless (or agent (member (plist-get data :messageId)
                               (harness-provider-copilot-session-streamed entry)))
       (let ((text (plist-get data :content)))
         (unless (harness-string-blank-p text)
           (harness-provider-copilot--emit entry (list :type 'text :delta text))))))
    ("assistant.usage" (harness-provider-copilot--add-usage entry data agent))
    ("session.usage_info"
     (let ((usage (harness-provider-copilot-session-usage entry)))
       (when (and (numberp (plist-get data :currentTokens)) (not (plist-get usage :context)))
         (setf (harness-provider-copilot-session-usage entry)
               (plist-put usage :current (plist-get data :currentTokens))))))
    ("session.error"
     (setf (harness-provider-copilot-session-error entry)
           (let ((msg (plist-get data :message)))
             (if (and (stringp msg) (not (string-empty-p msg)))
                 msg
               (format "%s error" (or (plist-get data :errorType) "unknown"))))))
    ("session.compaction_start"
     (harness-provider-copilot--emit entry '(:type hint :text "Copilot is compacting the context…")))
    ("session.compaction_complete"
     (harness-provider-copilot--emit
      entry (list :type 'hint
                  :text (if (harness-json-true-p (plist-get data :success))
                            (format "Context compacted by Copilot%s"
                                    (let ((pre (plist-get data :preCompactionTokens))
                                          (post (plist-get data :postCompactionTokens)))
                                      (if (and (numberp pre) (numberp post))
                                          (format ": %s → %s tokens"
                                                  (harness-format-tokens pre) (harness-format-tokens post))
                                        "")))
                          (format "Copilot could not compact the context: %s"
                                  (or (plist-get data :error) "unknown error"))))))
    ("session.warning"
     (let ((msg (plist-get data :message)))
       (when (stringp msg)
         (harness-provider-copilot--emit entry (list :type 'hint :text (concat "Copilot: " msg))))))
    (_ nil)))

(defun harness-provider-copilot--on-idle (entry sid data)
  "Handle the end of a turn of Copilot session SID on ENTRY.
DATA says whether it was aborted.  The turn of the harness ends before
anything waiting for SID to be idle resumes."
  (setf (harness-provider-copilot-session-busy entry)
        (delete sid (harness-provider-copilot-session-busy entry)))
  (when-let* ((timer (alist-get sid (harness-provider-copilot-session-aborts entry) nil nil #'equal)))
    (cancel-timer timer)
    (setf (harness-provider-copilot-session-aborts entry)
          (cl-remove sid (harness-provider-copilot-session-aborts entry) :key #'car :test #'equal)))
  (when (harness-provider-copilot--current-p entry sid)
    (harness-provider-copilot--end-turn entry (harness-json-true-p (plist-get data :aborted))))
  (let ((w (assoc sid (harness-provider-copilot-session-waiters entry))))
    (when w
      (setf (harness-provider-copilot-session-waiters entry)
            (delq w (harness-provider-copilot-session-waiters entry)))
      (dolist (fn (reverse (cdr w))) (funcall fn t)))))

(defun harness-provider-copilot--tool-request (entry sid data)
  "Turn the external tool request DATA of Copilot session SID into a tool call.
The call goes to ENTRY's turn, whose `:respond' answers the CLI."
  (let* ((proc (harness-provider-copilot-session-process entry))
         (request-id (plist-get data :requestId))
         (name (plist-get data :toolName))
         (call-id (or (plist-get data :toolCallId) (concat "call_" (harness-short-id 12))))
         (answered nil)
         (respond
          (lambda (result)
            (unless answered
              (setq answered t)
              (if (not (eq proc (harness-provider-copilot-session-process entry)))
                  (harness-log 'debug "provider-copilot: dropping the result of %s: its process is gone" name)
                (harness-provider-copilot--rpc
                 entry "session.tools.handlePendingToolCall"
                 (list :sessionId sid :requestId request-id
                       :result (harness-provider-copilot-tool-result result))
                 (lambda (_result error)
                   (when error
                     (harness-log 'debug "provider-copilot: result of %s not taken: %s"
                                  name (harness-provider-copilot--rpc-message "handlePendingToolCall" error))))))))))
    (if (and (harness-provider-copilot--current-p entry sid)
             (not (harness-provider-copilot-session-cancelled entry)))
        (harness-provider-copilot--emit
         entry (list :type 'tool-call :id call-id :name name
                     :input (plist-get data :arguments) :respond respond))
      (funcall respond '(:content "The harness is not running a turn in this conversation" :is-error t)))))

(defun harness-provider-copilot-tool-result (result)
  "Convert a harness tool RESULT (:content :is-error) for handlePendingToolCall."
  (let* ((content (plist-get result :content))
         (text (if (stringp content) content (format "%s" (or content ""))))
         (failed (harness-json-true-p (plist-get result :is-error))))
    (if failed
        (list :textResultForLlm text :resultType "failure" :error text)
      (list :textResultForLlm text :resultType "success"))))

(defun harness-provider-copilot--permission-request (entry sid data)
  "Answer the permission request DATA of Copilot session SID on ENTRY.
The harness checks permissions when it runs a tool, so its own tools are
approved here; anything else is refused, since it would not be the
harness's to run."
  (unless (harness-json-true-p (plist-get data :resolvedByHook))
    (let* ((request (plist-get data :permissionRequest))
           (kind (plist-get request :kind))
           (ours (equal kind "custom-tool")))
      (harness-log (if ours 'debug 'info) "provider-copilot: %s a %s permission request for %s"
                   (if ours "approving" "refusing") kind (or (plist-get request :toolName) "?"))
      (harness-provider-copilot--rpc
       entry "session.permissions.handlePendingPermissionRequest"
       (list :sessionId sid :requestId (plist-get data :requestId)
             :result (if ours
                         '(:kind "approve-once")
                       '(:kind "reject" :feedback "Only the harness's own tools may be used here.")))
       #'ignore))))

;;;; Usage and billing

(defun harness-provider-copilot-call-usage (data)
  "Return the token counts and cost of one model call from assistant.usage DATA.
The value is (:input :output :cache-read :cache-write :context :nano-aiu
:requests :finish).  Input tokens are the uncached ones, as the harness
counts them; `:context' is the whole prompt.  The CLI's `inputTokens'
includes cached tokens, and its itemized `copilotUsage' wins when
present, as in the CLI's own accounting."
  (let* ((details (harness-plist-get-in data '(:copilotUsage :tokenDetails)))
         (detail (lambda (type)
                   (let ((d (cl-find type details :key (lambda (x) (plist-get x :tokenType)) :test #'equal)))
                     (and d (numberp (plist-get d :tokenCount)) (plist-get d :tokenCount)))))
         (num (lambda (v) (if (numberp v) v 0)))
         (input-detail (funcall detail "input"))
         (cache-read (or (funcall detail "cache_read") (funcall num (plist-get data :cacheReadTokens))))
         (cache-write (max (funcall num (plist-get data :cacheWriteTokens))
                           (+ (or (funcall detail "cache_write") 0) (or (funcall detail "cache_write_1h") 0))))
         (input-total (funcall num (plist-get data :inputTokens)))
         (nano (harness-plist-get-in data '(:copilotUsage :totalNanoAiu))))
    (list :input (or input-detail (max 0 (- input-total cache-read cache-write)))
          :output (or (funcall detail "output") (funcall num (plist-get data :outputTokens)))
          :cache-read cache-read
          :cache-write cache-write
          :context (if input-detail (+ input-detail cache-read cache-write) input-total)
          :nano-aiu (and (numberp nano) nano)
          :requests (and (numberp (plist-get data :cost)) (plist-get data :cost))
          :finish (plist-get data :finishReason))))

(defun harness-provider-copilot--add-usage (entry data agent)
  "Add the model call that assistant.usage DATA reports to ENTRY's turn.
AGENT, the sub-agent that made the call, adds to the cost but not to
the size of the main conversation."
  (let* ((call (harness-provider-copilot-call-usage data))
         (sum (harness-provider-copilot-session-usage entry)))
    (dolist (k '(:input :output :cache-read :cache-write))
      (setq sum (plist-put sum k (+ (or (plist-get sum k) 0) (plist-get call k)))))
    (dolist (k '(:nano-aiu :requests))
      (when (plist-get call k)
        (setq sum (plist-put sum k (+ (or (plist-get sum k) 0) (plist-get call k))))))
    (unless agent
      (setq sum (plist-put sum :context (plist-get call :context)))
      (setq sum (plist-put sum :finish (plist-get call :finish))))
    (setq sum (plist-put sum :calls (1+ (or (plist-get sum :calls) 0))))
    (setf (harness-provider-copilot-session-usage entry) sum)
    (when-let* ((snapshots (plist-get data :quotaSnapshots)))
      (harness-provider-copilot--handle-quota entry snapshots))))

(defun harness-provider-copilot--billing-fields (usage)
  "Return the billing part of a usage event for the turn USAGE sums up.
The plan pays (`subscription', `:cost' 0) unless its allowance is used
up and additional usage is on (`extra-usage', billed at list price)."
  (let* ((status harness-provider-copilot--status)
         (plan (plist-get status :plan))
         (nano (plist-get usage :nano-aiu))
         (list-cost (and (numberp nano) (> nano 0) (* nano harness-provider-copilot--usd-per-nano-aiu)))
         (requests (plist-get usage :requests)))
    (if (plist-get status :using-extra)
        (let ((cost (or list-cost
                        (and (numberp requests) (* requests harness-provider-copilot--usd-per-premium-request)))))
          (list :billing 'extra-usage :plan plan :cost cost :list-cost cost))
      ;; Without a credit figure the session prices the list cost from
      ;; the catalogue's token prices.
      (list :billing 'subscription :plan plan :cost 0.0 :list-cost list-cost))))

(defun harness-provider-copilot--usage-event (entry)
  "Return the usage event for ENTRY's turn, or nil when it made no model call."
  (let ((usage (harness-provider-copilot-session-usage entry)))
    (when (plist-get usage :calls)
      (append (list :type 'usage
                    :input (plist-get usage :input) :output (plist-get usage :output)
                    :cache-read (plist-get usage :cache-read) :cache-write (plist-get usage :cache-write)
                    :context (or (plist-get usage :context) (plist-get usage :current)
                                 (+ (plist-get usage :input) (plist-get usage :cache-read)
                                    (plist-get usage :cache-write))))
              (harness-provider-copilot--billing-fields usage)))))

;;;; Account and quota

(defun harness-provider-copilot--plan-id (plan)
  "Return the plan id of the CLI's PLAN tier, or nil.
\"individual_pro\" gives \"pro\"."
  (when (and (stringp plan) (not (string-empty-p plan)))
    (let ((id (downcase plan)))
      (if (string-prefix-p "individual_" id) (substring id (length "individual_")) id))))

(defun harness-provider-copilot--plan-label (plan)
  "Return the display name of plan id PLAN (\"pro_plus\" gives \"Copilot Pro+\")."
  (when (and (stringp plan) (not (string-empty-p plan)))
    (concat "Copilot "
            (pcase plan
              ("pro_plus" "Pro+")
              ("edu" "Education")
              (_ (capitalize (replace-regexp-in-string "_" " " plan)))))))

(defun harness-provider-copilot-account-info (auth)
  "Classify AUTH, the CLI's auth.getStatus answer.
Return (:billing BILLING :plan ID :plan-label LABEL :auth TYPE :account
\(:login :host)).  A Copilot login is a subscription; BILLING is nil
when the CLI is not logged in."
  (let* ((in (harness-json-true-p (plist-get auth :isAuthenticated)))
         (plan (harness-provider-copilot--plan-id (plist-get auth :copilotPlan))))
    (list :billing (and in 'subscription)
          :plan plan
          :plan-label (harness-provider-copilot--plan-label plan)
          :auth (and in (or (plist-get auth :authType) "github"))
          :account (and in (harness-provider-copilot--compact
                            (list :login (plist-get auth :login) :host (plist-get auth :host)))))))

(defun harness-provider-copilot--publish (changes)
  "Merge CHANGES into the account status, announce it, and return it."
  (let* ((old harness-provider-copilot--status)
         (new (harness-plist-merge old changes)))
    (setq harness-provider-copilot--status new)
    (unless (equal old new)
      (harness-emit 'provider/quota-updated 'copilot new))
    new))

(defun harness-provider-copilot--handle-auth (auth)
  "Remember what the auth status AUTH says about the account."
  (let ((info (harness-provider-copilot-account-info auth)))
    (when (plist-get info :billing)
      (harness-provider-copilot--publish (harness-provider-copilot--compact info)))))

(defconst harness-provider-copilot--quota-labels
  '(("premium_interactions" "premium" "Premium requests this month")
    ("chat" "chat" "Chat messages this month")
    ("completions" "completions" "Code completions this month"))
  "Quota types of the CLI as (TYPE NAME LABEL).")

(defun harness-provider-copilot--credits-p (snapshot)
  "Non-nil when quota SNAPSHOT counts AI credits rather than premium requests."
  (harness-json-true-p (plist-get snapshot :tokenBasedBilling)))

(defun harness-provider-copilot--quota-window (type snapshot)
  "Convert quota SNAPSHOT of quota TYPE into a window plist, or nil when unlimited."
  (let ((entitled (plist-get snapshot :entitlementRequests))
        (used (plist-get snapshot :usedRequests))
        (remaining (plist-get snapshot :remainingPercentage)))
    (unless (or (harness-json-true-p (plist-get snapshot :isUnlimitedEntitlement))
                (and (numberp entitled) (< entitled 0)))
      (let* ((known (assoc type harness-provider-copilot--quota-labels))
             (credits (and (equal type "premium_interactions")
                           (harness-provider-copilot--credits-p snapshot)))
             (name (cond (credits "credits") (known (nth 1 known)) (t type)))
             (label (cond (credits "AI credits this month")
                          (known (nth 2 known))
                          (t (concat (capitalize (replace-regexp-in-string "_" " " type)) " this month")))))
        (harness-provider-copilot--compact
         (list :name name
               :label (if (and (numberp used) (numberp entitled) (> entitled 0))
                          (format "%s (%s of %s)" label (round used) (round entitled))
                        label)
               :used (cond ((numberp remaining) (max 0.0 (min 1.0 (/ (- 100.0 remaining) 100.0))))
                           ((and (numberp used) (numberp entitled) (> entitled 0))
                            (min 1.0 (/ (float used) entitled))))
               :resets (or (harness-provider-copilot--time (plist-get snapshot :resetDate))
                           (let ((ms (plist-get snapshot :resetDateEpochMs)))
                             (and (numberp ms) (/ ms 1000.0))))))))))

(defun harness-provider-copilot-quota-changes (snapshots)
  "Return the account status changes quota SNAPSHOTS imply.
SNAPSHOTS is the `quotaSnapshots' plist of account.getQuota or of an
assistant.usage event, keyed by quota type."
  (let (windows main)
    (cl-loop for (key snap) on snapshots by #'cddr
             do (let ((type (string-remove-prefix ":" (format "%s" key))))
                  (when (consp snap)
                    (when (equal type "premium_interactions") (setq main snap))
                    (when-let* ((w (harness-provider-copilot--quota-window type snap)))
                      (push w windows)))))
    (setq windows (nreverse windows))
    (append
     (list :updated (float-time) :available (and windows t) :windows windows)
     (when main
       (let* ((credits (harness-provider-copilot--credits-p main))
              (unit (if credits harness-provider-copilot--usd-per-credit
                      harness-provider-copilot--usd-per-premium-request))
              (remaining (plist-get main :remainingPercentage))
              (exhausted (and (numberp remaining) (<= remaining 0)))
              (allowed (or (harness-json-true-p (plist-get main :overageAllowedWithExhaustedQuota))
                           (harness-json-true-p (plist-get main :usageAllowedWithExhaustedQuota))))
              (overage (plist-get main :overage))
              (cap (plist-get main :overageEntitlement)))
         (list :extra (harness-provider-copilot--compact
                       (list :enabled (if allowed t :false)
                             :used (and (numberp overage) (* overage unit))
                             :limit (and (numberp cap) (> cap 0) (* cap harness-provider-copilot--usd-per-credit))
                             :currency "USD"))
               :limit-status (cond ((and exhausted (not allowed)) "rejected")
                                   ((and (numberp remaining) (<= remaining 10)) "allowed_warning")
                                   (t "allowed"))
               :using-extra (and exhausted allowed t)))))))

(defun harness-provider-copilot--handle-quota (entry snapshots)
  "Publish quota SNAPSHOTS and tell ENTRY's turn about the windows."
  (let* ((old (plist-get harness-provider-copilot--status :windows))
         (status (harness-provider-copilot--publish
                  (harness-provider-copilot-quota-changes snapshots)))
         (windows (plist-get status :windows)))
    (when (and entry windows (not (equal old windows)))
      (harness-provider-copilot--emit entry (list :type 'quota :windows windows)))
    status))

(defun harness-provider-copilot--stale-p ()
  "Non-nil when the plan's quota should be fetched again.
Asking counts like an answer, so a CLI that cannot report quota is not
asked again before `harness-provider-copilot-quota-ttl' has passed."
  (let* ((status harness-provider-copilot--status)
         (last (max (or (plist-get status :updated) 0) (or harness-provider-copilot--asked 0))))
    (cond ((zerop last) t)
          ((null harness-provider-copilot-quota-ttl) nil)
          (t (> (- (float-time) last) harness-provider-copilot-quota-ttl)))))

;;;; Probe and server-level requests

(defun harness-provider-copilot--live-entry ()
  "Return a session record whose process has finished its handshake, or nil."
  (let (best)
    (maphash (lambda (_ e)
               (let ((ready (harness-provider-copilot-session-ready e)))
                 (when (and (process-live-p (harness-provider-copilot-session-process e))
                            (not (harness-provider-copilot-session-host e))
                            ready (eq (harness-promise-state ready) 'resolved)
                            (or (null best)
                                (and (harness-provider-copilot-session-active best)
                                     (not (harness-provider-copilot-session-active e)))))
                   (setq best e))))
             harness-provider-copilot--sessions)
    best))

(defun harness-provider-copilot--start-probe ()
  "Return the probe record, starting a CLI process that serves no session.
It answers server-level requests (models, quota) and exits once nothing
uses it.  Signal an error when the program is missing."
  (let ((probe harness-provider-copilot--probe))
    (if (and probe (process-live-p (harness-provider-copilot-session-process probe)))
        probe
      (let ((entry (harness-provider-copilot--make-session :id "probe" :probe t)))
        (harness-provider-copilot--spawn entry temporary-file-directory)
        (setq harness-provider-copilot--probe entry)
        entry))))

(defun harness-provider-copilot--end-probe (entry)
  "Let the probe ENTRY exit by closing its input once nothing uses it."
  (when (and (zerop (or (harness-provider-copilot-session-users entry) 0))
             (process-live-p (harness-provider-copilot-session-process entry)))
    (process-send-eof (harness-provider-copilot-session-process entry))
    (let ((proc (harness-provider-copilot-session-process entry)))
      (run-at-time 5 nil (lambda () (when (process-live-p proc) (delete-process proc)))))))

(defun harness-provider-copilot--probe-gone (entry)
  "Forget the probe ENTRY whose process ended."
  (when (eq harness-provider-copilot--probe entry)
    (setq harness-provider-copilot--probe nil)))

(defun harness-provider-copilot--with-server (fn)
  "Call FN with a ready CLI record and its auth status; return FN's promise.
A live session process is used when there is one, else the probe."
  (condition-case err
      (let* ((live (harness-provider-copilot--live-entry))
             (entry (or live (harness-provider-copilot--start-probe))))
        (unless live
          (setf (harness-provider-copilot-session-users entry)
                (1+ (or (harness-provider-copilot-session-users entry) 0))))
        (let ((result (harness-then (harness-provider-copilot-session-ready entry)
                                    (lambda (auth) (funcall fn entry auth)))))
          (unless live
            (let ((done (lambda (&rest _)
                          (cl-decf (harness-provider-copilot-session-users entry))
                          ;; Requests made together share the probe.
                          (run-at-time 1 nil #'harness-provider-copilot--end-probe entry)
                          nil)))
              (harness-then result done done)))
          result))
    (error (harness-rejected err))))

;;;; Models

(defun harness-provider-copilot--model-label (id)
  "Return a display name for model ID (\"gpt-5.4-mini\" gives \"GPT-5.4 mini\")."
  (let ((words (split-string id "-")))
    (cond
     ((member (car words) '("gpt" "o1" "o3" "o4"))
      (string-join (cons (concat (upcase (car words))
                                 (if (cdr words) (concat "-" (cadr words)) ""))
                         (cddr words))
                   " "))
     (t (mapconcat (lambda (w) (if (string-match-p "\\`[a-z]" w) (capitalize w) w)) words " ")))))

(defun harness-provider-copilot--pricing (prices)
  "Convert the CLI's token PRICES into USD per million tokens.
PRICES are in AI credits per batch of `:batchSize' tokens."
  (let ((batch (plist-get prices :batchSize)))
    (when (and (numberp batch) (> batch 0))
      (let ((usd (lambda (credits)
                   (and (numberp credits)
                        (/ (* credits harness-provider-copilot--usd-per-credit 1000000.0) batch)))))
        (harness-provider-copilot--compact
         (list :input (funcall usd (plist-get prices :inputPrice))
               :output (funcall usd (plist-get prices :outputPrice))
               :cache-read (funcall usd (or (plist-get prices :cacheReadPrice) (plist-get prices :cachePrice)))
               :cache-write (funcall usd (plist-get prices :cacheWritePrice))))))))

(defun harness-provider-copilot-model-from-entry (model)
  "Convert MODEL, one entry of a models.list answer, into a model plist.
Return nil for a model the account's policy disables."
  (let* ((id (plist-get model :id))
         (caps (plist-get model :capabilities))
         (limits (plist-get caps :limits))
         (vision (harness-json-true-p (harness-plist-get-in caps '(:supports :vision))))
         (window (or (plist-get limits :max_context_window_tokens)
                     (and (numberp (plist-get limits :max_prompt_tokens))
                          (+ (plist-get limits :max_prompt_tokens)
                             (or (plist-get limits :max_output_tokens) 0)))))
         (efforts (cl-remove-if-not #'stringp (plist-get model :supportedReasoningEfforts)))
         (pricing (harness-provider-copilot--pricing (harness-plist-get-in model '(:billing :tokenPrices))))
         (multiplier (harness-plist-get-in model '(:billing :multiplier))))
    (when (and (stringp id) (not (equal (harness-plist-get-in model '(:policy :state)) "disabled")))
      (harness-provider-copilot--compact
       (list :name id
             :label (let ((name (plist-get model :name)))
                      (if (and (stringp name) (not (string-empty-p name))) name
                        (harness-provider-copilot--model-label id)))
             :context-window (and (numberp window) window)
             :max-output (plist-get limits :max_output_tokens)
             :input-modalities (if vision '("text" "image") '("text"))
             :thinking-levels efforts
             :pricing pricing
             :multiplier (and (numberp multiplier) multiplier)
             :capabilities (list :vision vision :thinking (and efforts t)))))))

(defun harness-provider-copilot--sort-models (models)
  "Return MODELS with the default model first."
  (let ((default (cl-find harness-provider-copilot-default-model models
                          :key (lambda (m) (plist-get m :name)) :test #'equal)))
    (if default (cons default (delq default (copy-sequence models))) models)))

(defun harness-provider-copilot--remember-catalogue (models)
  "Keep MODELS, converted from models.list, for looking up effort levels."
  (clrhash harness-provider-copilot--catalogue)
  (dolist (m models) (puthash (plist-get m :name) m harness-provider-copilot--catalogue))
  models)

(defun harness-provider-copilot--builtin-models (result)
  "Convert RESULT, a models.getBuiltInCatalog answer, into model plists."
  (delq nil (mapcar (lambda (m)
                      (let ((id (plist-get m :id)))
                        (and (stringp id)
                             (list :name id :label (harness-provider-copilot--model-label id)))))
                    (plist-get result :models))))

(defun harness-provider-copilot--models ()
  "Return a promise of the model catalogue.
It comes from models.list, or from the CLI's built-in list of models
before it is logged in.  Without the program there are no models."
  (if (not (harness-provider-copilot--program-p))
      (progn (harness-log 'info "provider-copilot: %s" (harness-provider-copilot--missing-message))
             (harness-resolved nil))
    (harness-provider-copilot--with-server
     (lambda (entry auth)
       (harness-then
        (if (harness-json-true-p (plist-get auth :isAuthenticated))
            (harness-then (harness-provider-copilot--call entry "models.list" nil)
                          (lambda (result)
                            (harness-provider-copilot--remember-catalogue
                             (delq nil (mapcar #'harness-provider-copilot-model-from-entry
                                               (plist-get result :models)))))
                          (lambda (err)
                            (harness-log 'warn "provider-copilot: listing models failed: %s"
                                         (harness-error-message err))
                            nil))
          (harness-resolved nil))
        (lambda (models)
          (if models
              (harness-provider-copilot--sort-models models)
            (harness-then (harness-provider-copilot--call entry "models.getBuiltInCatalog" nil)
                          (lambda (result)
                            (harness-provider-copilot--sort-models
                             (harness-provider-copilot--builtin-models result)))))))))))

(defun harness-provider-copilot--program-p ()
  "Non-nil when the `copilot' program can be found locally."
  (let ((program harness-provider-copilot-program))
    (if (file-name-absolute-p program)
        (file-executable-p program)
      (executable-find program))))

;;;; Quota

(defun harness-provider-copilot--refresh ()
  "Fetch the plan's quota; return a promise of the account status."
  (or harness-provider-copilot--refresh
      (let ((promise
             (harness-catch
              (harness-provider-copilot--with-server
               (lambda (entry auth)
                 (if (not (harness-json-true-p (plist-get auth :isAuthenticated)))
                     harness-provider-copilot--status
                   (harness-then (harness-provider-copilot--call entry "account.getQuota" nil)
                                 (lambda (result)
                                   (harness-provider-copilot--handle-quota
                                    nil (plist-get result :quotaSnapshots)))))))
              (lambda (err)
                (harness-log 'debug "provider-copilot: quota report failed: %s" (harness-error-message err))
                harness-provider-copilot--status))))
        (setq harness-provider-copilot--asked (float-time))
        (unless (harness-promise-settled-p promise)
          (setq harness-provider-copilot--refresh promise)
          (harness-then promise (lambda (_) (setq harness-provider-copilot--refresh nil))))
        promise)))

(defun harness-provider-copilot--quota (&optional refresh)
  "Return a promise of how the account is billed and of its plan's quota.
The shape is the one `provider/quota' documents.  A new report is
fetched first when REFRESH is non-nil or the last one is stale (see
`harness-provider-copilot-quota-ttl'); it makes no model call."
  (if (and (or refresh (harness-provider-copilot--stale-p)) (harness-provider-copilot--program-p))
      (harness-provider-copilot--refresh)
    (harness-resolved harness-provider-copilot--status)))

;;;; Requests

(defun harness-provider-copilot--model-name (request)
  "Return the Copilot model REQUEST asks for."
  (let ((name (cdr (harness-provider-parse-model (plist-get request :model)))))
    (if (or (null name) (equal name "default")) harness-provider-copilot-default-model name)))

(defun harness-provider-copilot--effort (model level)
  "Return the reasoning effort to ask MODEL for at thinking LEVEL, or nil.
A level the model lacks becomes the strongest one it has below LEVEL
\(else its weakest); a model without levels gets none.  Models the
catalogue does not know get LEVEL as is."
  (when (and (stringp level) (not (string-empty-p level)))
    (let* ((known (gethash model harness-provider-copilot--catalogue))
           (levels (plist-get known :thinking-levels))
           (rank (lambda (l) (or (cl-position l harness-provider-copilot--efforts :test #'equal) -1))))
      (cond ((null known) level)
            ((null levels) nil)
            ((member level levels) level)
            (t (let ((below (cl-remove-if (lambda (l) (> (funcall rank l) (funcall rank level))) levels)))
                 (if below
                     (car (sort (copy-sequence below) (lambda (a b) (> (funcall rank a) (funcall rank b)))))
                   (car (sort (copy-sequence levels) (lambda (a b) (< (funcall rank a) (funcall rank b))))))))))))

(defun harness-provider-copilot--directory (session)
  "Return SESSION's directory, with its TRAMP host when it has one."
  (let* ((cwd (or (plist-get session :cwd) default-directory))
         (host (plist-get session :host))
         (cwd (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd)))
    (file-name-as-directory (expand-file-name cwd))))

(defun harness-provider-copilot-tool (spec)
  "Return the external tool definition of harness tool SPEC."
  (list :name (plist-get spec :name)
        :description (or (plist-get spec :description) "")
        :parameters (or (plist-get spec :schema) '(:type "object" :properties :empty))
        ;; The harness asks for permission itself when it runs the tool.
        :skipPermission t
        ;; Harness tools such as bash or glob replace Copilot's own.
        :overridesBuiltInTool t))

(defun harness-provider-copilot-session-config (request)
  "Return the session.create / session.resume parameters for REQUEST.
Only the harness tools are available; the system prompt replaces
Copilot's."
  (let* ((model (harness-provider-copilot--model-name request))
         (effort (harness-provider-copilot--effort model (plist-get request :thinking)))
         (system (plist-get request :system))
         (tools (plist-get request :tools)))
    (append
     (list :model model
           :clientName harness-provider-copilot--client-name
           :workingDirectory (directory-file-name
                              (file-local-name (harness-provider-copilot--directory (plist-get request :session))))
           :streaming t
           :tools (harness-json-array (mapcar #'harness-provider-copilot-tool tools))
           :availableTools (harness-json-array (mapcar (lambda (s) (plist-get s :name)) tools))
           :toolSearch '(:enabled :false)
           :requestPermission t
           :requestUserInput :false)
     (when effort (list :reasoningEffort effort))
     (unless (harness-string-blank-p system)
       (list :systemMessage (list :mode "replace" :content system))))))

(defun harness-provider-copilot--key (config)
  "Return what tells session CONFIG apart from another, for reopening."
  (secure-hash 'sha1 (encode-coding-string (harness-json-encode config) 'utf-8 t)))

(defun harness-provider-copilot--read-base64 (path)
  "Return the contents of PATH base64 encoded, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (base64-encode-string (buffer-string) t))))

(defun harness-provider-copilot--image-attachment (block)
  "Return a blob attachment for image BLOCK, or nil when it has no data."
  (let* ((path (plist-get block :path))
         (data (or (plist-get block :data) (harness-provider-copilot--read-base64 path))))
    (when data
      (list :type "blob" :data data :mimeType (or (plist-get block :mime) "image/png")
            :displayName (if path (file-name-nondirectory path) "image")))))

(defun harness-provider-copilot-prompt (request)
  "Return (TEXT . ATTACHMENTS) for the trailing user messages of REQUEST, or nil.
Only what follows the last assistant message is new to the CLI."
  (let (texts attachments any)
    (dolist (msg (plist-get request :messages))
      (pcase (format "%s" (plist-get msg :role))
        ("assistant" (setq texts nil attachments nil any nil))
        ("user"
         (dolist (b (plist-get msg :content))
           (pcase (plist-get b :type)
             ("text"
              (let ((text (or (plist-get b :text) "")))
                (unless (string-empty-p text) (push text texts) (setq any t))))
             ("image"
              (when-let* ((a (harness-provider-copilot--image-attachment b)))
                (push a attachments) (setq any t)))
             ("file"
              (push (format "[attached file: %s]" (plist-get b :path)) texts)
              (setq any t))
             (_ nil))))))
    (when any
      (let ((text (string-join (nreverse texts) "\n\n")))
        (cons (if (and (string-empty-p text) attachments) "See the attached image." text)
              (nreverse attachments))))))

;;;; Turns

(defun harness-provider-copilot--finish (entry event)
  "End the current turn on ENTRY by delivering the done EVENT once."
  (when (harness-provider-copilot-session-active entry)
    (let ((fn (harness-provider-copilot-session-on-event entry)))
      (setf (harness-provider-copilot-session-active entry) nil
            (harness-provider-copilot-session-on-event entry) nil
            (harness-provider-copilot-session-request entry) nil)
      (when (harness-provider-copilot-session-side entry)
        (harness-provider-copilot--drop-side entry (harness-provider-copilot-session-target entry)))
      (when fn (funcall fn event)))))

(defun harness-provider-copilot--end-turn (entry aborted)
  "Report the usage of ENTRY's turn, then end it; ABORTED says the CLI stopped it."
  (when-let* ((usage (harness-provider-copilot--usage-event entry)))
    (harness-provider-copilot--emit entry usage))
  (let ((error (harness-provider-copilot-session-error entry))
        (finish (plist-get (harness-provider-copilot-session-usage entry) :finish)))
    (harness-provider-copilot--finish
     entry
     (cond ((or (harness-provider-copilot-session-cancelled entry) aborted)
            '(:type done :stop-reason cancelled))
           (error (list :type 'done :stop-reason 'error :error (concat "Copilot: " error)))
           ((equal finish "length") '(:type done :stop-reason max-tokens))
           (t '(:type done :stop-reason end-turn))))))

(defun harness-provider-copilot--drop-side (entry sid)
  "Close and delete the throwaway Copilot session SID on ENTRY once it is idle."
  (let ((drop (lambda ()
                (when (assoc sid (harness-provider-copilot-session-opened entry))
                  (setf (harness-provider-copilot-session-opened entry)
                        (cl-remove sid (harness-provider-copilot-session-opened entry)
                                   :key #'car :test #'equal))
                  (harness-provider-copilot--rpc
                   entry "session.detach" (list :sessionId sid)
                   (lambda (_r _e)
                     (harness-provider-copilot--rpc entry "sessions.delete" (list :sessionId sid) #'ignore)))))))
    (when sid
      (harness-provider-copilot--when-idle* entry sid (lambda (how) (when (eq how t) (funcall drop)))))))

(defun harness-provider-copilot--when-idle* (entry sid fn)
  "Call FN once Copilot session SID on ENTRY has no turn in flight.
FN gets t, or what made the wait end otherwise: `restart' when the
process was stopped on purpose, or a string when it went away."
  (if (member sid (harness-provider-copilot-session-busy entry))
      (let ((w (assoc sid (harness-provider-copilot-session-waiters entry))))
        (if w
            (push fn (cdr w))
          (push (list sid fn) (harness-provider-copilot-session-waiters entry))))
    (funcall fn t)))

(defun harness-provider-copilot--when-idle (entry sid)
  "Return a promise of SID once Copilot session SID on ENTRY is idle.
It is rejected with `harness-provider-copilot-restart' when the process
is stopped on purpose first, and with an error when it dies."
  (let ((promise (harness-make-promise)))
    (harness-provider-copilot--when-idle*
     entry sid (lambda (how)
                 (cond ((eq how t) (harness-resolve promise sid))
                       ((eq how 'restart) (harness-reject promise '(harness-provider-copilot-restart)))
                       (t (harness-reject promise (list 'error (format "%s" how)))))))
    promise))

(defun harness-provider-copilot--mark-open (entry sid key)
  "Remember that Copilot session SID is open in ENTRY's process with KEY."
  (setf (harness-provider-copilot-session-opened entry)
        (cons (cons sid key)
              (cl-remove sid (harness-provider-copilot-session-opened entry) :key #'car :test #'equal)))
  sid)

(defun harness-provider-copilot--create (entry config key)
  "Return a promise of a new Copilot session opened with CONFIG on ENTRY."
  (let ((id (harness-uuid)))
    (harness-then (harness-provider-copilot--call entry "session.create" (append (list :sessionId id) config))
                  (lambda (result)
                    (harness-provider-copilot--mark-open
                     entry (or (plist-get result :sessionId) id) key)))))

(defun harness-provider-copilot--restart-p (err)
  "Non-nil when ERR says that the process was stopped on purpose."
  (eq (car-safe err) 'harness-provider-copilot-restart))

(defun harness-provider-copilot--resume (entry sid config key note)
  "Return a promise of Copilot session SID opened with CONFIG on ENTRY.
When it cannot be resumed, a new session takes its place and NOTE, a
function, is called with a hint saying so."
  (harness-then
   (harness-provider-copilot--call entry "session.resume" (append (list :sessionId sid) config))
   (lambda (_) (harness-provider-copilot--mark-open entry sid key))
   (lambda (err)
     (if (harness-provider-copilot--restart-p err)
         (harness-rejected err)
       (harness-log 'warn "provider-copilot: cannot resume %s: %s" sid (harness-error-message err))
       (funcall note (format "Copilot could not resume its conversation (%s); this turn starts a new one without the earlier context"
                             (harness-error-message err)))
       (harness-provider-copilot--create entry config key)))))

(defun harness-provider-copilot--fork (entry source config key note)
  "Return a promise of a new fork of Copilot session SOURCE.
The fork is opened on ENTRY with CONFIG, whose KEY it is remembered by.
When it cannot be made, a new session takes its place and NOTE, a
function, is called with a hint saying so."
  (harness-then
   (harness-provider-copilot--call entry "sessions.fork" (list :sessionId source))
   (lambda (result) (harness-provider-copilot--resume entry (plist-get result :sessionId) config key note))
   (lambda (err)
     (if (harness-provider-copilot--restart-p err)
         (harness-rejected err)
       (harness-log 'warn "provider-copilot: cannot fork %s: %s" source (harness-error-message err))
       (funcall note (format "Copilot could not fork its conversation (%s); this turn starts a new one"
                             (harness-error-message err)))
       (harness-provider-copilot--create entry config key)))))

(defun harness-provider-copilot--open (entry sid config key note)
  "Return a promise of Copilot session SID, open on ENTRY with CONFIG.
A session open with other settings is resumed again once idle, which
applies them in place.  NOTE is passed to `harness-provider-copilot--resume'."
  (let ((open (assoc sid (harness-provider-copilot-session-opened entry))))
    (if (and open (equal (cdr open) key))
        (harness-resolved sid)
      (harness-then (harness-provider-copilot--when-idle entry sid)
                    (lambda (_) (harness-provider-copilot--resume entry sid config key note))))))

(defun harness-provider-copilot--open-target (entry request live)
  "Return a promise of the Copilot session REQUEST runs in, open on ENTRY.
The provider state names the conversation.  When the harness session
already has one in this process, a request that brings a fork of it, or
no state at all, is a side request (the naming of the session, say): it
runs in a throwaway session that is deleted afterwards, and the
conversation is left as it was.  LIVE says whether the turn still
wants the session, and to hear about it, once it is open."
  (let* ((state (plist-get request :provider-state))
         (id (plist-get state :copilot-session-id))
         (fork (and id (harness-json-true-p (plist-get state :fork-pending))))
         (main (harness-provider-copilot-session-main entry))
         (config (harness-provider-copilot-session-config request))
         (key (harness-provider-copilot--key config))
         (side (and main (or (null id) (and fork (equal id main)))))
         (note (lambda (text)
                 (when (funcall live)
                   (harness-provider-copilot--emit entry (list :type 'hint :text text))))))
    (setf (harness-provider-copilot-session-side entry) side)
    (harness-then
     (cond (fork (harness-provider-copilot--fork entry id config key note))
           ((null id) (harness-provider-copilot--create entry config key))
           (t (harness-provider-copilot--open entry id config key note)))
     (lambda (sid)
       (cond
        (side
         ;; A throwaway session nobody waits for any more goes at once.
         (unless (funcall live) (harness-provider-copilot--drop-side entry sid)))
        (t
         (setf (harness-provider-copilot-session-main entry) sid)
         (when (funcall live)
           (harness-provider-copilot--emit
            entry (list :type 'provider-state
                        :state (list :copilot-session-id sid :model (plist-get config :model)))))))
       sid))))

(defun harness-provider-copilot--ensure-process (entry request)
  "Make sure ENTRY has a live process for REQUEST; return its ready promise.
The promise is rejected with a readable message when the CLI is not
logged in."
  (let* ((directory (harness-provider-copilot--directory (plist-get request :session)))
         (host (file-remote-p directory))
         (proc (harness-provider-copilot-session-process entry))
         (ready (harness-provider-copilot-session-ready entry)))
    (when (and (process-live-p proc)
               (or (not (equal host (harness-provider-copilot-session-host entry)))
                   (and ready (eq (harness-promise-state ready) 'rejected))))
      (harness-log 'info "provider-copilot: restarting the process of %s" (harness-provider-copilot-session-id entry))
      (harness-provider-copilot--kill entry)
      (setq proc nil))
    (unless (process-live-p proc)
      (harness-provider-copilot--spawn entry directory))
    (harness-then (harness-provider-copilot-session-ready entry)
                  (lambda (auth)
                    (if (harness-json-true-p (plist-get auth :isAuthenticated))
                        auth
                      ;; Logging in later needs a new process to notice.
                      (harness-provider-copilot--kill entry)
                      (harness-rejected (list 'error (harness-provider-copilot--login-message auth))))))))

(defun harness-provider-copilot--send-turn (entry sid prompt)
  "Send PROMPT, (TEXT . ATTACHMENTS), as the turn of Copilot session SID on ENTRY."
  (setf (harness-provider-copilot-session-target entry) sid
        (harness-provider-copilot-session-sent entry) t)
  (push sid (harness-provider-copilot-session-busy entry))
  (let ((gen (harness-provider-copilot-session-generation entry)))
    (harness-provider-copilot--rpc
     entry "session.send"
     (append (list :sessionId sid :prompt (car prompt))
             (when (cdr prompt) (list :attachments (harness-json-array (cdr prompt)))))
     (lambda (_result error)
       (when error
         (setf (harness-provider-copilot-session-busy entry)
               (delete sid (harness-provider-copilot-session-busy entry)))
         (when (and (harness-provider-copilot-session-active entry)
                    (= gen (harness-provider-copilot-session-generation entry)))
           (harness-provider-copilot--finish
            entry (list :type 'done :stop-reason 'error
                        :error (if (stringp error) (harness-provider-copilot--exit-message entry)
                                 (harness-provider-copilot--rpc-message "session.send" error))))))))))

(defun harness-provider-copilot--run (entry request prompt generation &optional retried)
  "Run REQUEST's turn with PROMPT on ENTRY, as turn GENERATION.
Every step is asynchronous: start the process if needed, open the
conversation, wait until it is idle, send.  A turn whose process is
stopped on the way starts again once in a new one (RETRIED)."
  (let* ((live (lambda ()
                 (and (harness-provider-copilot-session-active entry)
                      (= generation (harness-provider-copilot-session-generation entry))
                      (not (harness-provider-copilot-session-cancelled entry)))))
         (fail (lambda (err)
                 (when (funcall live)
                   (if (and (harness-provider-copilot--restart-p err) (not retried))
                       (progn
                         (harness-log 'info "provider-copilot: the process of %s was stopped; starting the turn again"
                                      (harness-provider-copilot-session-id entry))
                         (harness-provider-copilot--run entry request prompt generation t))
                     (harness-provider-copilot--finish
                      entry (list :type 'done :stop-reason 'error
                                  :error (if (harness-provider-copilot--restart-p err)
                                             "the copilot process was stopped twice"
                                           (harness-error-message err))))))
                 nil)))
    (condition-case err
        (let* ((step (lambda (fn) (lambda (value) (if (funcall live) (funcall fn value) 'stopped))))
               (opened (harness-then (harness-provider-copilot--ensure-process entry request)
                                     (funcall step (lambda (_) (harness-provider-copilot--open-target
                                                                entry request live)))))
               (idle (harness-then opened (funcall step (lambda (sid) (harness-provider-copilot--when-idle entry sid)))))
               (sent (harness-then idle (funcall step (lambda (sid) (harness-provider-copilot--send-turn entry sid prompt))))))
          (harness-catch sent fail))
      (error (funcall fail err)))))

(defun harness-provider-copilot--abort (entry sid)
  "Ask ENTRY's CLI to stop the turn of Copilot session SID.
When it is not idle `harness-provider-copilot-interrupt-timeout' later,
the process is killed."
  (when (and (member sid (harness-provider-copilot-session-busy entry))
             (not (assoc sid (harness-provider-copilot-session-aborts entry))))
    (harness-provider-copilot--rpc entry "session.abort" (list :sessionId sid) #'ignore)
    (let ((proc (harness-provider-copilot-session-process entry)))
      (push (cons sid (run-at-time harness-provider-copilot-interrupt-timeout nil
                                   #'harness-provider-copilot--force-abort entry proc sid))
            (harness-provider-copilot-session-aborts entry)))))

(defun harness-provider-copilot--force-abort (entry proc sid)
  "Kill ENTRY's process PROC because the abort of SID went unanswered.
The turn being cancelled ends; another one the process was running
ends with an error, and one on its way to it starts again."
  (when (and (eq proc (harness-provider-copilot-session-process entry))
             (member sid (harness-provider-copilot-session-busy entry)))
    (harness-log 'warn "provider-copilot: abort ignored for %s; killing the process"
                 (harness-provider-copilot-session-id entry))
    (harness-provider-copilot--kill entry "copilot ignored an abort and was stopped")))

(defun harness-provider-copilot--cancel (entry generation)
  "Cancel turn GENERATION on ENTRY, killing the process if the CLI ignores it."
  (when (and (harness-provider-copilot-session-active entry)
             (= generation (harness-provider-copilot-session-generation entry))
             (not (harness-provider-copilot-session-cancelled entry)))
    (setf (harness-provider-copilot-session-cancelled entry) t)
    (let ((sid (harness-provider-copilot-session-target entry)))
      (if (and (harness-provider-copilot-session-sent entry)
               (process-live-p (harness-provider-copilot-session-process entry))
               (member sid (harness-provider-copilot-session-busy entry)))
          (harness-provider-copilot--abort entry sid)
        ;; Nothing was sent yet, or nothing runs: the turn ends here.
        (harness-provider-copilot--finish entry '(:type done :stop-reason cancelled))))))

(defun harness-provider-copilot--entry (session-id)
  "Return the process record for SESSION-ID, creating it when needed."
  (or (gethash session-id harness-provider-copilot--sessions)
      (puthash session-id (harness-provider-copilot--make-session :id session-id)
               harness-provider-copilot--sessions)))

(defun harness-provider-copilot--complete (request)
  "Run REQUEST through the GitHub Copilot CLI; return a handle with `:cancel'."
  (let* ((session (plist-get request :session))
         (sid (or (plist-get session :id) "default"))
         (entry (harness-provider-copilot--entry sid))
         (prompt (harness-provider-copilot-prompt request)))
    (when (harness-provider-copilot-session-active entry)
      ;; The new request takes over; the old turn's work stops.
      (let ((old (harness-provider-copilot-session-target entry)))
        (when (and old (harness-provider-copilot-session-sent entry))
          (harness-provider-copilot--abort entry old)))
      (harness-provider-copilot--finish
       entry '(:type done :stop-reason error :error "superseded by a new request")))
    (let ((generation (cl-incf (harness-provider-copilot-session-generation entry))))
      (setf (harness-provider-copilot-session-request entry) request
            (harness-provider-copilot-session-on-event entry) (plist-get request :on-event)
            (harness-provider-copilot-session-active entry) t
            (harness-provider-copilot-session-cancelled entry) nil
            (harness-provider-copilot-session-target entry) nil
            (harness-provider-copilot-session-side entry) nil
            (harness-provider-copilot-session-sent entry) nil
            (harness-provider-copilot-session-streamed entry) nil
            (harness-provider-copilot-session-usage entry) nil
            (harness-provider-copilot-session-error entry) nil)
      (harness-provider-copilot--emit entry '(:type start))
      (if (null prompt)
          (harness-provider-copilot--finish
           entry '(:type done :stop-reason error :error "No user message to send"))
        (condition-case err
            (harness-provider-copilot--run entry request prompt generation)
          (error (harness-provider-copilot--finish
                  entry (list :type 'done :stop-reason 'error :error (harness-error-message err))))))
      (list :cancel (lambda () (harness-provider-copilot--cancel entry generation))))))

(defun harness-provider-copilot--fork-state (_model-id state)
  "Return a promise of provider state for a fork of STATE.
The fork's first turn copies the Copilot session with sessions.fork, so
the child starts from the parent's conversation."
  (let ((id (plist-get state :copilot-session-id)))
    (harness-resolved (and id (list :copilot-session-id id :model (plist-get state :model)
                                    :fork-pending t)))))

;;;; Lifecycle

(defun harness-provider-copilot-close (session-id)
  "Shut down the CLI process serving SESSION-ID, if any."
  (when-let* ((entry (gethash session-id harness-provider-copilot--sessions)))
    (harness-provider-copilot--finish entry '(:type done :stop-reason cancelled))
    (harness-provider-copilot--kill entry)
    (remhash session-id harness-provider-copilot--sessions)
    t))

(defun harness-provider-copilot-close-all ()
  "Shut down every CLI process, the probe included."
  (dolist (id (hash-table-keys harness-provider-copilot--sessions))
    (harness-provider-copilot-close id))
  (when-let* ((probe harness-provider-copilot--probe))
    (harness-provider-copilot--kill probe)
    (setq harness-provider-copilot--probe nil)))

(defun harness-provider-copilot--on-session-gone (session-id &rest _)
  "Close the process for SESSION-ID when its session is deleted or deactivated."
  (harness-provider-copilot-close session-id))

(defun harness-provider-copilot--init ()
  "Subscribe to session lifecycle events."
  (harness-on 'session/deleted #'harness-provider-copilot--on-session-gone)
  (harness-on 'session/deactivated #'harness-provider-copilot--on-session-gone))

(harness-define-provider 'copilot
  :label "GitHub Copilot"
  :doc "Models of a GitHub Copilot plan through the official copilot CLI (subscription friendly)."
  :models #'harness-provider-copilot--models
  :complete #'harness-provider-copilot--complete
  :fork #'harness-provider-copilot--fork-state
  :quota #'harness-provider-copilot--quota
  :capabilities harness-provider-copilot-capabilities)

(harness-define-module 'provider-copilot
  :doc "GitHub Copilot CLI as a hosted-loop completion provider."
  :requires '(provider)
  :init #'harness-provider-copilot--init
  :shutdown #'harness-provider-copilot-close-all)

(provide 'harness-provider-copilot)
;;; harness-provider-copilot.el ends here
