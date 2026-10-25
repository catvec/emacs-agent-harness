;;; harness-ui-handoff.el --- The question of a model switch  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI half of the handoff module (harness-handoff.el), which loads
;; with it.
;;
;; A switch to a model that keeps its own conversation (Claude Code,
;; Copilot) starts a new conversation there, so the harness asks how to
;; carry the old one over.  The question is the panel that asks the same
;; of a cold prompt cache (harness-ui-carry.el): the ways to carry a
;; conversation over, with the keys, labels and wording of
;; harness-carry.el, each with what it costs as the harness priced it
;; (`handoff/check''s `:choices'): a brief summary written by the new
;; model, a summary written by the current one, a transcript file, a fresh
;; start, or cancel.  Above them the panel says what the switch is, why
;; it loses the conversation, its risks and what the new model's cold
;; cache costs; a batch names the sessions that lose their conversation
;; and says how many change in all, and each choice costs what it costs
;; for all of them.
;;
;; Summarising on the current model is the cheap choice while that
;; model's prompt cache is warm, as it reads the conversation back from
;; it; once the cache lapsed (or is another model's) it reads all of it
;; again uncached, and the choice says so, and costs that instead
;; \(`harness-ui-handoff--cache-note').  The cache panel
;; (harness-ui-cache.el) stays away while the question is asked, and
;; draws the tail again when the cache lapses, which brings the panel up
;; to date.
;;
;; Where the panel shows is the host's (harness-ui-carry.el): the chat of
;; the session, the buffer the command ran in when that is the session
;; list or the task board, else the session list, opened for it.  A
;; switch of many sessions started anywhere therefore asks the same panel
;; in a buffer you can see, and never in the minibuffer.  Choosing runs
;; `handoff/switch' (`handoff/switch-all' for a batch) through the UI
;; connection, and the panel goes away.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-carry)
(require 'harness-ui)
(require 'harness-ui-carry)

(defgroup harness-ui-handoff nil
  "Choosing how to carry a conversation over when the model changes."
  :group 'harness-ui)

;;;; What the cache means for a summary on the current model

(defun harness-ui-handoff--cache (check now)
  "Return how CHECK's session finds the cache of the model it switches from.
`warm' while the prompt cache its requests last used is that model's
and lasts at NOW, `expired' once it lapsed, `other' when it is another
model's (the session switched since), nil when nothing is known.  See
`handoff/check''s `:cache'.  Nothing is known of the cache of a session
whose turn runs, once its stamp is past: a turn reads the cache with
every request, and the stamp of a hosted loop (Claude Code) is the turn
before's until the turn says its next request, so the cache is not
reported lapsed at a moment before the turn began."
  (let* ((cache (plist-get check :cache))
         (expires (plist-get cache :expires))
         (from (plist-get check :from)))
    (when (numberp expires)
      (cond ((not (equal (or (plist-get cache :model) from) from)) 'other)
            ((< now expires) 'warm)
            ((harness-json-true-p (plist-get check :running)) nil)
            (t 'expired)))))

(defun harness-ui-handoff--cache-note (checks &optional now)
  "Return what the caches of the sessions of CHECKS mean for a summary, or nil.
That reads each conversation back from the model's prompt cache, cheap
while the cache lasts; once it lapsed, or is another model's, the whole
conversation is paid for again uncached.  NOW is the current time by
default.  A single session whose cache lapsed is told when; when a
redaction dropped that cache (its `:cache' has `:dropped', see
`session/reset-provider') it is told that, with the moment of the drop,
as the cache panel says it.  Nil when nothing is known."
  (let* ((now (or now (float-time)))
         (states (mapcar (lambda (c) (harness-ui-handoff--cache c now)) checks))
         (cold (cl-count-if (lambda (s) (memq s '(expired other))) states))
         (n (length checks)))
    (cond
     ((= cold 0) (and (cl-every (lambda (s) (eq s 'warm)) states) "cache warm"))
     ((< cold n) (format "uncached where the cache lapsed (%d of %d)" cold n))
     ((> n 1) "caches expired · all uncached")
     ((eq (car states) 'other) "cache cold · all uncached")
     (t (let* ((cache (plist-get (car checks) :cache))
               (clock (harness-ui-format-clock (plist-get cache :expires) now)))
          (if (plist-get cache :dropped)
              (format "cache dropped at %s by a redaction · all uncached" clock)
            (format "cache expired at %s · all uncached" clock)))))))

;;;; The choices

(defun harness-ui-handoff--check-choices (check)
  "Return the choices CHECK, a `handoff/check' answer, brings.
A harness that brings none gets the table's, unpriced."
  (or (cl-remove-if-not #'consp (append (plist-get check :choices) nil))
      (mapcar (lambda (entry) (harness-carry-switch-choice (car entry))) harness-carry-switch-ways)))

(defun harness-ui-handoff--from-label (check)
  "Return the label of the model CHECK's session switches from."
  (or (harness-ui-carry-text (plist-get check :from-label))
      (harness-ui-model-label (plist-get check :from))))

(defun harness-ui-handoff--writer (way checks label)
  "Return who writes WAY, a summary, for CHECKS switching to LABEL.
The brief summary is the new model's, the summary the current model's."
  (pcase way
    ('brief (format "new model %s" label))
    ('summary (let ((froms (delete-dups (mapcar #'harness-ui-handoff--from-label checks))))
                (if (cdr froms) "each current model" (format "current model %s" (car froms)))))))

(defun harness-ui-handoff--cost (way check choice now)
  "Return what CHOICE of WAY costs for CHECK's session at NOW, in dollars, or nil.
The summary reads the conversation back from the cache while it lasts,
and costs more once it lapsed: the check says both."
  (if (and (eq way 'summary) (memq (harness-ui-handoff--cache check now) '(expired other)))
      (or (plist-get choice :cost-uncached) (plist-get choice :cost))
    (plist-get choice :cost)))

(defun harness-ui-handoff--choices (checks label &optional now)
  "Return the choices of the panel asking about CHECKS, a switch to LABEL.
The ways, keys, labels and wording are those the harness sends with the
first check; what each costs is what it costs for the sessions of all of
them (`harness-carry-total'), nothing where a price is not known.  The
summary says whether the cache it reads from still lasts, as of NOW (the
current time by default), and who writes each of the two summaries."
  (let* ((now (or now (float-time)))
         (per-check (mapcar #'harness-ui-handoff--check-choices checks)))
    (mapcar
     (lambda (choice)
       (let* ((name (plist-get choice :choice))
              (way (harness-carry-way name))
              (mine (cl-mapcar (lambda (check choices)
                                 (cons check (cl-find name choices :key (lambda (c) (plist-get c :choice))
                                                      :test #'equal)))
                               checks per-check))
              (total (harness-carry-total
                      (mapcar (lambda (pair) (harness-ui-handoff--cost way (car pair) (cdr pair) now)) mine)))
              (note (and (eq way 'summary) (harness-ui-handoff--cache-note checks now))))
         (append (list :choice name :key (plist-get choice :key) :label (plist-get choice :label)
                       :what (string-join (delq nil (list (harness-ui-carry-text (plist-get choice :what)) note)) " · ")
                       :by (harness-ui-handoff--writer way checks label)
                       :cost total
                       :cost-text (harness-carry-cost-string way total)
                       :after (plist-get choice :after)
                       :mode (plist-get choice :mode)))))
     (car per-check))))

(defun harness-ui-handoff--mode (checks name)
  "Return the mode of `handoff/switch' the choice NAME of CHECKS hands over by.
`cancel' for the choice that leaves the model alone, and for a name that
is none of them."
  (let ((mode (plist-get (cl-find name (harness-ui-handoff--check-choices (car checks))
                                  :key (lambda (c) (plist-get c :choice)) :test #'equal)
                         :mode)))
    (if (and (stringp mode) (not (equal mode "cancel"))) (intern mode) 'cancel)))

;;;; The panel

(defun harness-ui-handoff--session-label (check)
  "Return the name to show for the session a `handoff/check' CHECK is about."
  (let ((name (plist-get check :name))
        (id (or (plist-get check :id) "?")))
    (if (and (stringp name) (not (string-blank-p name)))
        (format "“%s”" name)
      (substring id 0 (min 8 (length id))))))

(defun harness-ui-handoff--risk-row (risk)
  "Return RISK, a \"label: what it means\" string, as the cells of a row."
  (let ((colon (string-match ":" risk)))
    (if colon
        (list (substring risk 0 colon) (string-trim (substring risk (1+ colon))))
      (list risk ""))))

(defconst harness-ui-handoff--listed 6
  "How many sessions of a batch the panel names; the others are counted.")

(defun harness-ui-handoff--facts (checks total)
  "Return the labelled facts of the panel for CHECKS, TOTAL sessions in all.
The risks, what the new model's cold cache costs for one session, that
a turn runs, and for a batch which sessions lose their conversation."
  (let* ((first (car checks))
         (running (cl-some (lambda (c) (harness-json-true-p (plist-get c :running))) checks))
         (labels (mapcar #'harness-ui-handoff--session-label checks))
         (more (- (length labels) harness-ui-handoff--listed)))
    (append
     (mapcar #'harness-ui-handoff--risk-row (plist-get first :risks))
     (when (and (= total 1) (plist-get first :cache-cost))
       (list (list "Cache cost" (format "%s (list prices)" (plist-get first :cache-cost)))))
     (when running
       (list (list "Turn" "running · switch at its next step")))
     (when (> total 1)
       (list (list "Sessions"
                   (string-join (append (cl-subseq labels 0 (min (length labels) harness-ui-handoff--listed))
                                        (and (> more 0) (list (format "%d more" more)))
                                        (list (format "%d of %d change" (length checks) total)))
                                " · ")))))))

(defun harness-ui-handoff--spec (checks label total)
  "Return the spec of the panel asking about the switch of CHECKS to LABEL.
CHECKS are the `handoff/check' answers of the sessions that lose their
conversation, TOTAL how many sessions change in all.  The spec is made
afresh whenever the panel is drawn, so what the cache means for the
summary is true as of then."
  (let* ((total (or total (length checks)))
         (first (car checks))
         (from (harness-ui-handoff--from-label first)))
    (list :id "switch"
          :icon 'harness-icon-system :title "Switch model"
          :detail (if (= 1 total)
                      (format "%s → %s" from label)
                    (format "%d sessions → %s" total label))
          :detail-face 'bold
          :lines (list (harness-ui-carry-text (plist-get first :reason)))
          :rows (harness-ui-handoff--facts checks total)
          :ask "Choose how to hand over"
          :choices (harness-ui-handoff--choices checks label))))

;;;; Asking

(defun harness-ui-handoff--ask (checks label total session host callback)
  "Ask how to carry a lossy switch over: show the panel where the switch started.
See `harness-ui-switch-function' for CHECKS, LABEL, TOTAL, SESSION, HOST
and CALLBACK.  The panel shows in HOST when that can host it, else in
SESSION's chat, else in the session list (`harness-ui-carry-host');
CALLBACK gets the mode chosen.  With no buffer to show it in the switch
is cancelled: the minibuffer is never asked."
  (if-let* ((target (harness-ui-carry-host session host)))
      (harness-ui-carry-show target "switch"
                             (lambda () (harness-ui-handoff--spec checks label total))
                             (lambda (name) (funcall callback (harness-ui-handoff--mode checks name))))
    (message "Model unchanged: no buffer to ask in")
    (funcall callback 'cancel)))

;;;; Setup

(defun harness-ui-handoff--init ()
  "Let the UI ask its switch question as the panel of harness-ui-carry.el."
  (setq harness-ui-switch-function #'harness-ui-handoff--ask))

(harness-define-module 'ui-handoff
  :doc "The question of a model switch: choose how to carry the conversation over."
  :requires '(ui ui-chat ui-carry)
  :init #'harness-ui-handoff--init)

(provide 'harness-ui-handoff)
;;; harness-ui-handoff.el ends here
