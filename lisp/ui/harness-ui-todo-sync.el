;;; harness-ui-todo-sync.el --- Keeping a session's todo list true, from its chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI half of the todo-sync module (harness-todo-sync.el), which has a
;; cheap model rewrite a session's todo list every few steps it goes
;; without an update.  This half is how you ask for it by hand, and turn it
;; on or off for one session.  In a chat's message box:
;;
;;   /todos           write the session's todo list now, from its work so far
;;   /todos on        sync it every few steps, for this session, even where
;;                    `harness-todo-sync-steps' is nil
;;   /todos off       never sync it on its own, for this session
;;   /todos default   leave it to `harness-todo-sync-steps' again
;;   /todos status    say how it stands
;;
;; `harness-todo-sync' (M-x) does the same for the current session and asks
;; which.  The list lands in the panel above the compose box, as the
;; model's own would; the echo area says what came of the request.  Nothing
;; is added to the session's conversation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-commands)

(defconst harness-ui-todo-sync-actions
  '(("now" . "write the todo list now, from the work so far")
    ("on" . "sync it every few steps, for this session")
    ("off" . "never sync it on its own, for this session")
    ("default" . "leave it to the option, harness-todo-sync-steps")
    ("status" . "say how it stands"))
  "What /todos does: (NAME . DESCRIPTION), the first when no word is given.")

(defun harness-ui-todo-sync-parse-action (text)
  "Return the action TEXT, the words after /todos, names, as a symbol.
That is `now', `on', `off', `default' or `status'; an empty TEXT is
`now'.  Signal when it names none."
  (let ((word (downcase (string-trim (or text "")))))
    (cond ((member word '("" "now" "sync" "update")) 'now)
          ((assoc word harness-ui-todo-sync-actions) (intern word))
          (t (user-error "No such todo sync action %s: %s" word
                         (mapconcat #'car harness-ui-todo-sync-actions ", "))))))

;;;; What is said

(defun harness-ui-todo-sync--done-count (todos)
  "Return how many of TODOS, as they come over ACP, are done."
  (cl-count-if (lambda (todo) (equal (format "%s" (plist-get todo :status)) "done")) todos))

(defun harness-ui-todo-sync-said-run (result)
  "Return what to say of RESULT, the answer of `todo-sync/run'."
  (let* ((todos (plist-get result :todos))
         (n (length todos)))
    (pcase (format "%s" (plist-get result :status))
      ("updated" (format "Todo list written: %d item%s, %d done" n (if (= n 1) "" "s")
                         (harness-ui-todo-sync--done-count todos)))
      ("unchanged" "The todo list is right as it stands")
      ("none" "The work is too small for a todo list")
      ("stale" "The agent wrote its own todo list meanwhile: it stays as it is")
      ("gone" "This session was deleted")
      (other (format "Todo sync: %s" other)))))

(defun harness-ui-todo-sync-said-state (state)
  "Return how STATE, the answer of `todo-sync/state', reads in a sentence."
  (let* ((every (plist-get state :every))
         (setting (format "%s" (plist-get state :setting)))
         (model (plist-get state :model))
         (who (cond ((harness-json-true-p (plist-get state :own))
                     "the session's own model, on a fork of it")
                    (model (harness-ui-model-label model))
                    (t "the session's model"))))
    (cond
     ((equal setting "off")
      "The todo list is not synced for this session: /todos default or /todos on brings it back")
     ((not (and (numberp every) (> every 0)))
      "The todo list is not synced on its own: harness-todo-sync-steps is nil; /todos on syncs this session's")
     (t
      (format "The todo list is synced every %s%s, %d since it was last updated, by %s%s"
              (if (= every 1) "step" (format "%d steps" every))
              (if (equal setting "on") " (set for this session)" "")
              (or (plist-get state :steps) 0) who
              (if (harness-json-true-p (plist-get state :running)) "; a request is under way" ""))))))

;;;; Asking

(defun harness-ui-todo-sync--read-action ()
  "Read what to do with the todo list, with completion."
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (name)
                 (when-let* ((doc (cdr (assoc name harness-ui-todo-sync-actions))))
                   (concat "  " doc))))))
    (harness-ui-todo-sync-parse-action
     (completing-read "Todo list: " (mapcar #'car harness-ui-todo-sync-actions) nil t nil nil "now"))))

(defun harness-ui-todo-sync--failed (what err)
  "Say that WHAT failed with ERR; nothing failed when the UI let go on purpose."
  (unless (harness-ui-connection-replaced-p err)
    (message "%s failed: %s" what (harness-error-message err)))
  nil)

;;;###autoload
(defun harness-todo-sync (session-id &optional action)
  "Keep SESSION-ID's todo list true to its work, as ACTION says.
ACTION is `now' (the default), which has a cheap model write the list
from the session's work so far, whatever the step count says; `on' or
`off', which turn the sync every few steps on or off for this
session, whatever `harness-todo-sync-steps' says; `default', which
leaves it to the option again; or `status', which says how it stands.
Interactively it is this buffer's session, and you are asked which.
In a chat, /todos and /todos on, off, default or status do the same.
The session's conversation is never touched: the model is not told."
  (interactive (list (harness-ui-current-session-id) (harness-ui-todo-sync--read-action)))
  (pcase (or action 'now)
    ('now
     (message "Writing the todo list…")
     (harness-ui-call "_harness/todo-sync/run" (list :session-id session-id)
                      (lambda (result) (message "%s" (harness-ui-todo-sync-said-run result)))
                      (lambda (err) (harness-ui-todo-sync--failed "The todo list" err))))
    ((and (or 'on 'off 'default) switch)
     (harness-ui-call "_harness/todo-sync/set"
                      (list :session-id session-id :enabled (symbol-name switch))
                      (lambda (state) (message "%s" (harness-ui-todo-sync-said-state state)))
                      (lambda (err) (harness-ui-todo-sync--failed "Setting the todo sync" err))))
    ('status
     (harness-ui-call "_harness/todo-sync/state" (list :session-id session-id)
                      (lambda (state) (message "%s" (harness-ui-todo-sync-said-state state)))
                      (lambda (err) (harness-ui-todo-sync--failed "The todo sync" err))))
    (other (user-error "No such todo sync action: %s" other))))

(defun harness-ui-todo-sync--chat-command (args)
  "Run /todos ARGS in a chat's message box: sync its session's todo list.
ARGS is nothing, `on', `off', `default' or `status'
\(`harness-ui-todo-sync-parse-action').  One that cannot be read keeps
the text in the box."
  (harness-todo-sync harness-ui-session-id (harness-ui-todo-sync-parse-action args)))

;;;; Module

(defun harness-ui-todo-sync--init ()
  "Take /todos in the chat."
  (setf (alist-get "todos" harness-chat-commands nil nil #'equal) #'harness-ui-todo-sync--chat-command))

(defun harness-ui-todo-sync--shutdown ()
  "Leave /todos to the chat."
  (when (eq (cdr (assoc "todos" harness-chat-commands)) #'harness-ui-todo-sync--chat-command)
    (setq harness-chat-commands (assoc-delete-all "todos" harness-chat-commands))))

(harness-define-module 'ui-todo-sync
  :doc "Sync a session's todo list by hand, or switch the sync on or off for it: /todos in a chat."
  :requires '(ui ui-chat)
  :init #'harness-ui-todo-sync--init
  :shutdown #'harness-ui-todo-sync--shutdown)

(provide 'harness-ui-todo-sync)
;;; harness-ui-todo-sync.el ends here
