;;; harness-ui-merge.el --- A session's merge queue in its chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session whose branches merge back into it -- the sub-agents it
;; started, in worktrees of their own -- shows those merges beside its
;; todo list, above the compose box: which children are queued, merging
;; or in conflict, and which merged or failed recently, with the reason
;; the queue gave.  When the session's own branch is queued upward, the
;; panel is where that shows too: the queue of the session it merges
;; into is another session's panel, not this one's.
;;
;; It is the queue as the harness sees it (`merge/view', the same data
;; `merge/queue' gives plus the merges finished recently), fetched over
;; ACP once per session and kept here.  A merge event (`merge/queued',
;; `merge/started', `merge/conflict', `merge/finished') makes the open
;; chat of that queue's session fetch the view again and draw its tail,
;; so the panel follows the merges as they happen.  A session with no
;; merges, and no merge finished recently, shows no panel.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)

(defgroup harness-ui-merge nil
  "Showing a session's merge queue in its chat." :group 'harness-ui)

(defconst harness-ui-merge--finished-limit 3
  "Finished merges the panel lists before it counts the rest.")

(harness-ui-define-icon harness-ui-merge-icon "merge" "⇄" "merge"
  "Branches merging back into a session.")

(defvar harness-ui-merge--views (make-hash-table :test 'equal)
  "Session id -> its merge view, as last heard.
A view is the list `merge/view' returns: the live merges first, then
the ones finished recently, newest first.")

(defvar harness-ui-merge--asked (make-hash-table :test 'equal)
  "Session ids whose merge view was fetched once.")

(defun harness-ui-merge--chat-buffer (sid)
  "Return the live chat buffer showing session SID, or nil."
  (cl-find-if (lambda (buffer)
                (equal (buffer-local-value 'harness-ui-session-id buffer) sid))
              (buffer-list)))

(defun harness-ui-merge--redraw (sid)
  "Draw the tail of SID's chat buffer again, when it shows."
  (when-let* ((buffer (harness-ui-merge--chat-buffer sid)))
    (with-current-buffer buffer
      (when (functionp harness-compose-redraw-function)
        (funcall harness-compose-redraw-function)))))

(defun harness-ui-merge--fetch (sid)
  "Fetch the merge view of SID's queue and show it.
The view is fetched again on every merge event of that queue."
  (if (and (stringp sid) (not (string-empty-p sid)))
      (harness-ui-call
       "_harness/merge/view" (list :target sid)
       (lambda (view)
         (if view
             (puthash sid view harness-ui-merge--views)
           (remhash sid harness-ui-merge--views))
         (harness-ui-merge--redraw sid))
       #'ignore)
    (harness-ui-merge--redraw sid)))

(defun harness-ui-merge--view (sid)
  "Return the merge view of SID's queue, fetching it the first time.
Nil for a session with no merges queued and none finished recently."
  (when (and (stringp sid) (not (string-empty-p sid)))
    (unless (gethash sid harness-ui-merge--asked)
      (puthash sid t harness-ui-merge--asked)
      (harness-ui-merge--fetch sid))
    (gethash sid harness-ui-merge--views)))

;;;; The panel

(defun harness-ui-merge--status (item)
  "Return the status of ITEM, a view item, as a symbol.
The harness sends it as a string over ACP, and the panel accepts
either that or the symbol."
  (let ((status (plist-get item :status)))
    (if (symbolp status) status (intern (downcase (format "%s" status))))))

(defun harness-ui-merge--live-p (item)
  "Non-nil when ITEM, a view item, is a merge not through yet."
  (memq (harness-ui-merge--status item) '(queued merging conflict)))

(defun harness-ui-merge--mark (item)
  "Return (ICON . FACE) marking ITEM, a view item, in the panel."
  (pcase (harness-ui-merge--status item)
    ('queued '(harness-icon-idle . harness-dim-face))
    ('merging '(harness-icon-running . harness-status-running-face))
    ('conflict '(harness-icon-caution . harness-status-blocked-face))
    ('merged '(harness-icon-success . harness-success-face))
    (_ '(harness-icon-failure . harness-status-blocked-face))))

(defun harness-ui-merge--state (item)
  "Return what ITEM, a view item, says of its merge, in words."
  (let ((status (harness-ui-merge--status item)))
    (concat
     (pcase status
       ('queued (if (plist-get item :waiting)
                    (format "queued (after its own merges, position %s)" (plist-get item :position))
                  (format "queued (%s in line)" (plist-get item :position))))
       ('merging "merging now")
       ('conflict "conflict")
       ('merged "merged")
       ('aborted "aborted")
       ('failed "failed")
       ('cancelled "cancelled")
       (_ (format "%s" status)))
     (when-let* ((reason (plist-get item :reason)))
       (format ": %s" (harness-first-line reason 60))))))

(defun harness-ui-merge--lines (items)
  "Return one line per ITEM of a merge view, as the panel shows them."
  (string-join
   (mapcar (lambda (item)
             (let* ((mark (harness-ui-merge--mark item))
                    (name (or (plist-get item :name)
                              (substring (plist-get item :child) 0 8)))
                    (live (harness-ui-merge--live-p item)))
               (concat "   "
                       (propertize (harness-ui-icon (car mark)) 'face (cdr mark))
                       " "
                       (propertize (harness-truncate-end name 24)
                                   'face (if live 'bold 'harness-dim-face)
                                   'wrap-prefix "   ")
                       "  "
                       (propertize (harness-ui-merge--state item)
                                   'face 'harness-dim-face))))
           items)
   "\n"))

(defun harness-ui-merge--panel ()
  "Return the panel of this session's merge queue, or nil for none.
On `harness-chat-panel-functions'.  A session with nothing merging and
nothing merged recently shows nothing."
  (let* ((sid harness-ui-session-id)
         (view (harness-ui-merge--view sid))
         (live (cl-remove-if-not #'harness-ui-merge--live-p view))
         (done (cl-remove-if #'harness-ui-merge--live-p view))
         (finished (seq-take done harness-ui-merge--finished-limit))
         (shown (append live finished))
         (rest (- (length done) (length finished))))
    (when view
      (let ((title (format " Merge queue  %s%s%s"
                           (if live (format "%d live" (length live)) "idle")
                           (if (and live done) ", " "")
                           (if done (format "%d finished" (length done)) ""))))
        (concat
         (propertize (concat (harness-ui-icon 'harness-ui-merge-icon) title) 'face 'harness-label-face)
         "\n"
         (harness-ui-merge--lines shown)
         (if (> rest 0) (format "\n   %s %d more" (harness-ui-icon 'harness-icon-thinking) rest) "")
         "\n")))))

;;;; Events and setup

(defun harness-ui-merge--on-event (event args)
  "Follow merge EVENT with ARGS: fetch the queue's view and draw it again.
The second argument of every merge event names the queue's target: the
session merges go into, or a main checkout's directory, which no chat
shows."
  (when (string-prefix-p "merge/" event)
    (when-let* ((sid (nth 1 args)))
      (when (harness-ui-merge--chat-buffer sid)
        (harness-ui-merge--fetch sid)))))

(defun harness-ui-merge--setup ()
  "Put the merge queue panel in this chat buffer, before the others."
  (add-hook 'harness-chat-panel-functions #'harness-ui-merge--panel t))

(defun harness-ui-merge--init ()
  "Add the panel to every chat buffer and follow merge events."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-merge--setup))
  (add-hook 'harness-ui-event-functions #'harness-ui-merge--on-event))

(harness-ui-merge--init)

(harness-define-module 'ui-merge
  :doc "A session's merge queue: which sub-agent branches are queued, merging, in conflict, merged or failed."
  :requires '(ui ui-chat)
  :init #'harness-ui-merge--init)

(provide 'harness-ui-merge)
;;; harness-ui-merge.el ends here
