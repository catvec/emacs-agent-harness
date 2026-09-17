;;; harness-provider-process.el --- Newline-delimited JSON subprocess transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A transport (not a provider) for providers implemented as an external
;; program that speaks newline-delimited JSON over stdio.  It is the escape
;; hatch that lets a plugin implement a CLI/JSON-RPC provider without touching
;; the core: the plugin owns a transport, writes one JSON request per line and
;; translates the parsed replies/notifications into the provider callbacks of
;; DESIGN.md section 5.2.
;;
;; The child process is started lazily and is restarted by the next `send'
;; after it exits.  Nothing here blocks: the child is a pipe process whose
;; filter and sentinel run on the Emacs event loop, stdout is framed into
;; lines incrementally, and stderr is buffered in a bounded Lisp string (never
;; a visible buffer) so it cannot grow without limit.
;;
;; See DESIGN.md section 5.6.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)

(defcustom harness-provider-process-max-pending 1048576
  "Maximum characters buffered for an incomplete line from a process transport.
When a single stdout line exceeds this before its terminating newline arrives,
the partial line is discarded, the failure is reported through the transport's
`:on-stderr' callback, and framing resynchronises at the next newline."
  :type 'integer
  :group 'harness-providers)

(defcustom harness-provider-process-stderr-tail 8192
  "Maximum characters of recent stderr kept per process transport.
Older stderr is discarded as new output arrives; see
`harness-provider-process-transport-stderr'."
  :type 'integer
  :group 'harness-providers)

(cl-defstruct (harness-provider-process-transport
               (:constructor harness-provider-process-transport--make)
               (:copier nil))
  "A subprocess transport speaking newline-delimited JSON.

NAME is a symbol identifying the transport.  COMMAND and ARGS are the
executable and its argument vector.  CWD is the working directory (nil means
inherit the current one).  ENV is an alist of (VAR . VALUE) merged over the
current environment.  ON-MESSAGE is called with each parsed stdout message
that carries no matching request id; ON-STDERR is called with each chunk of
stderr; ON-EXIT is called with (STATUS DESCRIPTION) when the subprocess exits
on its own, where STATUS is the exit code (or nil when killed by a signal)."
  (name nil)
  (command nil)
  (args nil)
  (cwd nil)
  (env nil)
  (on-message nil)
  (on-stderr nil)
  (on-exit nil)
  (process nil)
  (stderr-process nil)
  (pending "")
  (next-id 0)
  (callbacks (make-hash-table :test #'equal))
  (stderr-tail "")
  (started nil)
  (exited nil)
  (restart-count 0))

(defun harness-provider-process-transport-create (plist)
  "Create a process transport from configuration PLIST.

Recognised keys: `:name' (a symbol), `:command' (string), `:args' (list of
strings), `:cwd' (string or nil), `:env' (alist of (VAR . VALUE) or nil),
`:on-message' (function of one parsed message), `:on-stderr' (function of one
string) and `:on-exit' (function of (status description))."
  (harness-provider-process-transport--make
   :name (harness-plist-or-alist-get :name plist)
   :command (harness-plist-or-alist-get :command plist)
   :args (harness-plist-or-alist-get :args plist)
   :cwd (harness-plist-or-alist-get :cwd plist)
   :env (harness-plist-or-alist-get :env plist)
   :on-message (harness-plist-or-alist-get :on-message plist)
   :on-stderr (harness-plist-or-alist-get :on-stderr plist)
   :on-exit (harness-plist-or-alist-get :on-exit plist)))

(defun harness-provider-process-transport-live-p (transport)
  "Return non-nil when TRANSPORT's subprocess is running."
  (let ((process (harness-provider-process-transport-process transport)))
    (and process (process-live-p process))))

(defun harness-provider-process-transport-start (transport)
  "Start TRANSPORT's subprocess if it is not already running.
Lazy and idempotent; never blocks.  Return non-nil when the process is
running after the call."
  (if (harness-provider-process-transport-live-p transport)
      t
    (when (harness-provider-process-transport-started transport)
      (cl-incf (harness-provider-process-transport-restart-count transport)))
    (setf (harness-provider-process-transport-pending transport) "")
    (setf (harness-provider-process-transport-stderr-tail transport) "")
    (setf (harness-provider-process-transport-exited transport) nil)
    (setf (harness-provider-process-transport-started transport) (float-time))
    (harness-provider-process--spawn transport)
    (harness-provider-process-transport-live-p transport)))

(defun harness-provider-process-transport-send (transport object &optional callback)
  "Send OBJECT (an alist) to TRANSPORT as one JSON line.

The subprocess is started first if needed, so sending after a stop or a crash
restarts it.  When CALLBACK is non-nil it is registered against OBJECT's
`:id'; the parsed reply carrying the same id calls CALLBACK with the parsed
message, or with (:error \"...\") if the transport stops or exits first.
Return the id, or nil when OBJECT has no `:id'."
  (harness-provider-process-transport-start transport)
  (let* ((id (harness-alist-get :id object))
         (process (harness-provider-process-transport-process transport)))
    (when (and callback id)
      (puthash id callback (harness-provider-process-transport-callbacks transport)))
    (if (not (process-live-p process))
        (when (and callback id)
          (remhash id (harness-provider-process-transport-callbacks transport))
          (funcall callback (list :error "transport is not running")))
      (condition-case err
          (process-send-string process (harness-json-write-line object))
        (error
         (when (and callback id)
           (remhash id (harness-provider-process-transport-callbacks transport))
           (funcall callback (list :error (format "send failed: %s"
                                                  (error-message-string err))))))))
    id))

(defun harness-provider-process-transport-request (transport method params callback)
  "Send a JSON-RPC request METHOD with PARAMS and call CALLBACK with the reply.

CALLBACK is called with (ERROR RESULT): ERROR is nil on success, otherwise the
reply's `:error' object (or an error string when the transport failed); RESULT
is the reply's `:result'.  Return the request id."
  (let ((id (harness-provider-process-transport--next-id transport)))
    (harness-provider-process-transport-send
     transport
     (list (cons 'jsonrpc "2.0")
           (cons 'id id)
           (cons 'method method)
           (cons 'params params))
     (lambda (reply)
       (funcall callback
                (harness-alist-get :error reply)
                (harness-alist-get :result reply))))
    id))

(defun harness-provider-process-transport-notify (transport method params)
  "Send a JSON-RPC notification METHOD with PARAMS.  Return nil."
  (harness-provider-process-transport-send
   transport
   (list (cons 'jsonrpc "2.0")
         (cons 'method method)
         (cons 'params params)))
  nil)

(defun harness-provider-process-transport-stop (transport)
  "Stop TRANSPORT's subprocess, failing every pending callback.
Each pending callback is called once with (:error \"transport stopped\").
`:on-exit' is not called; the process is not restarted until the next
`harness-provider-process-transport-start' or
`harness-provider-process-transport-send'."
  (harness-provider-process--fail-pending transport "transport stopped")
  (let ((process (harness-provider-process-transport-process transport))
        (stderr (harness-provider-process-transport-stderr-process transport)))
    (dolist (proc (delq nil (list process stderr)))
      (when (process-live-p proc)
        (set-process-sentinel proc #'ignore)
        (set-process-filter proc #'ignore)
        (delete-process proc))))
  (setf (harness-provider-process-transport-process transport) nil)
  (setf (harness-provider-process-transport-stderr-process transport) nil)
  (setf (harness-provider-process-transport-exited transport) t)
  transport)

(defun harness-provider-process-transport-restart (transport)
  "Stop TRANSPORT and start it again.
Pending callbacks are failed by the stop; the restart count is incremented."
  (harness-provider-process-transport-stop transport)
  (harness-provider-process-transport-start transport))

(defun harness-provider-process-transport-stderr (transport)
  "Return TRANSPORT's most recent stderr text (a bounded tail)."
  (or (harness-provider-process-transport-stderr-tail transport) ""))


;;; Internals

(defun harness-provider-process--next-id (transport)
  "Return the next request id for TRANSPORT."
  (let ((id (1+ (harness-provider-process-transport-next-id transport))))
    (setf (harness-provider-process-transport-next-id transport) id)
    id))

(defun harness-provider-process--env (env)
  "Return a list of \"VAR=VALUE\" strings for a subprocess from alist ENV.
ENV is merged over `process-environment' so the child keeps PATH and friends.
Returns nil when ENV is nil, which makes `make-process' inherit the current
environment unchanged."
  (when env
    (let* ((overlay-names (mapcar (lambda (pair) (format "%s" (car pair))) env))
           (overlay (mapcar (lambda (pair)
                              (format "%s=%s" (car pair) (cdr pair)))
                            env))
           (base (cl-remove-if
                  (lambda (entry)
                    (member (car (split-string entry "=")) overlay-names))
                  process-environment)))
      (append base overlay))))

(defun harness-provider-process--spawn (transport)
  "Create TRANSPORT's subprocess and its stderr pipe.
Returns the main process, or nil on failure (which is reported through
`:on-stderr' and by failing pending callbacks)."
  (let ((name (harness-provider-process-transport-name transport))
        (command (harness-provider-process-transport-command transport))
        (args (harness-provider-process-transport-args transport))
        (cwd (harness-provider-process-transport-cwd transport))
        (env (harness-provider-process-transport-env transport)))
    (condition-case err
        (let* ((stderr-process
                (make-pipe-process
                 :name (format "harness-provider-%s-stderr" name)
                 :coding 'utf-8-unix
                 :noquery t
                 :filter #'harness-provider-process--stderr-filter
                 :sentinel #'harness-provider-process--stderr-sentinel))
               (process
                (make-process
                 :name (format "harness-provider-%s" name)
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :command (cons command args)
                 :cwd cwd
                 :env (harness-provider-process--env env)
                 :stderr stderr-process
                 :filter #'harness-provider-process--stdout-filter
                 :sentinel #'harness-provider-process--sentinel)))
          (process-put process 'harness-provider-process-transport transport)
          (process-put stderr-process 'harness-provider-process-transport transport)
          (setf (harness-provider-process-transport-process transport) process)
          (setf (harness-provider-process-transport-stderr-process transport)
                stderr-process)
          process)
      (error
       (harness--log "could not start provider process %s: %s"
                     name (error-message-string err))
       (harness-provider-process--report-stderr
        transport (format "could not start process: %s" (error-message-string err)))
       (harness-provider-process--fail-pending
        transport (format "could not start process: %s" (error-message-string err)))
       (setf (harness-provider-process-transport-exited transport) t)
       nil))))

(defun harness-provider-process--stdout-filter (process chunk)
  "Feed stdout CHUNK from PROCESS into its transport's line framer.
Errors are logged, never signalled, because a process filter runs on the
event loop."
  (condition-case err
      (let ((transport (process-get process 'harness-provider-process-transport)))
        (when transport
          (harness-provider-process--feed transport chunk)))
    (error (harness--log "process transport stdout filter error: %s"
                         (error-message-string err)))))

(defun harness-provider-process--stderr-filter (process chunk)
  "Append stderr CHUNK from PROCESS to its transport's bounded tail."
  (condition-case err
      (let ((transport (process-get process 'harness-provider-process-transport)))
        (when transport
          (harness-provider-process--append-stderr transport chunk)))
    (error (harness--log "process transport stderr filter error: %s"
                         (error-message-string err)))))

(defun harness-provider-process--sentinel (process event)
  "Handle the exit of PROCESS, the subprocess of a transport."
  (condition-case err
      (let ((transport (process-get process 'harness-provider-process-transport)))
        (when (and transport
                   (eq process (harness-provider-process-transport-process transport)))
          (harness-provider-process--handle-exit transport process event)))
    (error (harness--log "process transport sentinel error: %s"
                         (error-message-string err)))))

(defun harness-provider-process--stderr-sentinel (process _event)
  "Forget PROCESS when the stderr pipe closes.
The pipe reaching EOF is expected when the child exits; nothing else to do."
  (condition-case err
      (let ((transport (process-get process 'harness-provider-process-transport)))
        (when (and transport
                   (eq process (harness-provider-process-transport-stderr-process
                                transport)))
          (setf (harness-provider-process-transport-stderr-process transport) nil)))
    (error (harness--log "process transport stderr sentinel error: %s"
                         (error-message-string err)))))

(defun harness-provider-process--handle-exit (transport process event)
  "Handle the subprocess PROCESS exiting for TRANSPORT.
Reports `:on-exit' and fails every pending callback so the agent loop never
hangs."
  (setf (harness-provider-process-transport-exited transport) t)
  (let ((status (process-exit-code process))
        (description (string-trim (or event ""))))
    (harness-provider-process--fail-pending
     transport (format "process exited: %s" description))
    (when-let* ((fn (harness-provider-process-transport-on-exit transport)))
      (funcall fn status description))))

(defun harness-provider-process--fail-pending (transport reason)
  "Call every pending callback of TRANSPORT with (:error REASON), then clear."
  (let ((callbacks (harness-provider-process-transport-callbacks transport)))
    (maphash (lambda (_id callback)
               (condition-case err
                   (funcall callback (list :error reason))
                 (error (harness--log "process transport callback error: %s"
                                      (error-message-string err)))))
             callbacks)
    (clrhash callbacks)))

(defun harness-provider-process--feed (transport chunk)
  "Append CHUNK to TRANSPORT's line buffer and process complete lines.
Complete lines are parsed as JSON and dispatched; the trailing incomplete
line is kept in the `pending' slot and reassembled across calls."
  (let* ((pending (concat (harness-provider-process-transport-pending transport)
                          chunk))
         (lines (split-string pending "\n"))
         (remainder (car (last lines))))
    (when (> (length remainder) harness-provider-process-max-pending)
      (harness--log "process transport %s: discarding %d characters of an incomplete line"
                    (harness-provider-process-transport-name transport)
                    (length remainder))
      (harness-provider-process--report-stderr
       transport
       (format "discarded %d characters of an incomplete line (exceeds `harness-provider-process-max-pending')"
               (length remainder)))
      (setq remainder ""))
    (setf (harness-provider-process-transport-pending transport) remainder)
    (dolist (line (butlast lines))
      (harness-provider-process--handle-line transport line))))

(defun harness-provider-process--handle-line (transport line)
  "Parse one complete stdout LINE and dispatch it."
  (let ((line (if (string-suffix-p "\r" line)
                  (substring line 0 -1)
                line)))
    (unless (string-empty-p (string-trim line))
      (let ((message (condition-case err
                         (harness-json-read line)
                       (error
                        (harness-provider-process--report-stderr
                         transport
                         (format "unparseable JSON line: %s" (error-message-string err)))
                        nil))))
        (when message
          (harness-provider-process--dispatch transport message))))))

(defun harness-provider-process--dispatch (transport message)
  "Route a parsed stdout MESSAGE to its callback or `:on-message'."
  (let* ((id (harness-alist-get :id message))
         (callbacks (harness-provider-process-transport-callbacks transport))
         (callback (and id (gethash id callbacks))))
    (if callback
        (progn
          (remhash id callbacks)
          (condition-case err
              (funcall callback message)
            (error (harness--log "process transport callback error: %s"
                                 (error-message-string err)))))
      (when-let* ((fn (harness-provider-process-transport-on-message transport)))
        (funcall fn message)))))

(defun harness-provider-process--append-stderr (transport chunk)
  "Append CHUNK to TRANSPORT's bounded stderr tail and call `:on-stderr'."
  (let* ((tail (or (harness-provider-process-transport-stderr-tail transport) ""))
         (combined (concat tail chunk))
         (max harness-provider-process-stderr-tail))
    (setf (harness-provider-process-transport-stderr-tail transport)
          (if (> (length combined) max)
              (substring combined (- (length combined) max))
            combined))
    (when-let* ((fn (harness-provider-process-transport-on-stderr transport)))
      (funcall fn chunk))))

(defun harness-provider-process--report-stderr (transport text)
  "Report TEXT through TRANSPORT's `:on-stderr' callback and tail."
  (harness-provider-process--append-stderr transport text))

(provide 'harness-provider-process)
;;; harness-provider-process.el ends here
