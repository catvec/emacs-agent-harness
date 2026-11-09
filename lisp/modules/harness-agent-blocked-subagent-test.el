;;; harness-agent-blocked-subagent-test.el --- A sub-agent that asks for access is seen blocked  -*- lexical-binding: t; -*-

;;; Commentary:

;; A sub-agent asks for a directory (`request_directory_access').  Only the
;; user can grant it, so the child waits, and so does its parent, which
;; waits for its report: the whole tree stands still.  Everything here is
;; real but the model: the state layer, the permission chain, the access
;; module, the demo provider, and the UI, which hears of the child over
;; the in-process ACP connection as it does from the harness process.
;;
;; The child must show as blocked wherever sessions are listed -- the
;; backend's own list, the session list -- and the parent's chat must show
;; that its child waits for the user: a line in the panel pinned above its
;; compose box, with the link that opens the child and the buttons that
;; answer.  Answering from there lets the child go on, and the line goes.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-ui--sessions)
(defvar harness-ui-session-id)
(defvar harness-perms--allowed-dirs)
(defvar harness-access--judged)
(defvar harness-ui-sessions--buffer-name)
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defmacro harness-blocked-subagent-test-with (&rest body)
  "Load the harness and the UI, connect them in-process, run BODY.
`outside' is a directory beside the working directory, which a session
may not reach; `parent' is the id of a session in it."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tools-agent tools-question
                          tools-fs perms readonly access acp priority))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-access--judged)
     (dolist (m '(ui ui-compose ui-markdown ui-popout ui-chat ui-pending ui-sessions ui-children))
       (harness-test-load-module m))
     (clrhash harness-ui--sessions)
     (let* ((harness-acp-token nil)
            (harness-provider-demo--delay 0.005)
            (default-directory dir)
            (base (file-name-as-directory (file-truename (harness-test-temp-dir))))
            (work (file-name-as-directory (expand-file-name "work" base)))
            (outside (file-name-as-directory (expand-file-name "shared-types" base)))
            (parent (progn (make-directory work t)
                           (make-directory outside t)
                           (plist-get (harness-call 'session/create :cwd work :name "Lead"
                                                    :model "demo:scripted" :permission-mode 'yolo)
                                      :id))))
       (ignore outside)
       (unwind-protect
           (progn
             (harness-ui-connection)
             (harness-test-wait (lambda () (harness-ui-session parent)) 5 "the UI to hear of the parent")
             ,@body)
         (when-let* ((buffer (get-buffer harness-ui-sessions--buffer-name))) (kill-buffer buffer))
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-blocked-subagent-test--script (outside)
  "Return the demo script in which a sub-agent asks for the directory OUTSIDE."
  (lambda (request)
    (if (string-match-p "ask for access" (downcase (harness-provider-demo--last-user-text request)))
        `((:type tool-call :id ,(concat "ask-" (harness-short-id)) :name "request_directory_access"
                 :input (:path ,outside :reason "Read the shared types"))
          (:type text :delta "Got it.") (:type done :stop-reason end-turn))
      '((:type text :delta "ok") (:type done :stop-reason end-turn)))))

(defun harness-blocked-subagent-test--spawn (parent)
  "Have PARENT start a sub-agent that asks for a directory; return its id."
  (plist-get (plist-get (harness-test-await
                         (harness-call 'tools/execute parent
                                       (list :id (harness-short-id) :name "spawn_agent"
                                             :input '(:prompt "ask for access" :name "needs-access"))))
                        :meta)
             :child-id))

(defun harness-blocked-subagent-test--text (buffer)
  "Return the text of BUFFER, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-blocked-subagent-test--panel (session-id)
  "Return the sub-agents panel of the chat of SESSION-ID, as drawn, with properties.
The chat is a buffer no window shows, which the panel takes to be 80
columns wide."
  (with-temp-buffer
    (setq-local harness-ui-session-id session-id)
    (harness-ui-children--panel)))

(ert-deftest harness-blocked-subagent-asking-for-access-is-blocked-in-the-list-and-the-parent ()
  "A sub-agent waiting for a directory is blocked in the session list and
shown, with a link to answer, in its parent's chat."
  (harness-blocked-subagent-test-with
    (let* ((harness-provider-demo-script-override (harness-blocked-subagent-test--script outside))
           (child (harness-blocked-subagent-test--spawn parent)))
      (harness-test-wait (lambda () (harness-call 'session/pending child)) 10 "the request for the directory")
      ;; The harness's own list.
      (should (eq 'blocked (plist-get (harness-call 'session/get child) :status)))
      (should (equal (list child)
                     (mapcar (lambda (s) (plist-get s :id))
                             (harness-call 'session/list (list :kind 'subagent :status 'blocked)))))
      (should-not (eq 'blocked (plist-get (harness-call 'session/get parent) :status)))
      ;; What the UI heard of it.
      (harness-test-wait (lambda () (equal "blocked" (format "%s" (plist-get (harness-ui-session child) :status))))
                         5 "the UI to hear that the child is blocked")
      ;; The session list: its row under its parent's, blocked, and the line
      ;; under it that says what it waits on, with the buttons that answer.
      (let ((default-directory work))
        (harness-sessions)
        (let* ((text (harness-blocked-subagent-test--text harness-ui-sessions--buffer-name))
               (lines (split-string text "\n")))
          (should (string-match-p "↳ needs-access" text))
          (should (string-match-p "↳ needs-access .*blocked" text))
          (should (cl-some (lambda (line) (string-match-p "\\[Allow\\] \\[Deny\\]  permission · .*Access .*shared-types" line))
                           lines))
          ;; Under its parent: the parent's row comes first.
          (should (< (string-match "Lead" text) (string-match "↳ needs-access" text)))))
      ;; The parent's chat: the line the panel pins above its compose box.
      (let* ((panel (harness-blocked-subagent-test--panel parent))
             (text (substring-no-properties panel))
             (pos (string-match "needs-access" text)))
        (should (string-match-p "Sub-agents  1 blocked" text))
        ;; What it asks is cut to the room the line has, a long path shortened.
        (should (string-match-p "needs-access  Blocked  \\[Allow\\] \\[Deny\\]  Access /" text))
        ;; The name is the link that opens the child.
        (should pos)
        (should (commandp (lookup-key (get-text-property pos 'keymap panel) [mouse-1]))))
      ;; Answered from the parent's chat, the child goes on and the line goes.
      (let* ((panel (harness-blocked-subagent-test--panel parent))
             (allow (string-match "\\[Allow\\]" (substring-no-properties panel))))
        (funcall (get-text-property allow 'harness-ui-action panel)))
      (harness-test-wait (lambda () (not (harness-call 'session/pending child))) 10 "the answer to reach the child")
      (harness-test-wait (lambda () (not (harness-call 'agent/running child))) 10 "the child to end")
      (should-not (eq 'blocked (plist-get (harness-call 'session/get child) :status)))
      (harness-test-wait (lambda () (not (equal "blocked" (format "%s" (plist-get (harness-ui-session child) :status)))))
                         5 "the UI to hear that it goes on")
      (should-not (harness-blocked-subagent-test--panel parent)))))

(provide 'harness-agent-blocked-subagent-test)
;;; harness-agent-blocked-subagent-test.el ends here
