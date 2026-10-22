;;; harness-ui-decisions-test.el --- Tests for lasting decisions in the UI  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI's cache of the harness's lasting decisions: fetched when the
;; UI connects, kept current by `decision/changed', fetched again after a
;; reload, emptied when the module stops; the commands that undo and redo
;; a decision by its id, or ask which; the button a decision offers in
;; each state and what it says.  The harness half is the real decisions
;; module, over the in-process connection, with a kind of decision of
;; the tests' own that switches a variable.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-ui--sessions)
(defvar harness-ui-decisions--cache)
(defvar harness-ui-decision-functions)
(defvar harness-ui-event-functions)
(defvar harness-ui-connected-hook)

(declare-function harness-decisions-define-kind "harness-decisions" (kind &rest spec))
(declare-function harness-ui-connect "harness-ui" (&optional address))
(declare-function harness-ui-request "harness-ui" (method &optional params))
(declare-function harness-ui-action-push "harness-ui" (&optional event))
(declare-function harness-ui-decision "harness-ui-decisions" (id))
(declare-function harness-ui-decisions "harness-ui-decisions" (&optional state))
(declare-function harness-ui-decisions-store "harness-ui-decisions" (decision))
(declare-function harness-ui-decisions-refresh "harness-ui-decisions" (&optional callback))
(declare-function harness-ui-decisions--on-event "harness-ui-decisions" (event args))
(declare-function harness-ui-decisions--init "harness-ui-decisions" ())
(declare-function harness-ui-decisions--shutdown "harness-ui-decisions" ())
(declare-function harness-ui-decision-button "harness-ui-decisions" (id state &optional help))
(declare-function harness-decision-undo "harness-ui-decisions" (id))
(declare-function harness-decision-redo "harness-ui-decisions" (id))

(defvar harness-ui-decisions-test--value nil
  "The setting the tests' kind of decision switches: `before' or `after'.")

(defvar harness-ui-decisions-test--changes nil
  "What `harness-ui-decision-functions' was called with, newest first.")

(defun harness-ui-decisions-test--note-change (id decision)
  "Record that the cache changed: decision ID, now DECISION."
  (push (list id decision) harness-ui-decisions-test--changes))

(defun harness-ui-decisions-test--flip (decision from to)
  "Switch the tests' setting from DECISION's FROM to its TO, if it holds FROM.
Return (OUTCOME . MESSAGE) as a kind's undo or redo does."
  (let ((record (plist-get decision :record)))
    (if (equal (format "%s" harness-ui-decisions-test--value) (format "%s" (plist-get record from)))
        (progn (setq harness-ui-decisions-test--value (intern (format "%s" (plist-get record to))))
               (list (if (eq to :before) 'undone 'done)))
      (cons 'changed (format "Not %s: the value is %s now" (if (eq to :before) "undone" "redone")
                             harness-ui-decisions-test--value)))))

