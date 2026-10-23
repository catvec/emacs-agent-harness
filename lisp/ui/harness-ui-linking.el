;;; harness-ui-linking.el --- Following the links agents write to sessions, messages and threads  -*- lexical-binding: t; -*-

;;; Commentary:

;; An agent points at something in the harness from its own words: a
;; session, a message or a tool call in one, a task, a thread of a task's
;; review.  It writes a harness: link (lisp/harness-links.el), the
;; Markdown renderer draws it as a link like any other, and this module is
;; what a click or RET on it does -- the UI half of the linking module,
;; which resolves a link and writes it out in full where the agent wrote
;; it.  The renderer knows nothing of sessions; it hands the URL to
;; `harness-ui-markdown-harness-link-function', and asks
;; `harness-ui-markdown-link-describe-function' what a link is, for its
;; tooltip and, when the author gave it no words, its label.  This module
;; sets both.
;;
;; Following asks nobody when the UI knows already.  A session link whose
;; reference the session cache resolves (`harness-ui-resolve-session': an
;; id, a unique start of one, a name) opens that session; a link to a
;; message or tool call the chat of its session shows opens the session
;; and goes to the node.  Anything else is resolved by the harness
;; (`_harness/link/resolve'): relative references (`last', `#2',
;; `bash#2') mean something only to it, as do the thread of a review and
;; the sessions it is asked about by a name this Emacs does not know.  The
;; answer says what the link names -- `:kind' `session', `message',
;; `call', `task' or `thread', and the `:session', `:node', `:task' and
;; `:thread' it is about -- and is opened by the function
;; `harness-ui-linking-handlers' holds for its kind.  A click never waits:
;; the request is made and the Emacs goes on.  What a link needs to be
;; resolved in is the session whose text holds it, the chat's, or the
;; report's task's (`harness-ui-linking-context-functions' lets other
;; views say theirs).
;;
;; What each kind opens: a session is visited in its project, as the
;; session list does (`harness-ui-visit-session'); a message or a call is
;; that, and then the chat is taken to the node, opening the fold or the
;; run of calls that hides it (`harness-ui-chat-goto-node'); a task
;; shows its report; a thread is for the module that draws a task's
;; review, which registers it.  A kind nobody handles opens the link's
;; session, if it has one, and says what it could not do.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-links)
(require 'harness-ui)
(require 'harness-ui-markdown)

(declare-function harness-ui-chat-goto-node "harness-ui-chat" (node-id &optional session-id regexp))
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-chat-block-kind "harness-ui-chat" (block))
(declare-function harness-chat-block-node "harness-ui-chat" (block))
(declare-function harness-chat-block-content "harness-ui-chat" (block))
(declare-function harness-ui-report-popout "harness-ui-report" (task))
(declare-function harness-ui-report-task "harness-ui-report" ())

(defgroup harness-ui-linking nil
  "Following the harness: links agents write."
  :group 'harness-ui)

(defvar harness-ui-linking-handlers nil
  "How a link the harness resolved is opened: an alist of (KIND . FUNCTION).
KIND is a string, \"session\", \"message\", \"call\", \"task\" or
\"thread\"; FUNCTION is called with the harness's answer, a plist
\(`:kind', `:url', `:label', `:session', `:session-name', `:node',
`:call-id', `:task', `:thread'; a key the link has no use for is
missing), and opens what it names.  A module that can show something
others cannot adds its own: the module that draws a task's review does,
for the thread of one.  A kind with none opens the session the answer
names, if any, and says it could not do more
\(`harness-ui-linking--unavailable').")

(defvar harness-ui-linking-context-functions nil
  "Functions of no arguments that say whose text the current buffer holds.
Each returns the id of the session the links in this buffer are written
in -- what a relative link, `harness:call/last', is relative to -- or
nil when the buffer is none that it knows.  The first answer wins; a
chat buffer is its session's without asking (`harness-ui-linking-context').")

;;;; The session whose text it is

(defun harness-ui-linking--report-context ()
  "Return the session of the task whose report this buffer shows, or nil."
  (when (fboundp 'harness-ui-report-task)
    (let ((session (plist-get (harness-ui-report-task) :session)))
      (and (stringp session) (not (string-empty-p session)) session))))

(defun harness-ui-linking-context ()
  "Return the id of the session whose text the current buffer holds, or nil.
That is the session a chat shows, else what
`harness-ui-linking-context-functions' say -- the task's session in a
report -- else nil: a link that needs one is then not relative to any,
and the harness says so."
  (let ((id (or (and (stringp harness-ui-session-id) harness-ui-session-id)
                (run-hook-with-args-until-success 'harness-ui-linking-context-functions))))
    (and (stringp id) (not (string-empty-p id)) id)))

;;;; The nodes a chat shows

(defun harness-ui-linking--rendered-node (link)
  "Return (SESSION . NODE) when the chat of LINK's session shows its node.
Nil when it does not, or when the link does not say by id: only a node
named by its id counts, or a call by the id its provider gave it, for a
handle (`last', `bash#2') means what it does where the harness reads
it.  The chat is the session's own buffer, if one is open
\(`harness-chat--buffer-for'), and shows the node when it has rendered
its block, so nothing is asked of the harness."
  (let* ((ref (plist-get link :session))
         (sid (if ref (harness-ui-resolve-session ref) (harness-ui-linking-context)))
         (buffer (and sid (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid)))
         (node (or (plist-get link :message) (plist-get link :call))))
    (when (and buffer (stringp node))
      (with-current-buffer buffer
        (let ((blocks (and (boundp 'harness-chat--blocks) harness-chat--blocks))
              (calls (and (eq (plist-get link :kind) 'call) (boundp 'harness-chat--calls) harness-chat--calls)))
          (cond ((and blocks (gethash node blocks)) (cons sid node))
                ((and calls (gethash node calls)) (cons sid (gethash node calls)))))))))

;;;; What a link is

(defun harness-ui-linking--status-text (session)
  "Return the status of the cached SESSION, as a word, or nil."
  (let ((status (plist-get session :status)))
    (and status (not (equal status "")) (format "%s" status))))

(defun harness-ui-linking--session-words (link)
  "Return (:label :help) for the session LINK, from the session cache."
  (let* ((ref (plist-get link :session))
         (id (harness-ui-resolve-session ref))
         (session (and id (harness-ui-session id))))
    (if session
        (list :label (harness-ui-session-name id)
              :help (format "mouse-1, RET: open the session %s%s" (harness-ui-session-name id)
                            (if-let* ((status (harness-ui-linking--status-text session)))
                                (format " (%s)" status)
                              "")))
      (list :help (format "mouse-1, RET: open the session %s" ref)))))

(defun harness-ui-linking--node-words (link)
  "Return words for the message or tool call LINK names, or nil.
They come from the chat that shows it, which has the node's block: a
call is its title, a message of yours or of the agent's the start of
what it says.  A node no chat shows has none, and the link reads as what
it is made of (`harness-links-label')."
  (when-let* ((hit (harness-ui-linking--rendered-node link))
              (buffer (harness-chat--buffer-for (car hit))))
    (with-current-buffer buffer
      (when-let* ((block (gethash (cdr hit) harness-chat--blocks)))
        (let ((kind (harness-chat-block-kind block)))
          (cond
           ((equal kind "tool-call")
            (let ((title (plist-get (harness-chat-block-node block) :title)))
              (and (stringp title) (not (string-blank-p title)) title)))
           ((member kind '("user" "assistant"))
            ;; What the first line says as it shows, without the markers
            ;; of its Markdown (`harness-ui-markdown-summary').
            (let ((text (harness-truncate-end
                         (substring-no-properties
                          (harness-ui-markdown-summary
                           (harness-first-line (or (harness-chat-block-content block) "") 200)))
                         40)))
              (and (not (string-empty-p text))
                   (format "%s “%s”" (if (equal kind "user") "your message" "reply") text))))))))))

(defun harness-ui-linking--thing-words (link)
  "Return (:label :help) for LINK, a message, a call, a thread or a task."
  (let* ((kind (plist-get link :kind))
         (ref (plist-get link :session))
         (id (and ref (harness-ui-resolve-session ref)))
         (name (and id (harness-ui-session-name id)))
         (where (cond (name (format " in the session %s" name))
                      ((and (null ref) (memq kind '(message call))) " in this session")
                      (t ""))))
    (list :label (or (and (memq kind '(message call)) (harness-ui-linking--node-words link))
                     (harness-links-label link name))
          :help (pcase kind
                  ('message (format "mouse-1, RET: open that message%s" where))
                  ('call (format "mouse-1, RET: open that tool call%s" where))
                  ('thread "mouse-1, RET: open that thread of a review")
                  ('task "mouse-1, RET: open that task")
                  (_ "mouse-1, RET: open this link")))))

(defun harness-ui-linking-describe (url)
  "Say what the harness link URL is, for the renderer: a plist, or nil.
The plist has `:label', the words to show for a link its author gave
none -- the session's name, for a session this Emacs knows -- and
`:help', its tooltip, which says what a click opens.  A URL that names
nothing gets nothing, and the renderer says so."
  (when-let* ((link (harness-links-parse url)))
    (if (eq (plist-get link :kind) 'session)
        (harness-ui-linking--session-words link)
      (harness-ui-linking--thing-words link))))

;;;; Following

(defun harness-ui-linking--follow-locally (link)
  "Open LINK without asking the harness when the UI knows what it names.
Return non-nil when it did: a session link whose reference the cache
resolves, a message or call link to a node the chat of its session shows."
  (pcase (plist-get link :kind)
    ('session
     (when-let* ((id (harness-ui-resolve-session (plist-get link :session))))
       (harness-ui-visit-session id)
       t))
    ((or 'message 'call)
     (when-let* ((hit (harness-ui-linking--rendered-node link)))
       (harness-ui-linking--open-node (list :session (car hit) :node (cdr hit)))
       t))))

(defun harness-ui-linking--failed (error)
  "Say in the echo area that the harness could not resolve a link, for ERROR."
  (let ((message (harness-error-message error)))
    (message "%s" (if (string-match-p "not found\\|No such\\|Unknown method" message)
                      "This harness cannot resolve links: it has no linking module"
                    (format "Could not follow the link: %s" message)))))

(defun harness-ui-linking--unavailable (result)
  "Open what the answer RESULT names of a kind nothing here can show.
That is its session, if it has one; either way the echo area says it."
  (let ((session (plist-get result :session)))
    (message "A link to a %s cannot be shown here%s" (plist-get result :kind)
             (if session ": its session opens instead" ""))
    (when session (harness-ui-visit-session session))))

(defun harness-ui-linking--dispatch (result)
  "Open the link the harness answered RESULT to, by its kind.
`harness-ui-linking-handlers' say how; an error a handler signals is
told in the echo area, as the click that made it has nowhere to signal
it to."
  (condition-case err
      (cond
       ((not (consp result)) (message "The harness did not say what this link names"))
       ((plist-get result :error) (message "%s" (plist-get result :error)))
       (t (let ((handler (or (cdr (assoc (format "%s" (plist-get result :kind))
                                         harness-ui-linking-handlers))
                             #'harness-ui-linking--unavailable)))
            (funcall handler result))))
    (error (message "%s" (error-message-string err)))))

(defun harness-ui-linking--in-place (window buffer function)
  "Call FUNCTION in WINDOW and BUFFER, as the click that asked for it was made.
The harness answers a moment after the click, when whatever the Emacs
was doing then -- a process filter, a timer -- has made another buffer
current: the session opens where the window of the click and the
buffer's position say (`harness-ui-visit-session'), as
`harness-ui-session-opener' does for any asynchronous opening.  A window
or a buffer gone by now leaves the Emacs as it is."
  (when (window-live-p window)
    (select-window window))
  (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
    (funcall function)))

(defun harness-ui-linking--resolve (url context)
  "Ask the harness what the link URL names, and open it.
CONTEXT is the session the link is written in, if any.  The answer is
opened where the click was (`harness-ui-linking--in-place')."
  (let ((window (selected-window))
        (buffer (current-buffer)))
    (harness-ui-call "_harness/link/resolve"
                     (append (list :url url) (and context (list :session context)))
                     (lambda (result)
                       (harness-ui-linking--in-place
                        window buffer (lambda () (harness-ui-linking--dispatch result))))
                     #'harness-ui-linking--failed)))

(defun harness-ui-linking-follow (url)
  "Open the harness link URL: the session, message, call, task or thread it names.
This is what a click on a link the Markdown renderer drew does
\(`harness-ui-markdown-harness-link-function').  A link that does not
read as one is an error.  The UI opens what it can without the harness
\(`harness-ui-linking--follow-locally'); the rest it asks the harness to
resolve, in the session whose text this buffer holds
\(`harness-ui-linking-context'), and opens the answer when it comes."
  (let ((link (harness-links-parse url)))
    (unless link
      (user-error "Not a link to anything in the harness: %s" url))
    (unless (harness-ui-linking--follow-locally link)
      (harness-ui-linking--resolve url (harness-ui-linking-context)))))

;;;###autoload
(defun harness-ui-linking-open (url)
  "Open the harness link URL, which you have as text.
It names a session, a message, a tool call, a task or a thread.
Interactively URL is asked for, starting from the link the kill ring
holds when it does (`harness-chat-copy-link' puts one there)."
  (interactive
   (list (let ((kill (car kill-ring)))
           (read-string "Harness link: "
                        (and (stringp kill) (harness-links-p (string-trim kill)) (string-trim kill))))))
  (harness-ui-linking-follow (string-trim url)))

;;;; Opening what the harness resolved

(defun harness-ui-linking--open-session (result)
  "Open the session the answer RESULT names."
  (let ((session (plist-get result :session)))
    (unless session (user-error "The harness named no session for this link"))
    (harness-ui-visit-session session)))

(defun harness-ui-linking--open-node (result)
  "Open the session RESULT names and take its chat to the node.
The chat is made when the session has none open, and the node shown once
it has loaded as far back as it takes (`harness-ui-chat-goto-node')."
  (let ((session (plist-get result :session))
        (node (plist-get result :node)))
    (unless session (user-error "The harness named no session for this link"))
    (harness-ui-visit-session session)
    (when (and (stringp node) (fboundp 'harness-ui-chat-goto-node))
      (harness-ui-chat-goto-node node session))))

(defun harness-ui-linking--open-task (result)
  "Open the task the answer RESULT names: its report, or its session without one."
  (let ((task (plist-get result :task))
        (session (plist-get result :session)))
    (cond
     ((and task (fboundp 'harness-ui-report-popout))
      (harness-ui-call "_harness/task/get" (list :id task)
                       (lambda (record)
                         (condition-case err
                             (cond ((and (consp record) (plist-get record :report))
                                    (harness-ui-report-popout record))
                                   (session (harness-ui-visit-session session))
                                   (t (message "This task has not handed a report in")))
                           (error (message "%s" (error-message-string err)))))
                       (lambda (err)
                         (message "Could not read the task: %s" (harness-error-message err))
                         (when session (harness-ui-visit-session session)))))
     (session (harness-ui-visit-session session))
     (t (user-error "The harness named no task for this link")))))

;;;; Module

(defun harness-ui-linking--init ()
  "Have the renderer's harness links followed and described here."
  (setq harness-ui-markdown-harness-link-function #'harness-ui-linking-follow
        harness-ui-markdown-link-describe-function #'harness-ui-linking-describe)
  ;; Not a handler another module added for the same kind: it is the one
  ;; that knows more.
  (pcase-dolist (`(,kind . ,function)
                 '(("session" . harness-ui-linking--open-session)
                   ("message" . harness-ui-linking--open-node)
                   ("call" . harness-ui-linking--open-node)
                   ("task" . harness-ui-linking--open-task)))
    (setf (alist-get kind harness-ui-linking-handlers nil nil #'equal) function))
  (add-hook 'harness-ui-linking-context-functions #'harness-ui-linking--report-context))

(defun harness-ui-linking--shutdown ()
  "Stop following harness links: the renderer says it cannot, again."
  (when (eq harness-ui-markdown-harness-link-function #'harness-ui-linking-follow)
    (setq harness-ui-markdown-harness-link-function nil))
  (when (eq harness-ui-markdown-link-describe-function #'harness-ui-linking-describe)
    (setq harness-ui-markdown-link-describe-function nil))
  (remove-hook 'harness-ui-linking-context-functions #'harness-ui-linking--report-context))

(harness-define-module 'ui-linking
  :doc "Following the links agents write: a click on a harness: link opens the session, message, tool call, task or thread it names."
  :requires '(ui ui-chat)
  :init #'harness-ui-linking--init
  :shutdown #'harness-ui-linking--shutdown)

(provide 'harness-ui-linking)
;;; harness-ui-linking.el ends here
