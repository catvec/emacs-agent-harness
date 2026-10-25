;;; harness-ui-cowboy.el --- The cold-cache question in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; A message to a session whose prompt cache went cold waits while the
;; harness asks what goes first (harness-cowboy.el): a brief summary, a
;; summary, a transcript file, a fresh start, the whole conversation as
;; it is, or not now.  The question is a pending question like any
;; other; its payload's `:cowboy' says when the cache lapsed (or that it
;; is held for a model the session no longer uses, or that a redaction
;; dropped it, and when), what carrying on costs and what each choice
;; costs, a dropped cache being compared with no cached price, as none
;; can be had.  This module draws it as a panel of its own, in place of
;; the ordinary question panel (`harness-ui-pending-panel-functions'), in
;; the chat and in a popout of it.
;;
;; The panel is the one that asks how to carry a conversation over
;; (harness-ui-carry.el), which the model switch uses too
;; (harness-ui-handoff.el): this module only says what to put in it --
;; why the cache is cold, which message waits, what resending costs
;; against the cache it lost -- and what an answer does.  The choices,
;; their keys and their wording are those of harness-carry.el, as the
;; harness sends them; what the payload leaves out of one is the table's.
;;
;; A key answers once -- b, s, t, f, c, i -- and its capital always: B,
;; S, T, F, C or I makes the choice `harness-cowboy-default' and stops
;; the asking (`harness-cowboy-ask'), saved as any setting is.  i
;; ignores the cold cache: the whole conversation goes and nothing is
;; added to it.  q answers not now: the message waits, and goes with the
;; next one.  The keys work while point is on the panel, a click on a
;; choice from anywhere; digits pick an option as on any question, and
;; text typed in the box answers it too ("transcript", "always brief");
;; in the box, where the keys type, C-c . and a key press it on the
;; panel (`harness-compose-panel-key'), which the panel's last line says.
;; Whatever is chosen, the model can search and read the conversation
;; left out with the session_history tool, which the panel says when
;; the session has it.
;;
;; The cache panel (harness-ui-cache.el) stays away while the question
;; waits: the question says all it would, and more.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-carry)
(require 'harness-ui)
(require 'harness-ui-pending)
(require 'harness-ui-carry)

(defgroup harness-ui-cowboy nil
  "Asking what goes first when a message meets a cold prompt cache."
  :group 'harness-ui)

;;;; Reading the question

(defun harness-ui-cowboy--info (r)
  "Return the `:cowboy' of question record R, or nil for an ordinary question."
  (let ((info (plist-get r :cowboy)))
    (and (consp info) info)))

(defun harness-ui-cowboy--choice (info way)
  "Return the choice of WAY for the panel of INFO.
What INFO says of it -- its label, wording, key, cost, writer and the
context after it -- wins; what it leaves out is the table's
\(`harness-carry-ways'), and its cost, writer and context after are
nil then."
  (let* ((name (symbol-name way))
         (entry (cl-find name (append (plist-get info :choices) nil)
                         :key (lambda (c) (format "%s" (plist-get c :choice))) :test #'equal))
         (choice (harness-carry-choice way)))
    (dolist (prop '(:label :what :key :cost-text :by))
      (when-let* ((text (harness-ui-carry-text (plist-get entry prop))))
        (setq choice (plist-put choice prop text))))
    (dolist (prop '(:cost :after))
      (when (numberp (plist-get entry prop))
        (setq choice (plist-put choice prop (plist-get entry prop)))))
    choice))

(defun harness-ui-cowboy--dropped (info)
  "Return when a redaction dropped the cache INFO speaks of, or nil.
That is INFO's `:dropped', a moment.  A cache held for another model
\(`:cache-model-label') is cold for that reason, whatever became of it:
the model the session uses now has none of it either way, so it reads
as that."
  (let ((dropped (plist-get info :dropped)))
    (and (numberp dropped)
         (not (harness-ui-carry-text (plist-get info :cache-model-label)))
         dropped)))

(defun harness-ui-cowboy-waiting-p (session-id)
  "Non-nil while SESSION-ID waits on the question about its cold cache.
Either the requests this UI knows of say so, or the session's own
pending list, as the UI last heard it."
  (or (cl-some #'harness-ui-cowboy--info (harness-ui-pending-items session-id))
      (cl-some (lambda (item) (plist-get (plist-get item :payload) :cowboy))
               (append (plist-get (harness-ui-session session-id) :pending) nil))))

;;;; Answering

(defun harness-ui-cowboy-answer (session-id pid choice &optional always)
  "Answer the cold-cache question PID of SESSION-ID with CHOICE.
CHOICE is a choice's name, such as \"brief\"; ALWAYS non-nil makes it
the default and stops the asking (not for \"hold\")."
  (harness-ui-pending-answer-question
   session-id pid (if (and always (not (equal choice "hold"))) (concat "always " choice) choice))
  (when (and always (not (equal choice "hold")))
    (message "%s from now on, without asking; harness-cowboy-ask turns asking back on"
             (harness-carry-label (harness-carry-way choice)))))

(defun harness-ui-cowboy--keymap (session-id pid)
  "Return the keymap of the panel of question PID of SESSION-ID.
A choice's key answers with it, its capital always; the digits of any
question pick an option, under them."
  (harness-ui-carry-keymap
   (list :choices (mapcar #'harness-carry-choice (harness-carry-names))
         :always t
         :answer (lambda (choice always) (harness-ui-cowboy-answer session-id pid choice always)))
   harness-ui-pending-question-map))

;;;; The panel

(defun harness-ui-cowboy--sender (from)
  "Return who sent the message waiting, FROM, as a noun phrase.
Another session's agent goes by its session's name, as the chat names
it (now, else when it wrote, else a short id): a session link
\(`harness-ui-session-link') that opens the session."
  (pcase (harness-sender-kind from)
    ('nil "your message")
    ('session
     (let* ((id (plist-get from :id))
            (label (or (harness-ui-carry-text (plist-get (and (stringp id) (harness-ui-session id)) :name))
                       (harness-ui-carry-text (plist-get from :name))
                       (and (stringp id) (substring id 0 (min 8 (length id))))
                       "?"))
            (shown (format "“%s”" label)))
       (concat "message from session "
               (if (stringp id)
                   (harness-ui-session-link id shown (format "Open the session %s" label))
                 shown))))
    (_ (format "message from %s" (harness-sender-description from)))))

(defun harness-ui-cowboy--detail (info now)
  "Return what the heading of the panel for INFO says, drawn at NOW.
It says why the cache is cold: it is held for another model, a
redaction dropped it (`:dropped'), or it lapsed (`:expires'), with the
time of the last two.  Clock times only, never ages, so it stays true
while it shows."
  (let* ((expires (plist-get info :expires))
         (dropped (harness-ui-cowboy--dropped info))
         (context (plist-get info :context))
         (stale (harness-ui-carry-text (plist-get info :cache-model-label)))
         (model (or (harness-ui-carry-text (plist-get info :model-label))
                    (and (plist-get info :model) (harness-ui-model-label (plist-get info :model))))))
    (string-join
     (delq nil (append
                (list (cond (stale (format "held for %s, not %s" stale model))
                            (dropped
                             (format "dropped by a redaction at %s" (harness-ui-format-clock dropped now)))
                            ((numberp expires)
                             (format "since %s" (harness-ui-format-clock expires now)))))
                (unless stale (list model))
                (list (and (numberp context) (> context 0)
                           (format "~%s tokens" (harness-format-tokens context))))))
     " · ")))

(defun harness-ui-cowboy--rows (info)
  "Return the labelled facts of the panel for INFO.
Which message waits, and what resending costs.  Where a lapsed cache is
compared with the price it would have cost cached, a cache a redaction
dropped is not: none can be had."
  (let* ((preview (harness-ui-carry-text (plist-get info :preview)))
         (carry (plist-get info :carry-on))
         (cached (plist-get info :carry-on-cached))
         (waiting (concat (harness-ui-cowboy--sender (plist-get info :from))
                          (if preview (format " · “%s”" (harness-truncate-end preview 120)) ""))))
    (delq nil
          (list (list "Waiting" waiting)
                (and (not (harness-ui-cowboy--dropped info)) (numberp carry) (numberp cached) (> carry cached)
                     (list "Resend" (format "%s uncached against %s cached"
                                            (harness-format-cost carry) (harness-format-cost cached))))))))

(defun harness-ui-cowboy--spec (session-id r &optional now)
  "Return the spec of the panel of question record R, of SESSION-ID.
See `harness-ui-carry-panel-string'.  NOW is the current time by default."
  (let* ((info (harness-ui-cowboy--info r))
         (pid (plist-get r :id))
         (now (or now (float-time))))
    (list :id pid
          :icon 'harness-icon-clock :title "Prompt cache cold"
          :detail (harness-ui-cowboy--detail info now)
          :rows (harness-ui-cowboy--rows info)
          :ask "Choose what goes first"
          :choices (mapcar (lambda (way) (harness-ui-cowboy--choice info way)) (harness-carry-names))
          :default (plist-get info :default)
          :always t
          :footer (list (and (harness-json-true-p (plist-get info :history))
                             "Left out: searchable with session_history")
                        "Type a choice below: “transcript”, “always brief”")
          :answer (lambda (choice always) (harness-ui-cowboy-answer session-id pid choice always)))))

(defun harness-ui-cowboy--string (spec)
  "Return the panel of SPEC, made by `harness-ui-cowboy--spec', as a string."
  (let ((string (harness-ui-carry-panel-string spec)))
    (add-text-properties 0 (length string) (list 'harness-ui-cowboy-panel (plist-get spec :id)) string)
    string))

(defun harness-ui-cowboy-panel-string (session-id r &optional now)
  "Return the panel of the cold-cache question record R of SESSION-ID.
NOW is the current time by default."
  (harness-ui-cowboy--string (harness-ui-cowboy--spec session-id r now)))

(defun harness-ui-cowboy--insert-panel (r)
  "Insert the panel of request record R when it is the cold-cache question.
On `harness-ui-pending-panel-functions': return non-nil when it did.
The panel is made whole before anything is inserted, so a failure
leaves the ordinary question panel to show instead."
  (when-let* (((and (equal (plist-get r :kind) "question") (harness-ui-cowboy--info r)))
              (session-id (harness-ui-pending-session))
              (spec (condition-case err
                        (harness-ui-cowboy--spec session-id r)
                      (error (message "Cold-cache panel: %s" (harness-error-short-message err)) nil)))
              (text (condition-case err
                        (harness-ui-cowboy--string spec)
                      (error (message "Cold-cache panel: %s" (harness-error-short-message err)) nil))))
    (let ((start (point))
          (pid (plist-get r :id)))
      (insert text)
      (harness-ui-pending-decorate start (point) pid
                                   (harness-ui-carry-keymap spec harness-ui-pending-question-map))
      t)))

;;;; Setup

(defun harness-ui-cowboy--init ()
  "Draw the cold-cache question as a panel of its own."
  (add-hook 'harness-ui-pending-panel-functions #'harness-ui-cowboy--insert-panel))

(harness-define-module 'ui-cowboy
  :doc "The cold-cache question as a panel: what goes first, at what cost."
  :requires '(ui ui-pending ui-carry)
  :init #'harness-ui-cowboy--init)

(provide 'harness-ui-cowboy)
;;; harness-ui-cowboy.el ends here
