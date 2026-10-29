;;; harness-ui-provider-check-test.el --- Tests for the check page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The command's choice of model, the report buffer filling in from the
;; harness's events, what a PASS, FAIL and SKIP say, the summary's
;; warning that a SKIP is unverified, and the page's own commands.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-ui--sessions)
(defvar harness-ui-session-id)
(defvar harness-ui-setting-target-function)
(defvar harness-ui-map)
(defvar harness-ui-event-functions)
(defvar harness-ui-provider-check--buffer-name)

(declare-function harness-provider-check "harness-ui-provider-check")
(declare-function harness-ui-provider-check-cancel "harness-ui-provider-check")
(declare-function harness-ui-provider-check-embedding-model "harness-ui-provider-check")
(declare-function harness-ui-provider-check-model-suite "harness-ui-provider-check")
(declare-function harness-ui-provider-check-other-model "harness-ui-provider-check")
(declare-function harness-ui-provider-check-provider-suite "harness-ui-provider-check")
(declare-function harness-ui-provider-check-rerun "harness-ui-provider-check")
(declare-function harness-ui-provider-check--shutdown "harness-ui-provider-check")
(declare-function harness-ui--dispatch-ui "harness-ui")

(defvar harness-ui-provider-check-test--calls nil)
(defvar harness-ui-provider-check-test--displayed nil)

(defconst harness-ui-provider-check-test--checks
  '((:id "catalogue" :suite "provider" :name "Registry and model catalogue")
    (:id "completion" :suite "provider" :name "Text completion and event lifecycle")
    (:id "instructions" :suite "model" :name "Instruction following"))
  "The plan the stubbed harness answers with.")

(defmacro harness-ui-provider-check-test-with (&rest body)
  "Load the UI and its check page, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (harness-test-load-module 'acp))
     (let ((harness-acp-token nil)
           (default-directory dir)
           (harness-process nil))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-provider-check)
       (clrhash harness-ui--sessions)
       (when (get-buffer harness-ui-provider-check--buffer-name)
         (kill-buffer harness-ui-provider-check--buffer-name))
       (unwind-protect (progn ,@body)
         (when (get-buffer harness-ui-provider-check--buffer-name)
           (kill-buffer harness-ui-provider-check--buffer-name))
         (clrhash harness-ui--sessions)
         (harness-ui-provider-check--shutdown)))))

(defun harness-ui-provider-check-test-session (id model)
  "Cache session ID whose model is MODEL."
  (puthash id (list :id id :name "Work" :model model :status "idle")
           harness-ui--sessions))

