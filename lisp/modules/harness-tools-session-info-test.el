;;; harness-tools-session-info-test.el --- Tests for the session_info tool  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-allowed-directories)
(defvar harness-perms-rules)
(defvar harness-perms--session-rules)

;; The sub-agents are there to give the session a child to name; the
;; access modules, to give it the live access the tool reports.
(defmacro harness-tools-session-info-test-with (&rest body)
  "Load the state layer with the demo provider, session_info and spawn_agent, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent perms
                        readonly access tools-session-info tools-agent priority))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-perms--session-rules)
     (let ((harness-provider-demo--delay 0.005)
           (harness-allowed-directories nil)
           (harness-perms-rules nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-session-info-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-session-info-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(defun harness-tools-session-info-test-text (sid)
  "Run session_info in SID and return its content."
  (plist-get (harness-test-await (harness-tools-session-info-test-run sid "session_info" nil)) :content))

(defun harness-tools-session-info-test-dir (prefix)
  "Create a temporary directory named PREFIX and return it normalised."
  (file-name-as-directory (harness-path-normalize (make-temp-file prefix t))))

(ert-deftest harness-tools-session-info-registers-session-info ()
  (harness-tools-session-info-test-with
    (should (eq 'read (plist-get (harness-call 'tools/get "session_info") :kind)))))

(ert-deftest harness-tools-session-info-describes-the-session ()
  (harness-tools-session-info-test-with
    (let* ((sid (harness-tools-session-info-test-session)))
      (harness-call 'session/update sid :name "main work" :silent t)
      (harness-test-await (harness-tools-session-info-test-run sid "spawn_agent" '(:prompt "hi" :name "kid")))
      (let ((text (harness-tools-session-info-test-text sid))
            (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id)))
        (should (string-match-p (concat "Session: " sid) text))
        (should (string-match-p "Name: main work" text))
        (should (string-match-p "Model: demo:scripted" text))
        (should (string-match-p (concat "^Temporary directory: " (regexp-quote (harness-call 'session/tmp-dir sid)) "$")
                                text))
        (should (string-match-p "Permission mode: ask" text))
        (should (string-match-p "^Non-interactive: off$" text))
        (should (string-match-p "Status: idle" text))
        (should (string-match-p "Parent: none" text))
        (should (string-match-p (concat "Children: " cid) text)))
      (harness-call 'session/update sid :non-interactive t :silent t)
      (should (string-match-p "^Non-interactive: on (the user is away"
                              (harness-tools-session-info-test-text sid))))))

(ert-deftest harness-tools-session-info-reports-a-fresh-sessions-defaults ()
  "A fresh session reports the global directories and no restriction of its own."
  (harness-tools-session-info-test-with
    (let* ((global (harness-tools-session-info-test-dir "harness-session-info-global-"))
           (harness-allowed-directories (list global))
           (sid (harness-tools-session-info-test-session))
           (text (harness-tools-session-info-test-text sid)))
      (should (string-match-p
               (concat "^    " (regexp-quote (harness-abbreviate-file-name global))
                       " (allowed for every session)$")
               text))
      (should (string-match-p "^  Network: on$" text))
      (should (string-match-p "^  Writing: on$" text))
      (should (string-match-p "^  Read-only directories:\n    none$" text))
      (should (string-match-p "^  Tools turned off: none$" text))
      (should (string-match-p "^  Linux capabilities (bash and elisp): none$" text))
      (should (string-match-p "^  Standing rules:\n    none (no standing allow or deny rule applies)$" text))
      ;; The working directory, the temporary directory and the tool output
      ;; directory are the fresh session's own, not grants it made.
      (should (string-match-p "^    .* (the working directory)$" text))
      (should (string-match-p "^    .* (this session's own temporary directory)$" text))
      (should-not (string-match-p "granted to this session$" text)))))

(ert-deftest harness-tools-session-info-reports-access-granted-at-runtime ()
  "Directories granted at runtime, and the rest of the live profile, appear."
  (harness-tools-session-info-test-with
    (let* ((sid (harness-tools-session-info-test-session))
           (grant (harness-tools-session-info-test-dir "harness-session-info-grant-"))
           (read-only (harness-tools-session-info-test-dir "harness-session-info-read-"))
           (secret (harness-tools-session-info-test-dir "harness-session-info-secret-")))
      ;; What the user raises and drop_access lowers, alone and in company.
      (harness-call 'session/set-ext sid :access
                    (list :network :false
                          :tools-off '("session_list")
                          :caps '("CAP_SYS_PTRACE")))
      (harness-call 'permission/allow-dir sid grant)
      (harness-call 'access/add-read-dir sid read-only)
      (setq harness-perms-rules
            (list (list :tool "bash" :commands '(("gcloud") ("gsutil")) :behavior 'allow)
                  (list :tool "write_file" :path (concat secret "**") :behavior 'deny)))
      (puthash sid (list (list :tool "session_list" :behavior 'allow))
               harness-perms--session-rules)
      (let ((text (harness-tools-session-info-test-text sid)))
        (should (string-match-p
                 (concat "^    " (regexp-quote (harness-abbreviate-file-name grant))
                         " (granted to this session)$")
                 text))
        (should (string-match-p
                 (concat "^  Read-only directories:\n    "
                         (regexp-quote (harness-abbreviate-file-name read-only))
                         " (may only be read)$")
                 text))
        (should (string-match-p "^  Network: off$" text))
        (should (string-match-p "^  Tools turned off: session_list$" text))
        (should (string-match-p "Linux capabilities (bash and elisp): CAP_SYS_PTRACE" text))
        (should (string-match-p "    this session: allow session_list" text))
        (should (string-match-p "    every session: allow bash (gcloud and gsutil)" text))
        (should (string-match-p "    every session: deny write_file in" text))
        (should (string-match-p "harness-session-info-secret" text)))
      ;; The mode is the live one too, not the one the session started with.
      (harness-call 'session/update sid :permission-mode 'accept-edits :silent t)
      (should (string-match-p "^Permission mode: accept-edits$"
                              (harness-tools-session-info-test-text sid))))))

(ert-deftest harness-tools-session-info-marks-what-the-policy-sets ()
  "A mode or switch the policy sets is reported as effective and marked."
  (harness-tools-session-info-test-with
    (let ((sid (harness-tools-session-info-test-session)))
      (harness-test-with-policy '((harness-permission-mode . yolo)
                                  (harness-non-interactive . t))
        (let ((text (harness-tools-session-info-test-text sid)))
          (should (string-match-p "^Permission mode: yolo (set by policy)$" text))
          (should (string-match-p "^Non-interactive: on .* (set by policy)$" text)))))))

(ert-deftest harness-tools-session-info-reports-a-read-only-session ()
  "A session's own read-only profile is reported, with its writing off."
  (harness-tools-session-info-test-with
    (let ((sid (harness-tools-session-info-test-session)))
      (harness-call 'session/set-ext sid :access '(:read-only t))
      (let ((text (harness-tools-session-info-test-text sid)))
        (should (string-match-p "^  Writing: off (this session is read-only)$" text))))))

(provide 'harness-tools-session-info-test)
;;; harness-tools-session-info-test.el ends here
