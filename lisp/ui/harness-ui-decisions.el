;;; harness-ui-decisions.el --- Lasting decisions in the UI: their undo and redo  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness keeps every answer that lasts as a decision
;; (harness-decisions.el): a permission answer for the session or
;; always, the cold-cache question answered "always" with a choice.  A
;; decision is `done' while what it set is in effect, `undone' once it
;; was taken back, and ends `changed' or `gone' once something else
;; changed what it set; decisions are the harness's, not a session's,
;; so one made in one session can be undone or redone from any other.
;;
;; The UI keeps the decisions in a cache, fetched whole when it connects
;; and after the harness reloads, then kept current by `decision/changed',
;; which the harness announces for every decision kept and every undo or
;; redo, whichever session it came from.  `harness-ui-decision' reads a
;; decision from it, and `harness-ui-decision-functions' hears every
;; change: the chat draws again the notes that refer to the decision, in
;; every session that shows one (harness-ui-chat.el).
;;
;; A decision offers one button, which says what a click does:
;; [Undo] while it is done, [Redo] while it is undone, nothing once it
;; ended (`harness-ui-decision-button').  The buttons run
;; `harness-decision-undo' and `harness-decision-redo', which M-x also
;; offers: they ask which decision, of those that can move that way,
;; newest first, so a decision can be moved even where no note of it is
;; on screen.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-ui-decisions--cache (make-hash-table :test 'equal)
  "Decision id -> the decision, as the harness last announced it.
Its `:state' and `:kind' are symbols (`harness-ui-decisions--read').")

