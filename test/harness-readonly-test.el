;;; harness-readonly-test.el --- Tests for read-only sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A test registers a policy of its own, `harness-readonly-test--policy',
;; which governs the sessions whose `:ext' carries `:readonly-test': the
;; readonly module then holds them to the reading and web tools, the
;; policy's own and, where the sandbox confines it, read-only bash.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-tools)
(defvar harness-readonly--policies)
(defvar harness-readonly-read-tools)
(declare-function harness-readonly--gate "harness-readonly")
(declare-function harness-readonly--init "harness-readonly")
(declare-function harness-readonly-register "harness-readonly")
(declare-function harness-readonly-unregister "harness-readonly")
(declare-function harness-readonly-policy "harness-readonly")
(declare-function harness-readonly-session-p "harness-readonly")
(declare-function harness-readonly-budget-point-p "harness-readonly")

(defconst harness-readonly-test-modules
  '(store project config provider provider-demo tools session agent tools-agent tools-question tools-plan tools-todo tools-session-info tools-fs readonly)
  "The modules every test loads.")

(defun harness-readonly-test--policy (session)
  "Govern SESSION when its `:ext' says `:readonly-test', with the policy it names.
The value t is a policy that adds todo_write; any other plist is the policy."
  (let ((value (plist-get (plist-get session :ext) :readonly-test)))
    (cond ((null value) nil)
          ((eq value t) (list :tools '("todo_write") :label "test mode" :doing "only looks"
                              :hint "Say what you would change instead."))
          (t value))))

(defmacro harness-readonly-test-with (&rest body)
  "Load the modules, register the test's policy and run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (dolist (m harness-readonly-test-modules)
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (harness-readonly-register 'test #'harness-readonly-test--policy)
     (unwind-protect (let ((default-directory dir)) ,@body)
       (harness-readonly-unregister 'test))))

(defun harness-readonly-test-session (&optional policy)
  "Create a demo session, read-only under POLICY (t: the test's own) when given."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                    (and policy (list :ext (list :readonly-test policy))))
             :id))

(defun harness-readonly-test-tools (sid)
  "Return the names of the tools session SID is offered."
  (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list sid)))

