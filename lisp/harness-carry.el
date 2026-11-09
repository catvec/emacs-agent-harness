;;; harness-carry.el --- The ways to carry a conversation over  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A conversation that cannot go on as it is has to be carried over some
;; way: summarised, written to a file, left behind, or sent whole.  Two
;; questions ask which.  The cold-cache question (harness-cowboy.el) asks
;; when a message meets a prompt cache gone cold; the model switch
;; (harness-handoff.el) asks when the new model keeps a conversation of
;; its own and would lose this one.  The UI draws both with one panel
;; (harness-ui-carry.el).  This file is what they share, and both sides of
;; the process split load it:
;;
;; - `harness-carry-ways', the ways, each with its key, its label and
;;   its wording.  A choice is a way with what it costs here: a plist
;;   (:choice NAME :key KEY :label LABEL :what WHAT :cost USD :cost-text
;;   TEXT :by MODEL :after TOKENS), which `harness-carry-choice' makes and
;;   `harness-carry-choices' makes for every way of a list from one
;;   `compaction/estimate' answer.  Both questions send their choices so,
;;   in that order, and the panel draws what it is sent.
;;
;; - `harness-carry-menu-ways', the short menu the questions show: a
;;   summary, a transcript file, a fresh start, carrying on and not now.
;;   The question before an automatic compaction and the one before a
;;   message to a session whose prompt cache went cold offer the same
;;   list, for different reasons; `harness-carry-menu' makes it from an
;;   estimate, marking a way that cannot be made as it is `:unavailable'
;;   rather than leaving it out, so the two menus stay one.
;;
;; A summary is the one way that asks a model to read the conversation,
;; so it is the one way whose offer depends on the prompt cache: a cold
;; read costs as much as sending the conversation again.  A transcript
;; file asks no model, and is the harness's own way: the conversation
;; goes to a file the model searches and reads as it needs.
;;
;; - the costs.  `harness-carry-cost-text' says what a way costs as an
;;   estimate gives it: "free" for what asks no model, "~$0.42" for the
;;   rest, and for carrying on what the uncached context costs.
;;   `harness-carry-cost-string' says it for a price already known, which
;;   is how the UI says what a switch of many costs in all.
;;
;; The two summaries keep the conversation's first and last messages as
;; they were written (harness-compaction.el), and say so.  Wording is
;; nouns and imperatives, a segment after another with " · ": the panel
;; wraps between segments.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-util)

(defconst harness-carry-menu-ways
  '(summary transcript fresh carry-on hold)
  "The ways the questions offer, in the order they offer them.
One short list for the question before an automatic compaction and the
one before a message to a session whose prompt cache went cold: the
same choices, for different reasons.  `summary' is the one way that asks
a model to read the conversation; `transcript' is the harness's own --
the conversation in a file the model reads.  `hold' is `Pause', which
no lasting answer may make the default.")

(defconst harness-carry-ways
  '((brief :key ?b :label "Brief"
           :what "narrative")
    (summary :key ?s :label "Summary"
             :what "context")
    (transcript :key ?t :label "Transcript"
                :what "file")
    (fresh :key ?f :label "Fresh start"
           :what "empty")
    (carry-on :key ?c :label "Continuation"
              :what "context")
    (ignore :key ?i :label "Silence"
            :what "context")
    (hold :key ?q :label "Pause"
          :what "pause"))
  "The ways to carry a conversation over, in the order they are offered.
