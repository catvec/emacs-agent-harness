;;; harness-ui-cowboy.el --- The cold-cache question in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; A message to a session whose prompt cache went cold waits while the
;; harness asks what goes first (harness-cowboy.el): a brief summary, a
;; summary, a transcript file, a fresh start, the whole conversation as
;; it is, or not now.  The question is a pending question like any
;; other; its payload's `:cowboy' says when the cache lapsed, what
;; carrying on costs and what each choice costs.  This module draws it
;; as a panel of its own, in place of the ordinary question panel
;; (`harness-ui-pending-panel-functions'), in the chat and in a popout
;; of it: who sent the message that waits, what carrying on costs
;; against the cache it lost, and a line per choice with its key, its
;; cost and what it does.  Its amber is the switch banner's
;; (harness-ui-switch.el), the other place a conversation is carried
;; over at a cost.
;;
;; A key answers once -- b, s, t, f, c -- and its capital always: B, S,
;; T, F or C makes the choice `harness-cowboy-default' and stops the
;; asking (`harness-cowboy-ask'), saved as any setting is.  q answers
;; not now: the message waits, and goes with the next one.  The keys
;; work while point is on the panel, a click on a choice from anywhere;
;; digits pick an option as on any question, and text typed in the box
;; answers it too ("transcript", "always brief").  Whatever is chosen,
;; the model can search and read the conversation left out with the
;; session_history tool, which the panel says when the session has it.
;;
;; The cache panel (harness-ui-cache.el) stays away while the question
;; waits: the question says all it would, and more.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-pending)

(defgroup harness-ui-cowboy nil
  "Asking what goes first when a message meets a cold prompt cache."
  :group 'harness-ui)

(defface harness-ui-cowboy-face
  '((((background light)) :background "#fff3d6" :extend t)
    (((background dark)) :background "#3a3117" :extend t))
  "Background of the cold-cache question: a message waits for your choice.
The switch banner's amber: both carry a conversation over at a cost."
  :group 'harness-ui-cowboy)

(defconst harness-ui-cowboy-keys
  '(("brief" ?b) ("summary" ?s) ("transcript" ?t) ("fresh" ?f) ("carry-on" ?c) ("hold" ?q))
  "The choices of the cold-cache question and their keys, in order.
Each entry is (CHOICE KEY): CHOICE as the harness names it (see
`harness-cowboy-choices'), KEY the key that answers with it on the
panel.  Its capital answers \"always\", but for `hold'.")

(defconst harness-ui-cowboy--labels
  '(("brief" "Brief summary" "a cheap model summarises the first and last messages")
    ("summary" "Summary" "the session's model summarises it all, reading it uncached")
    ("transcript" "Transcript file" "the conversation goes to a file the model reads as it needs")
    ("fresh" "Start afresh" "nothing is carried over; the model looks back when it needs to")
    ("carry-on" "Carry on" "the whole conversation goes again, uncached")
    ("hold" "Not now" "the message waits; nothing is sent yet"))
  "Label and description of each choice, for a question that brings none.")

;;;; Reading the question

(defun harness-ui-cowboy--info (r)
  "Return the `:cowboy' of question record R, or nil for an ordinary question."
  (let ((info (plist-get r :cowboy)))
    (and (consp info) info)))

(defun harness-ui-cowboy--text (value)
  "Return VALUE when it is a string with something in it, else nil."
  (and (stringp value) (not (string-blank-p value)) value))

(defun harness-ui-cowboy--choice (info choice)
  "Return what INFO says of CHOICE: (:choice :label :what :cost-text :by :after).
What INFO leaves out of a choice's label and description comes from
`harness-ui-cowboy--labels'; its cost, writer and context after are nil
then."
  (let ((entry (cl-find choice (append (plist-get info :choices) nil)
                        :key (lambda (c) (format "%s" (plist-get c :choice))) :test #'equal))
        (fallback (assoc choice harness-ui-cowboy--labels)))
    (list :choice choice
          :label (or (harness-ui-cowboy--text (plist-get entry :label)) (nth 1 fallback))
          :what (or (harness-ui-cowboy--text (plist-get entry :what)) (nth 2 fallback))
          :cost-text (harness-ui-cowboy--text (plist-get entry :cost-text))
          :by (harness-ui-cowboy--text (plist-get entry :by))
          :after (and (numberp (plist-get entry :after)) (plist-get entry :after)))))

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
             (nth 1 (assoc choice harness-ui-cowboy--labels)))))

(defun harness-ui-cowboy--command (session-id pid choice &optional always)
  "Return the command answering question PID of SESSION-ID with CHOICE.
ALWAYS as for `harness-ui-cowboy-answer'."
  (lambda () (interactive) (harness-ui-cowboy-answer session-id pid choice always)))

