;;; harness-ui-compaction-ask.el --- The question before an automatic compaction  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that comes near its model's context window is
;; compacted before it can be sent again, and compacting spends money:
;; the summary reads the conversation again, from the prompt cache while
;; that lasts.  So where the user can be asked, the harness asks first
;; (harness-compaction.el), in one list: Summary, Transcript, Fresh
;; start, Continuation and Pause -- the same list the cold-cache question
;; asks, for another reason.  A summary is offered only where its own
;; request reads the prompt cache, and says what it costs there; it is
;; shown, no cache, otherwise.  The ways that ask no model are always
;; offered, and carrying on is always one of them: past the model's
;; window too, the user's to choose.
;;
;; The question is a pending question like any other, with its own
;; `:compaction' in the payload.  This module draws it with the panel of
;; the ways to carry a conversation over (harness-ui-carry.el), which
;; the cold-cache question uses too (harness-ui-cowboy.el): one page and
;; one list, the same both questions show (`harness-carry-menu'), with
;; the choices, their keys and their costs the harness's.  What this
;; module says is the heading -- the context against the window the
;; model can be sent.  A summary whose own request would read the
;; conversation uncached is drawn, no cache.  A key answers once; the
;; capital of Continuation answers "always", which saves
;; `harness-compaction-carry-on' and stops the asking.  A client that
;; does not know `:compaction' shows the ordinary question, whose
;; options carry their costs in their words.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-pending)
(require 'harness-ui-carry)

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
                 model
                 (if (harness-json-true-p (plist-get info :cached))
                     "cached"
                   "uncached")))
     " · ")))

;;;; Answering

(defun harness-ui-compaction-ask-answer (session-id pid choice &optional always)
  "Answer the automatic-compaction question PID of SESSION-ID with CHOICE.
CHOICE is a choice's name, such as \"brief\"; ALWAYS non-nil makes it the
lasting answer, which only carrying on may be."
  (harness-ui-pending-answer-question
   session-id pid (if always (concat "always " choice) choice))
  (when always
    (message "%s · default"
             (harness-carry-label (harness-carry-way choice)))))

;;;; The panel

(defun harness-ui-compaction-ask--spec (session-id r)
  "Return the spec of the panel of question record R, of SESSION-ID.
See `harness-ui-carry-panel-string'."
  (let* ((info (harness-ui-compaction-ask--info r))
         (pid (plist-get r :id))
         (session (harness-ui-session session-id)))
    (list :id pid
          :icon 'harness-icon-compaction
          :title "Context"
          :detail (harness-ui-compaction-ask--detail info)
          :ask "Options"
          :choices (mapcar (lambda (entry) (harness-ui-carry-choice entry session))
                           (append (plist-get info :choices) nil))
          :default (plist-get info :default)
          :always (plist-get info :always)
          :footer (list (and (fboundp 'harness-compaction-history-p)
                             (harness-compaction-history-p session-id)
                             "session_history"))
          :answer (lambda (choice always)
                    (harness-ui-compaction-ask-answer session-id pid choice always)))))

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
  :doc "The question before an automatic compaction as a panel: one list of ways, what each choice costs, and carrying on."
  :requires '(ui ui-pending ui-carry)
  :init #'harness-ui-compaction-ask--init)

(provide 'harness-ui-compaction-ask)
;;; harness-ui-compaction-ask.el ends here
