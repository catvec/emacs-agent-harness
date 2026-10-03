;;; harness-ui-pending.el --- What a session waits on, drawn anywhere  -*- lexical-binding: t; -*-

;;; Commentary:

;; A blocked session waits on requests: a permission prompt for a tool
;; call, or a question an agent asked.  This module holds them per
;; session, draws their panels -- the permission prompt, the question
;; with its options and their diagrams -- and answers them, wherever a
;; UI shows them:
;;
;;   the chat        its tail, under the transcript (see ui-chat);
;;   the popout      one small window of its own, opened from the
;;                   session list, the task board or the tree, so a
;;                   request can be read and answered without leaving
;;                   the view or opening the session (see ui-popout).
;;
;; The store is the one source of truth: the chat mirrors it for the
;; session it shows, and a popout renders it fresh on every draw.  Both
;; panels and popouts are the same drawing code here, so a request looks
;; and answers the same in both.
;;
;; Requests arrive two ways and both are handled: the ACP request that
;; blocks a client (with a RESPOND function, when a chat buffer owns the
;; session) and the session's pending list from `_harness/session'
;; pushes, which is what a client that is not watching the session still
;; sees and can answer over `_harness/permission/answer' and
;; `_harness/question/answer'.
;;
;; Changing the store runs `harness-ui-pending-changed-hook' with the
;; session id: hosts redraw (the chat its tail, the popout its content),
;; and a popout with nothing left closes itself.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)

(defgroup harness-ui-pending nil
  "Requests a session waits on: permissions and questions." :group 'harness-ui)

(declare-function harness-ui-popout-show "harness-ui-popout")
(declare-function harness-ui-popout-refresh "harness-ui-popout")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-ui-popout-buffer "harness-ui-popout")

;;;; The store

(defvar harness-ui-pending--requests (make-hash-table :test 'equal)
  "Session id -> the request records it waits on, oldest first.
A record is a plist: `:id' `:kind' (\"permission\" or \"question\"),
`:respond' (the ACP callback, when a client owns the request, else nil),
`:created', and what its panel draws: `:title' `:tool' `:tool-kind'
`:input' `:paths' `:dir' `:reason' `:options' for a permission,
`:question' `:options' `:diagrams' for a question.")

(defvar harness-ui-pending--diagrams (make-hash-table :test 'equal)
  "Session id -> (PID . INDEX) of the diagram its panel shows.
The state belongs to the request, not to the buffer drawing it, so a
chat and a popout showing the same question show the same diagram.")

(defvar harness-ui-pending--answered (make-hash-table :test 'equal)
  "Session id -> (PID . TIME) of requests answered here.
The session's own pending list lags an answer by a round trip; this
keeps the request off the panels meanwhile, so answering one does not
bring it back for a moment.")

(defvar harness-ui-pending-changed-hook nil
  "Hook run with a session id after its requests change.
The chat redraws its tail for it, an open popout its content.")

(defvar-local harness-ui-pending-session-id nil
  "Session id whose requests this buffer draws.
The chat leaves it nil, so its `harness-ui-session-id' applies; a
popout sets it to the session its item belongs to.")

(defun harness-ui-pending--str (value)
  "Return VALUE as a string (a symbol or string), or nil for nil."
  (when value (if (symbolp value) (symbol-name value) (format "%s" value))))

(defun harness-ui-pending--session ()
  "Return the session id whose requests this buffer draws, or nil."
  (or harness-ui-pending-session-id
      (and (boundp 'harness-ui-session-id) harness-ui-session-id)))

(defun harness-ui-pending-items (session-id)
  "Return the request records SESSION-ID waits on, oldest first."
  (gethash session-id harness-ui-pending--requests))

(defun harness-ui-pending-record (session-id pid)
  "Return the request PID of SESSION-ID, or nil."
  (cl-find pid (harness-ui-pending-items session-id)
           :key (lambda (r) (plist-get r :id)) :test #'equal))

(defun harness-ui-pending-question (session-id)
  "Return the newest question SESSION-ID waits on, or nil."
  (cl-find "question" (reverse (harness-ui-pending-items session-id))
           :key (lambda (r) (plist-get r :kind)) :test #'equal))

(defun harness-ui-pending-summary (session)
  "Say what the first request of SESSION is, one short line, or nil.
This is for cards and rows that say what a session needs without
opening it."
  (when-let* ((item (car (plist-get session :pending))))
    (if (equal (format "%s" (plist-get item :kind)) "question")
        "has a question for you"
      "needs your permission")))

(defun harness-ui-pending-status (session)
  "Return \"question\", \"permission\" or nil: what SESSION waits on."
  (let ((item (car (plist-get session :pending))))
    (when item
      (if (equal (format "%s" (plist-get item :kind)) "question") "question" "permission"))))

(defun harness-ui-pending--changed (session-id)
  "Run `harness-ui-pending-changed-hook' for SESSION-ID."
  (when session-id
    (run-hook-with-args 'harness-ui-pending-changed-hook session-id)))

(defun harness-ui-pending--put (session-id records)
  "Store RECORDS for SESSION-ID and tell the hosts it changed."
  (if records
      (puthash session-id records harness-ui-pending--requests)
    (remhash session-id harness-ui-pending--requests))
  (harness-ui-pending--changed session-id))

(defun harness-ui-pending-add (session-id record)
  "Add or replace RECORD among the requests SESSION-ID waits on.
An answer already given here wins over news of the request still
arriving: the record keeps its `:respond' and does not come back."
  (let* ((pid (plist-get record :id))
         (old (harness-ui-pending-record session-id pid))
         (record (if (and old (plist-get old :respond) (not (plist-get record :respond)))
                     old record))
         (rest (cl-remove pid (harness-ui-pending-items session-id)
                          :key (lambda (r) (plist-get r :id)) :test #'equal)))
    (harness-ui-pending--put session-id (append rest (list record)))))

(defun harness-ui-pending-remove (session-id pid)
  "Forget the request PID of SESSION-ID."
  (harness-ui-pending--mark-answered session-id pid)
  (harness-ui-pending--put session-id
                           (cl-remove pid (harness-ui-pending-items session-id)
                                      :key (lambda (r) (plist-get r :id)) :test #'equal)))

(defun harness-ui-pending--mark-answered (session-id pid)
  "Remember that PID was answered here, for `harness-ui-pending-sync'."
  (puthash session-id
           (cons (cons pid (float-time))
                 (cl-remove-if (lambda (cell) (> (- (float-time) (cdr cell)) 30))
                               (gethash session-id harness-ui-pending--answered)))
           harness-ui-pending--answered))

(defun harness-ui-pending--answered-p (session-id pid)
  "Non-nil when PID of SESSION-ID was answered here just now."
  (let ((cell (assoc pid (gethash session-id harness-ui-pending--answered))))
    (and cell (< (- (float-time) (cdr cell)) 30))))

(defun harness-ui-pending--record-of-item (item)
  "Return the request record for ITEM, a pending item of a session.
ITEM is (:id :kind :payload) in the wire shape."
  (let* ((payload (plist-get item :payload))
         (kind (format "%s" (or (plist-get item :kind) ""))))
    (if (equal kind "question")
        (list :id (plist-get item :id) :kind "question" :created (float-time)
              :question (plist-get payload :question) :options (plist-get payload :options)
              :diagrams (plist-get payload :diagrams))
      (list :id (plist-get item :id) :kind "permission" :created (float-time)
            :title (or (plist-get payload :title) (plist-get payload :tool) "tool call")
            :tool (plist-get payload :tool) :tool-kind (harness-ui-pending--str (plist-get payload :kind))
            :input (plist-get payload :input) :paths (plist-get payload :paths)
            :dir (plist-get payload :dir) :reason (plist-get payload :reason)
            :options (plist-get payload :options)))))

(defun harness-ui-pending-sync (session-id items)
  "Reconcile the requests of SESSION-ID with its pending ITEMS.
Records a client owns (with a `:respond' function) keep it.  Return
non-nil when the store changed."
  (let ((changed nil))
    (dolist (item items)
      (let ((pid (plist-get item :id)))
        (unless (or (harness-ui-pending-record session-id pid)
                    (harness-ui-pending--answered-p session-id pid))
          (harness-ui-pending-add session-id (harness-ui-pending--record-of-item item))
          (setq changed t))))
    (dolist (r (harness-ui-pending-items session-id))
      (let ((pid (plist-get r :id)))
        (when (and (not (cl-find pid items :key (lambda (i) (plist-get i :id)) :test #'equal))
                   (> (- (float-time) (or (plist-get r :created) 0)) 0.5))
          (harness-ui-pending--put session-id
                                   (cl-remove r (harness-ui-pending-items session-id)))
          (setq changed t))))
    changed))

;;;; Answering

(defun harness-ui-pending--message-for (option dir)
  "Return the echo-area message for permission OPTION (DIR: a directory)."
  (pcase option
    ("allow-once" "Allowed")
    ("allow-session" (if dir "Directory allowed for this session" "Allowed for this session"))
    ("allow-always" (if dir "Directory always allowed" "Always allowed"))
    ("deny-always" "Always denied")
    (_ "Denied")))

(defun harness-ui-pending-answer-permission (session-id pid option)
  "Answer permission request PID of SESSION-ID with OPTION.
OPTION is an option id such as \"allow-once\".  An ACP request is
answered through the function that holds it; one only known from the
session's pending list goes over `_harness/permission/answer'."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    (if-let* ((respond (plist-get r :respond)))
        (funcall respond (list :outcome (list :outcome "selected" :optionId option)))
      (harness-ui-call "_harness/permission/answer"
                       (list :session-id session-id :pending-id pid :answer option) #'ignore))
    (harness-ui-pending-remove session-id pid)
    (message "%s" (harness-ui-pending--message-for option (plist-get r :dir)))))

(defun harness-ui-pending-answer-question (session-id pid answer)
  "Answer question PID of SESSION-ID with ANSWER."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    (if-let* ((respond (plist-get r :respond)))
        (funcall respond (list :answer answer))
      (harness-ui-call "_harness/question/answer"
                       (list :session-id session-id :pid pid :answer answer) #'ignore))
    (harness-ui-pending-remove session-id pid)))

;;;; Keys on the panels, and the commands behind them

(defun harness-ui-pending-at-point ()
  "Return the id of the request the panel at point is, or the newest one."
  (or (get-text-property (point) 'harness-ui-pending)
      (plist-get (car (last (harness-ui-pending-items (harness-ui-pending--session)))) :id)))

(defun harness-ui-pending--permission-command (option)
  "Return a command answering the permission at point with OPTION."
  (lambda ()
    (interactive)
    (let* ((session-id (harness-ui-pending--session))
           (pid (harness-ui-pending-at-point))
           (r (and pid (harness-ui-pending-record session-id pid))))
      (if (and r (equal (plist-get r :kind) "permission"))
          (harness-ui-pending-answer-permission session-id pid option)
        (user-error "No permission request waiting")))))

(defvar harness-ui-pending-permission-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") (harness-ui-pending--permission-command "allow-once"))
    (define-key map (kbd "s") (harness-ui-pending--permission-command "allow-session"))
    (define-key map (kbd "a") (harness-ui-pending--permission-command "allow-always"))
    (define-key map (kbd "n") (harness-ui-pending--permission-command "deny-once"))
    (define-key map (kbd "N") (harness-ui-pending--permission-command "deny-always"))
    map)
  "Keys active while point is on a permission panel.")

(defun harness-ui-pending--question-command (n)
  "Return a command answering the question at point with its Nth option."
  (lambda ()
    (interactive)
    (let* ((session-id (harness-ui-pending--session))
           (pid (harness-ui-pending-at-point))
           (r (and pid (harness-ui-pending-record session-id pid)))
           (option (nth n (plist-get r :options))))
      (if (and r (equal (plist-get r :kind) "question") option)
          (harness-ui-pending-answer-question session-id pid option)
        (user-error "No such option")))))

(defvar harness-ui-pending-question-map (make-sparse-keymap)
  "Keys active while point is on a question panel.
A digit answers with that option.")

(defvar harness-ui-pending-diagram-map (make-sparse-keymap)
  "Keys active while point is on the panel of a question with diagrams.
The question's digits, and n and p to switch whose diagram shows.")

;; Filled at top level, not in the `defvar's, so a reload updates them.
(dotimes (i 9)
  (define-key harness-ui-pending-question-map (kbd (number-to-string (1+ i)))
    (harness-ui-pending--question-command i)))
(set-keymap-parent harness-ui-pending-diagram-map harness-ui-pending-question-map)
(define-key harness-ui-pending-diagram-map (kbd "n") #'harness-ui-pending-next-diagram)
(define-key harness-ui-pending-diagram-map (kbd "p") #'harness-ui-pending-previous-diagram)

(defun harness-ui-pending--diagram-question ()
  "Return the question whose diagrams the diagram commands switch.
That is the one whose panel point is on, else the newest with diagrams."
  (let* ((session-id (harness-ui-pending--session))
         (at (get-text-property (point) 'harness-ui-pending))
         (r (and at (harness-ui-pending-record session-id at))))
    (or (and (harness-ui-pending--diagrams r) r)
        (cl-find-if #'harness-ui-pending--diagrams
                    (reverse (harness-ui-pending-items session-id)))
        (user-error "No question with diagrams is waiting"))))

(defun harness-ui-pending-next-diagram (&optional n)
  "Show the diagram of the next option of the question waiting with diagrams.
That is the question whose panel point is on, else the newest.  With
prefix argument N, move N options on; a negative N moves back."
  (interactive "p")
  (let ((r (harness-ui-pending--diagram-question)))
    (harness-ui-pending-step-diagram (harness-ui-pending--session) (plist-get r :id) (or n 1))))

(defun harness-ui-pending-previous-diagram (&optional n)
  "Show the diagram of the previous option of the question waiting with diagrams.
With prefix argument N, move N options back."
  (interactive "p")
  (harness-ui-pending-next-diagram (- (or n 1))))

(defun harness-ui-pending-allow-newest ()
  "Allow the newest pending permission request once."
  (interactive)
  (funcall (harness-ui-pending--permission-command "allow-once")))

(defun harness-ui-pending-deny-newest ()
  "Deny the newest pending permission request once."
  (interactive)
  (funcall (harness-ui-pending--permission-command "deny-once")))

(defvar-local harness-ui-pending--option-at-point nil
  "(QUESTION-ID . INDEX) of the option line point was on after the last command.")

(defun harness-ui-pending--follow-option ()
  "Show the diagram of the option whose line point moved onto.
Only a move counts: a diagram switched with point on an option's line
stays switched."
  (let* ((pid (get-text-property (point) 'harness-ui-pending))
         (i (and pid (get-text-property (point) 'harness-ui-pending-option)))
         (session-id (harness-ui-pending--session))
         (here (and i (cons pid i))))
    (unless (equal here harness-ui-pending--option-at-point)
      (setq harness-ui-pending--option-at-point here)
      (when (and here (harness-ui-pending--diagrams (harness-ui-pending-record session-id pid)))
        (harness-ui-pending-show-diagram session-id pid i)))))

;;;; Drawing the panels

(defun harness-ui-pending--offered-options (r)
  "Return the option ids offered with permission record R, or nil if unknown.
R's `:options' come from the session's pending item (ids as symbols or
strings) or from an ACP request (plists with `:optionId')."
  (delq nil (mapcar (lambda (o)
                      (cond ((and (consp o) (plist-get o :optionId)) (format "%s" (plist-get o :optionId)))
                            ((or (stringp o) (and o (symbolp o))) (format "%s" o))))
                    (append (plist-get r :options) nil))))

(defun harness-ui-pending-permission-buttons (r)
  "Return the (LABEL KEY OPTION) buttons for permission record R.
A directory prompt is worded for directories; only the options R
offers are shown, so an agent's own directory request has no
\"Allow once\"."
  (let ((all (if (plist-get r :dir)
                 '(("Allow once" "y" "allow-once") ("Allow directory for session" "s" "allow-session")
                   ("Always allow directory" "a" "allow-always") ("Deny" "n" "deny-once"))
               '(("Allow" "y" "allow-once") ("Allow for session" "s" "allow-session")
                 ("Always allow" "a" "allow-always") ("Deny" "n" "deny-once") ("Always deny" "N" "deny-always"))))
        (offered (harness-ui-pending--offered-options r)))
    (or (and offered (cl-remove-if-not (lambda (o) (member (nth 2 o) offered)) all))
        all)))

(defun harness-ui-pending--decorate (start end pid map)
  "Make START..END the panel of request PID, with keymap MAP."
  (add-text-properties start end (list 'harness-ui-pending pid))
  (add-face-text-property start end 'harness-ui-panel-face t)
  (harness-ui-add-keymap start end map))

(defun harness-ui-pending--insert-permission (r)
  "Insert the panel for permission record R."
  (let ((pid (plist-get r :id))
        (session-id (harness-ui-pending--session))
        (start (point)))
    (insert (propertize (concat " " (harness-ui-icon 'harness-icon-blocked) " Permission  ") 'face 'harness-label-face)
            (harness-ui-tool-title-string (plist-get r :tool) (plist-get r :title))
            "\n")
    (let ((facts (delq nil (list (and (plist-get r :tool-kind) (format "kind: %s" (plist-get r :tool-kind)))
                                 (and (plist-get r :paths)
                                      (format "paths: %s" (mapconcat #'abbreviate-file-name (plist-get r :paths) " ")))))))
      (when facts (insert (propertize (concat "   " (string-join facts "   ") "\n") 'face 'harness-dim-face))))
    (when-let* ((input (plist-get r :input)))
      (insert (propertize (concat "   " (harness-ui-tool-input-summary input) "\n") 'face 'harness-dim-face)))
    (when-let* ((reason (plist-get r :reason)))
      (insert (propertize (format "   %s\n" reason) 'face 'harness-hint-face)))
    (insert "   ")
    (dolist (o (harness-ui-pending-permission-buttons r))
      (let ((option (nth 2 o)))
        (insert (harness-ui-action-button (format "[%s]" (nth 0 o))
                                          (lambda () (harness-ui-pending-answer-permission session-id pid option))
                                          :help (format "Answer %s (%s)" (nth 0 o) (nth 1 o)))
                " " (harness-ui-kbd (nth 1 o)) "  ")))
    (insert "\n")
    (harness-ui-pending--decorate start (point) pid harness-ui-pending-permission-map)))

;;;;; Diagrams of a question's options
;;
;; The options of a question may each have a diagram, ASCII art or an
;; image (all of them or none: the ask_user tool sees to it).  A panel
;; shows one at a time, in one area under the options: a line of tabs,
;; one per option, between previous and next arrows, then the diagram of
;; the option whose tab is current, whose label is bold in the list.  A
;; click on a tab or an arrow, n and p on the panel, C-c C-f and C-c C-b
;; anywhere in the buffer, and point moving onto an option's line switch
;; it.  Answering is as without diagrams: a digit, a click on the option,
;; or the compose box.  The chat redraws the options and the area alone,
;; in place, so point, the windows and the compose box stay put.

(defun harness-ui-pending--diagrams (r)
  "Return the diagrams of question record R, one per option, or nil.
Each is (:type \"ascii\" :text TEXT) or (:type \"image\" :path PATH :mime MIME)."
  (and (equal (plist-get r :kind) "question")
       (plist-get r :options)
       (append (plist-get r :diagrams) nil)))

(defun harness-ui-pending--shown-index (session-id pid count)
  "Return which option's diagram the panel of PID shows, valid for COUNT options."
  (let ((i (cdr (assoc pid (gethash session-id harness-ui-pending--diagrams)))))
    (if (and (integerp i) (< -1 i count)) i 0)))

(defun harness-ui-pending-shown-diagram (session-id pid)
  "Return the index of the option whose diagram the panel of PID shows."
  (harness-ui-pending--shown-index session-id pid
                                   (length (plist-get (harness-ui-pending-record session-id pid) :options))))

(defun harness-ui-pending--question-map (r)
  "Return the keymap of the panel of question record R."
  (if (harness-ui-pending--diagrams r)
      harness-ui-pending-diagram-map
    harness-ui-pending-question-map))

(defun harness-ui-pending--diagram-image (path mime)
  "Return a line showing the image file PATH, of type MIME, of a diagram.
A remote file is not read, which would block: a button opens it instead."
  (if (file-remote-p path)
      (concat (harness-ui-action-button (format "[image %s]" path) (lambda () (find-file-other-window path))
                                        :help "Open the image")
              "\n")
    (harness-ui-image-string path mime)))

(defun harness-ui-pending--diagram-string (diagram)
  "Return the lines showing DIAGRAM, one option's (see the diagrams above)."
  (let ((indent (propertize "     " 'face 'harness-ui-panel-face)))
    (pcase (format "%s" (plist-get diagram :type))
      ("ascii" (propertize (harness-ui-ensure-newline (plist-get diagram :text))
                           'face 'harness-ui-output-face 'line-prefix indent 'wrap-prefix indent))
      ("image" (propertize (harness-ui-pending--diagram-image (plist-get diagram :path) (plist-get diagram :mime))
                           'line-prefix indent 'wrap-prefix indent))
      (_ (propertize "     (no diagram)\n" 'face 'harness-dim-face)))))

(defun harness-ui-pending--diagram-nav (label nav action help face)
  "Return a button LABEL of a diagram area's tab line, running ACTION.
NAV names it, `previous', `next' or an option's index, so point stays
on it as the area is redrawn.  HELP is its tooltip, FACE its face."
  (propertize (harness-ui-action-button label action :help help :face face)
              'harness-ui-pending-diagram-nav nav))

(defun harness-ui-pending--diagram-area (session-id r shown)
  "Return the diagram area of question record R showing option SHOWN's diagram."
  (let ((pid (plist-get r :id))
        (options (plist-get r :options)))
    (concat
     (propertize "   Diagram " 'face 'harness-dim-face)
     (harness-ui-pending--diagram-nav " \N{U+2039} " 'previous (lambda () (harness-ui-pending-step-diagram session-id pid -1))
                                      "Show the diagram of the previous option (p, C-c C-b)" 'harness-dim-face)
     (mapconcat (lambda (i)
                  (harness-ui-pending--diagram-nav (format " %d " (1+ i)) i
                                                   (lambda () (harness-ui-pending-show-diagram session-id pid i))
                                                   (format "Show the diagram of option %d, %s" (1+ i) (nth i options))
                                                   (if (= i shown) 'harness-ui-key-face 'harness-dim-face)))
                (number-sequence 0 (1- (length options))) "")
     (harness-ui-pending--diagram-nav " \N{U+203A} " 'next (lambda () (harness-ui-pending-step-diagram session-id pid 1))
                                      "Show the diagram of the next option (n, C-c C-f)" 'harness-dim-face)
     "  "
     (propertize (nth shown options) 'face 'bold 'wrap-prefix "   ")
     "\n"
     (harness-ui-pending--diagram-string (nth shown (harness-ui-pending--diagrams r))))))

(defun harness-ui-pending--option-line (session-id pid option i shown)
  "Return the line of OPTION, the Ith of question PID; SHOWN: its diagram shows."
  (propertize
   (concat (propertize "   " 'wrap-prefix "       ")
           (if (< i 9) (harness-ui-kbd (format " %d " (1+ i))) "   ")
           " "
           (propertize (harness-ui-action-button option
                                                 (lambda () (harness-ui-pending-answer-question session-id pid option))
                                                 :face (if shown 'bold 'default)
                                                 :help (if (< i 9) (format "Answer with this option (%d)" (1+ i))
                                                         "Answer with this option"))
                       'wrap-prefix "       ")
           "\n")
   'harness-ui-pending-option i))

(defun harness-ui-pending-question-body (session-id r)
  "Return the options of question record R of SESSION-ID, then its diagram area.
The text is marked `harness-ui-pending-question-body', so that switching
the diagram redraws it alone (`harness-ui-pending--redraw-question')."
  (let* ((pid (plist-get r :id))
         (shown (and (harness-ui-pending--diagrams r)
                     (harness-ui-pending--shown-index session-id pid (length (plist-get r :options))))))
    (propertize
     (concat (apply #'concat (seq-map-indexed (lambda (option i)
                                                (harness-ui-pending--option-line session-id pid option i (eql i shown)))
                                              (plist-get r :options)))
             (if shown (concat "\n" (harness-ui-pending--diagram-area session-id r shown)) ""))
     'harness-ui-pending-question-body pid)))

(defun harness-ui-pending--insert-question (r)
  "Insert the panel for question record R.
The question and each option get a line of their own, wrapped under
their indentation; digit keys pick an option while point is on the panel.
Options with diagrams get the area showing one of them under them."
  (let ((pid (plist-get r :id))
        (session-id (harness-ui-pending--session))
        (start (point)))
    (insert (propertize (concat " " (harness-ui-icon 'harness-icon-question) " Question") 'face 'harness-label-face)
            "\n"
            (propertize (concat "   " (or (plist-get r :question) "")) 'face 'bold 'wrap-prefix "   ")
            "\n")
    (when (plist-get r :options)
      (insert "\n" (harness-ui-pending-question-body session-id r)))
    (insert (cond ((not (plist-get r :options))
                   (propertize "   type your answer below\n" 'face 'harness-dim-face))
                  ((harness-ui-pending--diagrams r)
                   (concat "\n   " (harness-ui-kbd "C-c C-f")
                           (propertize " next diagram, " 'face 'harness-dim-face)
                           (harness-ui-kbd "C-c C-b")
                           (propertize " previous\n   or type another answer below\n" 'face 'harness-dim-face)))
                  (t (propertize "\n   or type another answer below\n" 'face 'harness-dim-face))))
    (harness-ui-pending--decorate start (point) pid (harness-ui-pending--question-map r))))

(defun harness-ui-pending-insert-panel (r)
  "Insert the panel for request record R at point."
  (if (equal (plist-get r :kind) "question")
      (harness-ui-pending--insert-question r)
    (harness-ui-pending--insert-permission r)))

(defun harness-ui-pending-insert-panels (&optional session-id)
  "Insert the panels of SESSION-ID's requests at point, oldest first."
  (dolist (r (harness-ui-pending-items (or session-id (harness-ui-pending--session))))
    (harness-ui-pending-insert-panel r)))

;;;;; Redrawing a question in place

(defun harness-ui-pending--question-body-region (pid)
  "Return (START . END) of the options and diagram area of question PID, or nil.
The panel is drawn in this buffer, the chat's tail say."
  (let ((pos (point-min)) (limit (point-max)) found)
    (while (and pos (not found) (< pos limit))
      (let ((next (next-single-property-change pos 'harness-ui-pending-question-body nil limit)))
        (when (equal (get-text-property pos 'harness-ui-pending-question-body) pid)
          (setq found (cons pos next)))
        (setq pos next)))
    found))

(defun harness-ui-pending--redraw-question (r)
  "Redraw the options and diagram area of question record R in place.
Point and the windows stay where they were; point on a tab or an arrow
stays on it.  Nothing happens where the panel is not drawn in this
buffer, as in a popout, which draws itself whole again instead."
  (let* ((session-id (harness-ui-pending--session))
         (pid (plist-get r :id))
         (region (harness-ui-pending--question-body-region pid)))
    (when region
      (let ((nav (and (equal (get-text-property (point) 'harness-ui-pending-question-body) pid)
                      (get-text-property (point) 'harness-ui-pending-diagram-nav)))
            (text (harness-ui-pending-question-body session-id r))
            (from (car region)))
        (harness-ui-replace-region from (cdr region) text)
        (let ((inhibit-read-only t)
              (buffer-undo-list t)
              (end (+ from (length text))))
          (harness-ui-pending--decorate from end pid (harness-ui-pending--question-map r))
          (put-text-property from end 'read-only t)
          (when-let* ((pos (and nav (text-property-any from end 'harness-ui-pending-diagram-nav nav))))
            (goto-char pos)))))))

(defun harness-ui-pending-show-diagram (session-id pid index)
  "Show the diagram of option INDEX of question PID of SESSION-ID, counting round."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless (harness-ui-pending--diagrams r)
      (user-error "This question has no diagrams"))
    (let ((i (mod index (length (plist-get r :options)))))
      (unless (= i (harness-ui-pending-shown-diagram session-id pid))
        (setf (alist-get pid (gethash session-id harness-ui-pending--diagrams) nil nil #'equal) i)
        ;; The buffer drawing the panel redraws it in place; a popout of the
        ;; same request, which draws itself whole, is refreshed here.
        (harness-ui-pending--redraw-question r)
        (harness-ui-pending--popout-changed session-id)))))

(defun harness-ui-pending-step-diagram (session-id pid n)
  "Show the diagram N options after the one question PID shows, counting round."
  (harness-ui-pending-show-diagram session-id pid (+ (harness-ui-pending-shown-diagram session-id pid) n)))

;;;; Bringing the ACP requests in

(defun harness-ui-pending--on-permission (params respond)
  "Own permission request PARAMS, with RESPOND; return non-nil when taken.
The request is owned when a buffer draws the session it belongs to
\(its chat, or a popout of it); otherwise it stays pending and other
clients, or the session's own pending list, answer it."
  (let ((session-id (plist-get params :sessionId)))
    (when (harness-ui-pending--drawn-anywhere-p session-id)
      (let* ((tc (plist-get params :toolCall))
             (extra (plist-get params :_harness))
             (pid (or (plist-get extra :pendingId) (plist-get tc :toolCallId) (harness-short-id 6))))
        (harness-ui-pending-add
         session-id
         (list :id pid :kind "permission" :respond respond :created (float-time)
               :title (or (plist-get tc :title) (plist-get extra :tool) "tool call")
               :tool (plist-get extra :tool) :tool-kind (format "%s" (plist-get tc :kind))
               :input (plist-get tc :rawInput) :paths (plist-get extra :paths)
               :dir (plist-get extra :dir) :reason (plist-get extra :reason)
               :options (plist-get params :options))))
      t)))

(defun harness-ui-pending--on-question (params respond)
  "Own question PARAMS, with RESPOND; return non-nil when taken."
  (let ((session-id (plist-get params :sessionId)))
    (when (harness-ui-pending--drawn-anywhere-p session-id)
      (harness-ui-pending-add
       session-id
       (list :id (or (plist-get params :requestId) (harness-short-id 6)) :kind "question" :respond respond
             :created (float-time)
             :question (plist-get params :question) :options (plist-get params :options)
             :diagrams (plist-get params :diagrams)))
      t)))

(defvar harness-ui-pending-drawn-predicates nil
  "Functions saying whether some buffer draws a session's requests.
Each takes a session id and returns non-nil when a buffer showing that
session's requests is open: a chat buffer for it, or a popout of them.
The chat adds one; without any, no ACP request is taken over and every
request is answered from the session's pending list instead.")

(defun harness-ui-pending--drawn-anywhere-p (session-id)
  "Non-nil when a buffer draws the requests of SESSION-ID."
  (and session-id
       (cl-some (lambda (fn) (ignore-errors (funcall fn session-id)))
                harness-ui-pending-drawn-predicates)))

;;;; The popout

(defun harness-ui-pending--popout-key (session-id)
  "Return the popout KEY of the requests of SESSION-ID."
  (list 'pending session-id))

(defun harness-ui-pending--popout-title (session-id)
  "Return the title of the popout of SESSION-ID's requests."
  (let ((session (harness-ui-session session-id))
        (status (harness-ui-pending-status (harness-ui-session session-id))))
    (format "%s · %s" (if session (harness-ui-session-label session) session-id)
            (if (equal status "question") "question" "permission"))))

(defun harness-ui-pending--popout-submit (session-id)
  "Return what the popout box of SESSION-ID sends with, or nil for no box.
A question is answered with the typed text; otherwise there is no box."
  (when (harness-ui-pending-question session-id)
    (lambda (text atts)
      (when atts (user-error "Answers cannot carry attachments"))
      (let ((q (harness-ui-pending-question session-id)))
        (if q (harness-ui-pending-answer-question session-id (plist-get q :id) text)
          (user-error "No question is waiting"))))))

(defun harness-ui-pending--popout-render (session-id)
  "Draw the content of the popout of SESSION-ID at point."
  (setq-local harness-ui-pending-session-id session-id)
  (harness-ui-pending-insert-panels session-id))

(defun harness-ui-pending-popout (session-id &optional keep-pos)
  "Show the popout of what SESSION-ID waits on, and return its buffer.
Nothing happens, and nil is returned, when it waits on nothing.  KEEP-POS
non-nil shows it without selecting its window (a refresh, say)."
  (when (and session-id (harness-ui-pending-items session-id))
    (unless (fboundp 'harness-ui-popout-show) (user-error "The popout module is not loaded"))
    (let ((buffer (harness-ui-popout-show
                   (harness-ui-pending--popout-key session-id)
                   (lambda () (harness-ui-pending--popout-title session-id))
                   (lambda () (harness-ui-pending--popout-render session-id))
                   :compose (lambda () (harness-ui-pending--popout-submit session-id))
                   :placeholder "Type an answer…"
                   :dir (plist-get (harness-ui-session session-id) :cwd))))
      (when keep-pos
        (let ((window (get-buffer-window buffer)))
          (when (window-live-p window) (set-window-point window (point)))))
      buffer)))

(defun harness-ui-pending--popout-changed (session-id)
  "Redraw the popout of SESSION-ID, or close it once nothing waits.
On `harness-ui-pending-changed-hook'."
  (when (fboundp 'harness-ui-popout-refresh)
    (let ((key (harness-ui-pending--popout-key session-id)))
      (if (harness-ui-pending-items session-id)
          (harness-ui-popout-refresh key)
        (harness-ui-popout-close key t)))))

(defun harness-ui-pending-popout-at-point ()
  "Pop out what the session at point waits on, if any.
On `harness-ui-popout-at-point-functions', so views that say which
session point stands for get the popout with one key."
  (when-let* ((session-id (and harness-ui-session-at-point-function
                               (harness-ui-session-at-point t)))
              ((harness-ui-pending-items session-id)))
    (harness-ui-pending-popout session-id)
    t))

;;;; Module

(defun harness-ui-pending--init ()
  "Join the UI: own ACP requests, and pop out what a session waits on."
  (add-hook 'harness-ui-permission-functions #'harness-ui-pending--on-permission)
  (add-hook 'harness-ui-question-functions #'harness-ui-pending--on-question)
  (when (boundp 'harness-ui-popout-at-point-functions)
    (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-pending-popout-at-point)))

(add-hook 'harness-ui-pending-changed-hook #'harness-ui-pending--popout-changed)

(harness-define-module 'ui-pending
  :doc "Requests a session waits on: panels, answering and the popout."
  :requires '(ui ui-compose)
  :init #'harness-ui-pending--init)

(provide 'harness-ui-pending)
;;; harness-ui-pending.el ends here