(defun harness-ui-cowboy--keymap (session-id pid)
  "Return the keymap of the panel of question PID of SESSION-ID.
A choice's key answers with it, its capital always; the digits of any
question pick an option, under them."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-pending-question-map)
    (pcase-dolist (`(,choice ,key) harness-ui-cowboy-keys)
      (define-key map (char-to-string key) (harness-ui-cowboy--command session-id pid choice))
      (unless (equal choice "hold")
        (define-key map (char-to-string (upcase key)) (harness-ui-cowboy--command session-id pid choice t))))
    map))

;;;; The panel

(defun harness-ui-cowboy--sender (from)
  "Return who sent the message waiting, FROM, as the subject of a sentence.
Another session's agent goes by its session's name, as the chat names
it (now, else when it wrote, else a short id): a button that opens the
session."
  (pcase (harness-sender-kind from)
    ('nil "Your message")
    ('session
     (let* ((id (plist-get from :id))
            (label (or (harness-ui-cowboy--text (plist-get (and (stringp id) (harness-ui-session id)) :name))
                       (harness-ui-cowboy--text (plist-get from :name))
                       (and (stringp id) (substring id 0 (min 8 (length id))))
                       "?"))
            (shown (format "“%s”" label)))
       (concat "A message from session "
               (if (and (stringp id) (fboundp 'harness-open-session))
                   (harness-ui-action-button shown (lambda () (harness-open-session id))
                                             :help (format "Open the session %s" label))
                 shown))))
    (_ (format "A message from %s" (harness-sender-description from)))))

(defun harness-ui-cowboy--heading (info now)
  "Return the heading of the panel for INFO, drawn at NOW.
Clock times only, never ages, so it stays true while it shows."
  (let* ((expires (plist-get info :expires))
         (context (plist-get info :context))
         (model (or (harness-ui-cowboy--text (plist-get info :model-label))
                    (and (plist-get info :model) (harness-ui-model-label (plist-get info :model))))))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-clock) " Prompt cache cold")
                     'face 'harness-label-face)
     "  "
     (propertize (string-join
                  (delq nil (list (and (numberp expires)
                                       (format "since %s" (harness-ui-format-clock expires now)))
                                  model
                                  (and (numberp context) (> context 0)
                                       (format "~%s tokens" (harness-format-tokens context)))))
                  " · ")
                 'face 'harness-dim-face)
     "\n")))

(defun harness-ui-cowboy--waiting (info)
  "Return the line saying which message waits, as INFO says."
  (let ((preview (harness-ui-cowboy--text (plist-get info :preview))))
    (propertize
     (concat "   " (harness-ui-cowboy--sender (plist-get info :from)) " waits"
             (if preview (format ": “%s”" (harness-truncate-end preview 120)) ".")
             "\n")
     'wrap-prefix "   ")))

(defun harness-ui-cowboy--carry-on (info)
  "Return the line saying what carrying on costs, as INFO says."
  (let ((carry (plist-get info :carry-on))
        (cached (plist-get info :carry-on-cached)))
    (propertize
     (concat "   Carrying on sends the whole conversation again, uncached"
             (if (and (numberp carry) (numberp cached) (> carry cached))
                 (format ": about %s instead of the %s it would cost cached."
                         (harness-format-cost carry) (harness-format-cost cached))
               ".")
             "  What goes first?\n")
     'face 'bold 'wrap-prefix "   ")))

(defun harness-ui-cowboy--help (choice entry info)
  "Return the tooltip of CHOICE's button, whose ENTRY INFO gives."
  (let ((cost (plist-get entry :cost-text))
        (by (plist-get entry :by))
        (after (plist-get entry :after))
        (key (cadr (assoc choice harness-ui-cowboy-keys))))
    (concat (plist-get entry :label) (if cost (format " (%s)" cost) "") ": " (plist-get entry :what) "."
            (if (and by (member choice '("brief" "summary"))) (format "\nWritten by %s." by) "")
            (if (and (numberp after) (> after 0) (not (member choice '("carry-on" "hold"))))
                (format "\nThe conversation then holds ~%s tokens." (harness-format-tokens after))
              "")
            (format "\nPress %c on this panel, or click%s."
                    key (if (equal choice "hold") "" (format "; %c makes it the default" (upcase key))))
            (if (equal choice (plist-get info :default)) "\nThe default, taken when nobody is asked." ""))))

(defun harness-ui-cowboy--rows (session-id pid info)
  "Return the lines of the choices of question PID of SESSION-ID, as INFO says."
  (let* ((entries (mapcar (lambda (c) (harness-ui-cowboy--choice info (car c))) harness-ui-cowboy-keys))
         (label-width (apply #'max (mapcar (lambda (e) (string-width (plist-get e :label))) entries)))
         ;; The costs' column, with its gap; none when no cost is known.
         (cost-column (let ((width (apply #'max 0 (mapcar (lambda (e) (string-width (or (plist-get e :cost-text) "")))
                                                          entries))))
                        (if (> width 0) (+ width 2) 0)))
         (default (plist-get info :default)))
    (mapconcat
     (lambda (entry)
       (let* ((choice (plist-get entry :choice))
              (key (cadr (assoc choice harness-ui-cowboy-keys)))
              (cost (or (plist-get entry :cost-text) ""))
              (prefix (concat "   " (harness-ui-kbd (format " %c " key)) " "))
              (indent (make-string (+ (string-width prefix) label-width 2 cost-column) ?\s)))
         (concat prefix
                 (harness-ui-action-button (plist-get entry :label)
                                           (lambda () (harness-ui-cowboy-answer session-id pid choice))
                                           :help (harness-ui-cowboy--help choice entry info))
                 (make-string (- (+ label-width 2) (string-width (plist-get entry :label))) ?\s)
                 cost
                 (make-string (- cost-column (string-width cost)) ?\s)
                 (propertize (concat (plist-get entry :what)
                                     (if (equal choice default) " · the default" ""))
                             'face 'harness-dim-face 'wrap-prefix indent)
                 "\n")))
     entries "")))

(defun harness-ui-cowboy--footer (info)
  "Return the lines under the choices, as INFO says."
  (concat
   (propertize "   " 'wrap-prefix "   ")
   (harness-ui-kbd " B ") " " (harness-ui-kbd " S ") " " (harness-ui-kbd " T ") " "
   (harness-ui-kbd " F ") " " (harness-ui-kbd " C ")
   (propertize " the same, from now on without asking\n" 'face 'harness-dim-face)
   (if (harness-json-true-p (plist-get info :history))
       (propertize "   Whichever you choose, the model can search and read the conversation it leaves out (session_history).\n"
                   'face 'harness-dim-face 'wrap-prefix "   ")
     "")
   (propertize "   or type a choice below: “transcript”, “always brief”\n"
               'face 'harness-dim-face 'wrap-prefix "   ")))

(defun harness-ui-cowboy--paint-prefixes (string face)
  "Return STRING with its wrap prefixes in FACE, as its text is.
A line that wraps shows its `wrap-prefix' with the prefix's own faces,
not the text's: without FACE, a panel's wrapped lines would show the
buffer's background where they are indented."
  (let ((pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((next (or (next-single-property-change pos 'wrap-prefix string len) len))
            (prefix (get-text-property pos 'wrap-prefix string)))
        (when (stringp prefix)
          (put-text-property pos next 'wrap-prefix (propertize prefix 'face face) string))
        (setq pos next))))
  string)

(defun harness-ui-cowboy-panel-string (session-id r &optional now)
  "Return the panel of the cold-cache question record R of SESSION-ID.
NOW is the current time by default."
  (let* ((info (harness-ui-cowboy--info r))
         (pid (plist-get r :id))
         (now (or now (float-time)))
         (string (concat (harness-ui-cowboy--heading info now)
                         (harness-ui-cowboy--waiting info)
                         (harness-ui-cowboy--carry-on info)
                         "\n"
                         (harness-ui-cowboy--rows session-id pid info)
                         "\n"
                         (harness-ui-cowboy--footer info))))
    (add-text-properties 0 (length string) (list 'harness-ui-cowboy-panel pid) string)
    (harness-ui-cowboy--paint-prefixes (harness-ui-add-face string 'harness-ui-cowboy-face)
                                       'harness-ui-cowboy-face)))

(defun harness-ui-cowboy--insert-panel (r)
  "Insert the panel of request record R when it is the cold-cache question.
On `harness-ui-pending-panel-functions': return non-nil when it did.
The panel is made whole before anything is inserted, so a failure
leaves the ordinary question panel to show instead."
  (when-let* ((info (and (equal (plist-get r :kind) "question") (harness-ui-cowboy--info r)))
              (session-id (harness-ui-pending-session))
              (text (condition-case err
                        (harness-ui-cowboy-panel-string session-id r)
                      (error (message "Cold-cache panel: %s" (error-message-string err)) nil))))
    (let ((start (point))
          (pid (plist-get r :id)))
      (insert text)
      (harness-ui-pending-decorate start (point) pid (harness-ui-cowboy--keymap session-id pid))
      t)))

;;;; Setup

(defun harness-ui-cowboy--init ()
  "Draw the cold-cache question as a panel of its own."
  (add-hook 'harness-ui-pending-panel-functions #'harness-ui-cowboy--insert-panel))

(harness-define-module 'ui-cowboy
  :doc "The cold-cache question as a panel: what goes first, at what cost."
  :requires '(ui ui-pending)
  :init #'harness-ui-cowboy--init)

(provide 'harness-ui-cowboy)
;;; harness-ui-cowboy.el ends here
