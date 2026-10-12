;;; harness-internal-test.el --- Tests for internal sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; An internal session records one model call the harness makes on its
;; own (the permission judge's, a session's name, a recap): see
;; `session/internal-start' and `session/internal-finish' in
;; harness-session.el.  The provider module's part, which starts and
;; finishes them around a request, is tested in harness-provider-test.el.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-session--internal-keep)
(defvar harness-session--internal-prompt-max)
(defvar harness-session--tmp-root)
(defvar harness-policy-file)
(declare-function harness-policy-load "harness-policy" ())
(declare-function harness-policy-apply "harness-policy" (&optional final))
(declare-function harness-policy-clear "harness-policy" ())

(defmacro harness-internal-test-with (modules &rest body)
  "Load the state modules and MODULES into a fresh bus; run BODY.
BODY runs in a temporary state directory, `dir', which is also its
`default-directory'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m (append '(store project config provider session) ,modules))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory dir))
       ,@body)))

(defun harness-internal-test-start (&rest plist)
  "Start an internal session with PLIST; return its plist."
  (harness-call 'session/get (apply #'harness-call 'session/internal-start plist)))

(defun harness-internal-test-ids ()
  "Return the ids of the internal sessions, sorted."
  (sort (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list (list :kind 'internal)))
        #'string<))

(ert-deftest harness-internal-start-records-the-call ()
  "An internal session is of kind internal, named after its job, running,
with the prompt as a message the harness sent and the model asked; it
sits where its parent does, in its parent's project."
  (harness-internal-test-with nil
    (let* ((cwd (harness-test-temp-dir))
           (parent (harness-call 'session/create :cwd cwd :model "demo:scripted" :project "/proj/"))
           (s (harness-internal-test-start :job "Permission judge" :model "demo:judge"
                                           :parent-id (plist-get parent :id)
                                           :prompt "Is rm -rf safe?"))
           (nodes (harness-call 'session/nodes (plist-get s :id))))
      (should (eq 'internal (plist-get s :kind)))
      (should (equal "Permission judge" (plist-get s :name)))
      (should (eq 'running (plist-get s :status)))
      (should (equal "demo:judge" (plist-get s :model)))
      (should (equal (plist-get parent :id) (plist-get s :parent-id)))
      (should (equal cwd (plist-get s :cwd)))
      (should (equal "/proj/" (plist-get s :project)))
      (should (= 1 (length nodes)))
      (should (eq 'user (plist-get (car nodes) :kind)))
      (should (equal "Is rm -rf safe?" (plist-get (car nodes) :content)))
      (should (equal (harness-sender-system "Permission judge") (harness-node-sender (car nodes))))
      ;; The parent's model is its own.
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get (plist-get parent :id)) :model))))))

(ert-deftest harness-internal-start-keeps-a-parent-only-when-it-exists ()
  "A parent that is gone is not kept; without one the session sits in
the state directory, a project of its own, unless told otherwise."
  (harness-internal-test-with nil
    (let ((s (harness-internal-test-start :job "Auto-name" :model "demo:judge"
                                          :parent-id "naming-1234" :prompt "Title this")))
      (should-not (plist-get s :parent-id))
      (should (equal (file-name-as-directory dir) (plist-get s :cwd)))
      (should (equal (file-name-as-directory dir) (plist-get s :project))))
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-internal-test-start :job "Task search" :model "demo:judge"
                                           :cwd cwd :project "/board/" :prompt "find it")))
      (should (equal cwd (plist-get s :cwd)))
      (should (equal "/board/" (plist-get s :project))))
    ;; No job still makes a named session; no prompt makes no message.
    (let ((s (harness-internal-test-start :model "demo:judge")))
      (should (equal "Internal call" (plist-get s :name)))
      (should-not (harness-call 'session/nodes (plist-get s :id))))))

(ert-deftest harness-internal-start-cuts-a-long-prompt ()
  "A prompt over the limit is cut there, with a note saying so."
  (harness-internal-test-with nil
    (let* ((long (make-string (+ harness-session--internal-prompt-max 500) ?x))
           (s (harness-internal-test-start :job "Insights summary" :model "demo:judge" :prompt long))
           (text (plist-get (car (harness-call 'session/nodes (plist-get s :id))) :content)))
      (should (string-prefix-p (make-string harness-session--internal-prompt-max ?x) text))
      (should-not (string-prefix-p (make-string (1+ harness-session--internal-prompt-max) ?x) text))
      (should (string-match-p "prompt was cut here" text))
      (should (string-match-p (format "%d characters" (length long)) text)))))

(ert-deftest harness-internal-finish-records-the-reply-and-failures ()
  "Finishing appends the reply, says why a call failed or was cancelled,
and leaves the session idle; a session that is gone is no error."
  (harness-internal-test-with nil
    (let ((ok (plist-get (harness-internal-test-start :job "Recap" :model "demo:judge" :prompt "recap") :id))
          (failed (plist-get (harness-internal-test-start :job "Recap" :model "demo:judge" :prompt "recap") :id))
          (cancelled (plist-get (harness-internal-test-start :job "Pet" :model "demo:judge" :prompt "hi") :id)))
      (should (equal ok (harness-call 'session/internal-finish ok :reply "All done." :stop-reason 'end-turn)))
      (should (eq 'idle (plist-get (harness-call 'session/get ok) :status)))
      (let ((last (car (last (harness-call 'session/nodes ok)))))
        (should (eq 'assistant (plist-get last :kind)))
        (should (equal "All done." (plist-get last :content))))
      ;; A failure: an empty reply is no message, the error a hint.
      (harness-call 'session/internal-finish failed :reply "" :stop-reason "error" :error "overloaded")
      (should (eq 'idle (plist-get (harness-call 'session/get failed) :status)))
      (should (equal '(user hint) (mapcar (lambda (n) (plist-get n :kind))
                                         (harness-call 'session/nodes failed))))
      (should (equal "Error: overloaded" (plist-get (car (last (harness-call 'session/nodes failed))) :content)))
      (harness-call 'session/internal-finish cancelled :stop-reason 'cancelled)
      (should (string-match-p "cancelled" (plist-get (car (last (harness-call 'session/nodes cancelled))) :content)))
      ;; Gone: nothing to do, and no error.
      (harness-call 'session/delete ok)
      (should-not (harness-call 'session/internal-finish ok :reply "late" :stop-reason 'end-turn))
      (should-not (harness-call 'session/internal-finish "no-such-session" :stop-reason 'error)))))

(ert-deftest harness-internal-sessions-are-pruned-but-never-running-ones ()
  "Starting one deletes the oldest internal sessions that are not
running beyond `harness-session--internal-keep'; other sessions stay."
  (harness-internal-test-with nil
    (let* ((harness-session--internal-keep 2)
           (main (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (clock 1000.0)
           (start (lambda (job)
                    (let ((id (harness-call 'session/internal-start :job job :model "demo:judge" :prompt job)))
                      ;; Created in order, whatever the clock's resolution.
                      (aset (gethash id harness-sessions) (cl-struct-slot-offset 'harness-session 'created)
                            (cl-incf clock))
                      id)))
           (a (funcall start "a"))            ; left running throughout
           (b (funcall start "b"))
           (c nil) (d nil) (e nil))
      (harness-call 'session/internal-finish b :reply "b" :stop-reason 'end-turn)
      (setq c (funcall start "c"))
      ;; Three now: the oldest that is not running, b, went.
      (should (equal (sort (list a c) #'string<) (harness-internal-test-ids)))
      (harness-call 'session/internal-finish c :reply "c" :stop-reason 'end-turn)
      (setq d (funcall start "d"))
      (should (equal (sort (list a d) #'string<) (harness-internal-test-ids)))
      ;; Both running: a third one leaves three, as none can go.
      (setq e (funcall start "e"))
      (should (equal (sort (list a d e) #'string<) (harness-internal-test-ids)))
      (should (harness-call 'session/exists-p main))
      ;; Keeping none deletes every one that is not running.
      (harness-call 'session/internal-finish d :stop-reason 'end-turn)
      (harness-call 'session/internal-finish e :stop-reason 'end-turn)
      (let* ((harness-session--internal-keep 0)
             (f (funcall start "f")))
        (should (equal (sort (list a f) #'string<) (harness-internal-test-ids))))
      (should (harness-call 'session/exists-p main)))))

(ert-deftest harness-internal-session-has-no-tmp-dir ()
  "An internal session runs no tools: no temporary directory is made."
  (harness-internal-test-with nil
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (id (harness-call 'session/internal-start :job "Recap" :model "demo:judge" :prompt "recap"))
           (path (expand-file-name id harness-session--tmp-root)))
      (should-not (harness-call 'session/tmp-dir id))
      (should-not (file-exists-p path))
      ;; A session of another kind still has one.
      (should (harness-call 'session/tmp-dir
                            (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))))))

(ert-deftest harness-internal-session-cannot-be-prompted ()
  "The agent refuses every message to an internal session."
  (harness-internal-test-with '(tools agent)
    (let ((id (harness-call 'session/internal-start :job "Session judge" :model "demo:judge" :prompt "judge")))
      (harness-call 'session/internal-finish id :reply "supervise" :stop-reason 'end-turn)
      (let ((err (should-error (harness-call 'agent/prompt id "carry on") :type 'harness-error)))
        (should (string-match-p "records one internal model call and cannot be continued"
                                (error-message-string err))))
      (should-error (harness-call 'agent/prompt id "later" (list :queue t)) :type 'harness-error)
      (should-not (plist-get (harness-call 'session/get id) :queue))
      (should (= 2 (length (harness-call 'session/nodes id)))))))

(ert-deftest harness-internal-sessions-stay-out-of-bulk-changes-and-trees ()
  "Bulk changes select an internal session only when asked for kind
internal, and its parent's fork family leaves it out."
  (harness-internal-test-with nil
    (let* ((parent (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))
           (id (harness-call 'session/internal-start :job "Auto-name" :model "demo:judge"
                             :parent-id parent :prompt "name it")))
      (harness-call 'session/internal-finish id :reply "A title" :stop-reason 'end-turn)
      (should (equal (list parent) (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/select nil))))
      (should (equal (list parent) (mapcar (lambda (s) (plist-get s :id))
                                           (harness-call 'session/select (list :ids (list parent id))))))
      (should (equal (list id) (mapcar (lambda (s) (plist-get s :id))
                                       (harness-call 'session/select (list :kind 'internal)))))
      (should (equal (list parent) (harness-call 'session/set-all (list :model "demo:other") (list :active t))))
      (should (equal "demo:judge" (plist-get (harness-call 'session/get id) :model)))
      (let ((tree (harness-call 'session/tree parent)))
        (should (equal (list parent) (mapcar (lambda (s) (plist-get s :id)) (plist-get tree :sessions))))
        (should-not (cl-find id (plist-get tree :nodes) :key (lambda (n) (plist-get n :session)) :test #'equal))))))

(ert-deftest harness-internal-session-keeps-its-model-under-a-policy ()
  "A policy that fixes the model fixes no internal session's: each
records the model its call asked."
  (harness-internal-test-with nil
    (harness-test-with-policy '((harness-model . "demo:pinned"))
      (let ((main (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:other"))
            (internal (harness-internal-test-start :job "Permission judge" :model "demo:judge" :prompt "?")))
        (should (equal "demo:pinned" (plist-get main :model)))
        (should (equal "demo:judge" (plist-get internal :model)))))))

(provide 'harness-internal-test)
;;; harness-internal-test.el ends here
