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
;;
;; A panel's keys -- a question's digits, a permission's y, s, a, n and N
;; -- act with point on the panel.  In the compose box they type, so each
;; panel is a panel of the box (`harness-compose-panel'): its C-c . reads
;; a key and presses it on the nearest panel that has it
;; (`harness-compose-panel-key'), and every panel says so in a dim line.
;;
;; An answer that lasts (Allow for session, Always allow, Always deny)
;; records a rule, and the panel says what the rule will cover before it
;; is given (see "What the lasting answers cover"): a prompt about a call
;; lists the covers the harness worked out for it, from the narrowest
;; (this exact command) to the widest (every call of the tool), and one
;; about a path outside the allowed directories lists the patterns around
;; its own.  A click on a line, or < and >, picks the one the answers hold
;; for; the least permissive stays one step away.
;;
;; A question that allows several options (`:allow-multiple', ask_user's
;; `allow_multiple') draws its options as check boxes.  A digit or a
;; click ticks or unticks one instead of answering; the options ticked
;; are the request's own state, so a chat and a popout of it agree, and
;; are answered with C-c C-c (or the panel's [Send answer]), together with
;; what the box holds: the options ticked, a line each, then the words.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)                  ; `harness-acp-permission-answers'
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-markdown)

(defgroup harness-ui-pending nil
  "Requests a session waits on: permissions and questions." :group 'harness-ui)

;; The mark of a line of covers or patterns that is picked, and of one
;; that is not: a ring with a dot in it, and a ring.
(harness-ui-define-icon harness-icon-radio-on "radio-on" "◉" "(*)"
                        "A choice that is picked: a ring with a dot in it.")
(harness-ui-define-icon harness-icon-radio-off "radio-off" "○" "( )"
                        "A choice that is not picked: a ring.")

;; The same for an option of a question that allows several: a box with
;; a check in it, and an empty one.
(harness-ui-define-icon harness-icon-check-on "check-on" "☑" "[x]"
                        "An option that is ticked: a box with a check in it.")
(harness-ui-define-icon harness-icon-check-off "check-off" "☐" "[ ]"
                        "An option that is not ticked: an empty box.")

(declare-function harness-ui-popout-show "harness-ui-popout")
(declare-function harness-ui-popout-refresh "harness-ui-popout")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-ui-popout-pixel-width "harness-ui-popout" (&optional window))
(declare-function harness-ui-popout-pixel-height "harness-ui-popout" (&optional lines))
(declare-function harness-ui-popout-submit "harness-ui-popout")
(declare-function harness-chat--buffer-for "harness-ui-chat" (session-id))

;;;; The store

(defvar harness-ui-pending--requests (make-hash-table :test 'equal)
  "Session id -> the request records it waits on, oldest first.
A record is a plist: `:id' `:kind' (\"permission\" or \"question\"),
`:respond' (the ACP callback, when a client owns the request, else nil),
`:connection' (the UI connection it came on, so an answer still goes out
on it), `:created', and what its panel draws: `:title' `:tool' `:tool-kind'
`:input' `:paths' `:cwd' `:pattern' `:dir' `:commands' `:covers'
`:reason' `:options' for a permission (`:paths' are what the call is
about, `:cwd' where a shell command runs, `:pattern' the glob the
answer holds for, and `:edited-pattern' the one the user typed;
`:commands' are the command patterns a shell call's lasting answers
hold for, and `:covers' words them for the panel), `:question'
`:options' `:diagrams' for a question, and `:allow-multiple' when the
user may tick several of its options.  A permission also has the
`:call-id' of the tool call that waits on it, and, when the harness
worked out what its lasting answers could cover, a `:ladder' of covers
\(plists of `:id' and `:label', narrowest first), the id of the one they
start on, `:cover', and the id the user picked instead, `:picked-cover'.")

(defvar harness-ui-pending--diagrams (make-hash-table :test 'equal)
  "Session id -> (PID . INDEX) of the diagram its panel shows.
The state belongs to the request, not to the buffer drawing it, so a
chat and a popout showing the same question show the same diagram.")

(defvar harness-ui-pending--picked (make-hash-table :test 'equal)
  "Session id -> alist of (PID . INDICES), the options ticked of its questions.
Only a question that allows several options has any (`:allow-multiple');
INDICES count from 0, smallest first.  Like the diagram shown, they
belong to the request, so a chat and a popout showing the same question
show the same boxes ticked, and answer with the same options.")

(defvar harness-ui-pending--expanded (make-hash-table :test 'equal)
  "Session id -> the ids of its permission requests whose input shows whole.
Like a question's diagram, this belongs to the request, so a chat and a
popout showing the same request show it the same.")

(defvar harness-ui-pending--answered (make-hash-table :test 'equal)
  "Session id -> (PID . TIME) of requests answered here.
The session's own pending list lags an answer by a round trip; this
keeps the request off the panels meanwhile, so answering one does not
bring it back for a moment.")

(defvar harness-ui-pending--images (make-hash-table :test 'equal)
  "(SESSION-ID PID INDEX) -> the image of that option, fetched from the harness.
\(loading), a list of its own for each time it is asked for, while it
is; then (:data BASE64 :mime MIME), or (:error MESSAGE) when the
harness could not give it.  Only for images this Emacs cannot read
itself (`harness-ui-pending--fetch-p'); a request leaving the store
takes its images along.")

(defvar harness-ui-pending-changed-hook nil
  "Hook run with a session id after its requests change.
The chat redraws its tail for it, an open popout its content.")

(defvar-local harness-ui-pending-session-id nil
  "Session id whose requests this buffer draws.
The chat leaves it nil, so its `harness-ui-session-id' applies; a
popout sets it to the session its item belongs to.")

(defvar-local harness-ui-pending-box-hints t
  "Non-nil when the panels drawn in this buffer say how to press a key from a box.
A panel's keys type into the compose box of a chat or a popout, so the
panel says how to press them from there.  A view without a compose box
sets this to nil.")

(defun harness-ui-pending--str (value)
  "Return VALUE as a string (a symbol or string), or nil for nil."
  (when value (if (symbolp value) (symbol-name value) (format "%s" value))))

(defun harness-ui-pending--session ()
  "Return the session id whose requests this buffer draws, or nil."
  (or harness-ui-pending-session-id
      (and (boundp 'harness-ui-session-id) harness-ui-session-id)))

(defun harness-ui-pending--forget-all ()
  "Forget every request, its diagrams and the answers just given.
Which requests show their input whole, the options ticked and the
images fetched for them, are forgotten too."
  (clrhash harness-ui-pending--requests)
  (clrhash harness-ui-pending--diagrams)
  (clrhash harness-ui-pending--picked)
  (clrhash harness-ui-pending--expanded)
  (clrhash harness-ui-pending--answered)
  (clrhash harness-ui-pending--images))

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

(defun harness-ui-pending--session-kind (session)
  "Return the kind of the request SESSION waits on, or nil.
The store is asked first: it knows a request as soon as it arrives,
while the session's own pending list may lag a round trip behind."
  (let* ((items (harness-ui-pending-items (plist-get session :id)))
         (item (car (or items (plist-get session :pending)))))
    (when item (format "%s" (plist-get item :kind)))))

(defun harness-ui-pending-summary (session)
  "Say what SESSION waits on, one short line, or nil.
This is for cards and rows that say what a session needs without
opening it."
  (when-let* ((kind (harness-ui-pending--session-kind session)))
    (if (equal kind "question") "has a question for you" "needs your permission")))

(defun harness-ui-pending-status (session)
  "Return \"question\", \"permission\" or nil: what SESSION waits on."
  (when-let* ((kind (harness-ui-pending--session-kind session)))
    (if (equal kind "question") "question" "permission")))

(defun harness-ui-pending--changed (session-id)
  "Run `harness-ui-pending-changed-hook' for SESSION-ID."
  (when session-id
    (run-hook-with-args 'harness-ui-pending-changed-hook session-id)))

(defun harness-ui-pending--put (session-id records)
  "Store RECORDS for SESSION-ID and tell the hosts it changed."
  (if records
      (puthash session-id records harness-ui-pending--requests)
    (remhash session-id harness-ui-pending--requests))
  (harness-ui-pending--forget-images session-id records)
  (harness-ui-pending--forget-picks session-id records)
  (harness-ui-pending--changed session-id))

(defun harness-ui-pending--forget-picks (session-id records)
  "Forget the options ticked of the questions of SESSION-ID not in RECORDS."
  (when-let* ((picks (gethash session-id harness-ui-pending--picked)))
    (let ((kept (cl-remove-if-not
                 (lambda (cell)
                   (cl-find (car cell) records :key (lambda (r) (plist-get r :id)) :test #'equal))
                 picks)))
      (if kept
          (puthash session-id kept harness-ui-pending--picked)
        (remhash session-id harness-ui-pending--picked)))))

(defun harness-ui-pending--forget-images (session-id records)
  "Forget the images fetched for the requests of SESSION-ID not in RECORDS."
  (let (gone)
    (maphash (lambda (key _)
               (when (and (equal (car key) session-id)
                          (not (cl-find (nth 1 key) records :key (lambda (r) (plist-get r :id)) :test #'equal)))
                 (push key gone)))
             harness-ui-pending--images)
    (dolist (key gone) (remhash key harness-ui-pending--images))))

(defun harness-ui-pending--keep-choices (old record)
  "Return RECORD with what the user chose on OLD, the same request drawn before.
That is the pattern they edited, and the cover they picked while
RECORD's ladder still has it: a request that arrives again, from the
session's pending list, must not undo what they chose on its panel."
  (when-let* ((edited (plist-get old :edited-pattern)))
    (setq record (plist-put (copy-sequence record) :edited-pattern edited)))
  (when-let* ((picked (plist-get old :picked-cover))
              ((harness-ui-pending--ladder-step record picked)))
    (setq record (plist-put (copy-sequence record) :picked-cover picked)))
  record)

(defun harness-ui-pending-add (session-id record)
  "Add or replace RECORD among the requests SESSION-ID waits on.
An answer already given here wins over news of the request still
arriving: the record keeps its `:respond' and does not come back.  A
pattern the user edited is kept too, for the same reason, and so is the
cover they picked (see `harness-ui-pending--keep-choices')."
  (let* ((pid (plist-get record :id))
         (old (harness-ui-pending-record session-id pid))
         (record (if (and old (plist-get old :respond) (not (plist-get record :respond)))
                     old
                   (harness-ui-pending--keep-choices old record)))
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
  "Remember that PID of SESSION-ID was answered here.
`harness-ui-pending-sync' keeps such a request off the panels."
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
              :diagrams (plist-get payload :diagrams) :cowboy (plist-get payload :cowboy)
              :allow-multiple (and (harness-json-true-p (plist-get payload :allow-multiple)) t))
      (list :id (plist-get item :id) :kind "permission" :created (float-time)
            :title (or (plist-get payload :title) (plist-get payload :tool) "tool call")
            :call-id (plist-get payload :call-id)
            :tool (plist-get payload :tool) :tool-kind (harness-ui-pending--str (plist-get payload :kind))
            :input (plist-get payload :input) :paths (plist-get payload :paths) :cwd (plist-get payload :cwd)
            :dir (plist-get payload :dir) :pattern (plist-get payload :pattern)
            :commands (plist-get payload :commands) :covers (plist-get payload :covers)
            :ladder (plist-get payload :ladder) :cover (plist-get payload :cover)
            :reason (plist-get payload :reason)
            :options (plist-get payload :options)))))

(defun harness-ui-pending-sync-session (session-id)
  "Learn SESSION-ID's requests from its cached session plist.
A view can know that a session waits -- the plist's `:pending' says so --
before anything has drawn the requests into the store: no chat is open
for it.  Bringing them in lets a view's popout show and answer them
\(see `harness-ui-pending-popout')."
  (when-let* ((session (harness-ui-session session-id)))
    (harness-ui-pending-sync session-id (plist-get session :pending))))

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

;;;; The answers, the same for every request
;;
;; Every permission request -- a tool call, a call reaching outside the
;; allowed directories, an agent asking for a directory -- is answered
;; with the same five options, under the same labels
;; (`harness-acp-permission-answers', the option names ACP clients get
;; too) and, wherever a request is answered from the keyboard, the same
;; keys (`harness-ui-pending-permission-keys').  What an answer covers
;; depends on the request, and its tooltip and the echo area after it
;; say so (`harness-ui-pending-answer-help'): Allow lets a call run, lets
;; one call reach the pattern of a request about a path outside, and
;; grants the directory an agent asked for until its turn ends -- the
;; narrowest allow, which records nothing.  The answers that last cover
;; what the panel lists above them, and it is for the user to pick (see
;; "What the lasting answers cover").

(defconst harness-ui-pending-permission-keys
  '(("allow-once" . "y") ("allow-session" . "s") ("allow-always" . "a")
    ("deny-once" . "n") ("deny-always" . "N"))
  "The key of each permission answer, by option id.
Every panel binds them all (`harness-ui-pending-permission-map'); a view
answering a request in place (the session list, the task board) binds
those of its buttons, y and n.")

(defconst harness-ui-pending--dir-request-tool "request_directory_access"
  "The tool an agent asks for a directory with.
That is `harness-perms-dir-tool', which the UI does not load when the
harness runs in a process of its own.")

(defun harness-ui-pending-answer-label (option)
  "Return the label of permission answer OPTION, an id such as \"allow-once\"."
  (or (nth 1 (assoc option harness-acp-permission-answers)) option))

(defun harness-ui-pending-answer-key (option)
  "Return the key answering a permission request with OPTION, or nil."
  (cdr (assoc option harness-ui-pending-permission-keys)))

(defun harness-ui-pending--dir-request-p (r)
  "Non-nil when permission record R is an agent's own request for a directory."
  (equal (plist-get r :tool) harness-ui-pending--dir-request-tool))

(defun harness-ui-pending-answer-help (r option)
  "Say what answering permission record R with OPTION does, in a few words.
The answers are the same for every request, but not what they cover:
the call itself, whose tool a lasting answer holds for, or whose
commands when the call is a shell command the harness read, or, when
the harness listed the covers it could have (`:ladder'), the one picked
\(see `harness-ui-pending--cover-label'); the pattern of a call reaching
outside the allowed directories, which allow-once lets that call reach;
or the directory an agent asked for, which allow-once grants until the
session's turn ends."
  (let ((pattern (or (harness-ui-pending--permission-pattern r)
                     (and (plist-get r :dir) (harness-abbreviate-file-name (format "%s" (plist-get r :dir))))))
        (tool (or (plist-get r :tool) "this tool"))
        (covers (plist-get r :covers))
        (label (harness-ui-pending--cover-label r))
        (request (harness-ui-pending--dir-request-p r)))
    (pcase option
      ("allow-once" (cond ((and request pattern) (format "Allow %s until this turn ends" pattern))
                          (pattern (format "Let this call reach %s, this time" pattern))
                          (t "Allow this call, this time")))
      ("allow-session" (cond (pattern (format "Allow %s for this session" pattern))
                             (label (format "Allow %s for this session" label))
                             (covers (format "Allow every %s call for this session" covers))
                             (t (format "Allow every %s call for this session" tool))))
      ("allow-always" (cond (pattern (format "Always allow %s, in every session" pattern))
                            (label (format "Always allow %s, in every session" label))
                            (covers (format "Always allow every %s call, in every session" covers))
                            (t (format "Always allow every %s call, in every session" tool))))
      ("deny-once" (if request "Deny the request" "Deny this call"))
      ("deny-always" (cond (pattern (format "Always deny %s, to every tool" pattern))
                           (label (format "Always deny %s" label))
                           (covers (format "Always deny every %s call" covers))
                           (t (format "Always deny every %s call" tool))))
      (_ (harness-ui-pending-answer-label option)))))

;;;; Answering

(defun harness-ui-pending--message-for (r option)
  "Return the echo-area message after answering permission record R with OPTION.
It says what the answer covered, as its button's tooltip did."
  (let ((shown (or (harness-ui-pending--permission-pattern r)
                   (and (plist-get r :dir) (harness-abbreviate-file-name (format "%s" (plist-get r :dir))))))
        (covers (plist-get r :covers))
        (label (harness-ui-pending--cover-label r)))
    (pcase option
      ("allow-once" (cond ((and shown (harness-ui-pending--dir-request-p r))
                           (format "Allowed %s until this turn ends" shown))
                          (shown (format "Allowed this call to reach %s" shown))
                          (t "Allowed this call")))
      ("allow-session" (cond (shown (format "Allowed %s for this session" shown))
                             (label (format "Allowed %s for this session" label))
                             (covers (format "Allowed every %s call for this session" covers))
                             (t "Allowed for this session")))
      ("allow-always" (cond (shown (format "Always allowed %s" shown))
                            (label (format "Always allowed %s" label))
                            (covers (format "Always allowed every %s call" covers))
                            (t "Always allowed")))
      ("deny-always" (cond (shown (format "Always denied %s" shown))
                           (label (format "Always denied %s" label))
                           (covers (format "Always denied every %s call" covers))
                           (t "Always denied")))
      (_ "Denied"))))

(defconst harness-ui-pending--lasting-options '("allow-session" "allow-always" "deny-always")
  "The permission answers that last: each records a rule, or a grant.
Allow and Deny hold for the one call and record nothing.")

(defun harness-ui-pending--answer-extras (r option)
  "Return what answering permission record R with OPTION carries beside it.
That is `:cover' with the id of the cover picked from R's ladder, for an
answer that lasts only (`harness-ui-pending--lasting-options'): the
others record nothing, so there is nothing for a cover to say; then
`:pattern' with the pattern the user edited.  Nil when it carries
neither."
  (append (and (member option harness-ui-pending--lasting-options)
               (when-let* ((cover (harness-ui-pending--cover-id r)))
                 (list :cover cover)))
          (when-let* ((edited (plist-get r :edited-pattern)))
            (list :pattern edited))))

(defun harness-ui-pending-answer-permission (session-id pid option &optional on-error)
  "Answer permission request PID of SESSION-ID with OPTION.
OPTION is an option id such as \"allow-once\".  A pattern the user
edited goes with the answer (see `harness-ui-pending-edit-pattern'), and
for an answer that lasts the cover the user picked from the request's
ladder (see `harness-ui-pending--answer-extras').  An ACP request is
answered through the function that holds it; one only known from the
session's pending list goes over `_harness/permission/answer', and
ON-ERROR, when given, is called with the error should that fail (else
the echo area says so).  An answer the request does not offer is
refused: its key does nothing else instead."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    (let ((extras (harness-ui-pending--answer-extras r option))
          (offered (harness-ui-pending--offered-options r)))
      (when (and offered (not (member option offered)))
        (user-error "This request does not offer %s" (harness-ui-pending-answer-label option)))
      (unless (harness-ui-pending--respond
               r (append (list :outcome (list :outcome "selected" :optionId option))
                         (and extras (list :_harness extras))))
        (harness-ui-call "_harness/permission/answer"
                         (list :session-id session-id :pending-id pid
                               :answer (if extras (append (list :option option) extras) option))
                         #'ignore on-error))
      (harness-ui-pending-remove session-id pid)
      (message "%s" (harness-ui-pending--message-for r option)))))

(defun harness-ui-pending-answer-question (session-id pid answer &optional on-error attachments)
  "Answer question PID of SESSION-ID with ANSWER.
ON-ERROR is as for `harness-ui-pending-answer-permission'.
ATTACHMENTS, the files the user attached to the answer (attachment
plists, as a compose box holds them), go with it: the harness sends
them to the model with the answer, so a screenshot its text names by
its token, [image 1], is one the model sees (`question/answer').  They
go as a message's do (`harness-compose-attachment-block'), an image
with its bytes, so a harness on another machine gets it too."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    ;; Lists, never empty, which encode as arrays: the in-process
    ;; connection hands the values over as they are.
    (let ((blocks (mapcar #'harness-compose-attachment-block attachments)))
      (unless (harness-ui-pending--respond
               r (append (list :answer answer) (and blocks (list :attachments blocks))))
        (harness-ui-call "_harness/question/answer"
                         (list :session-id session-id :pid pid
                               :answer (if blocks
                                           (list :answer answer :blocks (harness-acp-blocks-from-acp blocks))
                                         answer))
                         #'ignore on-error)))
    (harness-ui-pending-remove session-id pid)))

(defun harness-ui-pending--respond (r value)
  "Answer request record R through its RESPOND with VALUE.
Non-nil when it went out.  RESPOND answers the request on the
connection it came on, and only while that is the UI's live connection.
After the UI connected again (`harness-connect-remote', even back to the
same harness) the harness keeps the request pending, but would never
hear an answer sent on the old connection, and the session would stay
blocked: the caller then answers through the bus method instead
\(`permission/answer', `question/answer'), which is what this returns
nil for.  A record of the session's own pending list has no RESPOND at
all."
  (let ((respond (plist-get r :respond))
        (connection (plist-get r :connection)))
    (and respond
         (eq connection harness-ui-connection)
         (harness-acp-open-p connection)
         ;; Nil when it could not go out after all (see `harness-acp-set-handler').
         (funcall respond value))))

;;;; A question that allows several options
;;
;; The options ticked are kept per request (`harness-ui-pending--picked')
;; and drawn as check boxes.  The answer is made of them and of the words
;; typed in a box: the labels of the options ticked, in the order the
;; options were given, a line each, then the words.  That is text like any
;; other answer, which is all the harness, the model and the other
;; clients have to know of it.

(defun harness-ui-pending-multiple-p (r)
  "Non-nil when request record R lets the user tick several of its options."
  (and (equal (plist-get r :kind) "question")
       (plist-get r :allow-multiple)
       (plist-get r :options)
       t))

(defun harness-ui-pending-picked (session-id pid)
  "Return the indices of the options ticked of question PID of SESSION-ID.
They count from 0, smallest first.  That is nil when none is ticked, and
for a question that takes one answer."
  (let ((r (harness-ui-pending-record session-id pid)))
    (when (harness-ui-pending-multiple-p r)
      (let ((count (length (plist-get r :options))))
        (cl-remove-if-not (lambda (i) (< -1 i count))
                          (cdr (assoc pid (gethash session-id harness-ui-pending--picked))))))))

(defun harness-ui-pending-picked-labels (session-id pid)
  "Return the labels of the options ticked of question PID of SESSION-ID.
They are in the order the options were given."
  (let ((options (append (plist-get (harness-ui-pending-record session-id pid) :options) nil)))
    (mapcar (lambda (i) (nth i options)) (harness-ui-pending-picked session-id pid))))

(defun harness-ui-pending-compose-answer (session-id r text)
  "Return the answer that TEXT, typed in a box, makes to question record R.
R is a question of SESSION-ID.  That is TEXT itself, unless R allows
several options and some are ticked: then it is their labels, a line
each, and TEXT after them when it says anything."
  (let ((labels (and (harness-ui-pending-multiple-p r)
                     (harness-ui-pending-picked-labels session-id (plist-get r :id))))
        (text (if (stringp text) text "")))
    (if (null labels)
        text
      (string-join (append labels (unless (string-blank-p text) (list (string-trim text)))) "\n"))))

(defun harness-ui-pending-toggle-option (session-id pid index)
  "Tick option INDEX, from 0, of question PID of SESSION-ID, or untick it.
Only for a question that allows several options.  Where the options
have diagrams, the diagram shown is the option's.  Every panel showing
the question is drawn again in place, so that point and the windows stay."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless r (user-error "That question was answered already"))
    (unless (harness-ui-pending-multiple-p r) (user-error "This question takes one answer"))
    (unless (and (natnump index) (< index (length (plist-get r :options))))
      (user-error "No such option"))
    (let* ((picked (harness-ui-pending-picked session-id pid))
           (ticked (not (memq index picked)))
           (now (if ticked (sort (cons index picked) #'<) (remq index picked))))
      (setf (alist-get pid (gethash session-id harness-ui-pending--picked) nil t #'equal) now)
      ;; The option just ticked is the one to look at, where options have diagrams.
      (when (harness-ui-pending--diagrams r)
        (setf (alist-get pid (gethash session-id harness-ui-pending--diagrams) nil nil #'equal) index))
      (harness-ui-pending--redraw-everywhere session-id r)
      ;; Pressed from the box, the panel may be out of sight.
      (message "%s %s: %s" (if ticked "Ticked" "Unticked") (elt (plist-get r :options) index)
               (if now (format "%d of %d ticked" (length now) (length (plist-get r :options))) "none ticked")))))

(defvar-local harness-ui-pending-send-function nil
  "The command that sends the compose box of this buffer, or nil.
The chat and the popout set it (C-c C-c in both).  The panel of a
question that allows several options has a [Send answer] button, which
runs it, so that it does what the key does.")

(defun harness-ui-pending-send-picked (session-id pid)
  "Answer question PID of SESSION-ID with the options ticked, and the box's words.
This is what [Send answer] on the panel does.  The newest question is
the one the box answers, so for it the button runs the command that
sends the box (`harness-ui-pending-send-function'), with the options
ticked; any other question gets the options ticked alone."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless r (user-error "That question was answered already"))
    (let ((typed (and (harness-compose-live-p) (not (string-blank-p (harness-compose-text))))))
      (cond
       ((not (or typed (harness-ui-pending-picked session-id pid)))
        (user-error "Tick an option, or type an answer, first"))
       ((and harness-ui-pending-send-function
             (equal pid (plist-get (harness-ui-pending-question session-id) :id)))
        (call-interactively harness-ui-pending-send-function))
       (t (harness-ui-pending-answer-question
           session-id pid (harness-ui-pending-compose-answer session-id r "")))))))

(defun harness-ui-pending-picked-any-p (session-id)
  "Non-nil when the newest question of SESSION-ID has options ticked."
  (when-let* ((q (harness-ui-pending-question session-id)))
    (and (harness-ui-pending-picked session-id (plist-get q :id)) t)))

;;;; Patterns a prompt about paths is answered for
;;
;; A permission request about a path outside the allowed directories
;; (the jail's, or an agent's own request for a directory) is answered
;; for a glob pattern rather than for one file: its `:pattern', by
;; default everything in a directory, the root of the repository its
;; path lies in or the directory holding it.  The user edits
;; it, more or less specific, with `harness-ui-pending-edit-pattern'
;; (`e' on the panel, C-c C-p in the chat); the answer then carries the
;; edited pattern.  Any other request is about the call alone and comes
;; without a pattern, so its panel shows none.

(defun harness-ui-pending--permission-pattern (r)
  "Return the glob pattern permission record R is answered for, as shown, or nil.
That is the one the user edited, else the request's own, abbreviated."
  (or (plist-get r :edited-pattern)
      (and (stringp (plist-get r :pattern)) (harness-abbreviate-file-name (plist-get r :pattern)))))

(defconst harness-ui-pending--ancestors-near 3
  "How many of the directories above a remote pattern's own its lines list.
The nearest ones, before the last two: the home directory and the root
of the host, or the two highest of an absolute path.")

(defun harness-ui-pending--ancestor-patterns (dir)
  "Return the patterns of the directories above remote DIR, narrowest first.
Each is a directory's name and `**'.  The home directory of a login
comes after the directories in it, and the root of the host, the whole
host, is the last, since a path on a host has no repository root to
stop at (the harness cannot look).  A path with many directories keeps
the nearest few and the two highest, so the block does not grow with
it.  Nothing is looked up."
  (let (all (up (harness-remote-parent-dir dir)))
    (while up
      (push (concat up "**") all)
      (setq up (harness-remote-parent-dir up)))
    (setq all (nreverse all))
    (if (<= (length all) (+ harness-ui-pending--ancestors-near 2))
        all
      (append (cl-subseq all 0 harness-ui-pending--ancestors-near) (last all 2)))))

(defun harness-ui-pending--pattern-suggestions (r)
  "Return patterns more or less specific than permission record R's own.
The paths of the call itself, every file with one's extension in its
directory, that directory and each one above it up to the pattern's,
which may be the root of a repository, then the pattern and the
directory above its own: what
\\<minibuffer-local-map>\\[next-history-element] offers while editing,
narrowest first.  They are worked out from the names alone.

On a host there is no repository root to stop at, so the pattern is
followed by every directory above it (the nearest few and the two
highest of a long path): in a home directory the home directory
itself, and last the root of the host, the whole host, which is the
widest answer there is for it."
  (let* ((pattern (plist-get r :pattern))
         (dir (and (string-suffix-p "/**" pattern) (substring pattern 0 -2)))
         (remote (and dir (harness-file-remote-p dir)))
         (parent (and dir (not remote) (file-name-directory (directory-file-name dir))))
         (paths (mapcar (lambda (p) (format "%s" p)) (append (plist-get r :paths) nil)))
         ;; A path's own directory and those above it, while they lie
         ;; inside the pattern's directory.
         (dirs (lambda (p)
                 (let ((d (file-name-directory (directory-file-name p))) out)
                   (while (and d dir (string-prefix-p dir d) (not (equal d dir)))
                     (push (concat d "**") out)
                     (setq d (file-name-directory (directory-file-name d))))
                   (nreverse out)))))
    (delete-dups
     (mapcar #'harness-abbreviate-file-name
             (delq nil (append paths
                               (mapcar (lambda (p)
                                         (let ((d (file-name-directory p)))
                                           (and dir d (file-name-extension p) (string-prefix-p dir d)
                                                (concat d "*." (file-name-extension p)))))
                                       paths)
                               (mapcan (lambda (p) (funcall dirs p)) paths)
                               (list pattern)
                               (if remote
                                   (harness-ui-pending--ancestor-patterns dir)
                                 (list (and parent (not (equal parent dir)) (concat parent "**"))))))))))

(defun harness-ui-pending-set-pattern (session-id pid pattern)
  "Make PATTERN, or the request's own when nil, the one PID is answered for.
PID is a request of SESSION-ID.  The hosts drawing the request are
redrawn; point goes to the picked line of the request's patterns when
this buffer shows it."
  (harness-ui-pending--put
   session-id
   (mapcar (lambda (r)
             (if (equal (plist-get r :id) pid)
                 (plist-put (copy-sequence r) :edited-pattern pattern)
               r))
           (harness-ui-pending-items session-id)))
  (harness-ui-pending--goto-selected pid))

(defun harness-ui-pending--goto-selected (pid)
  "Put point on the picked line of the cover block of request PID, if drawn here.
After a redraw point is where the host left it: this takes it back to
the panel, so its keys go on working.  Failing the picked line, it goes
to the first line of the block.  The text properties are compared with
`equal', so the loop walks their changes."
  (cl-flet ((find (property)
              (let ((pos (point-min)) found)
                (while (and pos (not found))
                  (if (equal (get-text-property pos property) pid)
                      (setq found pos)
                    (setq pos (next-single-property-change pos property))))
                found)))
    (when-let* ((pos (and pid (or (find 'harness-ui-pending-selected) (find 'harness-ui-pending-cover)))))
      (goto-char pos))))

(defun harness-ui-pending-edit-pattern (&optional pid)
  "Edit the glob pattern the permission request PID is answered for.
PID defaults to the request at point, or else the newest one with a
pattern.  Only a request about a path outside the allowed directories
has one: everything in the root of the repository the path lies in,
or else in the directory holding it.  Edit it to be more specific (a
subdirectory, src/*.el, one file) or less (a parent directory).  `*'
matches within a name, `**' across directories; a relative pattern
is relative to the session's working directory.
\\<minibuffer-local-map>\\[next-history-element] offers patterns around
the request's own; an empty answer goes back to it."
  (interactive)
  (let* ((session-id (harness-ui-pending--session))
         (pid (or pid (harness-ui-pending-at-point)))
         (r (and pid (harness-ui-pending-record session-id pid))))
    ;; A newer request about the call alone has no pattern: it must not
    ;; hide the one of a request about a path outside.
    (unless (plist-get r :pattern)
      (setq r (cl-find-if (lambda (x) (plist-get x :pattern))
                          (reverse (harness-ui-pending-items session-id)))
            pid (plist-get r :id)))
    (unless r
      (user-error "No request about a path outside the allowed directories is waiting"))
    (let* ((own (harness-abbreviate-file-name (plist-get r :pattern)))
           (typed (string-trim (read-string "Pattern (* within a name, ** across directories): "
                                            (harness-ui-pending--permission-pattern r) nil
                                            (harness-ui-pending--pattern-suggestions r)))))
      (harness-ui-pending-set-pattern session-id pid
                                      (unless (or (string-empty-p typed) (equal typed own)) typed))
      (message "Answers now hold for %s"
               (harness-ui-pending--permission-pattern (harness-ui-pending-record session-id pid))))))

;;;; What the lasting answers cover
;;
;; Allow for session, Always allow and Always deny last: each records a
;; rule that decides later calls too, and the panel says what it will
;; cover before the answer is given, not only in a tooltip.  The harness
;; works the covers out from the call (see "Asking the user" in
;; harness-perms.el) and sends them as the request's ladder: steps from
;; the narrowest, this exact command or file, to the widest, every call
;; of the tool, each a few words naming what it leaves open ("every
;; gcloud call (any arguments)"), and the one the answers start on.  The
;; panel lists them as radio lines.  A click on a line, or < and >, picks
;; the one the lasting answers hold for, and the answer carries its id.
;; A request about a path outside the allowed directories has no ladder
;; from the harness: it is answered for a pattern, and its lines are the
;; patterns around its own (`harness-ui-pending--pattern-suggestions'),
;; picked the same way; `e' types any other.

(defun harness-ui-pending--step-id (step)
  "Return the id of ladder STEP, a plist, as a string."
  (harness-ui-pending--str (plist-get step :id)))

(defun harness-ui-pending--ladder (r)
  "Return the cover ladder of permission record R: its steps, narrowest first.
A step is a plist of `:id' and `:label'.  A step without either is left
out, and so is a ladder that is no list: it comes as a list, or over the
wire as a vector.  Nil when R has none."
  (and (equal (plist-get r :kind) "permission")
       (cl-remove-if-not (lambda (step)
                           (and (consp step)
                                (harness-ui-pending--step-id step)
                                (stringp (plist-get step :label))))
                         (and (sequencep (plist-get r :ladder))
                              (not (stringp (plist-get r :ladder)))
                              (append (plist-get r :ladder) nil)))))

(defun harness-ui-pending--ladder-step (r id)
  "Return the step of permission record R's ladder that has the id ID, or nil."
  (when-let* ((id (harness-ui-pending--str id)))
    (cl-find id (harness-ui-pending--ladder r)
             :key #'harness-ui-pending--step-id :test #'equal)))

(defun harness-ui-pending--cover-id (r)
  "Return the id of the cover permission record R's lasting answers hold for.
That is the step the user picked, else the one the harness started them
on (`:cover'), while the ladder still has it; else the narrowest.  Nil
when R has no ladder."
  (when-let* ((ladder (harness-ui-pending--ladder r)))
    (cond ((harness-ui-pending--ladder-step r (plist-get r :picked-cover))
           (harness-ui-pending--str (plist-get r :picked-cover)))
          ((harness-ui-pending--ladder-step r (plist-get r :cover))
           (harness-ui-pending--str (plist-get r :cover)))
          (t (harness-ui-pending--step-id (car ladder))))))

(defun harness-ui-pending--cover-label (r)
  "Return the words for what R's lasting answers cover, or nil without a ladder.
They are the label of the picked step, a noun phrase: \"every gcloud
call (any arguments)\"."
  (when-let* ((id (harness-ui-pending--cover-id r)))
    (plist-get (harness-ui-pending--ladder-step r id) :label)))

(defun harness-ui-pending--pattern-choices (r)
  "Return the patterns R's block lists, narrowest first, abbreviated.
That is what `harness-ui-pending--pattern-suggestions' offers, and the
pattern the user typed when it is none of them.  Nil when R is not
answered for a pattern."
  (when (stringp (plist-get r :pattern))
    (let ((suggestions (harness-ui-pending--pattern-suggestions r))
          (current (harness-abbreviate-file-name (harness-ui-pending--permission-pattern r))))
      (if (member current suggestions)
          suggestions
        (append suggestions (list current))))))

(defun harness-ui-pending--cover-steps (r)
  "Return the choices of permission record R's cover block as (ID LABEL).
Those of its ladder, narrowest first; for a request answered for a
pattern, the patterns, each its own id and label.  Nil when R has
neither."
  (cond ((harness-ui-pending--ladder r)
         (mapcar (lambda (step) (list (harness-ui-pending--step-id step) (plist-get step :label)))
                 (harness-ui-pending--ladder r)))
        ((stringp (plist-get r :pattern))
         (mapcar (lambda (pattern) (list pattern pattern)) (harness-ui-pending--pattern-choices r)))))

(defun harness-ui-pending--cover-selected (r)
  "Return the id of the choice of R's cover block that is picked now, or nil."
  (if (harness-ui-pending--ladder r)
      (harness-ui-pending--cover-id r)
    (when (stringp (plist-get r :pattern))
      (harness-abbreviate-file-name (harness-ui-pending--permission-pattern r)))))

(defun harness-ui-pending--lasting-names (r)
  "Return the names of the lasting answers R offers, as a phrase, or nil.
\"Allow for session, Always allow and Always deny\", say."
  (let* ((offered (harness-ui-pending--offered-options r))
         (names (delq nil (mapcar (lambda (option)
                                    (and (or (null offered) (member option offered))
                                         (harness-ui-pending-answer-label option)))
                                  harness-ui-pending--lasting-options))))
    (if (cdr names)
        (concat (string-join (butlast names) ", ") " and " (car (last names)))
      (car names))))

(defun harness-ui-pending--lasting-keys (r)
  "Return the keys of the lasting answers R offers, as \"s, a, N\", or nil."
  (let* ((offered (harness-ui-pending--offered-options r))
         (keys (delq nil (mapcar (lambda (option)
                                   (and (or (null offered) (member option offered))
                                        (harness-ui-pending-answer-key option)))
                                 harness-ui-pending--lasting-options))))
    (and keys (string-join keys ", "))))

(defun harness-ui-pending-set-cover (session-id pid id)
  "Make ID, a step of request PID's cover ladder, the one its answers hold for.
PID is a request of SESSION-ID.  The hosts drawing the request are
redrawn; point goes to the picked line when this buffer shows it."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless r (user-error "That request was answered already"))
    (unless (harness-ui-pending--ladder-step r id)
      (user-error "That request has no such cover"))
    (let ((id (harness-ui-pending--str id)))
      (unless (equal id (harness-ui-pending--cover-id r))
        (harness-ui-pending--put
         session-id
         (mapcar (lambda (x)
                   (if (equal (plist-get x :id) pid)
                       (plist-put (copy-sequence x) :picked-cover id)
                     x))
                 (harness-ui-pending-items session-id))))
      (harness-ui-pending--goto-selected pid))))

(defun harness-ui-pending--choose (session-id r id)
  "Make ID, a choice of permission record R's cover block, the picked one.
R is a request of SESSION-ID.  A step of a ladder becomes the cover; a
pattern the one R is answered for, and R's own pattern goes back to
being what it is when nothing was edited."
  (if (harness-ui-pending--ladder r)
      (harness-ui-pending-set-cover session-id (plist-get r :id) id)
    (harness-ui-pending-set-pattern session-id (plist-get r :id)
                                    (unless (equal id (harness-abbreviate-file-name (plist-get r :pattern))) id))))

(defun harness-ui-pending--move-cover (n pid)
  "Pick the choice N places on in the cover block of request PID.
PID defaults to the request at point, or else the newest with choices
to move between.  N is negative to go to a narrower cover, positive to
go to a wider one; at either end of the list nothing moves, and the echo
area says so."
  (let* ((session-id (harness-ui-pending--session))
         (named pid)
         (pid (or pid (harness-ui-pending-at-point)))
         (r (and pid (harness-ui-pending-record session-id pid))))
    ;; A request named by a button is the one to move, answered already or
    ;; not; for a key, a newer request with nothing to choose between must
    ;; not hide an older one that has.
    (unless (and r (cdr (harness-ui-pending--cover-steps r)))
      (when named
        (user-error (if r "That request has no covers to choose between" "That request was answered already")))
      (setq r (cl-find-if (lambda (x) (cdr (harness-ui-pending--cover-steps x)))
                          (reverse (harness-ui-pending-items session-id)))))
    (unless r
      (user-error "No permission request offers covers to choose between"))
    (let* ((steps (harness-ui-pending--cover-steps r))
           (i (or (cl-position (harness-ui-pending--cover-selected r) steps :key #'car :test #'equal) 0))
           (j (+ i n))
           (ladder (harness-ui-pending--ladder r)))
      (cond
       ((or (< j 0) (>= j (length steps)))
        (message "Already the %s %s: %s" (if (< j 0) "narrowest" "widest") (if ladder "cover" "pattern")
                 (cadr (nth i steps))))
       (t
        (harness-ui-pending--choose session-id r (car (nth j steps)))
        (message (if ladder "Lasting answers now cover %s" "Answers now hold for %s")
                 (cadr (nth j steps))))))))

(defun harness-ui-pending-cover-narrower (&optional pid)
  "Make the answers of permission request PID cover less: the next narrower line.
PID defaults to the request at point.  A request about a call lists the
covers its lasting answers can hold for, from the narrowest, this exact
command, to the widest, every call of the tool; one about a path outside
the allowed directories lists the patterns around its own.  At the
narrowest nothing changes."
  (interactive)
  (harness-ui-pending--move-cover -1 pid))

(defun harness-ui-pending-cover-wider (&optional pid)
  "Make the answers of permission request PID cover more: the next wider line.
PID defaults to the request at point; see
`harness-ui-pending-cover-narrower'.  At the widest nothing changes."
  (interactive)
  (harness-ui-pending--move-cover 1 pid))

(defun harness-ui-pending--steps-here-p ()
  "Nil when point is on a panel with no covers to choose between.
Its < and > have nothing to move there, so they type, into the compose
box (`harness-compose-acts-p')."
  (let* ((pid (get-text-property (point) 'harness-ui-pending))
         (r (and pid (harness-ui-pending-record (harness-ui-pending--session) pid))))
    (and r (cdr (harness-ui-pending--cover-steps r)) t)))

(put 'harness-ui-pending-cover-narrower 'harness-compose-acts-p #'harness-ui-pending--steps-here-p)
(put 'harness-ui-pending-cover-wider 'harness-compose-acts-p #'harness-ui-pending--steps-here-p)

;;;;; Drawing the covers

(defun harness-ui-pending--step-line (pid selected label action help &optional note)
  "Return the line of one choice of the cover block of request PID.
SELECTED non-nil marks it as the picked one: a ring with a dot, its
label bold.  LABEL is what it covers, ACTION (a function of no
arguments) what a click on it does, HELP its tooltip, and NOTE a dim word
after the label.  The picked line carries the property that takes
point back to it after a redraw (`harness-ui-pending--goto-selected')."
  (let ((line (concat (propertize "     " 'wrap-prefix "       ")
                      (propertize (harness-ui-action-button
                                   (concat (harness-ui-icon (if selected 'harness-icon-radio-on 'harness-icon-radio-off))
                                           " " label)
                                   ;; Weight alone: the panel's background shows through.
                                   action :face (if selected 'bold '(:weight normal)) :help help)
                                  'wrap-prefix "       ")
                      (if note (propertize (concat "  " note) 'face 'harness-dim-face) "")
                      "\n")))
    (if selected (propertize line 'harness-ui-pending-selected pid) line)))

(defun harness-ui-pending--cover-buttons (r &optional edit)
  "Return the buttons of the cover block of permission record R, on one line.
[Narrower] and [Wider] move the pick up and down the lines, and are
dim at the end they cannot go on to; EDIT adds [Edit], which types a
pattern of one's own.  The buttons that move are left out for a block
of one line."
  (let* ((pid (plist-get r :id))
         (steps (harness-ui-pending--cover-steps r))
         (i (or (cl-position (harness-ui-pending--cover-selected r) steps :key #'car :test #'equal) 0))
         (button (lambda (label key action help dim)
                   (concat (harness-ui-action-button label action :help help
                                                     :face (if dim 'harness-dim-face 'button))
                           " " (harness-ui-kbd key)))))
    (string-join
     (delq nil
           (list (and edit
                      (funcall button "[Edit]" "e" (lambda () (harness-ui-pending-edit-pattern pid))
                               "Edit the pattern, to make it more or less specific (e)" nil))
                 (and (cdr steps)
                      (funcall button "[Narrower]" "<" (lambda () (harness-ui-pending-cover-narrower pid))
                               "Pick the next line up, which covers less (<)" (= i 0)))
                 (and (cdr steps)
                      (funcall button "[Wider]" ">" (lambda () (harness-ui-pending-cover-wider pid))
                               "Pick the next line down, which covers more (>)" (= i (1- (length steps)))))))
     "  ")))

(defun harness-ui-pending--insert-ladder (r)
  "Insert the cover block of permission record R, which has a ladder.
A dim header says which answers the block is for, with their keys, then
comes a line for each step, narrowest first, the picked one marked; a
click on a line picks it.  A ladder of one step is that step on the
header's line.  Nothing is drawn when R offers no answer that lasts."
  (when-let* ((keys (harness-ui-pending--lasting-keys r)))
    (let* ((session-id (harness-ui-pending--session))
           (pid (plist-get r :id))
           (names (harness-ui-pending--lasting-names r))
           (ladder (harness-ui-pending--ladder r))
           (selected (harness-ui-pending--cover-id r))
           (header (propertize (format "   Lasting answers (%s) cover:" keys) 'face 'harness-dim-face))
           (start (point)))
      (if (null (cdr ladder))
          (insert header " " (propertize (plist-get (car ladder) :label) 'wrap-prefix "     ") "\n")
        (insert header "\n")
        (dolist (step ladder)
          (let ((id (harness-ui-pending--step-id step))
                (label (plist-get step :label)))
            (insert (harness-ui-pending--step-line
                     pid (equal id selected) label
                     (lambda () (harness-ui-pending-set-cover session-id pid id))
                     (format "Make %s cover %s (click)" names label)))))
        (insert "   " (harness-ui-pending--cover-buttons r) "\n"))
      (put-text-property start (point) 'harness-ui-pending-cover pid))))

(defun harness-ui-pending--pick-pattern (session-id pid pattern)
  "Make PATTERN the one request PID of SESSION-ID is answered for.
A click on a line of the block of patterns does this; the request may
have been answered since it was drawn."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless r (user-error "That request was answered already"))
    (harness-ui-pending--choose session-id r pattern)))

(defun harness-ui-pending--pattern-place (pattern)
  "Return a word for what remote PATTERN holds as a whole, or nil.
\"home directory\" for the home directory of a login (/ssh:box:~/**) and
\"whole host\" for the root of a host (/ssh:box:/**), the places a line of
the block of patterns would otherwise leave its reader to work out."
  (let ((dir (if (string-suffix-p "/**" pattern) (substring pattern 0 -2) pattern)))
    (cond ((and (harness-remote-home-p dir)
                (member (nth 2 (harness-remote-home-parts dir)) '("" "/")))
           "home directory")
          ((and (harness-file-remote-p dir) (member (harness-file-remote-p dir 'localname) '("" "/")))
           "whole host"))))

(defun harness-ui-pending--insert-patterns (r)
  "Insert the block of the patterns permission record R is answered for.
R is a request about a path outside the allowed directories: every
answer holds for a pattern.  The block lists the patterns around the
request's own, narrowest first, the picked one marked; the request's own
is noted as the default, and one the user typed that is none of the
others as edited.  A click picks a line, [Edit] types another pattern."
  (let* ((session-id (harness-ui-pending--session))
         (pid (plist-get r :id))
         (choices (harness-ui-pending--pattern-choices r))
         (suggestions (harness-ui-pending--pattern-suggestions r))
         (selected (harness-ui-pending--cover-selected r))
         (own (harness-abbreviate-file-name (plist-get r :pattern)))
         (start (point)))
    (if (null (cdr choices))
        (insert (propertize "   Answers hold for: " 'face 'harness-dim-face)
                (propertize (car choices) 'face 'harness-tool-subject-face)
                "  " (harness-ui-pending--cover-buttons r t) "\n")
      (insert (propertize "   Answers hold for:\n" 'face 'harness-dim-face))
      (dolist (pattern choices)
        (insert (harness-ui-pending--step-line
                 pid (equal pattern selected) pattern
                 (lambda () (harness-ui-pending--pick-pattern session-id pid pattern))
                 (if (equal pattern own)
                     (format "Make the answers hold for %s, the request's own pattern (click)" pattern)
                   (format "Make the answers hold for %s (click)" pattern))
                 (cond ((equal pattern own) "default")
                       ((not (member pattern suggestions)) "edited")
                       (t (harness-ui-pending--pattern-place pattern))))))
      (insert "   " (harness-ui-pending--cover-buttons r t) "\n"))
    (put-text-property start (point) 'harness-ui-pending-cover pid)))

(defun harness-ui-pending--insert-cover-block (r)
  "Insert what permission record R's answers cover: its ladder, or its patterns.
A request about a call has a ladder (`:ladder'); one about a path
outside the allowed directories is answered for a pattern; any other
has no block."
  (cond ((harness-ui-pending--ladder r) (harness-ui-pending--insert-ladder r))
        ((stringp (plist-get r :pattern)) (harness-ui-pending--insert-patterns r))))

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

(defvar harness-ui-pending-permission-map (make-sparse-keymap)
  "Keys active while point is on a permission panel.")

;; Filled at top level, not in the `defvar', so a reload updates the map:
;; an answer's key from `harness-ui-pending-permission-keys', the same on
;; every panel.
(pcase-dolist (`(,option . ,key) harness-ui-pending-permission-keys)
  (define-key harness-ui-pending-permission-map (kbd key) (harness-ui-pending--permission-command option)))
(define-key harness-ui-pending-permission-map (kbd "e") #'harness-ui-pending-edit-pattern)
;; Narrower and wider covers, where a panel lists some to choose between.
(define-key harness-ui-pending-permission-map (kbd "<") #'harness-ui-pending-cover-narrower)
(define-key harness-ui-pending-permission-map (kbd ">") #'harness-ui-pending-cover-wider)

(defun harness-ui-pending--pattern-here-p ()
  "Nil when point is on the panel of a permission request with no pattern.
Its `e' has no pattern to edit there, so it types, into the compose box
\(`harness-compose-acts-p')."
  (let* ((pid (get-text-property (point) 'harness-ui-pending))
         (r (and pid (harness-ui-pending-record (harness-ui-pending--session) pid))))
    (or (not (equal (plist-get r :kind) "permission"))
        (plist-get r :pattern))))

(put 'harness-ui-pending-edit-pattern 'harness-compose-acts-p #'harness-ui-pending--pattern-here-p)

(defun harness-ui-pending--question-command (n)
  "Return a command answering the question at point with its Nth option.
On the panel of a question that allows several options it ticks the
option, or unticks it, instead: the answer is sent when the user says
so (`harness-ui-pending-send-picked')."
  (lambda ()
    (interactive)
    (let* ((session-id (harness-ui-pending--session))
           (pid (harness-ui-pending-at-point))
           (r (and pid (harness-ui-pending-record session-id pid)))
           (option (nth n (plist-get r :options))))
      (cond ((not (and r (equal (plist-get r :kind) "question") option))
             (user-error "No such option"))
            ((harness-ui-pending-multiple-p r)
             (harness-ui-pending-toggle-option session-id pid n))
            (t (harness-ui-pending-answer-question session-id pid option))))))

(defun harness-ui-pending--option-here-p (n)
  "Nil when point is on the panel of a question with no option N (from 0).
The option's digit has nothing to act on there, so it types, into the
compose box (`harness-compose-acts-p')."
  (let* ((pid (get-text-property (point) 'harness-ui-pending))
         (r (and pid (harness-ui-pending-record (harness-ui-pending--session) pid))))
    (or (not (equal (plist-get r :kind) "question"))
        (nth n (plist-get r :options)))))

(defvar harness-ui-pending-question-map (make-sparse-keymap)
  "Keys active while point is on a question panel.
A digit answers with that option, or ticks it when the question allows
several; one beyond the options types, into the compose box.")

(defvar harness-ui-pending-diagram-map (make-sparse-keymap)
  "Keys active while point is on the panel of a question with diagrams.
The question's digits, and n and p to switch whose diagram shows.")

;; Defined and filled at top level, not in the `defvar's, so a reload
;; updates them.  A digit runs `harness-ui-pending-answer-N'.
(dotimes (i 9)
  (let ((command (intern (format "harness-ui-pending-answer-%d" (1+ i)))))
    (defalias command (harness-ui-pending--question-command i)
      (format "Answer the question at point with its option %d.
On the panel of a question that allows several options it ticks that
option, or unticks it, instead.  On the panel of a question with
fewer options the key types, into the compose box." (1+ i)))
    (put command 'harness-compose-acts-p (lambda () (harness-ui-pending--option-here-p i)))
    (define-key harness-ui-pending-question-map (kbd (number-to-string (1+ i))) command)))
(set-keymap-parent harness-ui-pending-diagram-map harness-ui-pending-question-map)
(define-key harness-ui-pending-diagram-map (kbd "n") #'harness-ui-pending-next-diagram)
(define-key harness-ui-pending-diagram-map (kbd "p") #'harness-ui-pending-previous-diagram)

(defvar harness-ui-pending-long-input-map (make-sparse-keymap)
  "Keys active while point is on a permission panel whose input is cut short.
The permission's keys, and TAB to show the input whole or put it back
on one line (`harness-ui-pending-toggle-input').")

;; Filled at top level, not in the `defvar', so a reload updates it.
(set-keymap-parent harness-ui-pending-long-input-map harness-ui-pending-permission-map)
(define-key harness-ui-pending-long-input-map (kbd "TAB") #'harness-ui-pending-toggle-input)
(define-key harness-ui-pending-long-input-map (kbd "<tab>") #'harness-ui-pending-toggle-input)

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
  "Answer the permission request at point, else the newest, with Allow.
That is its panel's [Allow] (y): see `harness-ui-pending-answer-help'
for what it covers."
  (interactive)
  (funcall (harness-ui-pending--permission-command "allow-once")))

(defun harness-ui-pending-deny-newest ()
  "Answer the permission request at point, else the newest, with Deny.
That is its panel's [Deny] (n)."
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
They are the same for every request, in the same order, under the same
labels and keys (`harness-acp-permission-answers',
`harness-ui-pending-permission-keys'); what each covers is in its
tooltip (`harness-ui-pending-answer-help').  Should R offer only some
answers, only those show."
  (let ((all (mapcar (lambda (a)
                       (list (nth 1 a) (harness-ui-pending-answer-key (nth 0 a)) (nth 0 a)))
                     harness-acp-permission-answers))
        (offered (harness-ui-pending--offered-options r)))
    (or (and offered (cl-remove-if-not (lambda (o) (member (nth 2 o) offered)) all))
        all)))

(defun harness-ui-pending--permission-facts (r)
  "Return the lines of facts the panel of permission record R states.
The first says its kind and, for a shell command, where it runs (`runs
in:').  The paths the call is about (`paths:') follow on that line, or
for a shell command on a line of their own: there they are the paths
the command names outside the session's directories, and they are left
out when they are just where it runs.  What its lasting answers cover
is a line of facts only when the harness sent no ladder of covers to
draw (`harness-ui-pending--insert-cover-block')."
  (let* ((cwd (plist-get r :cwd))
         (paths (mapcar (lambda (p) (format "%s" p)) (append (plist-get r :paths) nil)))
         (only-cwd (and cwd paths (null (cdr paths))
                        (equal (file-name-as-directory (car paths)) (file-name-as-directory cwd))))
         (about (and paths (not only-cwd)
                     (format "paths: %s" (mapconcat #'harness-abbreviate-file-name paths " "))))
         (covers (and (not (harness-ui-pending--ladder r)) (plist-get r :covers)))
         (first (delq nil (list (and (plist-get r :tool-kind) (format "kind: %s" (plist-get r :tool-kind)))
                                (and cwd (format "runs in: %s" (harness-abbreviate-file-name cwd)))
                                (and (not cwd) about)))))
    (delq nil (list (and first (string-join first "   "))
                    (and cwd about)
                    (and covers (format "lasting answers: every %s call" covers))))))

(defun harness-ui-pending--decorate (start end pid map)
  "Make START..END the panel of request PID, with keymap MAP.
It is a panel of the compose box too: \\<harness-compose-map>\\[harness-compose-panel-key] in the box presses
the panel's keys from there."
  (add-text-properties start end (list 'harness-ui-pending pid 'harness-compose-panel pid))
  (add-face-text-property start end 'harness-ui-panel-face t)
  (harness-ui-add-keymap start end map))

(defun harness-ui-pending--insert-permission (r)
  "Insert the panel for permission record R."
  (let ((pid (plist-get r :id))
        (session-id (harness-ui-pending--session))
        (start (point))
        (buttons (harness-ui-pending-permission-buttons r)))
    (insert (propertize (concat " " (harness-ui-icon 'harness-icon-blocked) " Permission  ") 'face 'harness-label-face)
            (harness-ui-tool-title-string (plist-get r :tool) (plist-get r :title))
            "\n")
    (dolist (line (harness-ui-pending--permission-facts r))
      (insert (propertize (concat "   " line "\n") 'face 'harness-dim-face)))
    (when (plist-get r :input)
      (harness-ui-pending--insert-input r))
    (when-let* ((reason (plist-get r :reason)))
      (insert (propertize (format "   %s\n" reason) 'face 'harness-hint-face)))
    ;; What the lasting answers cover, and the lines to pick it from.
    (harness-ui-pending--insert-cover-block r)
    (insert "   ")
    (dolist (o buttons)
      (let ((option (nth 2 o)))
        (insert (harness-ui-action-button (format "[%s]" (nth 0 o))
                                          (lambda () (harness-ui-pending-answer-permission session-id pid option))
                                          :help (format "%s (%s)" (harness-ui-pending-answer-help r option) (nth 1 o)))
                " " (harness-ui-kbd (nth 1 o)) "  ")))
    (insert "\n")
    ;; The keys above type in the compose box: this is how to press one there.
    (when-let* ((key (and harness-ui-pending-box-hints (nth 1 (car buttons)))))
      (insert "   " (harness-compose-panel-hint key) "\n"))
    (harness-ui-pending--decorate start (point) pid (harness-ui-pending--permission-map r))))

;;;;; A long input, whole
;;
;; A permission panel words the call's input on one line, each value cut
;; to its first line and the line to a width (see
;; `harness-ui-tool-input-summary'): a long command is cut short, and
;; the further lines of one are not shown at all.  When the line leaves
;; something out it ends in a toggle, [Show all] (with the number of
;; lines, when a value has several), which TAB anywhere on the panel
;; pushes too.  The panel then shows the input whole in place: each
;; value on a line of its own, and one the line cut short verbatim, in a
;; block of fixed-width lines under its key; [Show less] puts it back.
;; Which requests show their input whole belongs to the request, as the
;; diagram a question shows does, so a chat and a popout of it agree
;; (`harness-ui-pending--expanded').

(defun harness-ui-pending--value-text (value)
  "Return VALUE, a value of a tool input, whole, worded as on the panel.
That is how `harness-ui-summary-value' words it, before cutting it."
  (if (and (or (consp value) (vectorp value)) (cl-every #'harness-ui-option-label value))
      (mapconcat #'harness-ui-option-label value ", ")
    (harness-ui-format-value value)))

(defun harness-ui-pending--input-entries (input)
  "Return tool INPUT, a plist, as (KEY VALUE TEXT) entries.
KEY is the name the panel shows, VALUE the value and TEXT it whole."
  (cl-loop for (k v) on input by #'cddr
           collect (list (substring (symbol-name k) 1) v (harness-ui-pending--value-text v))))

(defun harness-ui-pending--value-cut-p (value text)
  "Non-nil when the panel's one line cuts VALUE short; TEXT is it whole."
  (not (equal (harness-ui-summary-value value) (string-trim text))))

(defun harness-ui-pending--input-long-p (r)
  "Non-nil when the one line of permission record R's input leaves some out.
A value cut short or with further lines does, and so does a line too
long for the panel."
  (when-let* ((input (and (equal (plist-get r :kind) "permission") (plist-get r :input))))
    (not (equal (or (harness-ui-tool-input-summary input) "")
                (mapconcat (lambda (e) (format "%s: %s" (nth 0 e) (string-trim (nth 2 e))))
                           (harness-ui-pending--input-entries input) "  ")))))

(defun harness-ui-pending-input-whole-p (session-id pid)
  "Non-nil when permission request PID of SESSION-ID shows its input whole."
  (and (member pid (gethash session-id harness-ui-pending--expanded)) t))

(defun harness-ui-pending--permission-map (r)
  "Return the keymap of the panel of permission record R.
A panel whose input the one line cuts short takes TAB, which shows it
whole; on the others TAB keeps the meaning it has in the buffer."
  (if (harness-ui-pending--input-long-p r)
      harness-ui-pending-long-input-map
    harness-ui-pending-permission-map))

(defun harness-ui-pending--block-string (text)
  "Return TEXT, a value of a tool input, as a block of lines under its key.
It is verbatim, in fixed-width lines, which wrap under their indentation."
  (let ((indent (propertize "     " 'face 'harness-ui-panel-face)))
    (propertize (harness-ui-ensure-newline text)
                'face 'harness-ui-output-face 'line-prefix indent 'wrap-prefix indent)))

(defun harness-ui-pending--show-all-label (entries)
  "Return the label of the toggle that shows input ENTRIES whole.
When a value the line cuts short has further lines, it counts the
lines of those values, so that lines past the first never go unseen."
  (let* ((cut (cl-remove-if-not (lambda (e) (harness-ui-pending--value-cut-p (nth 1 e) (nth 2 e))) entries))
         (lines (mapcar (lambda (e) (cl-count ?\n (harness-ui-ensure-newline (nth 2 e)))) cut)))
    (if (cl-some (lambda (n) (> n 1)) lines)
        (format "[Show all %d lines]" (apply #'+ lines))
      "[Show all]")))

(defun harness-ui-pending--input-toggle (session-id r whole)
  "Return the toggle of permission record R of SESSION-ID.
That is [Show all], or [Show less] when WHOLE: the input shows whole now."
  (let ((pid (plist-get r :id)))
    (propertize
     (concat (harness-ui-action-button
              (if whole "[Show less]" (harness-ui-pending--show-all-label
                                       (harness-ui-pending--input-entries (plist-get r :input))))
              (lambda () (harness-ui-pending-show-input session-id pid (not whole)))
              :help (if whole "Put the input back on one line (TAB)" "Show the whole input, every line of it (TAB)"))
             " " (harness-ui-kbd "TAB"))
     'harness-ui-pending-input-toggle pid)))

(defun harness-ui-pending--insert-input (r)
  "Insert the lines of permission record R's input.
That is one line (`harness-ui-tool-input-summary'), with a toggle when
it leaves something out, or, once the toggle was pushed, the input
whole: every value on a line of its own, and one the line cut short
in a block under its key, the toggle on the first line."
  (let* ((session-id (harness-ui-pending--session))
         (input (plist-get r :input))
         (long (harness-ui-pending--input-long-p r)))
    (if (not (and long (harness-ui-pending-input-whole-p session-id (plist-get r :id))))
        (insert (propertize (concat "   " (harness-ui-tool-input-summary input)) 'face 'harness-dim-face)
                (if long (concat "  " (harness-ui-pending--input-toggle session-id r nil)) "")
                "\n")
      (let ((toggle (concat "  " (harness-ui-pending--input-toggle session-id r t))))
        (pcase-dolist (`(,key ,value ,text) (harness-ui-pending--input-entries input))
          (let ((cut (harness-ui-pending--value-cut-p value text)))
            (insert (propertize (concat "   " key ":" (if cut "" (concat " " (string-trim text))))
                                'face 'harness-dim-face 'wrap-prefix "     ")
                    toggle "\n")
            (setq toggle "")
            (when cut (insert (harness-ui-pending--block-string text)))))))))

(defun harness-ui-pending-show-input (session-id pid whole)
  "Show the input of permission request PID of SESSION-ID whole, or on one line.
WHOLE non-nil shows it whole.  The hosts drawing the request are
redrawn; point goes to the request's toggle when this buffer draws it,
so that TAB there puts it back."
  (let ((pids (cl-remove-if (lambda (p) (or (equal p pid) (not (harness-ui-pending-record session-id p))))
                            (gethash session-id harness-ui-pending--expanded))))
    (if (or whole pids)
        (puthash session-id (if whole (cons pid pids) pids) harness-ui-pending--expanded)
      (remhash session-id harness-ui-pending--expanded)))
  (harness-ui-pending--changed session-id)
  ;; The text property is compared with `equal', so the loop walks the changes.
  (let ((pos (point-min)))
    (while (and pos (not (equal (get-text-property pos 'harness-ui-pending-input-toggle) pid)))
      (setq pos (next-single-property-change pos 'harness-ui-pending-input-toggle)))
    (when pos (goto-char pos))))

(defun harness-ui-pending-toggle-input (&optional pid)
  "Show the whole input of a permission request, or put it back on one line.
PID defaults to the request at point, or else the newest whose one
line leaves something out: a long command, or one of several lines.
The panel shows it in place, every value whole, in the chat and in a
popout of the request alike.  TAB on such a panel, and its [Show all]
and [Show less] buttons, run this."
  (interactive)
  (let* ((session-id (harness-ui-pending--session))
         (pid (or pid (harness-ui-pending-at-point)))
         (r (and pid (harness-ui-pending-record session-id pid))))
    (unless (harness-ui-pending--input-long-p r)
      (setq r (cl-find-if #'harness-ui-pending--input-long-p
                          (reverse (harness-ui-pending-items session-id)))))
    (unless r (user-error "No permission request has more of its input to show"))
    (harness-ui-pending-show-input session-id (plist-get r :id)
                                   (not (harness-ui-pending-input-whole-p session-id (plist-get r :id))))))

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
;;
;; An image is drawn in `harness-ui-image-colors', black on white by
;; default, as a browser shows the file, so a drawing made for a white
;; page reads under a dark theme too.  It is sized to show whole with the
;; lines around it: in a chat at most half the window's height (a BTW's
;; side window is short), in a popout as much as the popout has left
;; once the panel's text and the box are in, the popout growing taller
;; than others for it (`harness-ui-pending-popout-max-height').  Its path
;; is one on the harness's machine.  This Emacs reads it when it shares
;; that machine's files; otherwise it asks the harness for the image
;; (`question/image') and draws it once it comes: a harness reached at a
;; host and port, which may run elsewhere, and a file on a remote host,
;; which the harness process reads without blocking this Emacs.  One the
;; harness could not give, as over a connection that broke, is asked for
;; again once the UI connects again.

(defcustom harness-ui-pending-popout-max-height 0.75
  "Height the popout of a question with images grows to at most.
A fraction of the frame's height: more than other popouts take
\(`harness-ui-popout-max-height'), as a report's popout does, so the
images show large enough to compare, whole, with the options and the
box under them."
  :type 'number :group 'harness-ui-pending)

(defun harness-ui-pending--diagrams (r)
  "Return the diagrams of question record R, one per option, or nil.
Each is (:type \"ascii\" :text TEXT) or (:type \"image\" :path PATH :mime MIME)."
  (and (equal (plist-get r :kind) "question")
       (plist-get r :options)
       (append (plist-get r :diagrams) nil)))

(defun harness-ui-pending--image-question-p (r)
  "Non-nil when request record R is a question showing images."
  (cl-some (lambda (d) (equal (format "%s" (plist-get d :type)) "image"))
           (harness-ui-pending--diagrams r)))

(defun harness-ui-pending--shown-index (session-id pid count)
  "Return which option's diagram the panel of PID of SESSION-ID shows.
The index is kept valid for COUNT options."
  (let ((i (cdr (assoc pid (gethash session-id harness-ui-pending--diagrams)))))
    (if (and (integerp i) (< -1 i count)) i 0)))

(defun harness-ui-pending-shown-diagram (session-id pid)
  "Return the index of the option whose diagram the panel of PID shows.
SESSION-ID is the session the request PID belongs to."
  (harness-ui-pending--shown-index session-id pid
                                   (length (plist-get (harness-ui-pending-record session-id pid) :options))))

(defun harness-ui-pending--question-map (r)
  "Return the keymap of the panel of question record R."
  (if (harness-ui-pending--diagrams r)
      harness-ui-pending-diagram-map
    harness-ui-pending-question-map))

(defun harness-ui-pending--text-lines (r)
  "Return about how many lines the popout of question record R takes.
Its image left out, that is: the heading, the question and the
options, wrapped at the popout's width, the option shown above the
image, the hints and the blank lines of the panel, the box under it
and a line to spare."
  (let* ((columns (max 20 (/ (harness-ui-popout-pixel-width) (max 1 (frame-char-width)))))
         (lines (lambda (text indent)
                  (apply #'+ (mapcar (lambda (line) (max 1 (ceiling (+ indent (string-width line)) (float columns))))
                                     (split-string (format "%s" (or text "")) "\n"))))))
    (+ 1 (funcall lines (plist-get r :question) 3)
       1 (apply #'+ (mapcar (lambda (option) (funcall lines option (if (harness-ui-pending-multiple-p r) 9 7)))
                            (plist-get r :options)))
       ;; The line with [Send answer] of a question that allows several.
       (if (harness-ui-pending-multiple-p r) 1 0)
       2 3 2 1)))

(defun harness-ui-pending--image-box (r)
  "Return the size an image of question record R takes here, or nil.
In a popout that is (:max-width W :max-height H), in pixels: as wide as
the popout, and as high as it has room for beside the rest of the panel
and the box (`harness-ui-pending--text-lines'), so the image shows
whole.  Elsewhere, in a chat, nil: `harness-ui-image-string' sizes it to
the window."
  (when (and (fboundp 'harness-ui-popout-pixel-height) (derived-mode-p 'harness-ui-popout-mode))
    (list :max-width (max 1 (- (harness-ui-popout-pixel-width) (* 7 (frame-char-width))))
          :max-height (max (* 4 (frame-char-height))
                           (harness-ui-popout-pixel-height (harness-ui-pending--text-lines r))))))

(defun harness-ui-pending--fetch-p (path)
  "Non-nil when the image PATH of a question is asked of the harness.
PATH is on the harness's machine.  A harness the UI reached at a host
and port may run on another one, so its images are always asked for;
so is a file on a remote host, which the harness process reads without
blocking this Emacs.  A harness in this Emacs, or the harness process
it started (`harness-ui-connection-address' `process'), shares its
local files, which are read here."
  (or (stringp harness-ui-connection-address)
      (and harness-ui-connection-address (file-remote-p path) t)))

(defun harness-ui-pending--fetched-image (session-id pid index)
  "Return the image of option INDEX of question PID of SESSION-ID.
It comes from the harness: the first call asks for it
\(`question/image') and returns `loading'; once it comes, the panels
showing the question are drawn again with it.  It is then (:data
BASE64 :mime MIME), or (:error MESSAGE) when the harness could not
give it, which is asked for again once the UI connects again
\(`harness-ui-pending--retry-images').  Asking never signals: the
panel asking is being drawn."
  (let* ((key (list session-id pid index))
         (got (gethash key harness-ui-pending--images)))
    (cond
     ((eq (car-safe got) 'loading) 'loading)
     (got got)
     (t
      (let* ((asking (list 'loading))
             (drawing t)
             (settle (lambda (value)
                       ;; Not once the question went, which forgot it,
                       ;; nor once it was asked for again.
                       (when (eq (gethash key harness-ui-pending--images) asking)
                         (if value
                             (puthash key value harness-ui-pending--images)
                           (remhash key harness-ui-pending--images))
                         ;; The panel being drawn shows it as it is.
                         (unless drawing (harness-ui-pending--changed session-id)))
                       nil)))
        (puthash key asking harness-ui-pending--images)
        (condition-case err
            (harness-ui-call "_harness/question/image" (list :session-id session-id :pid pid :index index)
                             (lambda (result)
                               (funcall settle (list :data (plist-get result :data) :mime (plist-get result :mime))))
                             (lambda (err)
                               ;; The UI let go of the connection for another
                               ;; on purpose: the image is asked of that one.
                               (funcall settle (unless (harness-ui-connection-replaced-p err)
                                                 (list :error (harness-error-message err))))))
          ;; Connecting failed, as to a host that is not known.
          (error (funcall settle (list :error (harness-error-message err)))))
        (setq drawing nil)
        (let ((now (gethash key harness-ui-pending--images)))
          (if (or (null now) (eq now asking)) 'loading now)))))))

(defun harness-ui-pending--retry-images ()
  "Forget the images the harness could not give, and ask for them again.
On `harness-ui-connected-hook': a connection that broke failed them,
and the harness the UI reaches now may give them."
  (let (failed)
    (maphash (lambda (key value) (when (eq (car-safe value) :error) (push key failed)))
             harness-ui-pending--images)
    (dolist (key failed) (remhash key harness-ui-pending--images))
    (dolist (session-id (delete-dups (mapcar #'car failed)))
      (harness-ui-pending--changed session-id))))

(defun harness-ui-pending--diagram-image (session-id r index)
  "Return a line showing the image of option INDEX of question record R.
R is a question of SESSION-ID.  The image is sized for where it shows
\(`harness-ui-pending--image-box').  A file this Emacs shares with the
harness is read here; otherwise the harness is asked for it
\(`harness-ui-pending--fetch-p') and it shows once it comes.  A remote
file named by a harness in this Emacs is not read, which would block:
a button opens it instead."
  (let* ((diagram (nth index (harness-ui-pending--diagrams r)))
         (path (format "%s" (plist-get diagram :path)))
         (mime (plist-get diagram :mime))
         (box (harness-ui-pending--image-box r)))
    (cond
     ((harness-ui-pending--fetch-p path)
      (let ((got (harness-ui-pending--fetched-image session-id (plist-get r :id) index)))
        (cond ((eq got 'loading)
               (propertize (format "[loading the image %s\N{U+2026}]\n" (file-name-nondirectory path))
                           'face 'harness-dim-face))
              ((plist-get got :data)
               (apply #'harness-ui-image-string (list :data (plist-get got :data)) mime box))
              (t (propertize (format "[image %s: %s]\n" path (plist-get got :error))
                             'face 'harness-dim-face)))))
     ((file-remote-p path)
      (concat (harness-ui-action-button (format "[image %s]" path) (lambda () (find-file-other-window path))
                                        :help "Open the image")
              "\n"))
     (t (apply #'harness-ui-image-string path mime box)))))

(defun harness-ui-pending--diagram-string (session-id r index)
  "Return the lines showing the diagram of option INDEX of question record R.
R is a question of SESSION-ID; see the diagrams above."
  (let ((diagram (nth index (harness-ui-pending--diagrams r)))
        (indent (propertize "     " 'face 'harness-ui-panel-face)))
    (pcase (format "%s" (plist-get diagram :type))
      ("ascii" (propertize (harness-ui-ensure-newline (plist-get diagram :text))
                           'face 'harness-ui-output-face 'line-prefix indent 'wrap-prefix indent))
      ("image" (propertize (harness-ui-pending--diagram-image session-id r index)
                           'line-prefix indent 'wrap-prefix indent))
      (_ (propertize "     (no diagram)\n" 'face 'harness-dim-face)))))

(defun harness-ui-pending--diagram-nav (label nav action help face)
  "Return a button LABEL of a diagram area's tab line, running ACTION.
NAV names it, `previous', `next' or an option's index, so point stays
on it as the area is redrawn.  HELP is its tooltip, FACE its face."
  (propertize (harness-ui-action-button label action :help help :face face)
              'harness-ui-pending-diagram-nav nav))

(defun harness-ui-pending--diagram-area (session-id r shown)
  "Return the diagram area of question record R of SESSION-ID.
It shows option SHOWN's diagram."
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
     (harness-ui-pending--diagram-string session-id r shown))))

(defun harness-ui-pending--option-line (session-id pid option i shown &optional multiple ticked)
  "Return the line of OPTION, the Ith of question PID of SESSION-ID.
SHOWN is non-nil when its diagram shows.  MULTIPLE non-nil says the
question allows several options: the line starts with a check box, ticked
when TICKED, and a digit or a click on the line ticks or unticks the
option instead of answering with it."
  (let* ((box (and multiple (harness-ui-icon (if ticked 'harness-icon-check-on 'harness-icon-check-off))))
         ;; A wrapped line goes under the label, not under the box.
         (wrap (make-string (+ 7 (if box (1+ (string-width box)) 0)) ?\s)))
    (propertize
     (concat (propertize "   " 'wrap-prefix wrap)
             (if (< i 9) (harness-ui-kbd (format " %d " (1+ i))) "   ")
             " "
             (propertize
              (harness-ui-action-button
               (if box (concat box " " option) option)
               (if multiple
                   (lambda () (harness-ui-pending-toggle-option session-id pid i))
                 (lambda () (harness-ui-pending-answer-question session-id pid option)))
               :face (if shown 'bold 'default)
               :help (cond (multiple (if (< i 9)
                                         (format "%s this option (%d)" (if ticked "Untick" "Tick") (1+ i))
                                       (format "%s this option" (if ticked "Untick" "Tick"))))
                           ((< i 9) (format "Answer with this option (%d)" (1+ i)))
                           (t "Answer with this option")))
              'wrap-prefix wrap)
             "\n")
     'harness-ui-pending-option i)))

(defun harness-ui-pending--send-line (session-id pid picked count)
  "Return the line with [Send answer] under the options of question PID.
SESSION-ID is the question's session, PICKED the indices of the options
ticked and COUNT the number of options.  It says how many are ticked,
and the key that sends them, where the panel is in a buffer with a box."
  (concat (propertize "   " 'wrap-prefix "     ")
          (harness-ui-action-button "[Send answer]"
                                    (lambda () (harness-ui-pending-send-picked session-id pid))
                                    :help "Send the options ticked, and what the box holds with them (C-c C-c)")
          (if harness-ui-pending-box-hints (concat " " (harness-ui-kbd "C-c C-c")) "")
          (propertize (if picked (format "  %d of %d ticked" (length picked) count) "  none ticked")
                      'face 'harness-dim-face)
          "\n"))

(defun harness-ui-pending-question-body (session-id r)
  "Return the options of question record R of SESSION-ID, then its diagram area.
A question that allows several options has its [Send answer] line
between them.  The text is marked `harness-ui-pending-question-body', so
that switching the diagram, or ticking an option, redraws it alone
\(`harness-ui-pending--redraw-question')."
  (let* ((pid (plist-get r :id))
         (options (plist-get r :options))
         (multiple (harness-ui-pending-multiple-p r))
         (picked (and multiple (harness-ui-pending-picked session-id pid)))
         (shown (and (harness-ui-pending--diagrams r)
                     (harness-ui-pending--shown-index session-id pid (length options)))))
    (propertize
     (concat (apply #'concat (seq-map-indexed
                              (lambda (option i)
                                (harness-ui-pending--option-line session-id pid option i (eql i shown)
                                                                 multiple (and (memq i picked) t)))
                              options))
             (if multiple (harness-ui-pending--send-line session-id pid picked (length options)) "")
             (if shown (concat "\n" (harness-ui-pending--diagram-area session-id r shown)) ""))
     'harness-ui-pending-question-body pid)))

(defun harness-ui-pending--question-text (question)
  "Return QUESTION rendered as Markdown, indented under the panel's label.
The panel is narrow and a question may say a lot: its paragraphs, its
lists and its code render as they do in a transcript, every line
indented so it stays under \"Question\".  The plain text is bold; the
Markdown's own faces, such as a heading's or a code span's, win over
that."
  (let ((text (harness-ui-markdown-render (or question ""))))
    ;; The panel adds the line's newline itself.
    (setq text (string-remove-suffix "\n" text))
    (add-face-text-property 0 (length text) 'bold t text)
    (add-text-properties 0 (length text) (list 'line-prefix "   " 'wrap-prefix "   ") text)
    text))

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
            (harness-ui-pending--question-text (plist-get r :question))
            "\n")
    (when (plist-get r :options)
      (insert "\n" (harness-ui-pending-question-body session-id r)))
    ;; The digits above type in the compose box: the hint says how to press one there.
    ;; A question that allows several options says what the words typed are for.
    (let ((typed (if (harness-ui-pending-multiple-p r)
                     "or type a note below, sent with the options ticked · "
                   "or type another answer below · ")))
      (insert (cond ((not (plist-get r :options))
                     (propertize "   type your answer below\n" 'face 'harness-dim-face))
                    ((harness-ui-pending--diagrams r)
                     (concat "\n   " (harness-ui-kbd "C-c C-f")
                             (propertize " next diagram, " 'face 'harness-dim-face)
                             (harness-ui-kbd "C-c C-b")
                             (propertize (concat " previous\n   " typed) 'face 'harness-dim-face)
                             (harness-compose-panel-hint "1") "\n"))
                    (t (concat (propertize (concat "\n   " typed) 'face 'harness-dim-face)
                               (harness-compose-panel-hint "1") "\n")))))
    (harness-ui-pending--decorate start (point) pid (harness-ui-pending--question-map r))))

(defvar harness-ui-pending-panel-functions nil
  "Functions drawing the panel of a request their own way.
Each takes a request record and, when it draws that request, inserts
its panel at point and returns non-nil; the first to do so wins, and a
request none draws gets the ordinary panel.  A panel drawn so is the
request's as the ordinary one is: decorate it with
`harness-ui-pending-decorate', so that point on it finds the request.
The cold-cache question draws itself this way (harness-ui-cowboy.el).")

(defun harness-ui-pending-decorate (start end pid map)
  "Make START..END the panel of request PID, with keymap MAP.
For a panel `harness-ui-pending-panel-functions' draw."
  (harness-ui-pending--decorate start end pid map))

(defun harness-ui-pending-session ()
  "Return the session whose requests this buffer draws, or nil.
A chat's session, or a popout's."
  (harness-ui-pending--session))

(defun harness-ui-pending-insert-panel (r)
  "Insert the panel for request record R at point.
A function of `harness-ui-pending-panel-functions' may draw it instead."
  (cond
   ((run-hook-with-args-until-success 'harness-ui-pending-panel-functions r))
   ((equal (plist-get r :kind) "question")
    (harness-ui-pending--insert-question r))
   (t (harness-ui-pending--insert-permission r))))

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

(defun harness-ui-pending--redraw-everywhere (session-id r)
  "Draw the options and diagram area of question record R again, wherever shown.
R is a question of SESSION-ID.  The buffer drawing the panel -- this one,
else the session's chat -- redraws it in place, and a popout of the same
request, which draws itself whole, is refreshed.  What the panels show of
a request is the request's (the diagram shown, the options ticked), so
they follow each other."
  (harness-ui-pending--redraw-question r)
  (when-let* ((chat (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for session-id))))
    (unless (eq chat (current-buffer))
      (with-current-buffer chat (harness-ui-pending--redraw-question r))))
  (harness-ui-pending--popout-changed session-id))

(defun harness-ui-pending-show-diagram (session-id pid index)
  "Show the diagram of option INDEX of question PID of SESSION-ID, counting round."
  (let ((r (harness-ui-pending-record session-id pid)))
    (unless (harness-ui-pending--diagrams r)
      (user-error "This question has no diagrams"))
    (let ((i (mod index (length (plist-get r :options)))))
      (unless (= i (harness-ui-pending-shown-diagram session-id pid))
        (setf (alist-get pid (gethash session-id harness-ui-pending--diagrams) nil nil #'equal) i)
        (harness-ui-pending--redraw-everywhere session-id r)))))

(defun harness-ui-pending-step-diagram (session-id pid n)
  "Show the diagram N options after the one question PID of SESSION-ID shows.
The count goes round the options."
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
         (list :id pid :kind "permission" :respond respond :connection harness-ui-connection
               :created (float-time)
               :title (or (plist-get tc :title) (plist-get extra :tool) "tool call")
               :call-id (plist-get tc :toolCallId)
               :tool (plist-get extra :tool) :tool-kind (format "%s" (plist-get tc :kind))
               :input (plist-get tc :rawInput) :paths (plist-get extra :paths) :cwd (plist-get extra :cwd)
               :dir (plist-get extra :dir) :pattern (plist-get extra :pattern)
               :commands (plist-get extra :commands) :covers (plist-get extra :covers)
               :ladder (plist-get extra :ladder) :cover (plist-get extra :cover)
               :reason (plist-get extra :reason)
               :options (plist-get params :options))))
      t)))

(defun harness-ui-pending--on-question (params respond)
  "Own question PARAMS, with RESPOND; return non-nil when taken."
  (let ((session-id (plist-get params :sessionId)))
    (when (harness-ui-pending--drawn-anywhere-p session-id)
      (harness-ui-pending-add
       session-id
       (list :id (or (plist-get params :requestId) (harness-short-id 6)) :kind "question" :respond respond
             :connection harness-ui-connection :created (float-time)
             :question (plist-get params :question) :options (plist-get params :options)
             :diagrams (plist-get params :diagrams) :cowboy (plist-get params :cowboy)
             :allow-multiple (and (harness-json-true-p (plist-get params :allowMultiple)) t)))
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
  (let ((session (harness-ui-session session-id)))
    (format "%s · %s" (if session (harness-ui-session-label session) session-id)
            (if (harness-ui-pending-question session-id) "question" "permission"))))

(defun harness-ui-pending--popout-submit (session-id)
  "Return what the popout box of SESSION-ID sends with, or nil for no box.
A question is answered with the typed text and the files attached to
it, a screenshot the text names by its token among them, which reach
the model with the answer; otherwise there is no box.  For a question
that allows several options the options ticked come first, a line each."
  (when (harness-ui-pending-question session-id)
    (lambda (text atts)
      (let ((q (harness-ui-pending-question session-id)))
        (if q
            ;; An answer mentioning a file with @ goes as the text it is.
            (harness-ui-pending-answer-question session-id (plist-get q :id)
                                                (harness-ui-pending-compose-answer session-id q text) nil
                                                (harness-compose-without-references atts text))
          (user-error "No question is waiting"))))))

(defvar harness-ui-popout-empty-ok-function)

(defun harness-ui-pending--popout-render (session-id)
  "Draw the content of the popout of SESSION-ID at point.
An empty box may be sent while options are ticked: they are the answer."
  (setq-local harness-ui-pending-session-id session-id
              harness-ui-pending-send-function #'harness-ui-popout-submit
              harness-ui-popout-empty-ok-function
              (lambda () (harness-ui-pending-picked-any-p session-id)))
  (harness-ui-pending-insert-panels session-id))

(defun harness-ui-pending-popout (session-id &optional keep-pos)
  "Show the popout of what SESSION-ID waits on, and return its buffer.
Nothing happens, and nil is returned, when it waits on nothing.  KEEP-POS
non-nil shows it without selecting its window (a refresh, say)."
  ;; A view pops out a request the store may not have seen yet, when no
  ;; chat was open to sync it: the session's own pending list has it.
  (when session-id (harness-ui-pending-sync-session session-id))
  (when (and session-id (harness-ui-pending-items session-id))
    (unless (fboundp 'harness-ui-popout-show) (user-error "The popout module is not loaded"))
    (let ((buffer (harness-ui-popout-show
                   (harness-ui-pending--popout-key session-id)
                   (lambda () (harness-ui-pending--popout-title session-id))
                   (lambda () (harness-ui-pending--popout-render session-id))
                   :compose (lambda () (harness-ui-pending--popout-submit session-id))
                   :placeholder "Type an answer…"
                   :dir (plist-get (harness-ui-session session-id) :cwd)
                   ;; Images to compare take more room than text,
                   ;; asked on every draw: a question with images may
                   ;; come after the popout opened.
                   :max-height (lambda ()
                                 (and (cl-some #'harness-ui-pending--image-question-p
                                               (harness-ui-pending-items session-id))
                                      harness-ui-pending-popout-max-height)))))
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
session point stands for get the popout with one key.  The session's
cached pending list counts too, not only the store: a view is where a
request is first seen when no chat is open for its session."
  (when-let* ((session-id (and harness-ui-session-at-point-function
                               (harness-ui-session-at-point t))))
    (when (harness-ui-pending-popout session-id) t)))

;;;; Answering from a view
;;
;; A view of many sessions offers what a blocked one waits on right
;; beside it, without opening it: the task board on the card of a task
;; that requires your input, the session list under the row of a blocked
;; session.  Both draw the same buttons -- [Allow] and [Deny] for a
;; permission request, [Answer…] for a question, which pops it out to be
;; read and answered whole -- from `harness-ui-pending-view-actions', each
;; in its own style, and their keys answer through the same functions, so
;; a request is answered the same from either, and as a chat or a popout
;; of it would answer it.

(defun harness-ui-pending-first (session-id)
  "Return the request SESSION-ID waits on first, as a record, or nil.
The store knows a request as soon as it arrives, and is asked first.
The session's own pending list may lag a round trip behind, but it is
all there is for a session no chat or popout has drawn; an item of it
answered here just now is passed over."
  (or (car (harness-ui-pending-items session-id))
      (when-let* ((item (cl-find-if-not
                         (lambda (i) (harness-ui-pending--answered-p session-id (plist-get i :id)))
                         (append (plist-get (harness-ui-session session-id) :pending) nil))))
        (harness-ui-pending--record-of-item item))))

(defun harness-ui-pending--first-of-kind (session-id kind)
  "Return the request SESSION-ID waits on first, from the store, if of KIND.
The session's own pending list is brought into the store first, so the
request is answered as a chat or a popout of it would answer it.
Signal a user error when it waits on no request of KIND first."
  (unless session-id (user-error "No session here"))
  (harness-ui-pending-sync-session session-id)
  (let ((r (harness-ui-pending-first session-id)))
    (unless (equal (plist-get r :kind) kind)
      (user-error (if (equal kind "question") "No question is waiting" "No permission request is waiting")))
    r))

(defun harness-ui-pending-answer-first-permission (session-id option &optional on-error)
  "Answer the permission request SESSION-ID waits on first with OPTION.
OPTION is an option id such as \"allow-once\".  ON-ERROR, when given, is
called with the error should the answer fail; else the echo area says
so.  Signal a user error when it waits on no permission request."
  (let ((r (harness-ui-pending--first-of-kind session-id "permission")))
    (harness-ui-pending-answer-permission session-id (plist-get r :id) option on-error)))

(defun harness-ui-pending-answer-first-question (session-id answer &optional on-error attachments)
  "Answer the question SESSION-ID waits on first with ANSWER.
ON-ERROR is as for `harness-ui-pending-answer-first-permission'.  Signal
a user error when it waits on no question.  ATTACHMENTS go with the
answer (see `harness-ui-pending-answer-question').  The options ticked
of a question that allows several come before ANSWER
\(`harness-ui-pending-compose-answer')."
  (let* ((r (harness-ui-pending--first-of-kind session-id "question"))
         ;; The options ticked of a question that allows several go first.
         (answer (harness-ui-pending-compose-answer session-id r answer)))
    (harness-ui-pending-answer-question session-id (plist-get r :id) answer on-error attachments)
    (message "Answered: %s" (string-replace "\n" " / " answer))))

(defconst harness-ui-pending-view-answers '("allow-once" "deny-once")
  "The permission answers a view offers beside a blocked session.
They are the panel's [Allow] and [Deny], under the same labels and keys
\(y and n); the lasting answers are on the request's panel, which SPC
pops out.")

(defun harness-ui-pending-view-actions (session-id &optional on-error)
  "Return what a view offers for the request SESSION-ID waits on first.
That is nil when it waits on nothing, else a list of (LABEL ACTION
HELP), ACTION a function of no arguments, which the view draws as
buttons in its own style: for a permission request the panel's own
\[Allow] and [Deny] (`harness-ui-pending-view-answers'), whose HELP
says what they cover as their tooltips on the panel do, and [Answer…]
for a question, which pops it out to be read and answered whole
\(`harness-ui-pending-popout').  ON-ERROR is as for
`harness-ui-pending-answer-first-permission'.  The views bind the same
keys: y and n answer, SPC pops the request out."
  (let ((r (harness-ui-pending-first session-id)))
    (pcase (plist-get r :kind)
      ("permission"
       (mapcar (lambda (option)
                 (list (format "[%s]" (harness-ui-pending-answer-label option))
                       (lambda () (harness-ui-pending-answer-first-permission session-id option on-error))
                       (format "%s (%s)" (harness-ui-pending-answer-help r option)
                               (harness-ui-pending-answer-key option))))
               harness-ui-pending-view-answers))
      ("question"
       (list (list "[Answer…]"
                   (lambda ()
                     (unless (harness-ui-pending-popout session-id)
                       (user-error "No question is waiting")))
                   "Read the question and answer it (SPC)"))))))

(defun harness-ui-pending-subject (r &optional max)
  "Return what request record R is about, on one line of at most MAX characters.
For a permission request that is the title of the tool call, styled as
its panel's; for a question, the question."
  (if (equal (plist-get r :kind) "question")
      (propertize (harness-first-line (or (plist-get r :question) "") max) 'face 'bold)
    (harness-ui-tool-title-string (plist-get r :tool) (plist-get r :title) max)))

;;;; Module

(defun harness-ui-pending--init ()
  "Join the UI: own ACP requests, and pop out what a session waits on."
  (add-hook 'harness-ui-permission-functions #'harness-ui-pending--on-permission)
  (add-hook 'harness-ui-question-functions #'harness-ui-pending--on-question)
  (add-hook 'harness-ui-connected-hook #'harness-ui-pending--retry-images)
  (when (boundp 'harness-ui-popout-at-point-functions)
    (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-pending-popout-at-point)))

(add-hook 'harness-ui-pending-changed-hook #'harness-ui-pending--popout-changed)

(harness-define-module 'ui-pending
  :doc "Requests a session waits on: panels, answering and the popout."
  :requires '(ui ui-compose)
  :init #'harness-ui-pending--init)

(provide 'harness-ui-pending)
;;; harness-ui-pending.el ends here
