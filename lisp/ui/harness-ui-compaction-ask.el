;;; harness-ui-compaction-ask.el --- The question before an automatic compaction  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that comes near its model's context window is
;; compacted before it can be sent again, and compacting spends money:
;; the summary reads the whole conversation again.  So where the user
;; can be asked, the harness asks first (harness-compaction.el), with
;; the kinds of compaction and what each costs, and carrying on with
;; the whole conversation and what that costs: a brief summary, a
;; summary, a transcript file, a fresh start, a cut of the oldest
;; context, carrying on, or not now.
;;
;; The question is a pending question like any other, with its own
;; `:compaction' in the payload.  This module draws it with the panel of
;; the ways to carry a conversation over (harness-ui-carry.el), which
;; the cold-cache question uses too (harness-ui-cowboy.el): the
;; choices, their keys and their costs are the harness's, and what this
;; module says is the heading -- the context against the window the
;; model can be sent -- and the rows, what carrying on costs against
;; the cache.  A key answers once (b, s, t, f, x, c, q); there is no
;; "always" here, as every automatic compaction is the user's to
;; decide.  A client that does not know `:compaction' shows the
;; ordinary question, whose options carry their costs in their words.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-pending)
(require 'harness-ui-carry)

;;;; Reading the question

(defun harness-ui-compaction-ask--info (r)
  "Return the `:compaction' of question record R, or nil for another question."
  (let ((info (plist-get r :compaction)))
    (and (consp info) info)))

(defun harness-ui-compaction-ask--detail (info)
  "Return what the heading of the panel for INFO says, in one line."
  (let ((context (plist-get info :context))
        (window (plist-get info :window))
        (model (harness-ui-carry-text (plist-get info :model-label))))
    (string-join
     (delq nil
           (list (cond ((and (numberp context) (> context 0) (numberp window) (> window 0))
                        (format "~%s of %s tokens"
                                (harness-format-tokens context) (harness-format-tokens window)))
                       ((and (numberp context) (> context 0))
                        (format "~%s tokens" (harness-format-tokens context))))
                 model))
     " · ")))

(defun harness-ui-compaction-ask--rows (info &optional session)
  "Return the labelled facts of the panel for INFO.
What carrying on costs, against the price from the cache, where the
cache still lasts.  SESSION, a session plist, words the cost as a
plan's shares where it has rates."
  (let ((carry (plist-get info :carry-on))
        (cached (plist-get info :carry-on-cached))
        (warm (harness-json-true-p (plist-get info :cached))))
    (let ((text (lambda (usd)
                  (if session (harness-ui-estimate-text usd session) (harness-format-cost usd)))))
      (delq nil
            (list (and (numberp carry)
                       (list "Carry on"
                             (if (and warm (numberp cached) (> carry cached))
                                 (format "%s uncached against %s cached"
                                         (funcall text carry) (funcall text cached))
                               (format "%s uncached" (funcall text carry))))))))))

(defun harness-ui-compaction-ask--choice (entry session)
  "Return the choice of ENTRY, as the panel draws it, for SESSION.
Its label, wording, key, cost and the context after it come from the
harness; where the cost is a sum of money and SESSION has plan rates,
it reads as a share of the plan's windows."
  (let* ((name (plist-get entry :choice))
         (cost (plist-get entry :cost))
         (text (harness-ui-carry-text (plist-get entry :cost-text)))
         (choice (list :choice name
                       :key (harness-ui-carry-text (plist-get entry :key))
                       :label (harness-ui-carry-text (plist-get entry :label))
                       :what (harness-ui-carry-text (plist-get entry :what)))))
    (when (numberp (plist-get entry :after))
      (setq choice (plist-put choice :after (plist-get entry :after))))
    (when text
      (setq choice (plist-put choice :cost-text
                              (if (and (numberp cost) session (not (equal text "free")))
                                  (concat "~" (harness-ui-estimate-text cost session)
                                          (if (equal name "carry-on") " uncached" ""))
                                text))))
    choice))

;;;; Answering

(defun harness-ui-compaction-ask-answer (session-id pid choice)
  "Answer the automatic-compaction question PID of SESSION-ID with CHOICE.
CHOICE is a choice's name, such as \"brief\"."
  (harness-ui-pending-answer-question session-id pid choice))

;;;; The panel

(defun harness-ui-compaction-ask--spec (session-id r)
  "Return the spec of the panel of question record R, of SESSION-ID.
See `harness-ui-carry-panel-string'."
  (let* ((info (harness-ui-compaction-ask--info r))
         (pid (plist-get r :id))
         (session (harness-ui-session session-id)))
    (list :id pid
          :icon 'harness-icon-compaction
          :title "Context nearly full"
          :detail (harness-ui-compaction-ask--detail info)
          :rows (harness-ui-compaction-ask--rows info session)
          :ask "Choose what goes first"
          :choices (mapcar (lambda (entry) (harness-ui-compaction-ask--choice entry session))
                           (append (plist-get info :choices) nil))
          :default (plist-get info :default)
          :always nil
          :footer (list (and (fboundp 'harness-compaction-history-p)
                             (harness-compaction-history-p session-id)
                             "Left out: searchable with session_history"))
          :answer (lambda (choice _always)
                    (harness-ui-compaction-ask-answer session-id pid choice)))))

(defun harness-ui-compaction-ask--string (spec)
  "Return the panel of SPEC, a spec of `harness-ui-compaction-ask--spec'."
  (let ((string (harness-ui-carry-panel-string spec)))
    (add-text-properties 0 (length string)
                         (list 'harness-ui-compaction-ask-panel (plist-get spec :id))
                         string)
    string))

(defun harness-ui-compaction-ask-panel-string (session-id r)
  "Return the panel of the automatic-compaction question record R of SESSION-ID."
  (harness-ui-compaction-ask--string (harness-ui-compaction-ask--spec session-id r)))

(defun harness-ui-compaction-ask-waiting-p (session-id)
  "Non-nil while SESSION-ID waits on the question before an automatic compaction."
  (or (cl-some #'harness-ui-compaction-ask--info (harness-ui-pending-items session-id))
      (cl-some (lambda (item) (plist-get (plist-get item :payload) :compaction))
               (append (plist-get (harness-ui-session session-id) :pending) nil))))

(defun harness-ui-compaction-ask--insert-panel (r)
  "Insert the panel of request record R when it is the compaction question.
On `harness-ui-pending-panel-functions': return non-nil when it did."
  (when-let* (((and (equal (plist-get r :kind) "question")
                    (harness-ui-compaction-ask--info r)))
              (session-id (harness-ui-pending-session))
              (spec (condition-case err
                        (harness-ui-compaction-ask--spec session-id r)
                      (error (message "Compaction panel: %s" (harness-error-short-message err)) nil)))
              (text (condition-case err
                        (harness-ui-compaction-ask--string spec)
                      (error (message "Compaction panel: %s" (harness-error-short-message err)) nil))))
    (let ((start (point))
          (pid (plist-get r :id)))
      (insert text)
      (harness-ui-pending-decorate start (point) pid
                                   (harness-ui-carry-keymap spec harness-ui-pending-question-map))
      t)))

;;;; Setup

(defun harness-ui-compaction-ask--init ()
  "Draw the question before an automatic compaction as a panel of its own."
  (add-hook 'harness-ui-pending-panel-functions #'harness-ui-compaction-ask--insert-panel))

(harness-define-module 'ui-compaction-ask
  :doc "The question before an automatic compaction as a panel: the kinds, what each costs, and carrying on."
  :requires '(ui ui-pending ui-carry)
  :init #'harness-ui-compaction-ask--init)

(provide 'harness-ui-compaction-ask)
;;; harness-ui-compaction-ask.el ends here
