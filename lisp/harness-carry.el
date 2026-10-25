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

(defconst harness-carry-ways
  '((brief :key ?b :label "Brief summary"
           :what "narrative, tool calls in brief · first and last messages kept")
    (summary :key ?s :label "Summary"
             :what "whole conversation · first and last messages kept")
    (transcript :key ?t :label "Transcript file"
                :what "whole conversation as a file the model reads")
    (fresh :key ?f :label "Start afresh"
           :what "nothing carried over")
    (carry-on :key ?c :label "Carry on"
              :what "whole conversation again, uncached")
    (ignore :key ?i :label "Ignore"
            :what "whole conversation, nothing added")
    (hold :key ?q :label "Not now"
          :what "message waits"))
  "The ways to carry a conversation over, in the order they are offered.
Each entry is (WAY :key KEY :label LABEL :what WHAT): WAY a symbol, KEY
the character that picks it on a panel, LABEL what the options call it
and WHAT what it does, in nouns, a segment after another with \" · \".
A question names the ways it offers and may say the same thing
otherwise where the situation does: `hold' is \"Cancel\" for a model
switch, which has no message to keep waiting.")

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
`harness-carry-cost-string' for how it reads."
  (harness-carry-cost-string way (harness-carry-cost estimate way)))

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
             (append (list :label "Cancel" :what "model unchanged") props)
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
            (let ((kind (harness-carry-kind-estimate estimate way)))
              (funcall (or make #'harness-carry-choice) way
                       :cost (harness-carry-cost estimate way)
                       :cost-text (harness-carry-cost-text estimate way)
                       :by (plist-get kind :model-label)
                       :after (plist-get kind :after))))
          ways))

(provide 'harness-carry)
;;; harness-carry.el ends here