(defmacro harness-ui-decisions-test-with (&rest body)
  "Run BODY with the harness's decisions, the UI and its decisions cache.
The tests' kind of decision, `test', is defined, and its setting holds
`after', as a decision just made leaves it.  The UI is connected, and
its first fetch of the decisions has answered."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--clients nil)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store acp decisions))
         (harness-test-load-module m)))
     (setq harness-ui-decisions-test--value 'after
           harness-ui-decisions-test--changes nil)
     (harness-decisions-define-kind
      'test
      :undo (lambda (d) (harness-ui-decisions-test--flip d :after :before))
      :redo (lambda (d) (harness-ui-decisions-test--flip d :before :after)))
     (let ((harness-acp-token nil)
           (default-directory dir))
       (unwind-protect
           (progn
             (harness-test-load-module 'ui)
             (harness-test-load-module 'ui-decisions)
             (add-hook 'harness-ui-decision-functions #'harness-ui-decisions-test--note-change)
             (harness-ui-decisions-test--settle)
             (setq harness-ui-decisions-test--changes nil)
             ,@body)
         (remove-hook 'harness-ui-decision-functions #'harness-ui-decisions-test--note-change)
         (harness-ui-decisions--shutdown)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-decisions-test--settle ()
  "Fetch the decisions and wait for the answer.
The harness answers in order, so every fetch asked before has answered too."
  (let ((done nil))
    (harness-ui-decisions-refresh (lambda (_) (setq done t)))
    (harness-test-wait (lambda () done) 5 "the decisions fetched")))

(defun harness-ui-decisions-test--record (text &optional session)
  "Keep a decision of the tests' kind that TEXT says, made in SESSION; return it."
  (harness-call 'decision/record 'test (or session "s1") text '(:before before :after after)))

(defun harness-ui-decisions-test--ids (decisions)
  "Return the ids of DECISIONS."
  (mapcar (lambda (d) (plist-get d :id)) decisions))

(defun harness-ui-decisions-test--move (command id)
  "Run COMMAND on decision ID and return what the echo area said of it.
Complaints of the connection about the views this test does not load
are not it."
  (let (shown)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (when format-string (push (apply #'format format-string args) shown)))))
      (funcall command id)
      (harness-test-wait (lambda () (cl-find-if-not (lambda (m) (string-prefix-p "Harness: " m)) shown))
                         5 "the echo area"))))

(ert-deftest harness-ui-decisions-cache-follows-the-harness ()
  "The cache follows `decision/changed', and is fetched whole on connect and reload.
Each decision is cached with its state and kind as symbols, though they
travel as strings, and every change runs `harness-ui-decision-functions':
with the decision, or with nil after the whole cache was fetched."
  (harness-ui-decisions-test-with
    (let ((id (plist-get (harness-ui-decisions-test--record "Always setting the value to after") :id)))
      ;; Announced as it is kept.
      (harness-test-wait (lambda () (harness-ui-decision id)) 5 "the announcement")
      (let ((cached (harness-ui-decision id)))
        (should (eq 'done (plist-get cached :state)))
        (should (eq 'test (plist-get cached :kind)))
        (should (equal "Always setting the value to after" (plist-get cached :text)))
        (should (equal "s1" (plist-get cached :session))))
      (should (equal id (car (car harness-ui-decisions-test--changes))))
      (should (eq 'done (plist-get (cadr (car harness-ui-decisions-test--changes)) :state)))
      ;; A move made elsewhere -- another UI, the harness itself -- is heard too.
      (harness-call 'decision/undo id)
      (harness-test-wait (lambda () (eq 'undone (plist-get (harness-ui-decision id) :state)))
                         5 "the undo announced")
      (should (equal "Undone: no longer always setting the value to after"
                     (plist-get (harness-ui-decision id) :result)))
      (let ((id2 (plist-get (harness-ui-decisions-test--record "Always testing" "s2") :id)))
        (harness-test-wait (lambda () (harness-ui-decision id2)) 5 "the second decision")
        ;; Newest first, and by state.
        (should (equal (list id2 id) (harness-ui-decisions-test--ids (harness-ui-decisions))))
        (should (equal (list id2) (harness-ui-decisions-test--ids (harness-ui-decisions 'done))))
        (should (equal (list id) (harness-ui-decisions-test--ids (harness-ui-decisions 'undone))))
        ;; Fetched whole when the UI connects again: what it missed is there.
        (clrhash harness-ui-decisions--cache)
        (setq harness-ui-decisions-test--changes nil)
        (harness-ui-connect nil)
        (harness-test-wait (lambda () (harness-ui-decision id2)) 5 "the fetch on connect")
        (should (member '(nil nil) harness-ui-decisions-test--changes))
        (should (eq 'undone (plist-get (harness-ui-decision id) :state)))
        ;; Fetched whole after the harness reloaded: the cache is replaced.
        (puthash "d-stale" '(:id "d-stale" :state done :kind test :text "Old") harness-ui-decisions--cache)
        (setq harness-ui-decisions-test--changes nil)
        (harness-ui-decisions--on-event "harness/reloaded" nil)
        (harness-test-wait (lambda () harness-ui-decisions-test--changes) 5 "the fetch after a reload")
        (should (equal '((nil nil)) harness-ui-decisions-test--changes))
        (should-not (harness-ui-decision "d-stale"))
        (should (equal (list id2 id) (harness-ui-decisions-test--ids (harness-ui-decisions))))
        ;; What is no decision is not cached.
        (should-not (harness-ui-decisions-store '(:id "d-x" :state "lost")))
        (should-not (harness-ui-decisions-store '(:state "done")))
        (should-not (harness-ui-decision "d-x"))))))

(ert-deftest harness-ui-decisions-undo-and-redo-by-id ()
  "Undo and redo move a decision by its id, wherever it was made.
The echo area says what the harness said, and the decision it answers
with is cached at once.  A setting changed since ends the decision:
nothing more is offered, and asking again repeats why."
  (harness-ui-decisions-test-with
    (let ((id (plist-get (harness-ui-decisions-test--record "Always setting the value to after" "elsewhere") :id)))
      (harness-test-wait (lambda () (harness-ui-decision id)) 5 "the decision cached")
      (should (equal "Undone: no longer always setting the value to after"
                     (harness-ui-decisions-test--move #'harness-decision-undo id)))
      (should (eq 'before harness-ui-decisions-test--value))
      (should (eq 'undone (plist-get (harness-ui-decision id) :state)))
      (should (equal "Redone: always setting the value to after"
                     (harness-ui-decisions-test--move #'harness-decision-redo id)))
      (should (eq 'after harness-ui-decisions-test--value))
      (should (eq 'done (plist-get (harness-ui-decision id) :state)))
      ;; Changed since: it stays as it is, and the decision ends.
      (setq harness-ui-decisions-test--value 'other)
      (should (equal "Not undone: the value is other now"
                     (harness-ui-decisions-test--move #'harness-decision-undo id)))
      (should (eq 'other harness-ui-decisions-test--value))
      (should (eq 'changed (plist-get (harness-ui-decision id) :state)))
      (should (equal "Not undone: the value is other now"
                     (harness-ui-decisions-test--move #'harness-decision-redo id)))
      (should (eq 'changed (plist-get (harness-ui-decision id) :state))))))

(ert-deftest harness-ui-decisions-commands-ask-which ()
  "Interactively, undo offers the decisions in effect and redo the undone ones.
The newest come first, each with where and when it was made; with none
to offer, the command says so."
  (harness-ui-decisions-test-with
    (let ((harness-ui--sessions (make-hash-table :test 'equal))
          (offered nil)
          (sent nil))
      (dolist (d '((:id "d-old" :kind "test" :state "done" :text "Always A" :at 100.0 :session "s1")
                   (:id "d-new" :kind "test" :state "done" :text "Always B" :at 200.0)
                   (:id "d-back" :kind "test" :state "undone" :text "Always C" :at 150.0)
                   (:id "d-end" :kind "test" :state "changed" :text "Always D" :at 300.0)))
        (harness-ui-decisions-store d))
      (puthash "s1" '(:id "s1" :name "Work") harness-ui--sessions)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq offered (all-completions "" table))
                   (car offered)))
                ((symbol-function 'harness-ui-call)
                 (lambda (method params _callback &optional _on-error)
                   (push (list method params) sent))))
        (call-interactively #'harness-decision-undo)
        (should (equal 2 (length offered)))
        (should (string-prefix-p "Always B (" (nth 0 offered)))
        (should (string-prefix-p "Always A (Work, " (nth 1 offered)))
        (should (equal '("_harness/decision/undo" (:id "d-new")) (car sent)))
        (call-interactively #'harness-decision-redo)
        (should (equal 1 (length offered)))
        (should (string-prefix-p "Always C (" (car offered)))
        (should (equal '("_harness/decision/redo" (:id "d-back")) (car sent)))
        ;; Two that read alike are told apart by their ids.
        (harness-ui-decisions-store '(:id "d-twin" :kind "test" :state "done" :text "Always A" :at 100.0 :session "s1"))
        (call-interactively #'harness-decision-undo)
        (should (equal 3 (length (delete-dups (copy-sequence offered)))))
        (should (cl-some (lambda (o) (string-suffix-p "]" o)) offered))
        (clrhash harness-ui-decisions--cache)
        (should (equal "Nothing to undo"
                       (cadr (should-error (call-interactively #'harness-decision-undo) :type 'user-error))))
        (should (equal "Nothing to redo"
                       (cadr (should-error (call-interactively #'harness-decision-redo) :type 'user-error))))))))

(ert-deftest harness-ui-decisions-button-says-what-a-click-does ()
  "A decision offers [Undo] while done and [Redo] while undone, nothing once ended.
The tooltip says what a click does, by the decision's kind, unless the
caller says it; a click or RET moves that decision."
  (harness-ui-decisions-test-with
    (let ((sent nil))
      (dolist (d '((:id "d-p" :kind "permission" :state "done" :text "Always allowing every bash call, in every session")
                   (:id "d-c" :kind "cowboy" :state "undone" :text "Always starting afresh when the prompt cache is cold")
                   (:id "d-t" :kind "test" :state "changed" :text "Always testing")))
        (harness-ui-decisions-store d))
      (let ((undo (harness-ui-decision-button "d-p" 'done))
            (redo (harness-ui-decision-button "d-c" 'undone)))
        (should (equal "[Undo]" undo))
        (should (equal "Take back what this answer recorded" (get-text-property 0 'help-echo undo)))
        (should (eq 'button (get-text-property 0 'face undo)))
        (should (equal "[Redo]" redo))
        (should (equal "Make this the default again, without asking" (get-text-property 0 'help-echo redo)))
        (should (equal "Ask again when the prompt cache is cold"
                       (get-text-property 0 'help-echo (harness-ui-decision-button "d-c" 'done))))
        (should (equal "Record this answer again"
                       (get-text-property 0 'help-echo (harness-ui-decision-button "d-p" 'undone))))
        (should (equal "Take this decision back"
                       (get-text-property 0 'help-echo (harness-ui-decision-button "d-t" 'done))))
        (should (equal "Make this decision again"
                       (get-text-property 0 'help-echo (harness-ui-decision-button "d-unknown" 'undone))))
        (should (equal "Mine" (get-text-property 0 'help-echo (harness-ui-decision-button "d-t" 'done "Mine"))))
        ;; Ended, or nowhere: no button.
        (should-not (harness-ui-decision-button "d-t" 'changed))
        (should-not (harness-ui-decision-button "d-t" 'gone))
        (should-not (harness-ui-decision-button "d-t" nil))
        ;; A click runs the move of that decision.
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (method params _callback &optional _on-error)
                     (push (list method params) sent))))
          (with-temp-buffer
            (insert undo " " redo)
            (goto-char (point-min))
            (harness-ui-action-push)
            (should (equal '("_harness/decision/undo" (:id "d-p")) (car sent)))
            (goto-char (1- (point-max)))
            (harness-ui-action-push)
            (should (equal '("_harness/decision/redo" (:id "d-c")) (car sent)))))))))

(declare-function harness-ui-decision-label "harness-ui-decisions" (id way))
(declare-function harness-ui-decision-strikes-p "harness-ui-decisions" (id))
(defvar harness-ui-decision-labels)

(ert-deftest harness-ui-decisions-a-switch-reads-as-one ()
  "The decision to compact before the prompt cache lapses is a switch: its
button says [Turn off] while it is on and [Turn on] once it was turned
off, with a tooltip that says what a click does.  Every other kind keeps
[Undo] and [Redo], and so does a decision the UI has not heard of; only
a switch's notes keep their text when it is off."
  (harness-ui-decisions-test-with
    (let ((sent nil)
          (text "Compacting a conversation just before its prompt cache lapses, while it is still cached"))
      (dolist (d (list (list :id "d-on" :kind "precompact" :state "done" :text text)
                       (list :id "d-off" :kind "precompact" :state "undone" :text text)
                       (list :id "d-end" :kind "precompact" :state "changed" :text text)
                       '(:id "d-p" :kind "permission" :state "done" :text "Always allowing every bash call, in every session")
                       '(:id "d-c" :kind "cowboy" :state "undone" :text "Always starting afresh when the prompt cache is cold")))
        (harness-ui-decisions-store d))
      (let ((off (harness-ui-decision-button "d-on" 'done))
            (on (harness-ui-decision-button "d-off" 'undone)))
        (should (equal "[Turn off]" off))
        (should (eq 'button (get-text-property 0 'face off)))
        (should (equal "Stop compacting conversations just before their prompt cache lapses"
                       (get-text-property 0 'help-echo off)))
        (should (equal "[Turn on]" on))
        (should (equal "Compact conversations just before their prompt cache lapses again"
                       (get-text-property 0 'help-echo on)))
        (should (equal "Mine" (get-text-property 0 'help-echo (harness-ui-decision-button "d-on" 'done "Mine"))))
        ;; Ended: nothing, as for any decision.
        (should-not (harness-ui-decision-button "d-end" 'changed))
        (should-not (harness-ui-decision-button "d-end" 'gone))
        ;; A click moves that decision, as it does any.
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (method params _callback &optional _on-error)
                     (push (list method params) sent))))
          (with-temp-buffer
            (insert off " " on)
            (goto-char (point-min))
            (harness-ui-action-push)
            (should (equal '("_harness/decision/undo" (:id "d-on")) (car sent)))
            (goto-char (1- (point-max)))
            (harness-ui-action-push)
            (should (equal '("_harness/decision/redo" (:id "d-off")) (car sent))))))
      ;; The words of the others.
      (should (equal "[Undo]" (harness-ui-decision-button "d-p" 'done)))
      (should (equal "[Redo]" (harness-ui-decision-button "d-c" 'undone)))
      (should (equal "[Undo]" (harness-ui-decision-button "d-nowhere" 'done)))
      (should (equal "[Redo]" (harness-ui-decision-button "d-nowhere" 'undone)))
      (should (equal '("[Turn off]" "[Turn on]" "[Undo]" "[Redo]" "[Undo]" "[Redo]")
                     (list (harness-ui-decision-label "d-on" 'undo) (harness-ui-decision-label "d-on" 'redo)
                           (harness-ui-decision-label "d-p" 'undo) (harness-ui-decision-label "d-c" 'redo)
                           (harness-ui-decision-label nil 'undo) (harness-ui-decision-label "d-nowhere" 'redo))))
      ;; Only a switch's notes keep their text while it is off.
      (should-not (harness-ui-decision-strikes-p "d-on"))
      (should-not (harness-ui-decision-strikes-p "d-off"))
      (should (harness-ui-decision-strikes-p "d-p"))
      (should (harness-ui-decision-strikes-p "d-c"))
      (should (harness-ui-decision-strikes-p "d-nowhere"))
      (should (harness-ui-decision-strikes-p nil))
      ;; The table says it, so a kind of another module can read as a switch too.
      (let ((harness-ui-decision-labels '((cowboy :undo "[Ask again]" :redo "[Stop asking]" :strike nil)
                                          (permission :undo "[Revoke]"))))
        (should (equal "[Ask again]" (harness-ui-decision-label "d-c" 'undo)))
        (should (equal "[Stop asking]" (harness-ui-decision-label "d-c" 'redo)))
        (should-not (harness-ui-decision-strikes-p "d-c"))
        ;; A key left out reads as usual.
        (should (equal "[Revoke]" (harness-ui-decision-label "d-p" 'undo)))
        (should (equal "[Redo]" (harness-ui-decision-label "d-p" 'redo)))
        (should (harness-ui-decision-strikes-p "d-p"))
        ;; The precompact entry is gone from this table: it reads as any decision.
        (should (equal "[Undo]" (harness-ui-decision-label "d-on" 'undo)))
        (should (harness-ui-decision-strikes-p "d-on"))))))

(ert-deftest harness-ui-decisions-module-starts-and-stops ()
  "The module fetches the cache at once when the UI is connected already.
Stopped, it follows nothing more and empties the cache, which the views
hear.  A harness that keeps no decisions leaves the cache as it is, and
nothing is said of it."
  (harness-ui-decisions-test-with
    (let ((id (plist-get (harness-ui-decisions-test--record "Always testing") :id)))
      (harness-test-wait (lambda () (harness-ui-decision id)) 5 "the decision cached")
      (harness-ui-decisions--shutdown)
      (should-not (harness-ui-decision id))
      (should (equal '(nil nil) (car harness-ui-decisions-test--changes)))
      (should-not (memq #'harness-ui-decisions--on-event harness-ui-event-functions))
      (should-not (memq #'harness-ui-decisions-refresh harness-ui-connected-hook))
      ;; Started while connected: fetched at once.
      (harness-ui-decisions--init)
      (should (memq #'harness-ui-decisions--on-event harness-ui-event-functions))
      (should (memq #'harness-ui-decisions-refresh harness-ui-connected-hook))
      (harness-test-wait (lambda () (harness-ui-decision id)) 5 "the fetch at start")
      ;; A harness without decisions: the fetch fails, quietly.
      (harness-unregister-method 'decision/list)
      (setq harness-ui-decisions-test--changes nil)
      (let ((shown nil) (failed nil) (fetched nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (when format-string (push (apply #'format format-string args) shown)))))
          (harness-ui-decisions-refresh (lambda (_) (setq fetched t)))
          ;; Answered in order: once this one failed, the fetch has too.
          (harness-then (harness-ui-request "_harness/decision/list" nil)
                        #'ignore (lambda (_) (setq failed t)))
          (harness-test-wait (lambda () failed) 5 "the failed fetch"))
        (should-not fetched)
        (should-not shown)
        (should-not harness-ui-decisions-test--changes)
        (should (harness-ui-decision id))))))

(provide 'harness-ui-decisions-test)
;;; harness-ui-decisions-test.el ends here