(defvar harness-ui-decision-functions nil
  "Functions called with (ID DECISION) after a cached decision changes.
DECISION is the decision as cached now.  ID and DECISION are nil after
the whole cache was fetched again, or emptied.")

;;;; The cache

(defun harness-ui-decisions--read (decision)
  "Return DECISION, as the harness sent it, with its state and kind symbols.
Over the wire they come as strings.  Nil when DECISION is none: it has
no id, or no state the harness knows (`harness-decision-states')."
  (let ((id (and (consp decision) (plist-get decision :id)))
        (state (and (consp decision) (harness-decision-state (plist-get decision :state))))
        (kind (and (consp decision) (plist-get decision :kind))))
    (when (and (stringp id) (not (string-empty-p id)) state)
      (append (list :state state
                    :kind (if (and (stringp kind) (not (string-empty-p kind))) (intern kind) kind))
              (harness-plist-remove decision :state :kind)))))

(defun harness-ui-decision (id)
  "Return the lasting decision ID as the harness last announced it, or nil.
The plist is as `decision/record' describes it, its `:state' and
`:kind' symbols: `:text' says what it does, `:state' where it stands,
`:result' how its last undo or redo went.  Nil when the UI has not
heard of it: the harness forgot it as too old, or keeps no decisions."
  (and (stringp id) (gethash id harness-ui-decisions--cache)))

(defun harness-ui-decisions (&optional state)
  "Return the cached decisions, newest first; with STATE, those in STATE only."
  (let (out)
    (maphash (lambda (_ d) (when (or (null state) (eq state (plist-get d :state))) (push d out)))
             harness-ui-decisions--cache)
    (sort out (lambda (a b)
                (> (let ((at (plist-get a :at))) (if (numberp at) at 0))
                   (let ((at (plist-get b :at))) (if (numberp at) at 0)))))))

(defun harness-ui-decisions-store (decision)
  "Cache DECISION, as the harness sent it, and run `harness-ui-decision-functions'.
Return the decision as cached, or nil when DECISION is none."
  (when-let* ((d (harness-ui-decisions--read decision)))
    (puthash (plist-get d :id) d harness-ui-decisions--cache)
    (run-hook-with-args 'harness-ui-decision-functions (plist-get d :id) d)
    d))

(defun harness-ui-decisions-refresh (&optional callback)
  "Fetch every decision the harness keeps into the cache, then call CALLBACK.
CALLBACK, when given, gets the decisions as they came.  The cache is
replaced whole, and `harness-ui-decision-functions' runs with nil.  A
harness that keeps no decisions -- an older one, or one without the
decisions module -- answers with an error, which leaves the cache as
it is: there is nothing to say about it."
  (harness-ui-call "_harness/decision/list" nil
                   (lambda (decisions)
                     (clrhash harness-ui-decisions--cache)
                     (dolist (decision (append decisions nil))
                       (when-let* ((d (harness-ui-decisions--read decision)))
                         (puthash (plist-get d :id) d harness-ui-decisions--cache)))
                     (run-hook-with-args 'harness-ui-decision-functions nil nil)
                     (when callback (funcall callback decisions)))
                   #'ignore))

;;;; Undo and redo

(defun harness-ui-decisions--move (id way)
  "Ask the harness to move decision ID one step WAY, `undo' or `redo'.
The echo area says how it went, in the harness's words, and the
decision the harness answers with is cached at once; the harness also
announces it (`decision/changed'), for every view and every UI."
  (harness-ui-call (format "_harness/decision/%s" way) (list :id id)
                   (lambda (result)
                     (harness-ui-decisions-store (plist-get result :decision))
                     (message "%s" (or (plist-get result :message)
                                       (if (eq way 'undo) "Undone" "Redone"))))))

(defun harness-ui-decisions--label (decision)
  "Return how DECISION reads among others to choose from.
That is its text, then where and when it was made."
  (let* ((session (harness-ui-session (plist-get decision :session)))
         (name (plist-get session :name))
         (at (plist-get decision :at))
         (where (delq nil (list (and (stringp name) (not (string-empty-p name)) name)
                                (and (numberp at) (format-time-string "%b %-d %H:%M" at))))))
    (if where
        (format "%s (%s)" (plist-get decision :text) (string-join where ", "))
      (plist-get decision :text))))

(defun harness-ui-decisions--choose (prompt state)
  "Ask with PROMPT for one of the cached decisions in STATE; return its id.
The newest are offered first.  None in STATE is a `user-error'."
  (let ((choices nil))
    (dolist (d (harness-ui-decisions state))
      (let ((label (harness-ui-decisions--label d)))
        (when (assoc label choices)
          (setq label (format "%s [%s]" label (plist-get d :id))))
        (push (cons label (plist-get d :id)) choices)))
    (setq choices (nreverse choices))
    (unless choices
      (user-error (if (eq state 'done) "Nothing to undo" "Nothing to redo")))
    (cdr (assoc (completing-read
                 prompt
                 (lambda (string pred action)
                   (if (eq action 'metadata)
                       '(metadata (display-sort-function . identity)
                                  (cycle-sort-function . identity))
                     (complete-with-action action choices string pred)))
                 nil t)
                choices))))

;;;###autoload
(defun harness-decision-undo (id)
  "Undo the lasting decision ID, whichever session it was made in.
The harness takes back what it set -- the rule, the directory, the
cold-cache default -- if nothing changed that since; otherwise the
decision ends and what is there stays.  The echo area says which.
Interactively, ask which decision, of those in effect, newest first."
  (interactive (list (harness-ui-decisions--choose "Undo: " 'done)))
  (harness-ui-decisions--move id 'undo))

;;;###autoload
(defun harness-decision-redo (id)
  "Redo the lasting decision ID, undone before, whichever session made it.
The harness sets again what the decision had set, if nothing took its
place since; otherwise the decision ends and what is there stays.  The
echo area says which.  Interactively, ask which decision, of those
undone, newest first."
  (interactive (list (harness-ui-decisions--choose "Redo: " 'undone)))
  (harness-ui-decisions--move id 'redo))

;;;; The button

(defun harness-ui-decision-help (id way)
  "Return what the WAY button of decision ID says it does, WAY `undo' or `redo'."
  (pcase (cons (plist-get (harness-ui-decision id) :kind) way)
    ('(permission . undo) "Take back what this answer recorded")
    ('(permission . redo) "Record this answer again")
    ('(cowboy . undo) "Ask again when the prompt cache is cold")
    ('(cowboy . redo) "Make this the default again, without asking")
    (`(,_ . undo) "Take this decision back")
    (_ "Make this decision again")))

(defun harness-ui-decision-button (id state &optional help)
  "Return the button decision ID offers in STATE, or nil when it offers none.
It is [Undo] while STATE is `done', which runs `harness-decision-undo',
and [Redo] while it is `undone', which runs `harness-decision-redo'; an
ended decision offers nothing.  STATE is the decision's, or what a note
says of it when the cache does not know it.  HELP is the tooltip, by
default `harness-ui-decision-help'.  A click or RET runs it, in any
buffer (`harness-ui-action-button')."
  (pcase state
    ('done (harness-ui-action-button "[Undo]" (lambda () (harness-decision-undo id))
                                     :help (or help (harness-ui-decision-help id 'undo))))
    ('undone (harness-ui-action-button "[Redo]" (lambda () (harness-decision-redo id))
                                       :help (or help (harness-ui-decision-help id 'redo))))))

;;;; The module

(defun harness-ui-decisions--on-event (event args)
  "Follow the harness's decisions: EVENT with ARGS, from `_harness/event'.
`decision/changed' brings a decision as it is now; after
`harness/reloaded' the cache is fetched again."
  (pcase event
    ("decision/changed" (harness-ui-decisions-store (car args)))
    ("harness/reloaded" (harness-ui-decisions-refresh))))

(defun harness-ui-decisions--init ()
  "Keep the decisions cache: fetch it on connect and follow the harness.
When the UI is connected already, fetch it now."
  (add-hook 'harness-ui-event-functions #'harness-ui-decisions--on-event)
  (add-hook 'harness-ui-connected-hook #'harness-ui-decisions-refresh)
  (when (harness-ui-connected-p)
    (harness-ui-decisions-refresh)))

(defun harness-ui-decisions--shutdown ()
  "Stop following the decisions, and empty the cache.
The views then draw their notes without buttons."
  (remove-hook 'harness-ui-event-functions #'harness-ui-decisions--on-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-decisions-refresh)
  (clrhash harness-ui-decisions--cache)
  (run-hook-with-args 'harness-ui-decision-functions nil nil))

(harness-define-module 'ui-decisions
  :doc "Lasting decisions in the UI: the cache the notes' [Undo] and [Redo] read, and the commands that move one."
  :requires '(ui)
  :init #'harness-ui-decisions--init
  :shutdown #'harness-ui-decisions--shutdown)

(provide 'harness-ui-decisions)
;;; harness-ui-decisions.el ends here