(defun harness-readonly-test-decide (sid tool &optional kind paths)
  "Return what the permission chain decides for a call of TOOL in session SID."
  (harness-test-await
   (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                             (list :session (harness-call 'session/get sid) :tool tool
                                   :input nil :kind (or kind 'write) :paths paths :call-id "c1"))))

(defun harness-readonly-test-confined (value)
  "Stub `sandbox/confined-p': answer VALUE, or signal when it is `error'."
  (harness-register-method 'sandbox/confined-p
                           (lambda (_cwd) (if (eq value 'error) (error "No sandbox today") value))))

;;;; Policies

(ert-deftest harness-readonly-register-replaces-in-place-and-the-first-policy-decides ()
  "A policy registered again keeps its place; the first that governs a session wins."
  (harness-test-load-module 'readonly)
  (let ((harness-readonly--policies nil))
    (harness-readonly-register 'a (lambda (s) (and (plist-get s :a) '(:label "a"))))
    (harness-readonly-register 'b (lambda (s) (and (plist-get s :b) '(:label "b"))))
    (should (equal '(a b) (mapcar #'car harness-readonly--policies)))
    (should (equal "a" (plist-get (harness-readonly-policy '(:a t :b t)) :label)))
    (should (equal "b" (plist-get (harness-readonly-policy '(:b t)) :label)))
    (should-not (harness-readonly-policy '(:c t)))
    (should-not (harness-readonly-policy nil))
    ;; Again under a name it has: replaced where it stands.
    (harness-readonly-register 'a (lambda (s) (and (plist-get s :a) '(:label "a2"))))
    (should (equal '(a b) (mapcar #'car harness-readonly--policies)))
    (should (equal "a2" (plist-get (harness-readonly-policy '(:a t :b t)) :label)))
    (harness-readonly-unregister 'a)
    (should (equal "b" (plist-get (harness-readonly-policy '(:a t :b t)) :label)))
    ;; A policy that signals: callers that must not fail open take it as read-only.
    (harness-readonly-register 'broken (lambda (_s) (error "Broken")))
    (should-error (harness-readonly-policy '(:c t)))
    (should (harness-readonly-session-p '(:c t)))))

;;;; The tools a read-only session is offered

(ert-deftest harness-readonly-offers-a-governed-session-only-reading-tools ()
  "Reading, the web and the policy's own tools; no writes, and no bash without the sandbox."
  (harness-readonly-test-with
    (let* ((sid (harness-readonly-test-session t))
           (free (harness-readonly-test-session))
           (names (harness-readonly-test-tools sid)))
      (should (member "read_file" names))
      (should (member "grep" names))
      (should (member "todo_write" names))
      (should-not (member "write_file" names))
      (should-not (member "edit_file" names))
      (should-not (member "spawn_agent" names))
      (should-not (member "bash" names))
      ;; Every tool offered is one the policy allows.
      (dolist (name names)
        (should (or (member name harness-readonly-read-tools) (member name '("todo_write" "web_fetch" "web_search")))))
      ;; A policy may leave a reading or web tool out.
      (let ((narrow (harness-readonly-test-session '(:tools ("todo_write") :except ("web_fetch" "grep")))))
        (should-not (member "grep" (harness-readonly-test-tools narrow)))
        (should (member "read_file" (harness-readonly-test-tools narrow)))
        (should (eq 'deny (plist-get (harness-readonly-test-decide narrow "grep" 'read) :behavior))))
      ;; Another session keeps every tool, and so does the catalogue.
      (should (member "write_file" (harness-readonly-test-tools free)))
      (should (member "write_file" (harness-run-filter 'agent/tools '("write_file" "read_file") nil))))))

(ert-deftest harness-readonly-offers-bash-only-where-the-sandbox-confines-it ()
  "Bash is offered when `sandbox/confined-p' says the session's directory is confined."
  (harness-readonly-test-with
    (harness-test-load-module 'tools-shell)
    (let ((sid (harness-readonly-test-session t)))
      (should-not (member "bash" (harness-readonly-test-tools sid)))
      (harness-readonly-test-confined 'error)
      (should-not (member "bash" (harness-readonly-test-tools sid)))
      (harness-readonly-test-confined t)
      (should (member "bash" (harness-readonly-test-tools sid))))))

;;;; The permission stage

(ert-deftest harness-readonly-gate-denies-for-good-what-the-policy-does-not-allow ()
  "A write is denied, finally, with the policy's words; reading goes on to the later stages."
  (harness-readonly-test-with
    ;; A later stage that allows everything, as yolo mode would.
    (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (let ((sid (harness-readonly-test-session t))
          (free (harness-readonly-test-session)))
      (let ((decision (harness-readonly-test-decide sid "write_file")))
        (should (eq 'deny (plist-get decision :behavior)))
        (should (plist-get decision :final))
        (should (equal "test mode: this session only looks, so it may not use write_file"
                       (plist-get decision :reason)))
        (should (equal "Say what you would change instead." (plist-get decision :hint))))
      (should (eq 'allow (plist-get (harness-readonly-test-decide sid "read_file" 'read) :behavior)))
      (should (eq 'allow (plist-get (harness-readonly-test-decide sid "todo_write" 'meta) :behavior)))
      (should (eq 'allow (plist-get (harness-readonly-test-decide free "write_file") :behavior)))
      ;; Bash needs the sandbox; with it, the call goes on.
      (let ((decision (harness-readonly-test-decide sid "bash" 'exec)))
        (should (eq 'deny (plist-get decision :behavior)))
        (should (string-match-p "sandbox cannot confine" (plist-get decision :reason))))
      (harness-readonly-test-confined t)
      (should (eq 'allow (plist-get (harness-readonly-test-decide sid "bash" 'exec) :behavior))))))

(ert-deftest harness-readonly-gate-only-refuses-and-fails-closed ()
  "The gate allows nothing itself, and denies a call it cannot check."
  (harness-readonly-test-with
    (let ((sid (harness-readonly-test-session t))
          result)
      (harness-readonly--gate '(:behavior ask) (lambda (d) (setq result d))
                              (list :session (harness-call 'session/get sid) :tool "read_file"))
      (should (equal '(:behavior ask) result))
      ;; A policy that breaks: the call is denied, whatever the session.
      (harness-readonly-register 'broken (lambda (_s) (error "Broken")))
      (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
      (let ((decision (harness-readonly-test-decide (harness-readonly-test-session) "read_file" 'read)))
        (should (eq 'deny (plist-get decision :behavior)))
        (should (plist-get decision :final))
        (should (string-match-p "could not be checked" (plist-get decision :reason)))))))

(ert-deftest harness-readonly-gate-sits-before-the-jail-and-hooks-in-once ()
  "The stage is at 8 and the filters at 90; the module hooks in once, reloaded or not."
  (harness-readonly-test-with
    (should (= 8 (car (rassq #'harness-readonly--gate (gethash 'permission/decide harness--filters)))))
    (should (= 90 (car (rassq #'harness-readonly--tools (gethash 'agent/tools harness--filters)))))
    (should (= 90 (car (rassq #'harness-readonly--sandbox-options (gethash 'tools/sandbox-options harness--filters)))))
    (harness-readonly--init)
    (should (= 1 (cl-count #'harness-readonly--gate (gethash 'permission/decide harness--filters) :key #'cdr)))))

;;;; Bash

(ert-deftest harness-readonly-sandbox-options-make-bash-read-only-and-offline ()
  "A governed session's commands run read-only and offline; others as the handlers before said."
  (harness-readonly-test-with
    (let ((sid (harness-readonly-test-session t))
          (free (harness-readonly-test-session)))
      (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil sid)))
      (should (equal nil (harness-run-filter 'tools/sandbox-options nil free)))
      ;; Fails closed: a session nobody knows, and a policy that breaks.
      (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil "no-such-session")))
      (harness-readonly-register 'broken (lambda (_s) (error "Broken")))
      (should (plist-get (harness-run-filter 'tools/sandbox-options nil free) :read-only)))))

(ert-deftest harness-readonly-writes-are-refused-through-the-whole-tool-call ()
  "A governed session's write_file is refused with the reason, and writes nothing."
  (harness-readonly-test-with
    (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (let* ((sid (harness-readonly-test-session t))
           (file (expand-file-name "out.txt" (plist-get (harness-call 'session/get sid) :cwd)))
           (result (harness-test-await
                    (harness-call 'tools/execute sid (list :id (harness-short-id) :name "write_file"
                                                           :input (list :path file :content "hello")))
                    20)))
      (should (plist-get result :is-error))
      (should (string-match-p "test mode: .*write_file" (plist-get result :content)))
      (should-not (file-exists-p file)))))

;;;; Budgets

(ert-deftest harness-readonly-budget-points ()
  "The budget, then every half budget after it, or every EVERY calls."
  (harness-readonly-test-with
    (should-not (cl-some (lambda (n) (harness-readonly-budget-point-p n 40)) '(0 1 39 41 59 61)))
    (should (cl-every (lambda (n) (harness-readonly-budget-point-p n 40)) '(40 60 80 100)))
    (should (equal '(10 13 16 19) (cl-remove-if-not (lambda (n) (harness-readonly-budget-point-p n 10 3))
                                                    (number-sequence 1 20))))
    (should (equal '(1 2 3) (cl-remove-if-not (lambda (n) (harness-readonly-budget-point-p n 1)) '(0 1 2 3))))
    (dolist (budget '(nil 0 -3 "40"))
      (should-not (harness-readonly-budget-point-p 40 budget)))))

(provide 'harness-readonly-test)
;;; harness-readonly-test.el ends here
