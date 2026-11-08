;;; harness-decisions.el --- Lasting decisions, and their undo and redo  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some answers last beyond the moment they are given.  A permission
;; prompt answered for the session or always records a rule or grants a
;; directory (harness-perms.el); the cold-cache question answered
;; "always" with a choice makes that choice the default and stops the
;; asking (harness-cowboy.el).  Each such answer is a decision, kept
;; here: what it does in words, what it changed as data, and where it
;; stands.
;;
;; A decision is a switch with a cursor: `done' while what it changed is
;; in effect, `undone' once it was taken back.  Undo moves the cursor
;; back and redo forward, each done by the decision's kind
;; (`harness-decisions-define-kind'), and each only while the setting
;; still holds what the other move left there: undo while the rule, the
;; directory or the default is as the decision made it, redo while it is
;; as the undo left it.  Anything else -- the rule edited in Settings,
;; another answer that recorded it again, the default changed by hand --
;; ends the decision: `changed', or `gone' when what it changed is no
;; longer there at all, with a sentence saying so.  An ended decision
;; offers nothing more.  So a decision has a button that says what a
;; click does: [Undo] while done, [Redo] while undone.  One whose kind
;; kept the prompt that asked it (`decision/record' `:change') offers
;; [Change] as well: the prompt opens again and the new answer replaces
;; what the decision records (`decision/change').  A click never takes
;; back a change somebody else made, and two decisions never fight over
;; one setting: the one that holds it is the one whose button works.
;;
;; The decisions are the harness's, not a session's: one made in one
;; session can be undone or redone from any other.  Notes refer to one
;; by its id (harness-util.el): the hint where it was made, in its
;; `:meta' `:decision', and any hint or tool result written later where
;; it took effect, in its `:meta' `:decided-by' -- a cold cache
;; compacted unasked as the default it set says, a call its rule denied.
;; `decision/changed' announces every decision kept and every move, and
;; the chat draws each note's button from the decision as last announced
;; (harness-ui-decisions.el), in every session that shows one.
;;
;; The newest `harness-decisions-kept' decisions are kept in the state
;; directory (`harness-decisions--store'), so the buttons still work
;; after a restart.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-util)

(defconst harness-decisions-kept 500
  "How many lasting decisions are kept, the newest.
An older one is forgotten: the notes about it then offer no button.")

(defconst harness-decisions--store "decisions.json"
  "The document the decisions are kept in, under `harness-state-directory'.")

(defvar harness-decisions--entries nil
  "The lasting decisions, newest first; each a plist (see `decision/record').")

(defvar harness-decisions--kinds (make-hash-table :test 'eq)
  "Kind -> (:undo FN :redo FN :change FN).
As `harness-decisions-define-kind' gives them.")

(defun harness-decisions-define-kind (kind &rest spec)
  "Make decisions of KIND, a symbol, undone, redone and changed as SPEC says.
SPEC is (:undo FN :redo FN :change FN).  Each FN is called with the
decision, a plist as `decision/record' describes, whose `:record' says
what it changed.  The undo and redo FNs return (OUTCOME . MESSAGE).
The undo's OUTCOME is `undone' once it took the decision back, the
redo's `done' once it put it in effect again; either is `changed' when
what the decision changed was changed since by something else, which is
then left as it is, or `gone' when it is no longer there at all.
MESSAGE says what happened in a sentence, or is nil for the default one.
A FN that signals moves nothing.  The change FN asks the user again for
the answer the decision keeps, and returns (:session SESSION-ID :pending
PID); it changes nothing until that answer arrives.  Without it, and
without the prompt saved with the decision, the decision offers no
change.  The module that owns the setting defines its kind as it loads;
a decision of a kind no module defines can be neither undone nor
redone.  Return KIND."
  (puthash kind spec harness-decisions--kinds)
  kind)

(defun harness-decisions--sym (value)
  "Return VALUE, a symbol or its name, as a symbol, or nil."
  (cond ((and (stringp value) (not (string-empty-p value))) (intern value))
        ((and value (symbolp value) (not (memq value '(t :false :null)))) value)))

(defun harness-decisions--find (id)
  "Return the decision ID, or nil."
  (and (stringp id)
       (cl-find id harness-decisions--entries :key (lambda (d) (plist-get d :id)) :test #'equal)))

(defun harness-decisions--new-id ()
  "Return an id no decision has."
  (let (id)
    (while (or (null id) (harness-decisions--find id))
      (setq id (concat "d-" (harness-short-id 8))))
    id))

;;;; Keeping them

(defun harness-decisions--save ()
  "Write the decisions to the store; a failure is logged."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (harness-call 'store/save harness-decisions--store
                      (list :decisions (harness-json-array harness-decisions--entries)))
      (error (harness-log 'warn "decisions: saving failed: %s" (harness-error-message err))))))

(defun harness-decisions--public (decision)
  "Return DECISION as the harness sends it, without the prompt it kept.
`:changeable' tells that [Change] is offered, and `decision/change'
opens the prompt in the harness; the snapshot itself -- the call's
input among it -- stays here."
  (and decision (harness-plist-remove decision :change)))

(defun harness-decisions--change-p (decision)
  "Non-nil when DECISION can ask again for the answer it keeps.
That is when its kind defines a change function and the prompt that
asked the question was saved with it.  A decision made before prompts
were saved, and one of a kind no module here knows, cannot."
  (and (functionp (plist-get (gethash (plist-get decision :kind) harness-decisions--kinds) :change))
       (consp (plist-get decision :change))
       t))

(defun harness-decisions--read (entry)
  "Return ENTRY, a decision as the store gave it back, or nil when it is none.
Its kind and state are symbols again, and `:changeable' a boolean."
  (let ((id (plist-get entry :id))
        (kind (harness-decisions--sym (plist-get entry :kind)))
        (state (harness-decision-state (plist-get entry :state)))
        (text (plist-get entry :text))
        (changeable (harness-json-true-p (plist-get entry :changeable))))
    (when (and (stringp id) kind state (stringp text))
      (append (list :kind kind :state state :changeable (if changeable t :false))
              (harness-plist-remove entry :kind :state :changeable)))))

(defun harness-decisions--load ()
  "Read the decisions back from the store."
  (let ((data (and (harness-method-exists-p 'store/load)
                   (ignore-errors (harness-call 'store/load harness-decisions--store)))))
    (setq harness-decisions--entries
          (and (listp data)
               (delq nil (mapcar #'harness-decisions--read
                                 (cl-remove-if-not #'listp (plist-get data :decisions))))))))

(defun harness-decisions--update (id changes)
  "Merge CHANGES into decision ID; keep it, announce it and return it.
Nil when there is no decision ID."
  (let (new)
    (setq harness-decisions--entries
          (mapcar (lambda (d)
                    (if (equal (plist-get d :id) id)
                        (setq new (harness-plist-merge d changes))
                      d))
                  harness-decisions--entries))
    (when new
      (harness-decisions--save)
      (harness-emit 'decision/changed (harness-decisions--public new)))
    new))

(harness-defmethod decision/record (kind session-id text record &rest opts)
  "Keep a lasting decision of KIND, made in SESSION-ID; return it.
TEXT says what it does, as the note that tells of it reads (\"Always
allowing every bash call, in every session\"), and RECORD is what KIND
needs to undo and redo it (see `harness-decisions-define-kind').  The
decision starts `done': what it changed is in effect.  OPTS: `:node'
the note in SESSION-ID's transcript that tells of it, when it is
written already (`decision/attach' names it later); `:state' another
state to start in and `:result' the sentence that goes with it, for a
decision kept only now of a note written before decisions were (see
harness-perms.el); `:change' the prompt that asked the answer, as its
kind needs to ask it again (`harness-decisions-define-kind'), which
makes the decision `:changeable'; `:at' when it was made.
`decision/changed' announces it.  Only the newest
`harness-decisions-kept' are kept.  A decision is the plist

  (:id ID :kind KIND :text TEXT :record RECORD
   :session SESSION-ID :node NODE-ID :at FLOAT
   :state done|undone|changed|gone :result TEXT :moved-at FLOAT
   :changeable BOOL :change SNAPSHOT)

where `:result' says how its last undo or redo went, `:moved-at' when,
`:changeable' tells whether it offers [Change], and `:change' is what
that asks again with.  Both are left out of a decision that offers no
change.  `:change' is the harness's alone: what is announced and
returned to clients has `:changeable' but not the prompt."
  (let* ((kind (harness-decisions--sym kind))
         (state (or (harness-decision-state (plist-get opts :state)) 'done))
         (change (plist-get opts :change))
         (changeable (and change
                          (functionp (plist-get (gethash kind harness-decisions--kinds) :change)))))
    (unless kind
      (signal 'harness-error (list "A decision needs a kind")))
    (unless (and (stringp text) (not (string-blank-p text)))
      (signal 'harness-error (list "A decision needs a text that says what it does")))
    (let ((decision (append
                     (list :id (harness-decisions--new-id) :kind kind :text text :record record
                           :session session-id :node (plist-get opts :node)
                           :at (or (plist-get opts :at) (float-time))
                           :state state :result (plist-get opts :result) :moved-at nil
                           :changeable (if changeable t :false))
                     (and changeable (list :change change)))))
      (push decision harness-decisions--entries)
      (when (> (length harness-decisions--entries) harness-decisions-kept)
        (setq harness-decisions--entries (seq-take harness-decisions--entries harness-decisions-kept)))
      (harness-decisions--save)
      (harness-emit 'decision/changed (harness-decisions--public decision))
      decision)))

(harness-defmethod decision/attach (id session-id node-id)
  "Name NODE-ID of SESSION-ID as the note that tells of decision ID.
That is the note written right after the decision was kept, whose
`:meta' `:decision' names it.  `decision/changed' announces it.  Return
the decision; signal a `harness-error' when there is no decision ID."
  (or (harness-decisions--update id (list :session session-id :node node-id))
      (signal 'harness-error (list (format "No decision %s" id)))))

(harness-defmethod decision/get (id)
  "Return the lasting decision ID, a plist (see `decision/record'), or nil.
Its `:changeable' says whether it offers [Change]; the prompt it kept
stays in the harness, and `decision/change' opens it."
  (harness-decisions--public (harness-decisions--find id)))

(harness-defmethod decision/list (&rest opts)
  "Return the lasting decisions kept, newest first.
OPTS: `:kind' only those of that kind; `:state' only those in that
state (see `harness-decision-states'); `:session' only those made in
that session; `:limit' at most that many."
  (let* ((kind (harness-decisions--sym (plist-get opts :kind)))
         (state (harness-decision-state (plist-get opts :state)))
         (session (plist-get opts :session))
         (limit (plist-get opts :limit))
         (out (cl-remove-if-not
               (lambda (d)
                 (and (or (null kind) (eq kind (plist-get d :kind)))
                      (or (null state) (eq state (plist-get d :state)))
                      (or (null session) (equal session (plist-get d :session)))))
               harness-decisions--entries)))
    (mapcar #'harness-decisions--public
            (if (and (natnump limit) (> (length out) limit)) (seq-take out limit) out))))

;;;; Undo and redo

(defun harness-decisions--downcase-first (text)
  "Return TEXT with its first letter in lower case."
  (if (string-empty-p text) text (concat (downcase (substring text 0 1)) (substring text 1))))

(defun harness-decisions--moved-text (decision outcome way)
  "Return the default sentence for DECISION's WAY, undo or redo, ending OUTCOME."
  (let ((what (harness-decisions--downcase-first (plist-get decision :text))))
    (pcase outcome
      ('undone (concat "Undone: no longer " what))
      ('done (concat "Redone: " what))
      ('changed (format "Not %s: it was changed since, so it stays as it is"
                        (if (eq way 'undo) "undone" "redone")))
      (_ (format "Nothing to %s: it is no longer there" way)))))

(defun harness-decisions--idle-text (decision way)
  "Return why WAY, undo or redo, leaves DECISION as it is.
Its last result says so when it has one."
  (let ((result (plist-get decision :result)))
    (if (and (stringp result) (not (string-empty-p result)))
        result
      (pcase (plist-get decision :state)
        ('done (format "Nothing to %s: it is in effect" way))
        ('undone (format "Nothing to %s: it was undone already" way))
        (_ (format "Nothing to %s: it offers nothing more" way))))))

(defun harness-decisions--move (id way)
  "Move decision ID one step WAY, `undo' or `redo'; return what happened.
Only a decision `done' is undone, and only one `undone' is redone: any
other is left as it is, and the answer says why.  The decision's kind
does the move; what it says becomes the decision's state and result,
kept and announced.  Return (:outcome OUTCOME :message TEXT :decision
DECISION): OUTCOME is the decision's state after it, or `failed' when
the move could not be made (the kind signalled, or no module defines
it), which leaves the decision as it was."
  (let* ((decision (or (harness-decisions--find id)
                       (signal 'harness-error
                               (list (format "No decision %s: it was never kept, or was forgotten as too old" id)))))
         (state (harness-decision-state (plist-get decision :state)))
         (fn (plist-get (gethash (plist-get decision :kind) harness-decisions--kinds)
                        (if (eq way 'undo) :undo :redo)))
         (ends (if (eq way 'undo) '(undone changed gone) '(done changed gone))))
    (cond
     ((not (eq state (if (eq way 'undo) 'done 'undone)))
      (list :outcome state :message (harness-decisions--idle-text decision way) :decision decision))
     ((not (functionp fn))
      (list :outcome 'failed :decision decision
            :message (format "Could not %s it: no module here knows decisions of kind %s"
                             way (plist-get decision :kind))))
     (t
      (let* ((result (condition-case err
                         (funcall fn decision)
                       (error
                        (harness-log 'warn "decisions: %s of %s failed: %s" way id (harness-error-message err))
                        (cons 'failed (format "Could not %s it: %s" way (harness-error-message err))))))
             (outcome (harness-decision-state (car-safe result))))
        (if (not (memq outcome ends))
            (list :outcome 'failed :decision decision
                  :message (or (cdr-safe result) (format "Could not %s it" way)))
          (let* ((message (or (cdr result) (harness-decisions--moved-text decision outcome way)))
                 (new (harness-decisions--update id (list :state outcome :result message
                                                          :moved-at (float-time)))))
            (list :outcome outcome :message message :decision new))))))))

(harness-defmethod decision/undo (id)
  "Take back the lasting decision ID, if what it changed is still as it left it.
The decision's kind takes it back (`harness-decisions-define-kind'),
and the decision is `undone', ready to be redone; when what it changed
was changed since, by Settings or another answer, it stays as it is
and the decision ends `changed', or `gone' when it is no longer there.
A decision not `done' is left alone.  It may have been made in another
session: decisions are the harness's.  Return (:outcome OUTCOME
:message TEXT :decision DECISION), as `harness-decisions--move' says."
  (harness-decisions--move id 'undo))

(harness-defmethod decision/redo (id)
  "Put the lasting decision ID in effect again, if nothing took its place.
The decision must be `undone'.  Its kind records again what it had
recorded, while the setting is still as the undo left it, and the
decision is `done' again, ready to be undone; otherwise the decision
ends `changed' or `gone' and the setting stays as it is.  Return
\(:outcome OUTCOME :message TEXT :decision DECISION), as
`harness-decisions--move' says."
  (harness-decisions--move id 'redo))

(harness-defmethod decision/change (id)
  "Ask again for the answer lasting decision ID keeps; it changes nothing yet.
Only a decision `done' or `undone' whose kind can ask again, and which
was kept with the prompt that asked it, offers this.  Its kind opens
the original prompt again, answerable with the choices it had, and
returns (:session SESSION-ID :pending PID): the answer then replaces
what the decision records, or leaves it as it is when nobody answers.
A decision `changed' or `gone' offers no change, and neither does one
kept before prompts were saved.  Signal a `harness-error' when the
decision cannot be asked about now."
  (let* ((decision (or (harness-decisions--find id)
                       (signal 'harness-error
                               (list (format "No decision %s: it was never kept, or was forgotten as too old" id)))))
         (state (harness-decision-state (plist-get decision :state)))
         (fn (plist-get (gethash (plist-get decision :kind) harness-decisions--kinds) :change)))
    (cond
     ((not (memq state '(done undone)))
      (signal 'harness-error (list "This decision ended, so it offers no change")))
     ((not (functionp fn))
      (signal 'harness-error
              (list (format "No module here knows how to change decisions of kind %s"
                            (plist-get decision :kind)))))
     ((not (harness-decisions--change-p decision))
      (signal 'harness-error (list "This decision kept no prompt to ask again")))
     (t
      (let ((answer (condition-case err
                        (funcall fn decision)
                      (error (signal 'harness-error
                                     (list (format "Could not ask again: %s"
                                                   (harness-error-short-message err))))))))
        (unless (and (plist-get answer :session) (plist-get answer :pending))
          (signal 'harness-error (list "The original prompt could not be opened")))
        answer)))))

(harness-defmethod decision/revise (id &rest changes)
  "Merge CHANGES into lasting decision ID and announce it; return the decision.
This is how a kind replaces what its decision records once a changed
answer arrived: it keeps the id, its session and its note, and takes
the new text, record and prompt.  `:id', `:kind', `:session' and `:at'
cannot be changed.  Signal a `harness-error' when there is no decision
ID."
  (let ((changes (harness-plist-remove changes :id :kind :session :at)))
    (or (harness-decisions--update id changes)
        (signal 'harness-error (list (format "No decision %s" id))))))

;;;; The module

(defun harness-decisions--init ()
  "Read the decisions kept back from the store."
  (harness-decisions--load))

(harness-declare-event 'decision/changed "(DECISION) once a lasting decision is kept, named its note, undone, redone or changed: DECISION as it is now (see `decision/record').")

(harness-define-module 'decisions
  :doc "Lasting decisions -- answers that hold beyond their moment -- with their undo, redo and change, from any session."
  :requires '(store)
  :init #'harness-decisions--init)

(provide 'harness-decisions)
;;; harness-decisions.el ends here