(defmacro harness-ui-provider-check-test-recording (&rest body)
  "Run BODY with `harness-ui-call' recorded and answered.
The check page's `_harness/provider/check-start' is answered with the
plan in `harness-ui-provider-check-test--checks'; a cancel or any
other call is answered with nil.  The recorded calls stay in
`harness-ui-provider-check-test--calls' after BODY, for the test to
read."
  (declare (indent 0))
  `(progn
     (setq harness-ui-provider-check-test--calls nil
           harness-ui-provider-check-test--displayed nil)
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params callback &optional _on-error)
                  (push (list method params) harness-ui-provider-check-test--calls)
                  (when (equal method "_harness/provider/check-start")
                    (funcall callback
                             (list :job (plist-get params :job)
                                   :model (plist-get params :model)
                                   :suite (plist-get params :suite)
                                   :total (length harness-ui-provider-check-test--checks)
                                   :checks harness-ui-provider-check-test--checks)))
                  (when (equal method "_harness/provider/check-cancel")
                    (funcall callback t))
                  nil))
               ((symbol-function 'harness-ui-display-view)
                (lambda (buffer &rest _)
                  (setq harness-ui-provider-check-test--displayed buffer))))
       ,@body)))

(defun harness-ui-provider-check-test-call (method)
  "Return the last recorded call of METHOD."
  (cl-find-if (lambda (call) (equal (car call) method))
              harness-ui-provider-check-test--calls))

(defun harness-ui-provider-check-test-buffer ()
  "Return the check page buffer."
  (get-buffer harness-ui-provider-check--buffer-name))

(defun harness-ui-provider-check-test-text ()
  "Return the page's text."
  (with-current-buffer (harness-ui-provider-check-test-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-provider-check-test-dispatch (event &rest args)
  "Send the page the harness event EVENT with ARGS."
  (harness-ui--dispatch-ui "_harness/event"
                           (list :event event :args (apply #'vector args))
                           nil))

(ert-deftest harness-ui-provider-check-uses-the-current-model ()
  "The command checks the session's model, and opens a page drawn from the plan."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil)
            (harness-ui-provider-check-test--calls nil))
        (harness-ui-provider-check-test-recording
          (harness-provider-check))
        (let ((start (harness-ui-provider-check-test-call
                      "_harness/provider/check-start")))
          (should start)
          (should (equal (plist-get (cadr start) :model) "checkfake:model"))
          (should (equal (plist-get (cadr start) :suite) "all"))
          (should (stringp (plist-get (cadr start) :job))))
        (should (eq harness-ui-provider-check-test--displayed
                    (harness-ui-provider-check-test-buffer)))
        (with-current-buffer (harness-ui-provider-check-test-buffer)
          (should (derived-mode-p 'harness-ui-provider-check-mode))
          (should (equal harness-ui-provider-check--model "checkfake:model"))
          (should (equal harness-ui-provider-check--state 'running))
          (should (= 3 (length harness-ui-provider-check--plan))))
        (let ((text (harness-ui-provider-check-test-text)))
          (should (string-match-p "checkfake:model" text))
          (should (string-match-p "Provider contract" text))
          (should (string-match-p "Model behavior" text))
          (should (string-match-p "Registry and model catalogue" text))
          (should (string-match-p "WAIT" text)))))))

(ert-deftest harness-ui-provider-check-current-model-comes-from-a-setting-target ()
  "A task board's new-task settings name the model to check, not a session."
  (harness-ui-provider-check-test-with
    (with-temp-buffer
      (let ((harness-ui-setting-target-function
             (lambda () (list (list :model "demo:scripted") #'ignore "for new tasks"))))
        (should (equal (harness-ui-provider-check--current-model) "demo:scripted"))))))

(ert-deftest harness-ui-provider-check-prefix-chooses-any-model ()
  "With a prefix argument the command asks the catalogue for a model."
  (harness-ui-provider-check-test-with
    (let ((harness-ui-provider-check-confirm nil))
      (cl-letf (((symbol-function 'harness-ui-choose-model)
                 (lambda (callback) (funcall callback "other:model" "Other")))
                ((symbol-function 'harness-ui-provider-check--ask-and-open)
                 (lambda (model label)
                   (setq harness-ui-provider-check-test--displayed (list model label)))))
        (harness-ui-provider-check-test-recording
          (harness-provider-check 4)))
      (should (equal harness-ui-provider-check-test--displayed
                     '("other:model" "Other"))))))

(ert-deftest harness-ui-provider-check-events-fill-the-page ()
  "Results and the summary arrive as events and what they say is drawn."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (with-current-buffer (harness-ui-provider-check-test-buffer)
        (let ((job harness-ui-provider-check--job))
          (harness-ui-provider-check-test-dispatch
           "provider-check/result" job
           '(:id "catalogue" :suite "provider" :name "Registry and model catalogue"
             :status "pass" :detail "Listed with model id and context window.")
           1 3)
          (harness-ui-provider-check-test-dispatch
           "provider-check/result" job
           '(:id "completion" :suite "provider"
             :name "Text completion and event lifecycle"
             :status "fail" :detail "Turn ended with error (error text suppressed)."
             :advice "Fix reasoning-effort mapping before using this provider.")
           2 3)
          (harness-ui-provider-check-test-dispatch
           "provider-check/result" job
           '(:id "instructions" :suite "model" :name "Instruction following"
             :status "skip" :detail "Model advertises no known thinking level.")
           3 3)
          (harness-ui-provider-check-test-dispatch
           "provider-check/finished" job "checkfake:model"
           (list '(:id "catalogue" :suite "provider"
                   :name "Registry and model catalogue" :status "pass"
                   :detail "Listed with model id and context window.")
                 '(:id "completion" :suite "provider"
                   :name "Text completion and event lifecycle" :status "fail"
                   :detail "Turn ended with error (error text suppressed)."
                   :advice "Fix reasoning-effort mapping before using this provider.")
                 '(:id "instructions" :suite "model"
                   :name "Instruction following" :status "skip"
                   :detail "Model advertises no known thinking level."))
           '(:pass 1 :fail 1 :skip 1 :completed 3 :total 3 :cancelled nil :seconds 1.5))
          (should (eq harness-ui-provider-check--state 'finished))
          (should (= 3 (length harness-ui-provider-check--results)))
          (let ((text (harness-ui-provider-check-test-text)))
            (should (string-match-p "PASS  Registry and model catalogue" text))
            (should (string-match-p "FAIL  Text completion and event lifecycle" text))
            (should (string-match-p "SKIP  Instruction following" text))
            (should (string-match-p "Guidance: Fix reasoning-effort" text))
            (should (string-match-p "1 passed · 1 failed · 1 skipped" text))
            (should (string-match-p "Skipped checks are unverified" text))
            (should-not (string-match-p "WAIT" text))))))))

(ert-deftest harness-ui-provider-check-closing-the-page-cancels-the-job ()
  "Nothing would show a killed page's results, so its job is told to stop."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (let ((sent nil)
            (buffer (harness-ui-provider-check-test-buffer))
            (job nil))
        (setq job (buffer-local-value 'harness-ui-provider-check--job buffer))
        (cl-letf (((symbol-function 'harness-ui-notify)
                   (lambda (method params) (push (list method params) sent))))
          (kill-buffer buffer))
        (should (equal (caar sent) "_harness/provider/check-cancel"))
        (should (equal (plist-get (cadar sent) :job) job))
        (should-not (get-buffer harness-ui-provider-check--buffer-name))))))

(ert-deftest harness-ui-provider-check-ignores-another-jobs-events ()
  "An old job's events do not touch a report that now follows another job."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (with-current-buffer (harness-ui-provider-check-test-buffer)
        (harness-ui-provider-check-test-dispatch
         "provider-check/result" "some-old-job"
         '(:id "catalogue" :suite "provider" :name "Registry and model catalogue"
           :status "fail" :detail "Old failure")
         1 3)
        (should-not harness-ui-provider-check--results)))))

(ert-deftest harness-ui-provider-check-cancel-sends-the-job ()
  "Cancelling from the page asks the harness to cancel its job."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (let ((job nil))
        (with-current-buffer (harness-ui-provider-check-test-buffer)
          (setq job harness-ui-provider-check--job)
          (harness-ui-provider-check-test-recording
            (harness-ui-provider-check-cancel))
          (should (equal (plist-get (cadr (harness-ui-provider-check-test-call
                                           "_harness/provider/check-cancel"))
                                    :job)
                         job)))))))

(ert-deftest harness-ui-provider-check-key-commands-run-the-right-scopes ()
  "g, p and m rerun the page's model with the scope they name."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (with-current-buffer (harness-ui-provider-check-test-buffer)
        (harness-ui-provider-check-test-recording
          (harness-ui-provider-check-rerun)
          (harness-ui-provider-check-provider-suite)
          (harness-ui-provider-check-model-suite))
        (let ((starts (cl-remove-if-not
                       (lambda (call) (equal (car call)
                                             "_harness/provider/check-start"))
                       harness-ui-provider-check-test--calls)))
          (should (= 3 (length starts)))
          (should (equal (mapcar (lambda (call) (plist-get (cadr call) :suite))
                                 starts)
                         '("model" "provider" "all"))))))))

(ert-deftest harness-ui-provider-check-other-model-and-embeddings ()
  "M chooses a model; E gives an embedding model to the provider suite."
  (harness-ui-provider-check-test-with
    (harness-ui-provider-check-test-session "s1" "checkfake:model")
    (with-temp-buffer
      (setq-local harness-ui-session-id "s1")
      (let ((harness-ui-provider-check-confirm nil))
        (harness-ui-provider-check-test-recording (harness-provider-check)))
      (with-current-buffer (harness-ui-provider-check-test-buffer)
        (cl-letf (((symbol-function 'harness-ui-choose-model)
                   (lambda (callback) (funcall callback "other:model" "Other")))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) "checkfake:embed")))
          (harness-ui-provider-check-test-recording
            (harness-ui-provider-check-embedding-model)
            (harness-ui-provider-check-other-model))
          (let ((starts (cl-remove-if-not
                         (lambda (call) (equal (car call)
                                               "_harness/provider/check-start"))
                         harness-ui-provider-check-test--calls)))
            (should (= 2 (length starts)))
            ;; Newest first: the other model, then the embedding run.
            (should (equal (plist-get (cadr (car starts)) :model)
                           "other:model"))
            (should (equal (plist-get (cadr (car starts)) :suite)
                           "all"))
            (should (equal (plist-get (cadr (car (last starts))) :model)
                           "checkfake:model"))
            (should (equal (plist-get (cadr (car (last starts))) :suite)
                           "provider"))
            (should (equal (plist-get (cadr (car (last starts))) :embedding-model)
                           "checkfake:embed"))))))))

(ert-deftest harness-ui-provider-check-page-keys-and-menu ()
  "The mode binds every command its menu group names."
  (harness-ui-provider-check-test-with
    (dolist (entry '(("g" . harness-ui-provider-check-rerun)
                     ("p" . harness-ui-provider-check-provider-suite)
                     ("m" . harness-ui-provider-check-model-suite)
                     ("M" . harness-ui-provider-check-other-model)
                     ("E" . harness-ui-provider-check-embedding-model)
                     ("c" . harness-ui-provider-check-cancel)))
      (should (eq (lookup-key harness-ui-provider-check-mode-map
                              (kbd (car entry)))
                  (cdr entry))))
    (let ((group (get 'harness-ui-provider-check-mode 'harness-menu-group)))
      (should group)
      (dolist (column (cddr group))
        (dolist (item (append column nil))
          (when (and (consp item) (stringp (car item)))
            (let* ((key (car item))
                   (events (kbd key)))
              ;; A buffer command is behind `.': one plain key.
              (should (equal "." (key-description (substring events 0 1))))
              (should (= 2 (length events)))
              (should-not (harness-ui--menu-key-taken-p key))
              (should (eq (nth 2 item)
                          (lookup-key harness-ui-provider-check-mode-map
                                      (substring events 1)))))))))
    (should (memq #'harness-ui-provider-check--on-event
                  harness-ui-event-functions))))

(provide 'harness-ui-provider-check-test)
;;; harness-ui-provider-check-test.el ends here
