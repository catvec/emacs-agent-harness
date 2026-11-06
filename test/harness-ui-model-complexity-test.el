;;; harness-ui-model-complexity-test.el --- Tests for the model complexity guide  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp-token)
(defvar harness-ui-map)
(defvar harness-ui-model-picker-functions)
(defvar harness-ui-model-complexity--rows)
(defvar harness-ui-model-complexity--state)
(defvar harness-ui-model-complexity--buffer-name)

(defconst harness-ui-model-complexity-test--rows
  '((:id "claude:haiku" :label "Claude Haiku" :provider-label "Claude Code"
	 :complexity-label "Simple tasks" :complexity-description "Small, well-specified edits."
	 :complexity-basis "Default guide (estimate)")
    (:id "chatgpt:gpt-5.6-luna" :label "GPT-5.6 Luna" :provider-label "ChatGPT"
	 :complexity-label "Routine tasks" :complexity-description "Everyday changes and tests."
	 :complexity-basis "Default guide (estimate)")
    (:id "chatgpt:gpt-6-sol" :label "GPT-6 Sol" :provider-label "ChatGPT"
	 :complexity-label "Complex tasks" :complexity-description "Multi-file debugging."
	 :complexity-basis "User rule (estimate)")
    (:id "chatgpt:gpt-6-astra" :label "GPT-6 Astra" :provider-label "ChatGPT"
	 :complexity-label "Very complex tasks" :complexity-description "Large, ambiguous problems."
	 :complexity-basis "Default guide (estimate)")
    (:id "local:unknown" :label "Unknown model" :provider-label "Local"
	 :complexity-label "Unrated" :complexity-description "No matching rule."
	 :complexity-basis "No matching rule"))
  "Example wire-format rows, including user guidance and an unrated model.")

(defmacro harness-ui-model-complexity-test-with (&rest body)
  "Load the UI and optional plugin in isolation, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-acp--server-enabled nil)
          (harness-acp-token nil))
      (harness-test-load-module 'acp)
      (harness-test-load-module 'ui)
      (let ((harness-ui-model-picker-functions nil)
            (harness-ui-map (copy-keymap harness-ui-map)))
        (harness-test-load-module 'ui-model-complexity)
        (unwind-protect (progn ,@body)
          (harness-ui-model-complexity--shutdown))))))

