;;; harness-codex-quota.el --- Read optional Codex CLI plan usage  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Sign in with ChatGPT (SIWC) access tokens cannot read numerical plan
;; usage: /v1/responses sends no quota headers for these tokens and the
;; Codex usage endpoint does not accept them.  A person may separately
;; sign in with `codex login'.  Its app-server can read its own rate limits
;; without handing the harness a second token or spending inference quota.
;; This module starts a short-lived app-server only after opt-in, checks
;; its ChatGPT account against the SIWC account, and returns an indicative
;; Codex usage snapshot.  It never reads auth.json or logs protocol output.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

(defcustom harness-codex-quota-program "codex"
  "Codex CLI executable used for optional, read-only plan quota queries.
The CLI must have been signed in with `codex login' to the same ChatGPT
account as the harness.  The harness does not read Codex's credentials."
  :type 'string :group 'harness)

(defconst harness-codex-quota--timeout 20
  "Seconds allowed for a short-lived Codex app-server quota read.")

(cl-defstruct (harness-codex-quota--read (:copier nil))
  "State of one read-only app-server conversation."
  process stderr timer promise (pending "") (done nil) email)

(defun harness-codex-quota--finish (read result)
  "Finish READ with sanitized RESULT; close the process and buffers."
  (unless (harness-codex-quota--read-done read)
    (setf (harness-codex-quota--read-done read) t)
    (when-let* ((timer (harness-codex-quota--read-timer read)))
      (cancel-timer timer))
    (when-let* ((proc (harness-codex-quota--read-process read)))
      (when (process-live-p proc) (delete-process proc)))
    (when-let* ((stderr (harness-codex-quota--read-stderr read)))
      (when (buffer-live-p stderr) (kill-buffer stderr)))
    (harness-resolve (harness-codex-quota--read-promise read) result)))

(defun harness-codex-quota--send (read id method &optional params)
  "Send METHOD with ID and optional PARAMS to READ's app-server."
  (process-send-string
   (harness-codex-quota--read-process read)
   (concat (harness-json-encode
            (append (list :id id :method method) (when params (list :params params))))
           "\n")))

