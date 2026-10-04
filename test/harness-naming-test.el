;;; harness-naming-test.el --- Tests for session naming  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-naming--running)
(defvar harness-naming--base-system-prompt)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-agent-running-p "harness-agent")
(declare-function harness-naming-sanitise "harness-naming")

(defmacro harness-naming-test-with (&rest body)
  "Load the state layer with the demo provider and naming, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent naming))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-naming--running)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-naming-auto t)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-naming-test-script
  '((:type text :delta "  \"Refactor the ") (:type text :delta "parser\".") (:type done :stop-reason end-turn)))

(defun harness-naming-test-session (&rest plist)
  "Create a demo session; PLIST overrides the defaults."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (harness-test-temp-dir) :model "demo:scripted")))
             :id))

(defun harness-naming-test-answered-session (&rest plist)
  "A session with one answered exchange already in the transcript."
  (let ((id (apply #'harness-naming-test-session plist)))
    (harness-call 'session/append id '(:kind user :content "refactor the parser please"))
    (harness-call 'session/append id '(:kind assistant :content "Done."))
    id))

(defun harness-naming-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-naming-test-hints (id)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes id))))

(defun harness-naming-test-name (id)
  (plist-get (harness-call 'session/get id) :name))

(defmacro harness-naming-test-counting-completes (var &rest body)
  "Run BODY with VAR counting the provider requests made."
  (declare (indent 1))
  `(cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
              ((symbol-function 'harness-method/provider/complete)
               (lambda (req) (cl-incf ,var) (funcall orig req))))
     ,@body))

(ert-deftest harness-naming-sanitise ()
  (should (equal "Refactor the parser" (harness-naming-sanitise "  \"Refactor the parser\".")))
  (should (equal "Fix login bug" (harness-naming-sanitise "**Fix login bug**\n\nMore text")))
  (should (equal "Add tests" (harness-naming-sanitise "# Add tests")))
  (should (equal "Add tests" (harness-naming-sanitise "Title: Add tests")))
  (should (equal "Migrate to sqlite" (harness-naming-sanitise "‘Migrate   to sqlite’!")))
  (should (null (harness-naming-sanitise "  \n\"\" ")))
  (let ((long (harness-naming-sanitise (make-string 100 ?x))))
    (should (= 60 (length long)))
    (should (string-suffix-p "…" long))))

(ert-deftest harness-naming-name-sets-the-session-name ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (requests nil) (done nil))
      (harness-on 'naming/done (lambda (sid name) (push (list sid name) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (equal "Refactor the parser" (harness-await (harness-call 'naming/name id)))))
      (should (equal "Refactor the parser" (harness-naming-test-name id)))
      (should (equal (list (list id "Refactor the parser")) done))
      (should (equal '("Naming session…" "renamed to Refactor the parser") (harness-naming-test-hints id)))
      ;; No fork capability: the transcript goes out as messages, no provider state.
      (let* ((req (car requests))
             (last (car (last (plist-get req :messages)))))
        (should (= 1 (length requests)))
        (should (null (plist-get req :provider-state)))
        (should (null (plist-get req :tools)))
        (should (= 3 (length (plist-get req :messages))))
        (should (string-match-p "3 to 6 words" (plist-get (car (last (plist-get last :content))) :text))))
      (should (zerop (hash-table-count harness-naming--running))))))

(ert-deftest harness-naming-system-prompt-filter ()
  "Modules add to a session's naming system prompt with `naming/system-prompt'."
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (other (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (systems nil))
      (harness-add-filter 'naming/system-prompt
                          (lambda (prompt session)
                            (if (equal (plist-get session :id) id) (concat prompt "\n\nLike a ticket.") prompt)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push (plist-get req :system) systems) (funcall orig req))))
        (harness-await (harness-call 'naming/name id))
        (harness-await (harness-call 'naming/name other)))
      (should (equal (list harness-naming--base-system-prompt
                           (concat harness-naming--base-system-prompt "\n\nLike a ticket."))
                     systems)))))

(ert-deftest harness-naming-name-error-rejects ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom"))))
      (should-error (harness-await (harness-call 'naming/name id)))
      (should (null (harness-naming-test-name id)))
      (should (equal '("Naming session…" "Naming failed: boom") (harness-naming-test-hints id)))
      (should (zerop (hash-table-count harness-naming--running))))))

(ert-deftest harness-naming-name-runs-once-per-session ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (calls 0))
      (harness-naming-test-counting-completes calls
        (let ((p1 (harness-call 'naming/name id))
              (p2 (harness-call 'naming/name id)))
          (should (eq p1 p2))
          (harness-await p1)))
      (should (= 1 calls))
      (should (= 1 (cl-count "Naming session…" (harness-naming-test-hints id) :test #'equal))))))

(ert-deftest harness-naming-auto-after-first-turn ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session))
           (harness-provider-demo-script-override harness-naming-test-script))
      (should (null (harness-naming-test-name id)))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "auto name")
      (should (equal "Refactor the parser" (harness-naming-test-name id)))
      (should (equal '(user assistant hint hint) (harness-naming-test-kinds id)))
      (should (equal '("Naming session…" "renamed to Refactor the parser") (harness-naming-test-hints id))))))

(ert-deftest harness-naming-auto-names-only-once ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello"))
        (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "auto name")
        (harness-await (harness-call 'agent/prompt id "second"))
        (harness-test-wait (lambda () (not (harness-agent-running-p id)))))
      ;; Two turns plus one naming request.
      (should (= 3 calls))
      (should (= 1 (cl-count "Naming session…" (harness-naming-test-hints id) :test #'equal))))))

(ert-deftest harness-naming-auto-leaves-named-session-alone ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session :name "Given name"))
           (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello")))
      (should (= 1 calls))
      (should (equal "Given name" (harness-naming-test-name id)))
      (should (equal '(user assistant) (harness-naming-test-kinds id))))))

(ert-deftest harness-naming-auto-skips-btw-and-subagent ()
  (harness-naming-test-with
    (dolist (kind '(btw subagent))
      (let ((id (harness-naming-test-session :kind kind))
            (calls 0))
        (harness-naming-test-counting-completes calls
          (harness-await (harness-call 'agent/prompt id "hello")))
        (should (= 1 calls))
        (should (null (harness-naming-test-name id)))
        (should (equal '(user assistant) (harness-naming-test-kinds id)))))))

(ert-deftest harness-naming-auto-respects-custom ()
  (harness-naming-test-with
    (let ((harness-naming-auto nil)
          (id (harness-naming-test-session))
          (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello")))
      (should (= 1 calls))
      (should (null (harness-naming-test-name id))))))

(ert-deftest harness-naming-auto-ignores-non-end-turn ()
  (harness-naming-test-with
    (let ((id (harness-naming-test-session))
          (calls 0))
      (harness-add-filter 'agent/before-turn
                          (lambda (_v next _s) (funcall next (list :proceed nil :reason "held"))))
      (harness-naming-test-counting-completes calls
        (should (eq 'blocked (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason))))
      (should (= 0 calls))
      (should (null (harness-naming-test-name id))))))

(ert-deftest harness-naming-uses-provider-fork-when-supported ()
  (harness-naming-test-with
    (let ((forks nil) (requests nil))
      (harness-define-provider 'forky
        :label "Forking fake"
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "Forked title here"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (model state)
                (push (list model state) forks)
                (harness-resolved (list :forked-from (plist-get state :cli))))
        :capabilities '(:fork t :hosted-loop t))
      (let ((id (harness-naming-test-answered-session :model "forky:m")))
        (harness-call 'session/set-provider-state id '(:cli "abc"))
        (should (equal "Forked title here" (harness-await (harness-call 'naming/name id))))
        (should (equal '(("forky:m" (:cli "abc"))) forks))
        (should (= 1 (length requests)))
        (should (equal '(:forked-from "abc" :provider "forky") (plist-get (car requests) :provider-state)))
        (should (equal "Forked title here" (harness-naming-test-name id)))
        ;; The session's own state is untouched by the fork.
        (should (equal '(:cli "abc") (plist-get (harness-call 'session/get id) :provider-state)))))))

(ert-deftest harness-naming-falls-back-when-fork-fails ()
  (harness-naming-test-with
    (let ((requests nil))
      (harness-define-provider 'forky
        :label "Forking fake"
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "Plain title"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (_model _state) (harness-rejected (list 'harness-error "no fork today")))
        :capabilities '(:fork t))
      (let ((id (harness-naming-test-answered-session :model "forky:m")))
        (should (equal "Plain title" (harness-await (harness-call 'naming/name id))))
        (should (null (plist-get (car requests) :provider-state)))
        (should (= 3 (length (plist-get (car requests) :messages))))))))

(provide 'harness-naming-test)
;;; harness-naming-test.el ends here