(ert-deftest harness-ui-model-complexity-guide-shows-levels-real-names-and-ids ()
  (harness-ui-model-complexity-test-with
   (with-temp-buffer
     (harness-ui-model-complexity-mode)
     (setq harness-ui-model-complexity--rows harness-ui-model-complexity-test--rows
           harness-ui-model-complexity--state 'ready)
     (harness-ui-model-complexity--render)
     (let ((text (buffer-string)))
       (dolist (model harness-ui-model-complexity-test--rows)
         (should (string-match-p (regexp-quote (plist-get model :label)) text))
         (should (string-match-p (regexp-quote (plist-get model :id)) text)))
       (should (string-match-p "Estimates, not benchmarks" text))
       (should (string-match-p (regexp-quote "[user estimate]") text))
       (should (< (string-match "Simple tasks" text) (string-match "Routine tasks" text)))
       (should (< (string-match "Routine tasks" text) (string-match "Complex tasks" text)))
       (should (< (string-match "Complex tasks" text) (string-match "Very complex tasks" text)))
       (should (< (string-match "Very complex tasks" text) (string-match "Unrated" text))))
     (should-not truncate-lines)
     (should buffer-read-only))))

(ert-deftest harness-ui-model-complexity-guide-loading-empty-and-error-states ()
  (harness-ui-model-complexity-test-with
   (with-temp-buffer
     (harness-ui-model-complexity-mode)
     (harness-ui-model-complexity--render)
     (should (string-match-p "Loading" (buffer-string)))
     (setq harness-ui-model-complexity--state 'ready)
     (harness-ui-model-complexity--render)
     (should (string-match-p "Configure a provider or sign in" (buffer-string)))
     (setq harness-ui-model-complexity--state 'error)
     (harness-ui-model-complexity--render)
     (should (string-match-p "enable model-complexity" (buffer-string)))
     (should (string-match-p "normal model picker is still available" (buffer-string))))))

(ert-deftest harness-ui-model-complexity-refresh-ignores-superseded-answers ()
  (harness-ui-model-complexity-test-with
   (let (requests)
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params ok err) (push (list method params ok err) requests))))
       (with-temp-buffer
         (harness-ui-model-complexity-mode)
         (harness-ui-model-complexity--load (current-buffer))
         (harness-ui-model-complexity-refresh)
         (should (equal (caar requests) "_harness/model-complexity/list"))
         (should (equal (cadar requests) '(:refresh t)))
         (funcall (nth 2 (car requests)) harness-ui-model-complexity-test--rows)
         (funcall (nth 3 (cadr requests)) "old failure")
         (funcall (nth 2 (cadr requests)) nil)
         (should (eq harness-ui-model-complexity--state 'ready))
         (should (equal harness-ui-model-complexity--rows harness-ui-model-complexity-test--rows)))
       ;; An answer delivered after the buffer was killed must be harmless.
       (funcall (nth 2 (car requests)) nil)
       (funcall (nth 3 (car requests)) "late failure")))))

(ert-deftest harness-ui-model-complexity-picker-preserves-order-and-real-model-id ()
  (harness-ui-model-complexity-test-with
   (let (picked)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt table &rest _)
                  (should (string-match-p "estimated work complexity" prompt))
                  (let* ((all (all-completions "" table))
                         (meta (completion-metadata "" table nil)))
                    (should (eq (completion-metadata-get meta 'display-sort-function) 'identity))
                    (should (eq (completion-metadata-get meta 'cycle-sort-function) 'identity))
                    (should (string-prefix-p "Simple tasks" (nth 0 all)))
                    (should (string-prefix-p "Routine tasks" (nth 1 all)))
                    (should (string-prefix-p "Unrated" (car (last all))))
                    (nth 1 all)))))
       (harness-ui-model-complexity--read
        harness-ui-model-complexity-test--rows
        (lambda (id label) (setq picked (list id label))))
       (should (equal picked '("chatgpt:gpt-5.6-luna" "GPT-5.6 Luna (ChatGPT)")))))))

(ert-deftest harness-ui-model-complexity-picker-disambiguates-equal-names ()
  (harness-ui-model-complexity-test-with
   (let* ((one (copy-sequence (car harness-ui-model-complexity-test--rows)))
          (two (plist-put (copy-sequence one) :id "claude:other-haiku"))
          picked)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (let ((all (all-completions "" table)))
                    (should (= (length all) 2))
                    (should-not (equal (car all) (cadr all)))
                    (cadr all)))))
       (harness-ui-model-complexity--read (list one two) (lambda (id _label) (setq picked id))))
     (should (equal picked "claude:other-haiku")))))

(ert-deftest harness-ui-model-complexity-picker-empty-and-quit-do-not-select ()
  (harness-ui-model-complexity-test-with
   (let (picked)
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
       (harness-ui-model-complexity--read harness-ui-model-complexity-test--rows
                                          (lambda (&rest _) (setq picked t))))
     (should-not picked)
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
       (should (eq (condition-case nil
                       (harness-ui-model-complexity--read
                        harness-ui-model-complexity-test--rows (lambda (&rest _) (setq picked t)))
                     (quit 'cancelled))
                   'cancelled)))
     (should-not picked))))

(ert-deftest harness-ui-model-complexity-hook-is-optional-idempotent-and-removable ()
  (harness-ui-model-complexity-test-with
   (harness-ui-model-complexity--init)
   (should (= 1 (cl-count #'harness-ui-model-complexity--pick harness-ui-model-picker-functions)))
   (should (eq (lookup-key harness-ui-map (kbd "=")) #'harness-model-complexity))
   (let (default-picker)
     (cl-letf (((symbol-function 'harness-ui--choose-model) (lambda (_) (setq default-picker t))))
       (harness-ui-model-complexity--shutdown)
       (harness-ui-choose-model #'ignore))
     (should default-picker))
   (should-not (lookup-key harness-ui-map (kbd "=")))
   (define-key harness-ui-map (kbd "=") #'ignore)
   (harness-ui-model-complexity--init)
   (harness-ui-model-complexity--shutdown)
   (should (eq (lookup-key harness-ui-map (kbd "=")) #'ignore))))

(ert-deftest harness-ui-model-complexity-hook-fetches-rankings-and-falls-back ()
  (harness-ui-model-complexity-test-with
   (let (sent picked fallback)
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params ok _err)
                  (setq sent (list method params))
                  (funcall ok harness-ui-model-complexity-test--rows)))
               ((symbol-function 'completing-read)
                (lambda (_prompt table &rest _) (car (all-completions "" table)))))
       (harness-ui-choose-model (lambda (id _label) (setq picked id))))
     (should (equal sent '("_harness/model-complexity/list" (:refresh t))))
     (should (equal picked "claude:haiku"))
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (_method _params _ok err) (funcall err "No such method")))
               ((symbol-function 'harness-ui--choose-model)
                (lambda (callback) (setq fallback callback))))
       (harness-ui-choose-model #'ignore))
     (should (eq fallback #'ignore)))))

(ert-deftest harness-ui-model-complexity-picker-keeps-the-originating-frame ()
  (harness-ui-model-complexity-test-with
   (let ((origin (selected-frame)) pending seen read)
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (_method _params ok _err) (setq pending ok)))
               ((symbol-function 'harness-ui--in-frame)
                (lambda (frame fn) (setq seen frame) (funcall fn)))
               ((symbol-function 'harness-ui-model-complexity--read)
                (lambda (&rest _) (setq read t))))
       (harness-ui-choose-model #'ignore)
       (should-not read)
       (funcall pending harness-ui-model-complexity-test--rows)
       (should (eq origin seen))
       (should read)
       (setq seen nil read nil)
       ;; An answer for a closed frame must not prompt on another one.
       (cl-letf (((symbol-function 'frame-live-p) (lambda (_) nil)))
         (funcall pending harness-ui-model-complexity-test--rows))
       (should-not seen)
       (should-not read)))))

(ert-deftest harness-ui-model-complexity-opening-and-copying-never-changes-a-model ()
  (harness-ui-model-complexity-test-with
   (let ((kill-ring nil)
         (name "*test model guide*")
         (harness-ui-model-complexity--buffer-name "*test model guide*"))
     (unwind-protect
         (cl-letf (((symbol-function 'harness-ui-display-view) #'ignore)
                   ((symbol-function 'harness-ui-call)
                    (lambda (method _params ok &optional _err)
                      (should (equal method "_harness/model-complexity/list"))
                      (funcall ok harness-ui-model-complexity-test--rows))))
           (harness-model-complexity)
           (with-current-buffer name
             (goto-char (point-min))
             (should-error (harness-ui-model-complexity-copy-id) :type 'user-error)
             (search-forward "GPT-5.6 Luna")
             (harness-ui-model-complexity-copy-id)
             (should (equal (car kill-ring) "chatgpt:gpt-5.6-luna"))))
       (when (get-buffer name) (kill-buffer name))))))

(ert-deftest harness-ui-model-complexity-enable-selects-both-optional-halves ()
  (let ((harness-enabled-modules '(model-complexity))
        (harness-disabled-modules nil))
    (let ((selected (harness--selected-modules (harness--module-sources))))
      (dolist (name '(model-complexity ui-model-complexity provider ui))
        (should (memq name selected)))))
  (let ((harness-enabled-modules nil)
        (harness-disabled-modules nil))
    (let ((selected (harness--selected-modules (harness--module-sources))))
      (should-not (memq 'model-complexity selected))
      (should-not (memq 'ui-model-complexity selected)))))

(ert-deftest harness-ui-model-complexity-rankings-round-trip-over-acp ()
  "The real backend answer crosses ACP and renders, without inference calls."
  (harness-test-with-temp-state
   (harness-test-reset-bus)
   (let ((harness-acp--server-enabled nil)
         (harness-acp-token nil)
         (harness-ui-model-picker-functions nil))
     (dolist (module '(store project config session provider model-complexity acp ui ui-model-complexity))
       (harness-test-load-module module))
     (let ((harness-ui-model-complexity--buffer-name "*test model complexity ACP*"))
       (unwind-protect
           (progn
             (harness-define-provider
              'test :label "Test catalogue"
              :models (lambda () '((:name "gpt-6-sol" :context-window 1000)
                                   (:name "unrecognized" :context-window 1000)
                                   (:name "claude-haiku-4-5" :context-window 1000)))
              :complete (lambda (&rest _) (ert-fail "The guide must not call a model")))
             (save-window-excursion
               (harness-model-complexity)
               (harness-test-wait
		(lambda () (with-current-buffer "*test model complexity ACP*"
                             (eq harness-ui-model-complexity--state 'ready)))
		5 "model complexity ACP answer")
               (with-current-buffer "*test model complexity ACP*"
                 (should (string-match-p "Simple tasks" (buffer-string)))
                 (should (string-match-p "Complex tasks" (buffer-string)))
                 (should (string-match-p "Unrated" (buffer-string)))
                 (should (equal '("test:claude-haiku-4-5" "test:gpt-6-sol" "test:unrecognized")
				(mapcar (lambda (m) (plist-get m :id)) harness-ui-model-complexity--rows))))))
         (harness-ui-model-complexity--shutdown)
         (when (get-buffer "*test model complexity ACP*") (kill-buffer "*test model complexity ACP*")))))))

(provide 'harness-ui-model-complexity-test)
;;; harness-ui-model-complexity-test.el ends here