(defun harness-codex-quota--quota (response)
  "Return the display-only plan quota in Codex's rate limits RESPONSE.
These are the Codex CLI's limits, not authoritative limits for SIWC.
The backend's multi-bucket view names `codex' separately; prefer it
where present rather than showing another model's allowance."
  (let* ((buckets (plist-get response :rateLimitsByLimitId))
         (single (plist-get response :rateLimits))
         ;; If the server supplies named buckets, an absent Codex bucket
         ;; cannot be replaced by another model's backward-compatible view.
         (limits (if (and (listp buckets) buckets)
                     (plist-get buckets :codex)
                   (when (member (plist-get single :limitId) '(nil :null "codex"))
                     single)))
         (windows (delq nil (mapcar
                             (lambda (kind)
                               (let* ((window (plist-get limits kind))
                                      (used (plist-get window :usedPercent))
                                      (minutes (plist-get window :windowDurationMins))
                                      (named (harness-provider-quota-window-name minutes))
                                      (reset (harness-provider-quota-time (plist-get window :resetsAt))))
                                 (when (and (numberp used) named)
                                   (append (list :name (car named) :label (cadr named)
                                                 :used (harness-provider-plan-percent used)
                                                 :minutes minutes)
                                           (when reset (list :resets reset))))))
                             '(:primary :secondary))))
         (plan (plist-get limits :planType)))
    (when windows
      (append (list :windows windows :updated (float-time) :source "codex-cli"
                    :informational t :available t :limit-status nil)
              (when (stringp plan)
                (list :plan plan :plan-label (harness-provider-plan-label plan)))))))

(defun harness-codex-quota--reply (read reply)
  "Handle a protocol REPLY to READ, never exposing raw output or errors."
  (let ((id (plist-get reply :id))
        (result (plist-get reply :result)))
    (when (plist-get reply :error)
      (harness-codex-quota--finish read '(:status error)))
    (unless (harness-codex-quota--read-done read)
      (pcase id
        (1 (if result
               (progn
                 (process-send-string (harness-codex-quota--read-process read)
                                      "{\"method\":\"initialized\"}\n")
                 (harness-codex-quota--send read 2 "account/read"
                                            '(:refreshToken :false)))
             (harness-codex-quota--finish read '(:status error))))
        (2 (let* ((account (plist-get result :account))
                  (email (plist-get account :email)))
             (if (and (equal (plist-get account :type) "chatgpt")
                      (stringp email) (not (string-empty-p email)))
                 (progn
                   (setf (harness-codex-quota--read-email read) email)
                   (harness-codex-quota--send read 3 "account/rateLimits/read"
                                              '(:excludeResetCreditDetails t)))
               (harness-codex-quota--finish read '(:status no-account)))))
        (3 (if-let* ((quota (harness-codex-quota--quota result)))
               (harness-codex-quota--finish
                read (list :status 'ok :email (harness-codex-quota--read-email read)
                           :quota quota))
             (harness-codex-quota--finish read '(:status no-quota))))
        (_ nil)))))

(defun harness-codex-quota--filter (read _process text)
  "Process the newline-delimited app-server TEXT for READ."
  (unless (harness-codex-quota--read-done read)
    (let ((pending (concat (harness-codex-quota--read-pending read) text)))
      ;; Do not retain arbitrarily large output from a malformed process.
      (if (> (length pending) 131072)
          (harness-codex-quota--finish read '(:status error))
        (while (and (not (harness-codex-quota--read-done read))
                    (string-match "\n" pending))
          (let ((line (substring pending 0 (match-beginning 0))))
            (setq pending (substring pending (match-end 0)))
            (condition-case nil
                (let ((reply (harness-json-parse line)))
                  (when (and (listp reply) (plist-member reply :id))
                    (harness-codex-quota--reply read reply)))
              (error (harness-codex-quota--finish read '(:status error))))))
        (setf (harness-codex-quota--read-pending read) pending)))))

(defun harness-codex-quota-read ()
  "Return a promise of a sanitized Codex CLI plan quota or a status.
It is (:status ok :email EMAIL :quota QUOTA), or (:status no-account,
no-quota, error, missing, timeout).  No credentials cross this API.
The caller decides whether the CLI account matches its SIWC account."
  (let* ((promise (harness-make-promise))
         (read (make-harness-codex-quota--read :promise promise))
         (stderr (generate-new-buffer " *harness-codex-quota-stderr*" t)))
    (setf (harness-codex-quota--read-stderr read) stderr)
    (condition-case nil
        (let ((proc (make-process
                     :name "harness-codex-quota" :command (list harness-codex-quota-program
                                                                  "app-server" "--stdio")
                     :coding 'utf-8-unix :connection-type 'pipe :noquery t
                     :stderr stderr
                     :filter (lambda (proc text) (harness-codex-quota--filter read proc text))
                     :sentinel (lambda (proc _event)
                                 (unless (process-live-p proc)
                                   (harness-codex-quota--finish read '(:status error)))))))
          (when-let* ((ep (get-buffer-process stderr)))
            (set-process-query-on-exit-flag ep nil)
            (set-process-sentinel ep #'ignore))
          (unless (harness-codex-quota--read-done read)
            (setf (harness-codex-quota--read-process read) proc
                  (harness-codex-quota--read-timer read)
                  (run-at-time harness-codex-quota--timeout nil
                               (lambda () (harness-codex-quota--finish read '(:status timeout)))))
            (harness-codex-quota--send
             read 1 "initialize"
             '(:clientInfo (:name "emacs-agent-harness" :title "Emacs agent harness"
                            :version "1.0")))))
      (error (harness-codex-quota--finish read '(:status missing))))
    promise))

(provide 'harness-codex-quota)
;;; harness-codex-quota.el ends here
