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
(require 'harness-acp)                  ; `harness-acp-permission-answers'
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
`:connection' (the UI connection it came on, so an answer still goes out
on it), `:created', and what its panel draws: `:title' `:tool' `:tool-kind'
`:input' `:paths' `:cwd' `:pattern' `:dir' `:reason' `:options' for a
permission (`:paths' are what the call is about, `:cwd' where a shell
command runs, `:pattern' the glob the answer holds for, and
`:edited-pattern' the one the user typed), `:question' `:options'
`:diagrams' for a question.  A permission also has the `:call-id' of
the tool call that waits on it.")

(defvar harness-ui-pending--diagrams (make-hash-table :test 'equal)
  "Session id -> (PID . INDEX) of the diagram its panel shows.
The state belongs to the request, not to the buffer drawing it, so a
chat and a popout showing the same question show the same diagram.")

(defvar harness-ui-pending--expanded (make-hash-table :test 'equal)
  "Session id -> the ids of its permission requests whose input shows whole.
Like a question's diagram, this belongs to the request, so a chat and a
popout showing the same request show it the same.")

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

(defun harness-ui-pending--forget-all ()
  "Forget every request, its diagrams and the answers just given.
Which requests show their input whole is forgotten too."
  (clrhash harness-ui-pending--requests)
  (clrhash harness-ui-pending--diagrams)
  (clrhash harness-ui-pending--expanded)
  (clrhash harness-ui-pending--answered))

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
  (harness-ui-pending--changed session-id))

(defun harness-ui-pending-add (session-id record)
  "Add or replace RECORD among the requests SESSION-ID waits on.
An answer already given here wins over news of the request still
arriving: the record keeps its `:respond' and does not come back.  A
pattern the user edited is kept too, for the same reason."
  (let* ((pid (plist-get record :id))
         (old (harness-ui-pending-record session-id pid))
         (record (cond ((and old (plist-get old :respond) (not (plist-get record :respond))) old)
                       ((plist-get old :edited-pattern)
                        (plist-put (copy-sequence record) :edited-pattern (plist-get old :edited-pattern)))
                       (t record)))
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
              :diagrams (plist-get payload :diagrams))
      (list :id (plist-get item :id) :kind "permission" :created (float-time)
            :title (or (plist-get payload :title) (plist-get payload :tool) "tool call")
            :call-id (plist-get payload :call-id)
            :tool (plist-get payload :tool) :tool-kind (harness-ui-pending--str (plist-get payload :kind))
            :input (plist-get payload :input) :paths (plist-get payload :paths) :cwd (plist-get payload :cwd)
            :dir (plist-get payload :dir) :pattern (plist-get payload :pattern)
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
;; narrowest allow, which records nothing.

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
the call itself, whose tool a lasting answer holds for; the pattern of
a call reaching outside the allowed directories, which allow-once lets
that call reach; or the directory an agent asked for, which allow-once
grants until the session's turn ends."
  (let ((pattern (or (harness-ui-pending--permission-pattern r)
                     (and (plist-get r :dir) (abbreviate-file-name (format "%s" (plist-get r :dir))))))
        (tool (or (plist-get r :tool) "this tool"))
        (request (harness-ui-pending--dir-request-p r)))
    (pcase option
      ("allow-once" (cond ((and request pattern) (format "Allow %s until this turn ends" pattern))
                          (pattern (format "Let this call reach %s, this time" pattern))
                          (t "Allow this call, this time")))
      ("allow-session" (if pattern (format "Allow %s for this session" pattern)
                         (format "Allow every %s call for this session" tool)))
      ("allow-always" (if pattern (format "Always allow %s, in every session" pattern)
                        (format "Always allow every %s call, in every session" tool)))
      ("deny-once" (if request "Deny the request" "Deny this call"))
      ("deny-always" (if pattern (format "Always deny %s, to every tool" pattern)
                       (format "Always deny every %s call" tool)))
      (_ (harness-ui-pending-answer-label option)))))

;;;; Answering

(defun harness-ui-pending--message-for (r option)
  "Return the echo-area message after answering permission record R with OPTION.
It says what the answer covered, as its button's tooltip did."
  (let ((shown (or (harness-ui-pending--permission-pattern r)
                   (and (plist-get r :dir) (abbreviate-file-name (format "%s" (plist-get r :dir)))))))
    (pcase option
      ("allow-once" (cond ((and shown (harness-ui-pending--dir-request-p r))
                           (format "Allowed %s until this turn ends" shown))
                          (shown (format "Allowed this call to reach %s" shown))
                          (t "Allowed this call")))
      ("allow-session" (if shown (format "Allowed %s for this session" shown) "Allowed for this session"))
      ("allow-always" (if shown (format "Always allowed %s" shown) "Always allowed"))
      ("deny-always" (if shown (format "Always denied %s" shown) "Always denied"))
      (_ "Denied"))))

(defun harness-ui-pending-answer-permission (session-id pid option &optional on-error)
  "Answer permission request PID of SESSION-ID with OPTION.
OPTION is an option id such as \"allow-once\".  A pattern the user
edited goes with the answer (see `harness-ui-pending-edit-pattern').
An ACP request is answered through the function that holds it; one only
known from the session's pending list goes over
`_harness/permission/answer', and ON-ERROR, when given, is called with
the error should that fail (else the echo area says so).  An answer the
request does not offer is refused: its key does nothing else instead."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    (let ((edited (plist-get r :edited-pattern))
          (offered (harness-ui-pending--offered-options r)))
      (when (and offered (not (member option offered)))
        (user-error "This request does not offer %s" (harness-ui-pending-answer-label option)))
      (unless (harness-ui-pending--respond
               r (append (list :outcome (list :outcome "selected" :optionId option))
                         (and edited (list :_harness (list :pattern edited)))))
        (harness-ui-call "_harness/permission/answer"
                         (list :session-id session-id :pending-id pid
                               :answer (if edited (list :option option :pattern edited) option))
                         #'ignore on-error))
      (harness-ui-pending-remove session-id pid)
      (message "%s" (harness-ui-pending--message-for r option)))))

(defun harness-ui-pending-answer-question (session-id pid answer &optional on-error)
  "Answer question PID of SESSION-ID with ANSWER.
ON-ERROR is as for `harness-ui-pending-answer-permission'."
  (when-let* ((r (harness-ui-pending-record session-id pid)))
    (unless (harness-ui-pending--respond r (list :answer answer))
      (harness-ui-call "_harness/question/answer"
                       (list :session-id session-id :pid pid :answer answer) #'ignore on-error))
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

;;;; Patterns a prompt about paths is answered for
;;
;; A permission request about a path outside the allowed directories
;; (the jail's, or an agent's own request for a directory) is answered
;; for a glob pattern rather than for one file: its `:pattern', by
;; default everything in the directory of its paths.  The user edits
;; it, more or less specific, with `harness-ui-pending-edit-pattern'
;; (`e' on the panel, C-c C-p in the chat); the answer then carries the
;; edited pattern.  Any other request is about the call alone and comes
;; without a pattern, so its panel shows none.

(defun harness-ui-pending--permission-pattern (r)
  "Return the glob pattern permission record R is answered for, as shown, or nil.
That is the one the user edited, else the request's own, abbreviated."
  (or (plist-get r :edited-pattern)
      (and (stringp (plist-get r :pattern)) (abbreviate-file-name (plist-get r :pattern)))))

(defun harness-ui-pending--pattern-suggestions (r)
  "Return patterns more or less specific than permission record R's own.
The paths of the call itself, every file with one's extension in the
directory, the directory, and its parent: what
\\<minibuffer-local-map>\\[next-history-element] offers while editing."
  (let* ((pattern (plist-get r :pattern))
         (dir (and (string-suffix-p "/**" pattern) (substring pattern 0 -2)))
         (parent (and dir (file-name-directory (directory-file-name dir))))
         (paths (mapcar (lambda (p) (format "%s" p)) (append (plist-get r :paths) nil))))
    (delete-dups
     (mapcar #'abbreviate-file-name
             (delq nil (append paths
                               (mapcar (lambda (p)
                                         (and dir (file-name-extension p) (equal (file-name-directory p) dir)
                                              (concat dir "*." (file-name-extension p))))
                                       paths)
                               (list pattern
                                     (and parent (not (equal parent dir)) (concat parent "**")))))))))

(defun harness-ui-pending-set-pattern (session-id pid pattern)
  "Make PATTERN, or the request's own when nil, the one PID is answered for.
PID is a request of SESSION-ID.  The hosts drawing the request are
redrawn; point goes to the request's pattern line when this buffer
shows it."
  (harness-ui-pending--put
   session-id
   (mapcar (lambda (r)
             (if (equal (plist-get r :id) pid)
                 (plist-put (copy-sequence r) :edited-pattern pattern)
               r))
           (harness-ui-pending-items session-id)))
  ;; Point on the panel's pattern line again, after the redraw; the text
  ;; property is compared with `equal', so the loop walks the changes.
  (let ((pos (point-min)))
    (while (and pos (not (and (equal (get-text-property pos 'harness-ui-pending-pattern) pid)
                              (equal (get-text-property pos 'harness-ui-pending) pid))))
      (setq pos (next-single-property-change pos 'harness-ui-pending-pattern)))
    (when pos (goto-char pos))))

(defun harness-ui-pending-edit-pattern (&optional pid)
  "Edit the glob pattern the permission request PID is answered for.
PID defaults to the request at point, or else the newest one with a
pattern.  Only a request about a path outside the allowed directories
has one: everything in the directory the path lies in.  Edit it to be
more specific (a subdirectory, src/*.el, one file) or less (a parent
directory).  `*' matches within a name, `**' across directories; a
relative pattern is relative to the session's working directory.
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
    (let* ((own (abbreviate-file-name (plist-get r :pattern)))
           (typed (string-trim (read-string "Pattern (* within a name, ** across directories): "
                                            (harness-ui-pending--permission-pattern r) nil
                                            (harness-ui-pending--pattern-suggestions r)))))
      (harness-ui-pending-set-pattern session-id pid
                                      (unless (or (string-empty-p typed) (equal typed own)) typed))
      (message "Answers now hold for %s"
               (harness-ui-pending--permission-pattern (harness-ui-pending-record session-id pid))))))

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
A digit answers with that option; one beyond the options types, into
the compose box.")

(defvar harness-ui-pending-diagram-map (make-sparse-keymap)
  "Keys active while point is on the panel of a question with diagrams.
The question's digits, and n and p to switch whose diagram shows.")

;; Defined and filled at top level, not in the `defvar's, so a reload
;; updates them.  A digit runs `harness-ui-pending-answer-N'.
(dotimes (i 9)
  (let ((command (intern (format "harness-ui-pending-answer-%d" (1+ i)))))
    (defalias command (harness-ui-pending--question-command i)
      (format "Answer the question at point with its option %d.
On the panel of a question with fewer options the key types instead,
into the compose box." (1+ i)))
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

(defun harness-ui-pending--insert-pattern-line (r)
  "Insert the line of the pattern permission record R is answered for.
Only a request about a path outside the allowed directories has one."
  (let ((pid (plist-get r :id))
        (start (point)))
    (insert (propertize "   pattern: " 'face 'harness-dim-face)
            (propertize (harness-ui-pending--permission-pattern r) 'face 'harness-tool-subject-face)
            (if (plist-get r :edited-pattern) (propertize " (edited)" 'face 'harness-dim-face) "")
            "  "
            (harness-ui-action-button "[Edit]" (lambda () (harness-ui-pending-edit-pattern pid))
                                      :help "Edit the pattern, to make it more or less specific (e)")
            " " (harness-ui-kbd "e")
            "\n")
    (put-text-property start (point) 'harness-ui-pending-pattern pid)))

(defun harness-ui-pending--permission-facts (r)
  "Return the lines of facts the panel of permission record R states.
The first says its kind and, for a shell command, where it runs (`runs
in:').  The paths the call is about (`paths:') follow on that line, or
for a shell command on a line of their own: there they are the paths
the command names outside the session's directories, and they are left
out when they are just where it runs."
  (let* ((cwd (plist-get r :cwd))
         (paths (mapcar (lambda (p) (format "%s" p)) (append (plist-get r :paths) nil)))
         (only-cwd (and cwd paths (null (cdr paths))
                        (equal (file-name-as-directory (car paths)) (file-name-as-directory cwd))))
         (about (and paths (not only-cwd)
                     (format "paths: %s" (mapconcat #'abbreviate-file-name paths " "))))
         (first (delq nil (list (and (plist-get r :tool-kind) (format "kind: %s" (plist-get r :tool-kind)))
                                (and cwd (format "runs in: %s" (abbreviate-file-name cwd)))
                                (and (not cwd) about)))))
    (delq nil (list (and first (string-join first "   "))
                    (and cwd about)))))

(defun harness-ui-pending--decorate (start end pid map)
  "Make START..END the panel of request PID, with keymap MAP."
  (add-text-properties start end (list 'harness-ui-pending pid))
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
    (when (plist-get r :pattern)
      (harness-ui-pending--insert-pattern-line r))
    (insert "   ")
    (dolist (o buttons)
      (let ((option (nth 2 o)))
        (insert (harness-ui-action-button (format "[%s]" (nth 0 o))
                                          (lambda () (harness-ui-pending-answer-permission session-id pid option))
                                          :help (format "%s (%s)" (harness-ui-pending-answer-help r option) (nth 1 o)))
                " " (harness-ui-kbd (nth 1 o)) "  ")))
    (insert "\n")
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

(defun harness-ui-pending--diagrams (r)
  "Return the diagrams of question record R, one per option, or nil.
Each is (:type \"ascii\" :text TEXT) or (:type \"image\" :path PATH :mime MIME)."
  (and (equal (plist-get r :kind) "question")
       (plist-get r :options)
       (append (plist-get r :diagrams) nil)))

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
     (harness-ui-pending--diagram-string (nth shown (harness-ui-pending--diagrams r))))))

(defun harness-ui-pending--option-line (session-id pid option i shown)
  "Return the line of OPTION, the Ith of question PID of SESSION-ID.
SHOWN is non-nil when its diagram shows."
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
  (let ((session (harness-ui-session session-id)))
    (format "%s · %s" (if session (harness-ui-session-label session) session-id)
            (if (harness-ui-pending-question session-id) "question" "permission"))))

(defun harness-ui-pending--popout-submit (session-id)
  "Return what the popout box of SESSION-ID sends with, or nil for no box.
A question is answered with the typed text; otherwise there is no box."
  (when (harness-ui-pending-question session-id)
    (lambda (text atts)
      ;; An answer mentioning a file with @ goes as the text it is.
      (when (harness-compose-without-references atts text)
        (user-error "Answers cannot carry attachments"))
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

(defun harness-ui-pending-answer-first-question (session-id answer &optional on-error)
  "Answer the question SESSION-ID waits on first with ANSWER.
ON-ERROR is as for `harness-ui-pending-answer-first-permission'.  Signal
a user error when it waits on no question."
  (let ((r (harness-ui-pending--first-of-kind session-id "question")))
    (harness-ui-pending-answer-question session-id (plist-get r :id) answer on-error)
    (message "Answered: %s" answer)))

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
  (when (boundp 'harness-ui-popout-at-point-functions)
    (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-pending-popout-at-point)))

(add-hook 'harness-ui-pending-changed-hook #'harness-ui-pending--popout-changed)

(harness-define-module 'ui-pending
  :doc "Requests a session waits on: panels, answering and the popout."
  :requires '(ui ui-compose)
  :init #'harness-ui-pending--init)

(provide 'harness-ui-pending)
;;; harness-ui-pending.el ends here
