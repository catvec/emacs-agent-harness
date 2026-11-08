;;; harness-decisions-test.el --- Tests for lasting decisions, their undo and redo  -*- lexical-binding: t; -*-

;;; Commentary:

;; A kind of decision of the tests' own stands for the permission rules
;; and the cold-cache default: it switches a variable between the value
;; before the decision and the one it set, and only while the variable
;; holds what the last move left there.  The registry, the store and the
;; events are the real ones.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-decisions--entries)
(defvar harness-decisions-kept)
(declare-function harness-decisions-define-kind "harness-decisions" (kind &rest spec))
(declare-function harness-decisions--load "harness-decisions" ())
(declare-function harness-decisions--find "harness-decisions" (id))
(declare-function harness-acp--extension-allowed-p "harness-acp" (name))
(defvar harness-acp--forwarded-events)

(defvar harness-decisions-test--value nil
  "The setting the tests' kind of decision changes.")

(defvar harness-decisions-test--events nil
  "The decisions `decision/changed' announced, newest first.")

(defvar harness-decisions-test--asked nil
  "The decision whose change the tests' kind was last asked for.")

(defun harness-decisions-test--change (decision)
  "Ask again for the answer of the tests' DECISION; return where it asks.
The tests' kind has no real prompt: the answer says the session and
the pending question, and the decision is remembered in
`harness-decisions-test--asked'."
  (setq harness-decisions-test--asked decision)
  (list :session (plist-get decision :session) :pending "p-asked"))

(defun harness-decisions-test--flip (decision from to word)
  "Set the tests' setting from DECISION's FROM to its TO, when it holds FROM.
WORD names the move in the sentence of a setting changed since.
Return (OUTCOME . MESSAGE) as a kind's undo or redo does."
  (let ((record (plist-get decision :record)))
    (if (equal (format "%s" harness-decisions-test--value) (format "%s" (plist-get record from)))
        (progn (setq harness-decisions-test--value (intern (format "%s" (plist-get record to))))
               (list (if (eq to :before) 'undone 'done)))
      (cons 'changed (format "Not %s: the value is %s now" word harness-decisions-test--value)))))

(defun harness-decisions-test--undo (decision)
  "Undo the tests' DECISION."
  (harness-decisions-test--flip decision :after :before "undone"))

(defun harness-decisions-test--redo (decision)
  "Redo the tests' DECISION."
  (harness-decisions-test--flip decision :before :after "redone"))

(defmacro harness-decisions-test-with (&rest body)
  "Run BODY with the decisions module, its store empty, and the tests' kind.
The tests' setting holds `after', as a decision just made left it."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store decisions))
       (harness-test-load-module m))
     (setq harness-decisions--entries nil
           harness-decisions-test--events nil
           harness-decisions-test--asked nil
           harness-decisions-test--value 'after)
     (harness-decisions-define-kind 'test
                                    :undo #'harness-decisions-test--undo
                                    :redo #'harness-decisions-test--redo
                                    :change #'harness-decisions-test--change)
     (harness-on 'decision/changed (lambda (d) (push d harness-decisions-test--events)))
     ,@body))

(defun harness-decisions-test--record (&rest opts)
  "Keep a decision of the tests' kind made in session \"s1\"; return it.
OPTS go to `decision/record'."
  (apply #'harness-call 'decision/record 'test "s1" "Always setting the value to after"
         '(:before before :after after) opts))

(ert-deftest harness-decisions-undo-then-redo ()
  "A decision is kept done; undo takes it back, redo puts it back, each once.
Each move is announced, and asking for a move it cannot make again
changes nothing and says why."
  (harness-decisions-test-with
    (let* ((d (harness-decisions-test--record))
           (id (plist-get d :id)))
      (should (string-prefix-p "d-" id))
      (should (eq 'done (plist-get d :state)))
      (should (eq 'test (plist-get d :kind)))
      (should (equal "s1" (plist-get d :session)))
      (should (equal (list d) harness-decisions-test--events))
      (should (equal d (harness-call 'decision/get id)))
      ;; Redo of a decision in effect does nothing.
      (should (equal '(done . "Nothing to redo: it is in effect")
                     (let ((r (harness-call 'decision/redo id))) (cons (plist-get r :outcome) (plist-get r :message)))))
      ;; Undo.
      (let ((r (harness-call 'decision/undo id)))
        (should (eq 'undone (plist-get r :outcome)))
        (should (equal "Undone: no longer always setting the value to after" (plist-get r :message)))
        (should (eq 'undone (plist-get (plist-get r :decision) :state))))
      (should (eq 'before harness-decisions-test--value))
      (should (eq 'undone (plist-get (car harness-decisions-test--events) :state)))
      (should (numberp (plist-get (harness-call 'decision/get id) :moved-at)))
      ;; Undone already: nothing more happens.
      (setq harness-decisions-test--events nil)
      (let ((r (harness-call 'decision/undo id)))
        (should (eq 'undone (plist-get r :outcome)))
        (should (equal "Undone: no longer always setting the value to after" (plist-get r :message))))
      (should-not harness-decisions-test--events)
      (should (eq 'before harness-decisions-test--value))
      ;; Redo, then undo again: the cursor goes back and forth.
      (let ((r (harness-call 'decision/redo id)))
        (should (eq 'done (plist-get r :outcome)))
        (should (equal "Redone: always setting the value to after" (plist-get r :message))))
      (should (eq 'after harness-decisions-test--value))
      (should (eq 'done (plist-get (car harness-decisions-test--events) :state)))
      (should (eq 'undone (plist-get (harness-call 'decision/undo id) :outcome)))
      (should (eq 'before harness-decisions-test--value))
      (should (eq 'done (plist-get (harness-call 'decision/redo id) :outcome)))
      (should (eq 'after harness-decisions-test--value))
      ;; No such decision.
      (should-error (harness-call 'decision/undo "d-nothere") :type 'harness-error))))

(ert-deftest harness-decisions-a-setting-changed-since-ends-it ()
  "A setting somebody else changed is left alone, and the decision ends there.
Neither undo nor redo moves it afterwards, whatever the setting holds."
  (harness-decisions-test-with
    (let ((id (plist-get (harness-decisions-test--record) :id)))
      ;; Changed by hand before the undo.
      (setq harness-decisions-test--value 'other)
      (let ((r (harness-call 'decision/undo id)))
        (should (eq 'changed (plist-get r :outcome)))
        (should (equal "Not undone: the value is other now" (plist-get r :message))))
      (should (eq 'other harness-decisions-test--value))
      (setq harness-decisions-test--value 'after)
      (should (eq 'changed (plist-get (harness-call 'decision/undo id) :outcome)))
      (should (eq 'changed (plist-get (harness-call 'decision/redo id) :outcome)))
      (should (eq 'after harness-decisions-test--value)))
    ;; Changed by hand after the undo: no redo either.
    (setq harness-decisions-test--value 'after)
    (let ((id (plist-get (harness-decisions-test--record) :id)))
      (harness-call 'decision/undo id)
      (setq harness-decisions-test--value 'other)
      (let ((r (harness-call 'decision/redo id)))
        (should (eq 'changed (plist-get r :outcome)))
        (should (equal "Not redone: the value is other now" (plist-get r :message))))
      (should (eq 'other harness-decisions-test--value)))))

(ert-deftest harness-decisions-a-move-that-fails-moves-nothing ()
  "A kind that signals, or one no module defines, leaves the decision as it was."
  (harness-decisions-test-with
    (let ((id (plist-get (harness-decisions-test--record) :id)))
      (harness-decisions-define-kind 'test :undo (lambda (_d) (error "Disk full")) :redo #'ignore)
      (let ((r (harness-call 'decision/undo id)))
        (should (eq 'failed (plist-get r :outcome)))
        (should (equal "Could not undo it: Disk full" (plist-get r :message))))
      (should (eq 'done (plist-get (harness-call 'decision/get id) :state)))
      (should (eq 'after harness-decisions-test--value)))
    (let ((d (harness-call 'decision/record 'nobody "s1" "Something nobody knows" nil)))
      (should (eq 'failed (plist-get (harness-call 'decision/undo (plist-get d :id)) :outcome)))
      (should (eq 'done (plist-get (harness-call 'decision/get (plist-get d :id)) :state))))
    (should-error (harness-call 'decision/record nil "s1" "No kind" nil) :type 'harness-error)
    (should-error (harness-call 'decision/record 'test "s1" "  " nil) :type 'harness-error)))

(ert-deftest harness-decisions-are-kept-across-a-restart ()
  "The decisions are read back from the state directory, their states and kinds
symbols again, and a decision undone before the restart is redone after."
  (harness-decisions-test-with
    (let* ((id (plist-get (harness-decisions-test--record) :id)))
      (harness-call 'decision/attach id "s1" "n-note")
      (harness-call 'decision/undo id)
      (setq harness-decisions--entries nil)
      (harness-decisions--load)
      (let ((d (harness-call 'decision/get id)))
        (should (eq 'undone (plist-get d :state)))
        (should (eq 'test (plist-get d :kind)))
        (should (equal "n-note" (plist-get d :node)))
        (should (equal "Undone: no longer always setting the value to after" (plist-get d :result))))
      (should (eq 'done (plist-get (harness-call 'decision/redo id) :outcome)))
      (should (eq 'after harness-decisions-test--value)))))

(ert-deftest harness-decisions-list-attach-and-keep-the-newest ()
  "The list is newest first and filters by kind, state and session; a note
is attached once written; only the newest decisions are kept."
  (harness-decisions-test-with
    (let* ((a (plist-get (harness-decisions-test--record) :id))
           (b (plist-get (harness-call 'decision/record 'other "s2" "Something else" '(:x 1)) :id)))
      (should (equal (list b a) (mapcar (lambda (d) (plist-get d :id)) (harness-call 'decision/list))))
      (should (equal (list a) (mapcar (lambda (d) (plist-get d :id)) (harness-call 'decision/list :kind "test"))))
      (should (equal (list b) (mapcar (lambda (d) (plist-get d :id)) (harness-call 'decision/list :session "s2"))))
      (harness-call 'decision/undo a)
      (should (equal (list a) (mapcar (lambda (d) (plist-get d :id)) (harness-call 'decision/list :state "undone"))))
      (should (= 1 (length (harness-call 'decision/list :limit 1))))
      (setq harness-decisions-test--events nil)
      (let ((d (harness-call 'decision/attach b "s2" "n-1")))
        (should (equal "n-1" (plist-get d :node)))
        (should (equal (list d) harness-decisions-test--events)))
      (should-error (harness-call 'decision/attach "d-nothere" "s2" "n-1") :type 'harness-error))
    ;; A decision kept only now, of a note written before, starts where the note says.
    (let ((d (harness-decisions-test--record :state 'undone :result "Undone before" :node "n-old")))
      (should (eq 'undone (plist-get d :state)))
      (should (equal "Undone before" (plist-get d :result)))
      (should (equal "n-old" (plist-get d :node))))
    (let ((harness-decisions-kept 3))
      (dotimes (_ 3) (harness-decisions-test--record))
      (should (= 3 (length (harness-call 'decision/list)))))))

(ert-deftest harness-decisions-change-asks-again-when-the-prompt-was-kept ()
  "A decision kept with the prompt that asked it offers a change: its kind
is asked again, with the decision as it stands, and answers where the
prompt opens.  One kept without a prompt, or of a kind that cannot ask,
offers none; one that ended offers none either."
  (harness-decisions-test-with
    (let* ((change '(:prompt (:question "What goes first?" :options ("a" "b"))))
           (d (harness-decisions-test--record :change change))
           (id (plist-get d :id)))
      (should (harness-json-true-p (plist-get d :changeable)))
      (should (equal change (plist-get d :change)))
      (should (equal '(:session "s1" :pending "p-asked") (harness-call 'decision/change id)))
      ;; Clients get where it stands, and that it can change, not the prompt.
      (should (equal (harness-plist-remove d :change) (harness-call 'decision/get id)))
      (should (equal d harness-decisions-test--asked))
      ;; A kind that cannot ask says so, and nothing moves.
      (harness-decisions-define-kind 'test
                                     :undo #'harness-decisions-test--undo
                                     :redo #'harness-decisions-test--redo
                                     :change (lambda (_d) (error "No session there")))
      (let ((err (condition-case err
                     (progn (harness-call 'decision/change id) nil)
                   (harness-error err))))
        (should (equal "Could not ask again: No session there" (cadr err))))
      (should (eq 'done (plist-get (harness-call 'decision/get id) :state)))
      (harness-decisions-define-kind 'test
                                     :undo #'harness-decisions-test--undo
                                     :redo #'harness-decisions-test--redo
                                     :change #'harness-decisions-test--change)
      ;; Ended, it offers no change.
      (harness-call 'decision/undo id)
      (setq harness-decisions-test--value 'other)
      (should (eq 'changed (plist-get (harness-call 'decision/redo id) :outcome)))
      (should-error (harness-call 'decision/change id) :type 'harness-error)
      ;; Kept without a prompt: nothing to open.
      (let ((plain (harness-decisions-test--record)))
        (should (eq :false (plist-get plain :changeable)))
        (should-not (plist-get plain :change))
        (should-error (harness-call 'decision/change (plist-get plain :id)) :type 'harness-error))
      ;; A kind no module here knows how to ask.
      (let ((unknown (harness-call 'decision/record 'nobody "s1" "Something nobody knows" nil
                                   :change '(:prompt (:question "Q")))))
        (should (eq :false (plist-get unknown :changeable)))
        (should-error (harness-call 'decision/change (plist-get unknown :id)) :type 'harness-error)))))

(ert-deftest harness-decisions-change-is-kept-and-revised ()
  "The prompt a decision keeps is saved with it and read back; a change
replaces its text, record and state while keeping its id, session and
note, and is announced."
  (harness-decisions-test-with
    (let* ((change '(:prompt (:question "What goes first?" :options ("a" "b")) :cover "wide"))
           (d (harness-decisions-test--record :change change :node "n-1"))
           (id (plist-get d :id)))
      (harness-call 'decision/undo id)
      (setq harness-decisions--entries nil)
      (harness-decisions--load)
      (let ((back (harness-call 'decision/get id)))
        (should (harness-json-true-p (plist-get back :changeable)))
        (should-not (plist-get back :change))
        (should (equal change (plist-get (harness-decisions--find id) :change)))
        (should (equal "n-1" (plist-get back :node)))
        (should (eq 'undone (plist-get back :state)))
        ;; The kind asks again after the restart, as the decision stands.
        (should (equal '(:session "s1" :pending "p-asked") (harness-call 'decision/change id))))
      ;; A changed answer becomes the decision's, in place.
      (setq harness-decisions-test--events nil)
      (let ((revised (harness-call 'decision/revise id
                                   :id "d-other" :kind 'other :session "s2" :at 1.0
                                   :text "Always setting the value to before"
                                   :record '(:before before :after after)
                                   :state 'done :result "Changed")))
        (should (equal id (plist-get revised :id)))
        (should (eq 'test (plist-get revised :kind)))
        (should (equal "s1" (plist-get revised :session)))
        (should (equal "n-1" (plist-get revised :node)))
        (should (equal "Always setting the value to before" (plist-get revised :text)))
        (should (eq 'done (plist-get revised :state)))
        (should (equal "Changed" (plist-get revised :result)))
        (should (equal (list (harness-plist-remove revised :change))
                       harness-decisions-test--events)))
      (should-error (harness-call 'decision/revise "d-nothere" :text "x") :type 'harness-error))))

(ert-deftest harness-decisions-reach-clients ()
  "Clients call the decision methods and hear when one changes."
  (harness-test-load-module 'acp)
  (should (harness-acp--extension-allowed-p "decision/undo"))
  (should (harness-acp--extension-allowed-p "decision/redo"))
  (should (harness-acp--extension-allowed-p "decision/change"))
  (should (harness-acp--extension-allowed-p "decision/list"))
  (should (memq 'decision/changed harness-acp--forwarded-events)))

(provide 'harness-decisions-test)
;;; harness-decisions-test.el ends here
