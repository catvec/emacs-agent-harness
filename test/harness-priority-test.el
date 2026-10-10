;;; harness-priority-test.el --- Tests for session priority  -*- lexical-binding: t; -*-

;;; Commentary:

;; The priority plugin (lisp/modules/harness-priority.el) owns the
;; levels, and keeps a session's priority in the session's `:ext': any
;; session can have one, a session with none of its own takes its
;; parent's, and the tasks and the tool slots queue by it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)

(defmacro harness-priority-test-with (&rest body)
  "Load the state modules and the plugin into a fresh bus and state dir, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (harness-test-load-module 'priority)
     (clrhash harness-sessions)
     (let ((default-directory dir))
       ,@body)))

;;;; The levels

(ert-deftest harness-priority-levels-read-and-rank ()
  "The levels are low, medium and high; reading one is forgiving, ranking easy."
  (should (equal '(low medium high) harness-priority-levels))
  (should (eq 'medium harness-priority-default))
  (should (eq 'high (harness-priority-read "high")))
  (should (eq 'high (harness-priority-read 'HIGH)))
  (should (eq 'low (harness-priority-read " low ")))
  ;; What a person, a board command or a tool may write for medium.
  (should (eq 'medium (harness-priority-read "med")))
  (should (eq 'medium (harness-priority-read "Med")))
  (should (eq 'medium (harness-priority-read nil)))
  (should-error (harness-priority-read "urgent"))
  (should-error (harness-priority-read "med-high"))
  (should-error (harness-priority-read 3))
  ;; Reading a stored value never signals: nil, or a name no level has,
  ;; is the default.
  (should (eq 'low (harness-priority-level "low")))
  (should (eq 'medium (harness-priority-level nil)))
  (should (eq 'medium (harness-priority-level "urgent")))
  (should (= 0 (harness-priority-rank 'low)))
  (should (= 2 (harness-priority-rank "high")))
  (should (= 1 (harness-priority-rank nil)))
  (should (= 1 (harness-priority-rank "nothing")))
  (should (harness-priority-above-p 'high 'medium))
  (should (harness-priority-above-p 'high "low"))
  (should-not (harness-priority-above-p 'medium 'high))
  (should-not (harness-priority-above-p 'low 'low))
  ;; The levels as a sentence, as the error a bad one gets uses them.
  (should (equal "low, medium or high" (harness-priority-levels-text))))

(ert-deftest harness-priority-create-options ()
  "`harness-priority-ext' is the `:ext' a session is created with."
  (should (equal '(:priority "high") (harness-priority-ext 'high)))
  (should (equal '(:priority "medium") (harness-priority-ext nil)))
  (should (equal '(:priority "medium") (harness-priority-ext "med")))
  (should (equal '(:priority "low") (harness-priority-ext "low")))
  (should-error (harness-priority-ext "urgent")))

;;;; A session's priority

(ert-deftest harness-priority-a-session-keeps-its-own ()
  "Any session has a priority, kept in its `:ext' and read back as a level."
  (harness-priority-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd) :id)))
      ;; Medium until it is given one.
      (should (equal "medium" (harness-call 'priority/get id)))
      (should (= 1 (harness-call 'priority/rank id)))
      (should (eq 'medium (harness-priority-of id)))
      (should (equal "high" (harness-call 'priority/set id "high")))
      (should (equal "high" (harness-call 'priority/get id)))
      (should (= 2 (harness-call 'priority/rank id)))
      (should (eq 'high (harness-priority-of id)))
      ;; It lives in the session's `:ext', as the level's name.
      (should (equal '(:priority "high") (plist-get (harness-call 'session/get id) :ext)))
      ;; The command names, as a client sends them.
      (should (equal "low" (harness-call 'priority/set id "LOW")))
      (should (equal "medium" (harness-call 'priority/set id "med")))
      (should (eq 'low (harness-priority-set-session id 'low)))
      (should (eq 'low (harness-priority-of id)))
      ;; A name no level has is refused, and changes nothing.
      (should-error (harness-call 'priority/set id "urgent"))
      (should-error (harness-priority-set-session id "med-high"))
      (should (equal "low" (harness-call 'priority/get id)))
      ;; A session nobody knows has no priority to tell, and cannot be set.
      (should (equal "medium" (harness-call 'priority/get "no-such-session")))
      (should-error (harness-call 'priority/set "no-such-session" "high")))))

(ert-deftest harness-priority-a-session-takes-its-parents ()
  "A session with none of its own works at its parent's priority."
  (harness-priority-test-with
    (let* ((cwd (harness-test-temp-dir))
           (parent (plist-get (harness-call 'session/create :cwd cwd) :id))
           (child (plist-get (harness-call 'session/create :cwd cwd :parent-id parent) :id))
           (grand (plist-get (harness-call 'session/create :cwd cwd :parent-id child) :id)))
      (should (equal "medium" (harness-call 'priority/get child)))
      (harness-call 'priority/set parent "high")
      ;; A sub-agent, and a sub-agent's fork, work at the task's priority.
      (should (equal "high" (harness-call 'priority/get child)))
      (should (equal "high" (harness-call 'priority/get grand)))
      (should (= 2 (harness-call 'priority/rank grand)))
      ;; A session's own wins over its parent's, an explicit medium too.
      (harness-call 'priority/set child "low")
      (should (equal "low" (harness-call 'priority/get child)))
      (should (equal "low" (harness-call 'priority/get grand)))
      (harness-call 'priority/set child "medium")
      (should (equal "medium" (harness-call 'priority/get grand)))
      ;; Removing it again hands the session back to its parent.
      (harness-call 'session/set-ext child :priority nil)
      (should (equal "high" (harness-call 'priority/get child)))
      (should (equal "high" (harness-call 'priority/get grand)))
      ;; A session whose chain up has none is the default.
      (harness-call 'priority/set parent "medium")
      (should (equal "medium" (harness-call 'priority/get grand))))))

(ert-deftest harness-priority-sessions-are-created-with-it ()
  "A `:ext' of `harness-priority-ext' gives the new session its priority."
  (harness-priority-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd
                                        :ext (harness-priority-ext 'high))
                          :id))
           (plain (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (should (equal "high" (harness-call 'priority/get id)))
      (should (equal "medium" (harness-call 'priority/get plain)))
      ;; A stored session keeps it: it is in the record, not the runtime.
      (should (equal '(:priority "high") (plist-get (harness-call 'session/get id) :ext))))))

(ert-deftest harness-priority-clients-reach-the-priorities ()
  "A client reaches them over ACP as `_harness/priority/...'."
  (harness-priority-test-with
    (harness-test-load-module 'acp)
    (should (member "priority/get" (harness-acp--extension-methods)))
    (should (member "priority/rank" (harness-acp--extension-methods)))
    (should (member "priority/set" (harness-acp--extension-methods)))))

(provide 'harness-priority-test)
;;; harness-priority-test.el ends here