Each entry is (WAY :key KEY :label LABEL :what WHAT): WAY a symbol, KEY
the character that picks it on a panel, LABEL what the options call it
and WHAT what it does, a noun or an adjective, a segment after another
with \" · \".  A question names the ways it offers and may say the
same thing otherwise where the situation does: `hold' is \"No switch\"
for a model switch, which has no message to keep waiting.")

(defun harness-carry-names ()
  "Return the symbols of `harness-carry-ways', in order."
  (mapcar #'car harness-carry-ways))

(defun harness-carry-way (value)
  "Return the way VALUE names, a symbol, or nil.
VALUE is a way's symbol or its name, in any case."
  (let ((sym (cond ((and value (symbolp value)) value)
                   ((stringp value) (intern-soft (downcase (string-trim value)))))))
    (and sym (assq sym harness-carry-ways) sym)))

(defun harness-carry-property (way property)
  "Return PROPERTY of WAY, one of `:key', `:label' and `:what'."
  (plist-get (cdr (assq (harness-carry-way way) harness-carry-ways)) property))

(defun harness-carry-key (way)
  "Return the key that picks WAY on a panel, a character, or nil."
  (harness-carry-property way :key))

(defun harness-carry-label (way)
  "Return the label of WAY."
  (or (harness-carry-property way :label) (format "%s" way)))

(defun harness-carry-by-key (key)
  "Return the way the character or one-letter string KEY picks, or nil."
  (let ((char (if (stringp key) (and (= (length key) 1) (aref key 0)) key)))
    (car (cl-find char harness-carry-ways :key (lambda (e) (plist-get (cdr e) :key))))))

;;;; What a way reads

(defun harness-carry-reads-cache-p (way estimate)
  "Non-nil when WAY, as ESTIMATE prices it, reads the conversation from the cache.
That is the estimate's own word for the way (`:cached'), never the
session's cache stamp: a way's request has its own prefix, and only an
estimate that says that prefix is cached is evidence that it is.  A way
that asks no model reads nothing, and is not one."
  (let ((kind (harness-carry-kind-estimate estimate way)))
    (and kind
         (memq way '(summary brief))
         (harness-json-true-p (plist-get kind :cached))
         t)))

(defun harness-carry-available-p (way estimate)
  "Non-nil when WAY can be carried out as ESTIMATE prices it.
Everything is, but a way that asks a model to read the conversation: it
is offered only when the estimate says its own request reads the cache,
because a cold read costs as much as the turn it would save."
  (or (not (memq (harness-carry-way way) '(summary brief)))
      (harness-carry-reads-cache-p way estimate)))

(defun harness-carry-cache-text (way estimate)
  "Return where WAY, as ESTIMATE prices it, reads the conversation.
\"cached\" or \"uncached\" for a way that asks a model to read it, and
nil for a way the estimate says nothing about: the other ways' costs say
it themselves.  It is a word of the panel's line, not a sentence."
  (let ((way (harness-carry-way way)))
    (when (memq way '(summary brief))
      (let ((kind (harness-carry-kind-estimate estimate way)))
        (and kind
             (if (harness-json-true-p (plist-get kind :cached))
                 "cached"
               "uncached"))))))

;;;; What each way costs

(defun harness-carry-kind-estimate (estimate way)
  "Return ESTIMATE's entry for the compaction kind WAY names, or nil.
ESTIMATE is a `compaction/estimate' answer."
  (cl-find-if (lambda (k) (eq (harness-carry-way (plist-get k :kind)) way))
              (plist-get estimate :kinds)))

(defun harness-carry-cost (estimate way)
  "Return what WAY costs as ESTIMATE says, in US dollars, or nil.
ESTIMATE is a `compaction/estimate' answer.  Carrying on, and ignoring
the cold cache, cost sending the context as things are; holding costs
nothing and has no price."
  (pcase way
    ((or 'carry-on 'ignore) (plist-get estimate :carry-on))
    ('hold nil)
    (_ (plist-get (harness-carry-kind-estimate estimate way) :cost))))

(defun harness-carry-cost-string (way cost)
  "Return what WAY costs when it costs COST dollars, in a few words, or nil.
\"free\" for what asks no model, \"~$0.42\" for the rest, and for
carrying on, or ignoring the cold cache, what the uncached context
costs.  Nil when COST is not known: holding has no price."
  (cond ((memq way '(transcript fresh)) "free")
        ((not (numberp cost)) nil)
        ((memq way '(carry-on ignore)) (format "~%s uncached" (harness-format-cost cost)))
        (t (format "~%s" (harness-format-cost cost)))))

(defun harness-carry-cost-text (estimate way)
  "Return what WAY costs as ESTIMATE says, in a few words, or nil.
ESTIMATE is a `compaction/estimate' answer: see
`harness-carry-cost-string' for how it reads.  Carrying on with a cache
that lasts reads its price from the cache, and says so; one that lapsed
pays to send the conversation again, uncached."
  (let ((cost (harness-carry-cost estimate way)))
    (if (and (memq (harness-carry-way way) '(carry-on ignore))
             (numberp cost)
             (harness-json-true-p (plist-get estimate :cached)))
        (format "~%s cached" (harness-format-cost cost))
      (harness-carry-cost-string way cost))))

(defun harness-carry-total (costs)
  "Return the sum of COSTS, prices in dollars, or nil when one is not known.
A price that is not known makes a total that would pass for the whole."
  (and costs (cl-every #'numberp costs) (apply #'+ costs)))

;;;; The model switch

(defconst harness-carry-switch-ways
  '((brief . compact-new) (summary . compact) (transcript . transcript)
    (fresh . none) (hold . cancel))
  "The ways a model switch offers, with the mode of `handoff/switch' of each.
Each entry is (WAY . MODE): WAY one of `harness-carry-ways', the ones the
cold-cache question offers too, and MODE the `handoff/switch' mode that
does it; `cancel' is no mode, but the answer that leaves the model alone.
A brief summary is written by the new model, a summary by the current
one, and `none' starts afresh with nothing carried over.")

(defun harness-carry-switch-choice (way &rest props)
  "Return the choice of WAY, one of `harness-carry-switch-ways'.
It is `harness-carry-choice' with PROPS, and `:mode', the mode of
`handoff/switch' that hands over by it.  Holding is cancelling the
switch there, which has no message to keep waiting."
  (apply #'harness-carry-choice way
         :mode (symbol-name (cdr (assq way harness-carry-switch-ways)))
         (if (eq way 'hold)
             (append (list :label "No switch" :what "model unchanged") props)
           props)))

;;;; Choices

(defun harness-carry-choice (way &rest props)
  "Return the choice of WAY, with PROPS added or put over its own.
That is (:choice NAME :key KEY :label LABEL :what WHAT ...): NAME is
WAY's name, KEY its key as a one-character string, and PROPS, a plist,
add what a question knows of it (`:cost', `:cost-text', `:by', `:after',
`:mode') or say its label or wording otherwise (`:label', `:what')."
  (let ((label (if (plist-member props :label) (plist-get props :label) (harness-carry-label way)))
        (what (if (plist-member props :what)
                  (plist-get props :what)
                (or (harness-carry-property way :what) ""))))
    (append (list :choice (symbol-name way)
                  :key (char-to-string (harness-carry-key way))
                  :label label :what what)
            (cl-loop for (prop value) on props by #'cddr
                     unless (memq prop '(:label :what))
                     append (list prop value)))))

(defun harness-carry-choices (ways estimate &optional make)
  "Return the choices of WAYS, symbols, as ESTIMATE prices them.
ESTIMATE is a `compaction/estimate' answer, or nil, which leaves
every price out.  Each choice has the cost of its way as the estimate
gives it (`:cost'), how it reads (`:cost-text'), the label of the model
that would write it (`:by', for the two summaries) and the context
that stands for the conversation after it (`:after').  MAKE makes each
choice, `harness-carry-choice' by default; a model switch passes
`harness-carry-switch-choice'."
  (mapcar (lambda (way)
            (let* ((kind (harness-carry-kind-estimate estimate way))
                   (cache (harness-carry-cache-text way estimate))
                   (what (and cache
                              (string-join
                               (delq nil (list (harness-carry-property way :what) cache))
                               " · "))))
              (apply (or make #'harness-carry-choice) way
                     (append (list :cost (harness-carry-cost estimate way)
                                   :cost-text (harness-carry-cost-text estimate way)
                                   :by (plist-get kind :model-label)
                                   :after (plist-get kind :after))
                             (and what (list :what what))))))
          ways))

(defun harness-carry--not-offered (choice why)
  "Return CHOICE shown but not offered, WHY a noun phrase saying why.
The writer goes: no model writes a way that is not offered."
  (let ((choice (plist-put (plist-put (copy-sequence choice) :unavailable t) :cost nil)))
    (setq choice (plist-put choice :by nil))
    (setq choice (plist-put choice :cost-text "no cache"))
    (plist-put choice :why why)))

(defun harness-carry-menu (estimate)
  "Return the ways the questions offer, as choices, as ESTIMATE prices them.
They are `harness-carry-menu-ways' in order, made by
`harness-carry-choices'.  A way that cannot be made as ESTIMATE prices
it -- a summary whose own request the prompt cache does not hold -- is
kept, marked `:unavailable' and saying why, rather than left out: both
questions show the same menu, and only the reason they are asked
differs.  The caller draws an unavailable choice without a key, and
answers a name of one as it answers a name that is no choice.  Carrying
on is always offered, past the model's window too: it is the user's to
choose, and the provider that cannot send the conversation says so."
  (mapcar (lambda (choice)
            (let ((way (harness-carry-way (plist-get choice :choice))))
              (if (harness-carry-available-p way estimate)
                  choice
                (harness-carry--not-offered choice "no cache"))))
          (harness-carry-choices harness-carry-menu-ways estimate)))

(provide 'harness-carry)
;;; harness-carry.el ends here
