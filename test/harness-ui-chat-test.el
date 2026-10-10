;;; harness-ui-chat-test.el --- Tests for the chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the chat buffer against the real state layer, the demo
;; provider and the in-process ACP connection: rendering of every node
;; kind, streaming, folding, coalescing, the pending panel, the queue,
;; lazy history and redraws.  Runs in batch, so nothing here needs a
;; window system; image, clipboard and drag-and-drop paths are skipped.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-claude-program)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-usage-live-interval)
(defvar harness-ui--live)
(defvar mwheel-scroll-up-function)
(defvar mwheel-scroll-down-function)
(defvar harness-perms-rules)
(defvar harness-perms--session-rules)
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-perms--add-rule-noted "harness-perms")
(declare-function harness-ui-session-live "harness-ui")

(defvar harness-ui-chat-test-events nil "Recorded (EVENT . ARGS), newest first.")

(defun harness-ui-chat-test-record-event (event args)
  "Record EVENT with ARGS."
  (push (cons event args) harness-ui-chat-test-events))

(defmacro harness-ui-chat-test-with (&rest body)
  "Load the state layer, the demo provider, ACP and the chat UI, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-ui-chat-test-events nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (pcase-dolist (`(,name . ,label) '(("list_dir" . "List directory") ("read_file" . "Read file")
                                          ("glob" . "Find files") ("grep" . "Search files")))
         (harness-define-tool name :label label :description name :kind 'read :coalescable t
                              :subject (lambda (input) (or (plist-get input :path) (plist-get input :pattern)))
                              :handler (lambda (input _ctx) (format "%s of %s" name (plist-get input :path)))))
       (harness-define-tool "bash" :label "Bash" :description "bash" :kind 'exec
                            :handler (lambda (input _ctx) (format "ran %s" (plist-get input :command))))
       (harness-define-tool "ask_user" :label "Question" :description "ask" :kind 'meta
                            :handler (lambda (input _ctx) (format "answer to %s: red" (plist-get input :question))))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       ;; Images, videos and audio the transcript shows.
       (harness-test-load-module 'ui-media)
       (clrhash harness-ui--sessions)
       (add-hook 'harness-ui-event-functions #'harness-ui-chat-test-record-event)
       (unwind-protect
           (progn ,@body)
         (remove-hook 'harness-ui-event-functions #'harness-ui-chat-test-record-event)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-chat-test-session (&optional name)
  "Create a demo session called NAME and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                           :name (or name "Chat test"))
             :id))

(defun harness-ui-chat-test-open (sid)
  "Open the chat buffer of SID and wait until it has rendered."
  (let ((buf (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                       5 "chat buffer loaded")
    buf))

(defun harness-ui-chat-test-turns-ended (sid)
  "Return how many turns of SID ended."
  (cl-count-if (lambda (e) (and (equal (car e) "agent/turn-ended") (equal (cadr e) sid)))
               harness-ui-chat-test-events))

(defun harness-ui-chat-test-type (buf text)
  "Type TEXT into the compose box of BUF."
  (with-current-buffer buf
    (goto-char harness-compose-end)
    (insert text)))

(defun harness-ui-chat-test-prompt (buf text)
  "Send TEXT from BUF's compose box and wait for the turn to end."
  (with-current-buffer buf
    (let* ((sid harness-ui-session-id)
           (before (harness-ui-chat-test-turns-ended sid))
           (turns (or (plist-get (plist-get (harness-ui-session sid) :usage) :turns) 0)))
      (harness-ui-chat-test-type buf text)
      (harness-chat-send)
      (harness-test-wait (lambda () (> (harness-ui-chat-test-turns-ended sid) before)) 10 "turn ended")
      ;; The debounced session push (idle, usage counted) lands shortly after.
      (harness-test-wait (lambda () (let ((s (harness-ui-session sid)))
                                      (and (equal "idle" (plist-get s :status))
                                           (> (or (plist-get (plist-get s :usage) :turns) 0) turns))))
                         5 "session idle after the turn")
      (accept-process-output nil 0.1))))

(defun harness-ui-chat-test-blocks (buf kind)
  "Return the blocks of KIND in BUF, oldest first."
  (with-current-buffer buf
    (cl-remove-if-not (lambda (b) (equal (harness-chat-block-kind b) kind))
                      (mapcar (lambda (id) (gethash id harness-chat--blocks)) (reverse harness-chat--order)))))

(defun harness-ui-chat-test-face-at (pos face)
  "Non-nil when FACE is among the faces at POS."
  (let ((f (get-text-property pos 'face)))
    (or (eq f face) (and (listp f) (memq face f)))))

(defun harness-ui-chat-test-find (buf text &optional from)
  "Return the position of TEXT in BUF after FROM, or nil."
  (with-current-buffer buf
    (save-excursion
      (goto-char (or from (point-min)))
      (let ((case-fold-search nil))
        (search-forward text nil t)))))

;;;; Rendering a full turn

(ert-deftest harness-ui-chat-tour-renders-every-kind ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Tour"))
           (buf (harness-ui-chat-test-open sid)))
      (harness-test-wait (lambda () (equal (buffer-name buf) "*harness: Tour*")) 5 "buffer renamed")
      (with-current-buffer buf
        (should (derived-mode-p 'harness-chat-mode))
        (should (equal sid harness-ui-session-id))
        (should (string-match-p "No messages yet" (buffer-string))))
      (harness-ui-chat-test-prompt buf "give me the tour")
      (with-current-buffer buf
        ;; The user block carries the text on the user background.
        (let ((pos (harness-ui-chat-test-find buf "give me the tour")))
          (should pos)
          (should (harness-ui-chat-test-face-at (1- pos) 'harness-user-face))
          ;; Sender names, not icons, tell the two sides apart.
          (should (harness-ui-chat-test-face-at (- (harness-ui-chat-test-find buf "You") 1)
                                                'harness-user-label-face))
          (let ((agent (harness-ui-chat-test-find buf "Agent")))
            (should (< pos agent))
            (should (harness-ui-chat-test-face-at (1- agent) 'harness-agent-label-face))))
        ;; Thinking is collapsed under an overlay and expands.
        (let* ((think (car (harness-ui-chat-test-blocks buf "thinking")))
               (text-pos (harness-ui-chat-test-find buf "wants a tour")))
          (should think)
          (should (harness-chat-block-collapsed think))
          (should text-pos)
          (should (invisible-p (1- text-pos)))
          (should (string-match-p "thinking ([0-9]+ words)" (buffer-string)))
          (harness-chat-toggle-block (harness-chat-block-id think))
          (should-not (invisible-p (1- text-pos)))
          (should-not (harness-chat-block-collapsed think))
          (harness-chat-toggle-block (harness-chat-block-id think))
          (should (invisible-p (1- text-pos))))
        ;; The tool call and its result are one block, completed.
        (let ((tools (harness-ui-chat-test-blocks buf "tool-call")))
          (should (= 1 (length tools)))
          (should (harness-chat-block-result (car tools)))
          ;; Titled with the tool's label, which the header shows in place of its name.
          (should (string-prefix-p "List directory: " (plist-get (harness-chat-block-node (car tools)) :title)))
          (should-not (harness-ui-chat-test-blocks buf "tool-result"))
          (let ((title-pos (harness-ui-chat-test-find buf "List directory")))
            (should (harness-ui-chat-test-face-at (1- title-pos) 'harness-tool-face))
            (should (harness-ui-chat-test-face-at (1- title-pos) 'harness-tool-title-face))
            ;; What the call is about follows, in a face of its own.
            (should (harness-ui-chat-test-face-at (1+ title-pos) 'harness-tool-subject-face))
            (let ((header (save-excursion (goto-char title-pos)
                                          (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))
              (should (string-match-p "List directory /" header))
              (should-not (string-match-p "list_dir" header))))
          ;; It ran: a green circle.
          (let ((mark (harness-ui-chat-test-find buf (harness-ui-icon 'harness-icon-success)
                                                 (harness-ui-chat-test-find buf "List directory"))))
            (should mark)
            (should (harness-ui-chat-test-face-at (1- mark) 'harness-success-face)))
          (let ((out (harness-ui-chat-test-find buf "list_dir of")))
            (should out)
            (should (invisible-p (1- out)))))
        ;; Markdown rendered: heading face, code block, quote.
        (let ((h (harness-ui-chat-test-find buf "Tour" (harness-ui-chat-test-find buf "give me the tour"))))
          (should h)
          (should (harness-ui-chat-test-face-at (1- h) 'harness-md-heading-1)))
        (should (harness-ui-chat-test-find buf "(defun hello ()"))
        (should (harness-ui-chat-test-find buf "Quotes render too"))
        (should-not (string-match-p "```" (buffer-string)))
        ;; Node order: user, thinking, assistant, tool, assistant.
        (should (equal '("user" "thinking" "assistant" "tool-call" "assistant")
                       (mapcar (lambda (id) (harness-chat-block-kind (gethash id harness-chat--blocks)))
                               (reverse harness-chat--order))))
        ;; Streaming left no pending re-render and the content is final.
        (should (= 0 (hash-table-count harness-chat--render-timers)))
        (let ((last (car (last (harness-ui-chat-test-blocks buf "assistant")))))
          (should (string-prefix-p "# Tour" (harness-chat-block-content last))))
        ;; Every block is read-only; the compose box is not.
        (should (get-text-property (1+ (point-min)) 'read-only))
        (harness-ui-chat-test-type buf "z")
        (should (equal "z" (harness-compose-text)))
        (should (equal default-directory (plist-get (harness-ui-session sid) :cwd)))
        (harness-compose-set "")
        ;; Copying the last response yields its Markdown.
        (harness-chat-copy-last-response)
        (should (string-prefix-p "# Tour" (current-kill 0)))
        ;; The header shows the session and the compose box is empty again.
        ;; The whole of it: in the 80 columns of batch the spend makes room.
        (let ((header (harness-chat--header most-positive-fixnum)))
          (should (string-match-p "Tour" header))
          (should (string-match-p "demo" header))
          (should (string-match-p "\\$0.0042" header))
          ;; The context in use: the last prompt and what its call wrote.
          (should (string-match-p "2.2k/" header))
          (should (string-match-p " 180 out " header)))
        (should (string-match-p "idle" (harness-chat--mode-line)))
        (should (equal "" (harness-compose-text)))))))

(defun harness-ui-chat-test-bar-face-at (pos face)
  "Non-nil when the bar in the margin at POS is drawn in FACE."
  (let* ((prefix (get-text-property pos 'line-prefix))
         (f (and prefix (get-text-property 0 'face prefix))))
    (or (eq f face) (and (listp f) (memq face f)))))

(ert-deftest harness-ui-chat-handoff-notes ()
  "A note handing the conversation to another provider's model is the harness's.
It names the two models and opens the transcript it points at; a
summary made for a handoff says so."
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session))
          (file (expand-file-name "handoff.md" (harness-test-temp-dir)))
          (visited nil))
      (harness-call 'session/append sid '(:kind user :content "fix the parser"))
      (harness-call 'session/append sid
                    (list :kind 'user :content "Read the transcript before you answer."
                          :meta (list :from (harness-sender-system "model handoff")
                                      :handoff (list :mode "transcript" :file file
                                                     :from "demo:scripted" :to "claude:claude-opus-5-5"))))
      (harness-call 'session/append sid
                    (list :kind 'compaction :content "The parser needs fixing."
                          :meta (list :handoff (list :mode "compact" :from "demo:scripted"
                                                     :to "claude:claude-opus-5-5"))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (with-current-buffer buf
          (let ((case-fold-search nil)
                (from (harness-ui-model-label "demo:scripted"))
                (to (harness-ui-model-label "claude:claude-opus-5-5")))
            (should (= 1 (how-many "^You$" (point-min) (point-max))))
            (should (= 1 (how-many "^System · model handoff$" (point-min) (point-max))))
            (should (= 1 (how-many (concat "^" (regexp-quote (format "%s → %s" from to))) (point-min) (point-max))))
            (should (= 1 (how-many (regexp-quote (concat "context compacted to hand over to " to))
                                   (point-min) (point-max))))))
        (let ((action (with-current-buffer buf
                        (get-text-property (- (harness-ui-chat-test-find buf "[open the transcript]") 2)
                                           'harness-chat-action))))
          (should (functionp action))
          (cl-letf (((symbol-function 'find-file-other-window) (lambda (f &rest _) (setq visited f))))
            (funcall action))
          (should (equal file visited)))))))

(ert-deftest harness-ui-chat-call-the-harness-recorded ()
  "A tool call the harness recorded (the merge queue's conflict resolver,
as a spawn_agent call) renders and folds like the agent's own, but is
no part of the agent's turn: it names who made it where the agent's
header would stand, runs until its result comes whatever the session
does, and links the session it started.  The agent's next block opens
a turn of its own, and a redraw renders the same."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Fixer"))
           (rid (harness-ui-chat-test-session "Merge child"))
           (from (harness-sender-system "merge queue"))
           (opened nil))
      (harness-call 'session/append sid '(:kind user :content "fix the parser"))
      (harness-call 'session/append sid '(:kind assistant :content "Fixed it."))
      (harness-call 'session/hint sid "Merge into main has conflicts in README; session Merge child resolves them")
      (harness-call 'session/append sid (list :kind 'tool-call :tool "spawn_agent" :call-id "m1"
                                              :title "Sub-agent: Merge child"
                                              :input (list :name "Merge child" :prompt "Resolve the conflicts in README.")
                                              :meta (list :from from :child-id rid)))
      (let ((buf (harness-ui-chat-test-open sid)))
        (cl-flet ((check (done)
                    (with-current-buffer buf
                      (let* ((case-fold-search nil)
                             (block (car (harness-ui-chat-test-blocks buf "tool-call")))
                             (sender (harness-ui-chat-test-find buf "System · merge queue"))
                             (title (harness-ui-chat-test-find buf "Sub-agent"))
                             (link (harness-ui-chat-test-find buf "session: Merge child" title)))
                        ;; The harness's, not the agent's: the one Agent header is the reply's.
                        (should (= 1 (how-many "^System · merge queue$" (point-min) (point-max))))
                        (should (< (harness-ui-chat-test-find buf "Fixed it.") sender title))
                        (should (= (if done 2 1) (how-many "^Agent$" (point-min) (point-max))))
                        ;; Folded like any call, the link to its session in sight.
                        (should (= 1 (length (harness-ui-chat-test-blocks buf "tool-call"))))
                        (should-not (harness-ui-chat-test-blocks buf "tool-result"))
                        (should (harness-chat-block-collapsed block))
                        (should link)
                        (should-not (invisible-p (1- link)))
                        (should (invisible-p (1- (harness-ui-chat-test-find buf "Resolve the conflicts in README." link))))
                        (setq opened nil)
                        (cl-letf (((symbol-function 'harness-open-session) (lambda (id &rest _) (setq opened id)))
                                  ((symbol-function 'harness-ui-display-session) (lambda (id &rest _) (setq opened id))))
                          (funcall (get-text-property (1- link) 'harness-chat-action))
                          (should (equal rid opened))
                          ;; The call's own block opens it too, not only the
                          ;; session line: mouse-1 and RET on the title.
                          (let ((keys (get-text-property (1- title) 'keymap)))
                            (setq opened nil)
                            (call-interactively (lookup-key keys (kbd "RET")))
                            (should (equal rid opened))
                            (setq opened nil)
                            (call-interactively (lookup-key keys [mouse-1]))
                            (should (equal rid opened))))
                        ;; Running while the session idles, until its result comes.
                        (let ((status (save-excursion (goto-char title)
                                                      (buffer-substring (line-beginning-position) (line-end-position)))))
                          (if done
                              (should (string-match-p (regexp-quote (harness-ui-icon 'harness-icon-success)) status))
                            (should (string-match-p "running" status))))))))
          (check nil)
          ;; The result joins the call's block.
          (harness-call 'session/append sid (list :kind 'tool-result :call-id "m1" :output "Resolved."
                                                  :meta (list :from from :child-id rid)))
          ;; The agent's next reply opens a turn of its own.
          (harness-call 'session/append sid '(:kind assistant :content "Back to work."))
          (harness-test-wait (lambda () (harness-ui-chat-test-find buf "Back to work.")) 5 "the reply")
          (check t)
          (with-current-buffer buf
            (should (< (harness-ui-chat-test-find buf "Sub-agent")
                       (harness-ui-chat-test-find buf "Agent" (harness-ui-chat-test-find buf "Sub-agent"))
                       (harness-ui-chat-test-find buf "Back to work.")))
            (harness-chat-redraw)
            (harness-test-wait (lambda () (not harness-chat--loading)) 5 "redrawn"))
          (check t))))))

(ert-deftest harness-ui-chat-call-block-opens-the-session-it-started ()
  "A tool call that names a session -- the spawn_agent call the harness
named its child on, while the call still runs -- opens that session
from anywhere on its block, on mouse-1 or RET, as well as from its
session line.  A button in the block keeps its own key; a call that
names no session is no link."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Parent"))
           (kid (harness-ui-chat-test-session "Kid"))
           (buf (harness-ui-chat-test-open sid))
           (opened nil))
      (harness-call 'session/append sid '(:kind user :content "delegate the tour"))
      (harness-call 'session/append sid
                    (list :kind 'tool-call :tool "spawn_agent" :call-id "s1"
                          :title "Sub-agent: Kid" :input (list :prompt "do the tour" :name "Kid")
                          :meta (list :model "demo:scripted" :child-id kid)))
      (harness-call 'session/append sid
                    (list :kind 'tool-call :tool "bash" :call-id "s2"
                          :title "Bash: true" :input '(:command "true")))
      (harness-test-wait (lambda () (harness-ui-chat-test-find buf "Bash")) 5 "the calls rendered")
      (with-current-buffer buf
        (let* ((child-title (harness-ui-chat-test-find buf "Sub-agent"))
               (block (cl-find "s1" (harness-ui-chat-test-blocks buf "tool-call")
                               :key (lambda (b) (plist-get (harness-chat-block-node b) :call-id))
                               :test #'equal)))
          (should block)
          ;; The session line is there, and opens the child.
          (let ((line (harness-ui-chat-test-find buf "session: Kid" child-title)))
            (should line)
            (cl-letf (((symbol-function 'harness-open-session) (lambda (id &rest _) (setq opened id)))
                      ((symbol-function 'harness-ui-display-session) (lambda (id &rest _) (setq opened id))))
              (funcall (get-text-property (1- line) 'harness-chat-action))
              (should (equal kid opened))
              ;; The block's own text opens it too, on RET and on a click.
              (let ((keys (get-text-property (1- child-title) 'keymap)))
                (should (keymapp keys))
                (setq opened nil)
                (call-interactively (lookup-key keys (kbd "RET")))
                (should (equal kid opened))
                (setq opened nil)
                (call-interactively (lookup-key keys [mouse-1]))
                (should (equal kid opened)))
              ;; The fold icon keeps its own key: RET on it folds.
              (let ((fold (harness-ui-chat-test-find
                           buf (harness-ui-icon 'harness-icon-collapsed)
                           (harness-chat-block-start block))))
                (should fold)
                (should (harness-chat-block-collapsed block))
                (call-interactively
                 (lookup-key (get-text-property (1- fold) 'keymap) (kbd "RET")))
                (should-not (harness-chat-block-collapsed block)))))
          ;; A call that names no session is no link.
          (let ((plain (harness-ui-chat-test-find buf "Bash")))
            (should plain)
            (should-not (get-text-property (1- plain) 'keymap))
            (should-not (harness-ui-chat-test-find buf "session:" (1- plain)))))))))

(ert-deftest harness-ui-chat-call-block-links-outside-and-failed-calls ()
  "A call the harness recorded -- the supervisor's worker -- and a call
whose result came back an error that names no session both open their
sub-agent from the block: the call node names it from the start."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Boss"))
           (worker (harness-ui-chat-test-session "Worker"))
           (from (harness-sender-system "supervisor"))
           (buf (harness-ui-chat-test-open sid))
           (opened nil))
      (harness-call 'session/append sid
                    (list :kind 'tool-call :tool "spawn_agent" :call-id "w1"
                          :title "Sub-agent: Worker" :input (list :prompt "do the job" :name "Worker")
                          :meta (list :from from :child-id worker)))
      ;; The result speaks for the step; it does not name the worker again.
      (harness-call 'session/append sid
                    (list :kind 'tool-result :call-id "w1" :output "Step failed: boom" :is-error t
                          :meta (list :from from)))
      (harness-test-wait (lambda () (harness-ui-chat-test-find buf "Step failed")) 5 "the result rendered")
      (with-current-buffer buf
        (let* ((title (harness-ui-chat-test-find buf "Sub-agent"))
               (keys (get-text-property (1- title) 'keymap)))
          (should (harness-ui-chat-test-find buf "session: Worker" title))
          (should (keymapp keys))
          (cl-letf (((symbol-function 'harness-ui-display-session) (lambda (id &rest _) (setq opened id))))
            (setq opened nil)
            (call-interactively (lookup-key keys (kbd "RET")))
            (should (equal worker opened))
            (setq opened nil)
            (call-interactively (lookup-key keys [mouse-1]))
            (should (equal worker opened)))
          ;; The failed call still says so.
          (should (harness-ui-chat-test-find buf "failed")))))))

(ert-deftest harness-ui-chat-messages-the-user-did-not-write ()
  "A message the harness or another session sent names its sender, not \"You\",
on a background and bar of its own; the user's own messages are as before."
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session))
          (opened nil))
      (harness-call 'session/append sid '(:kind user :content "my own words"))
      (harness-call 'session/append sid (list :kind 'user :content "carry on after the restart"
                                              :meta (list :from (harness-sender-system "tasks"))))
      (harness-call 'session/append sid (list :kind 'user :content "rebase please"
                                              :meta (list :steering t
                                                          :from (harness-sender-session
                                                                 '(:id "0123456789abcdef" :name "Fix the parser")))))
      (harness-call 'session/append sid (list :kind 'user :content "from a nameless one"
                                              :meta (list :from (harness-sender-session '(:id "fedcba9876543210")))))
      (let ((buf (harness-ui-chat-test-open sid))
            (start (lambda (buf text) (- (harness-ui-chat-test-find buf text) (length text)))))
        (with-current-buffer buf
          (let ((case-fold-search nil))
            ;; One "You", over the user's own message; the others name their sender.
            (should (= 1 (how-many "^You$" (point-min) (point-max))))
            (should (= 1 (how-many "^System · tasks$" (point-min) (point-max))))
            (should (= 1 (how-many "^Session · Fix the parser$" (point-min) (point-max))))
            ;; Without a name, a session goes by its short id.
            (should (= 1 (how-many "^Session · fedcba98$" (point-min) (point-max)))))
          (let ((mine (funcall start buf "my own words"))
                (label (funcall start buf "System · tasks"))
                (system (funcall start buf "carry on after the restart"))
                (session (funcall start buf "rebase please")))
            (should (harness-ui-chat-test-face-at mine 'harness-user-face))
            (should (harness-ui-chat-test-bar-face-at mine 'harness-user-bar-face))
            (should (harness-ui-chat-test-face-at label 'harness-system-label-face))
            (dolist (pos (list label system session))
              (should (harness-ui-chat-test-face-at pos 'harness-system-face))
              (should-not (harness-ui-chat-test-face-at pos 'harness-user-face))
              (should (harness-ui-chat-test-bar-face-at pos 'harness-system-bar-face))))
          ;; The sending session's name opens it.
          (let ((action (get-text-property (funcall start buf "Fix the parser") 'harness-chat-action)))
            (should (functionp action))
            (cl-letf (((symbol-function 'harness-open-session) (lambda (id &rest _) (setq opened id))))
              (funcall action))
            (should (equal "0123456789abcdef" opened)))))
      ;; One that arrives while the buffer is open is shown so too.
      (let ((buf (harness-chat--buffer-for sid)))
        (harness-call 'session/append sid (list :kind 'user :content "resolve the conflicts"
                                                :meta (list :from (harness-sender-system "merge queue"))))
        (harness-test-wait (lambda () (harness-ui-chat-test-find buf "System · merge queue")) 5 "the live message")
        (with-current-buffer buf
          (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "resolve the conflicts"))
                                                'harness-system-face)))))))

;; In a graphical frame an icon is a space whose `display' draws its
;; image.  Toggling a block once carried the collapsed icon's `display'
;; over to the expanded one, so the arrow never turned.  Batch draws no
;; images, so image icons are stubbed in.
(ert-deftest harness-ui-chat-fold-icon-follows-the-block ()
  (harness-ui-chat-test-with
    (cl-letf (((symbol-function 'icon-string)
               (lambda (name) (propertize " " 'display (list 'image :type 'svg :file (format "%s.svg" name)))))
              (harness-ui--icons (make-hash-table :test 'equal)))
      (let* ((sid (harness-ui-chat-test-session "Arrows"))
             (buf (harness-ui-chat-test-open sid)))
        (harness-ui-chat-test-prompt buf "give me the tour")
        (with-current-buffer buf
          (let ((blocks (append (harness-ui-chat-test-blocks buf "thinking")
                                (harness-ui-chat-test-blocks buf "tool-call"))))
            (should (= 2 (length blocks)))
            (dolist (block blocks)
              (cl-flet* ((icon-pos () (text-property-any (harness-chat-block-start block) (harness-chat-block-end block)
                                                         'harness-chat-fold-icon t))
                         (icon () (plist-get (cdr (get-text-property (icon-pos) 'display)) :file)))
                (should (harness-chat-block-collapsed block))
                (should (equal "harness-icon-collapsed.svg" (icon)))
                ;; Clicking the arrow expands the block and turns the arrow,
                ;; which stays a working button.
                (call-interactively (lookup-key (get-text-property (icon-pos) 'keymap) (kbd "RET")))
                (should-not (harness-chat-block-collapsed block))
                (should (equal "harness-icon-expanded.svg" (icon)))
                (should (= 1 (- (next-single-property-change (icon-pos) 'harness-chat-fold-icon) (icon-pos))))
                (should (equal (harness-chat-block-id block) (get-text-property (icon-pos) 'harness-chat-node)))
                (call-interactively (lookup-key (get-text-property (icon-pos) 'keymap) (kbd "RET")))
                (should (harness-chat-block-collapsed block))
                (should (equal "harness-icon-collapsed.svg" (icon)))))))))))

(ert-deftest harness-ui-chat-header-shows-the-plan ()
  "A session a subscription pays for shows the plan and its quota, not a price."
  (harness-ui-chat-test-with
    (clrhash harness-ui--quotas)
    (let* ((sid (harness-ui-chat-test-session "Plan test"))
           (buf (harness-ui-chat-test-open sid)))
      (harness-call 'session/usage-add sid '(:input 100 :output 10 :cost 0.0 :list-cost 0.5
                                             :billing subscription :plan "pro"))
      (harness-ui--store-quota "demo" '(:billing "subscription" :plan "pro" :plan-label "Claude Pro"
                                        :windows ((:name "5h" :label "Current session (5 hours)" :used 0.42))))
      (harness-test-wait (lambda () (equal "subscription"
                                           (format "%s" (plist-get (plist-get (harness-ui-session sid) :usage) :billing))))
                         5 "the session update")
      (with-current-buffer buf
        ;; The whole header: the plan's window is what this is about, so
        ;; ask for a wide line rather than what an 80-column batch window keeps.
        (let ((header (harness-chat--header most-positive-fixnum)))
          (should (string-match-p "Pro . 5h 42%" header))
          (should-not (string-match-p "\\$0\\.5" header))
          (let ((pos (string-match "Pro" header)))
            (should (string-match-p "Covered by Claude Pro" (get-text-property pos 'help-echo header)))
            ;; One line: showing it in the echo area must not move the header.
            (should-not (string-match-p "\n" (get-text-property pos 'help-echo header)))
            (should (get-text-property pos 'local-map header))))))))

(ert-deftest harness-ui-chat-header-shows-the-output-rate ()
  "The header says how fast the session's model wrote, as the harness measured it.
The harness times the turn's streaming; the figure stays once the
session is idle, dimmed, and makes room first in a narrow window."
  (harness-ui-chat-test-with
    (harness-test-load-module 'usage)
    (clrhash harness-ui--rates)
    (let* ((sid (harness-ui-chat-test-session "Rate"))
           (buf (harness-ui-chat-test-open sid))
           (harness-provider-demo--delay 0.05)
           (harness-provider-demo-script-override
            (append (make-list 8 '(:type text :delta "word "))
                    '((:type usage :input 100 :output 40 :cost 0.0001 :context 100)
                      (:type done :stop-reason end-turn)))))
      (with-current-buffer buf
        (should-not (string-match-p "tok/s" (harness-chat--header most-positive-fixnum))))
      (harness-ui-chat-test-prompt buf "hello")
      (harness-test-wait (lambda () (harness-ui-session-rate sid)) 5 "the rate")
      (let ((rate (harness-ui-session-rate sid)))
        (should (= 40 (plist-get rate :output)))
        (should (= 1 (plist-get rate :calls)))
        (should (equal "demo:scripted" (plist-get rate :model)))
        (with-current-buffer buf
          (let* ((full (harness-chat--header most-positive-fixnum))
                 (text (concat (harness-ui-format-rate-number (plist-get rate :rate)) " tok/s"))
                 (pos (string-search text full)))
            (should pos)
            ;; After the context, before the spend.
            (should (< (string-search (harness-ui-format-context (harness-ui-session sid)) full) pos))
            (should (< pos (string-search "$" full)))
            (should (memq 'harness-dim-face (ensure-list (get-text-property pos 'face full))))
            (should (string-prefix-p "Last output rate: " (get-text-property pos 'help-echo full)))
            ;; A column short, the rate goes and the rest stays.
            (should (equal (string-replace (concat "  " text) "" (substring-no-properties full))
                           (substring-no-properties
                            (harness-chat--header (1- (harness-ui-header-string-width full))))))))))))

(ert-deftest harness-ui-chat-header-counts-tokens-as-they-stream ()
  "The header's token figures grow while the model streams, not at the end.
The harness counts what streams, a token for every four characters, and
the header marks figures so estimated with \"~\".  The call's usage
report replaces the estimate with the real numbers, which stay once the
turn ended: the context in use is then the prompt plus what the call
wrote.  The output goes after the context and before the rate."
  (harness-ui-chat-test-with
    (harness-test-load-module 'usage)
    (clrhash harness-ui--live)
    (clrhash harness-ui--rates)
    (let* ((sid (harness-ui-chat-test-session "Live"))
           (buf (harness-ui-chat-test-open sid))
           (harness-usage-live-interval 0.05)
           (harness-provider-demo--delay 0.05)
           (harness-provider-demo-script-override
            (append (make-list 40 '(:type text :delta "eight ch"))
                    '((:type usage :input 100 :output 70 :cost 0.0001 :context 100)
                      (:type done :stop-reason end-turn))))
           (out (lambda (live) (plist-get live :output))))
      (with-current-buffer buf
        (should-not (string-match-p " out" (harness-chat--header most-positive-fixnum)))
        (harness-ui-chat-test-type buf "hello")
        (harness-chat-send))
      ;; Streaming: two tokens for each delta of eight characters, all estimated.
      (harness-test-wait (lambda () (>= (or (funcall out (harness-ui-session-live sid)) 0) 10))
                         5 "the live count")
      (let ((live (harness-ui-session-live sid)))
        (should (= 0 (% (funcall out live) 2)))
        (should (= (funcall out live) (plist-get live :estimated)))
        (should (= (funcall out live) (plist-get live :context)))
        (with-current-buffer buf
          (let ((header (harness-chat--header most-positive-fixnum)))
            (should (string-search (format "  ~%d/" (plist-get live :context)) header))
            (should (string-search (format "  ~%d out" (funcall out live)) header))))
        (harness-test-wait (lambda () (> (or (funcall out (harness-ui-session-live sid)) 0) (funcall out live)))
                           5 "the live count to grow"))
      (should (equal "running" (plist-get (harness-ui-session sid) :status)))
      ;; Reported and ended: the real numbers.
      (harness-test-wait (lambda () (= 1 (harness-ui-chat-test-turns-ended sid))) 10 "the turn to end")
      (harness-test-wait (lambda () (equal "idle" (plist-get (harness-ui-session sid) :status)))
                         5 "the session idle")
      (harness-test-wait (lambda () (harness-ui-session-rate sid)) 5 "the rate")
      (should-not (gethash sid harness-ui--live))
      (with-current-buffer buf
        (let* ((header (harness-chat--header most-positive-fixnum))
               (context (string-search "  170/" header))
               (output (string-search "  70 out" header))
               (rate (string-search " tok/s" header)))
          (should context)
          (should output)
          (should rate)
          (should (< context output rate))
          (should-not (string-search "~" header))
          (should (equal "Context tokens in use: 170; output tokens: 70."
                         (get-text-property (+ 2 output) 'help-echo header))))))))

(ert-deftest harness-ui-chat-header-context-figure-raises-the-limit ()
  "The token figure in the chat header is a button.  It offers the
session's context limit, up to the model's own window (8k for the demo
model), and the header shows the new window at once.  The conversation
is untouched: no node, compaction or turn is added by the change."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Capped"))
           (buf (harness-ui-chat-test-open sid))
           (nodes (length (harness-call 'session/nodes sid))))
      ;; A cap like a sub-agent's: 4k of the 8k model.
      (harness-call 'session/update sid :context-window-limit 4000 :silent t)
      (harness-test-wait (lambda () (equal 4000 (plist-get (harness-ui-session sid) :context-window-limit)))
                         5 "the cap to reach the UI")
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (equal 4000 (plist-get harness-chat--session
                                                             :context-window-limit))))
                         5 "the cap to reach the chat")
      (with-current-buffer buf
        (let* ((header (harness-chat--header most-positive-fixnum))
               (pos (string-search "0/4.0k" header)))
          (should pos)
          ;; A button as the header's other segments are.
          (should (get-text-property pos 'local-map header))
          (should (eq 'mode-line-highlight (get-text-property pos 'mouse-face header)))
          (should (string-match-p "capped at 4.0k" (get-text-property pos 'help-echo header)))
          (should (string-match-p "changes the limit" (get-text-property pos 'help-echo header)))
          ;; Run what the button runs: no limit, the model's whole window.
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (car (cl-find-if (lambda (o) (string-prefix-p "no limit" (car o))) table)))))
            (call-interactively #'harness-set-context-limit))))
      (harness-test-wait (lambda () (null (plist-get (harness-ui-session sid) :context-window-limit)))
                         5 "the limit cleared")
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (equal 8000 (plist-get harness-chat--session :context-window))))
                         5 "the chat's new window")
      (with-current-buffer buf
        (should (string-search "0/8.0k" (harness-chat--header most-positive-fixnum))))
      ;; The conversation is not touched: at most the hint that says the
      ;; limit changed, and no restart (a user or assistant node), no
      ;; compaction and no turn.
      (let ((now (harness-call 'session/nodes sid)))
        (should (<= (length now) (1+ nodes)))
        (dolist (n now)
          (should (equal "hint" (format "%s" (plist-get n :kind))))))
      (should (equal "idle" (plist-get (harness-ui-session sid) :status))))))

(ert-deftest harness-ui-chat-hover-help-is-one-line ()
  "Every tooltip of a rendered session fits one echo-area line.
With tooltips off (`tooltip-mode' nil) the help shows in the echo area,
where a second line grows the mini window, shrinks every window and
moves the button under the mouse."
  (harness-ui-chat-test-with
    (clrhash harness-ui--quotas)
    (let* ((sid (harness-ui-chat-test-session "Hover"))
           (buf (harness-ui-chat-test-open sid)))
      (harness-ui-chat-test-prompt buf "give me the tour")
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (let ((last (car (last (harness-ui-chat-test-blocks buf "assistant")))))
                                        (and last (string-prefix-p "# Tour" (harness-chat-block-content last))))))
                         5 "the tour")
      ;; A plan with a quota gives the header's spend segment its long tooltip.
      (harness-call 'session/usage-add sid '(:input 100 :output 10 :cost 0.0 :list-cost 0.5
                                             :billing subscription :plan "pro"))
      (harness-ui--store-quota "demo" '(:billing "subscription" :plan "pro" :plan-label "Claude Pro"
                                        :extra (:enabled t :used 0.4 :limit 10.0)
                                        :windows ((:name "5h" :label "Current session (5 hours)" :used 0.42)
                                                  (:name "7d" :label "Weekly (7 days)" :used 0.7))))
      (harness-test-wait (lambda () (equal "subscription"
                                           (format "%s" (plist-get (plist-get (harness-ui-session sid) :usage) :billing))))
                         5 "the session update")
      (with-current-buffer buf
        (let ((offenders nil))
          (dolist (text (list (buffer-string) (harness-chat--header most-positive-fixnum)))
            (let ((pos 0))
              (while (< pos (length text))
                (let ((help (get-text-property pos 'help-echo text)))
                  (when (and (stringp help) (string-match-p "\n" help))
                    (push help offenders)))
                (setq pos (1+ pos)))))
          ;; The header's spend tooltip really is among them: the whole
          ;; header, since a narrow window may drop the spend segment.
          (let* ((header (harness-chat--header most-positive-fixnum))
                 (pos (string-match "Pro" header)))
            (should (string-match-p "Covered by Claude Pro" (get-text-property pos 'help-echo header))))
          (should-not offenders))))))

(ert-deftest harness-ui-chat-header-functions-come-first ()
  "What `harness-chat-header-functions' return leads the header, in order.
The session's own segments follow unchanged; nil adds nothing; a
buffer-local function changes only its buffer's header."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session "Mine")))
           (other (harness-ui-chat-test-open (harness-ui-chat-test-session "Other")))
           ;; Whole headers: no segment of theirs makes room for the other.
           (own (with-current-buffer buf (harness-chat--header most-positive-fixnum)))
           (other-own (with-current-buffer other (harness-chat--header most-positive-fixnum))))
      (should (string-match-p "Mine" own))
      (with-current-buffer buf
        (add-hook 'harness-chat-header-functions (lambda () (propertize " first" 'face 'bold)) nil t)
        (add-hook 'harness-chat-header-functions #'ignore t t)
        (add-hook 'harness-chat-header-functions (lambda () " second") t t)
        (let ((header (harness-chat--header most-positive-fixnum)))
          (should (equal (concat " first second" own) header))
          (should (eq 'bold (get-text-property 1 'face header)))
          ;; The session's segments keep their clicks.
          (should (get-text-property (string-search "Mine" header) 'local-map header))))
      (should (equal other-own (with-current-buffer other (harness-chat--header most-positive-fixnum))))
      (with-current-buffer buf
        (kill-local-variable 'harness-chat-header-functions)
        (should (equal own (harness-chat--header most-positive-fixnum)))))))

(defun harness-ui-chat-test-segment (header command)
  "Return (TEXT POS) of the segment of HEADER that runs COMMAND, or nil."
  (let ((map (harness-chat--segment-map command))
        (pos 0) found)
    (while (and (not found) (< pos (length header)))
      (if (eq map (get-text-property pos 'local-map header))
          (setq found pos)
        (setq pos (next-single-property-change pos 'local-map header (length header)))))
    (when found
      (list (substring-no-properties header found (next-single-property-change found 'local-map header (length header)))
            found))))

(ert-deftest harness-ui-chat-header-shows-and-toggles-non-interactive ()
  "The header line says whether the session waits for the user, right
after its permission mode.  A click there toggles it in the harness,
the header follows, and the transcript notes each change."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Away"))
           (buf (harness-ui-chat-test-open sid))
           (w (selected-window)))
      (set-window-buffer w buf)
      (cl-flet* ((header () (with-current-buffer buf (harness-chat--header)))
                 (segment () (harness-ui-chat-test-segment (header) #'harness-toggle-non-interactive))
                 (prop (name) (get-text-property (cadr (segment)) name (header)))
                 (click () (funcall (lookup-key (prop 'local-map) [header-line mouse-1])
                                    (list 'mouse-1 (list w 'header-line '(0 . 0) 0))))
                 (await (on what) (harness-test-wait
                                   (lambda () (eq on (harness-json-true-p
                                                      (plist-get (harness-ui-session sid) :non-interactive))))
                                   5 what)))
        (should (equal "interactive" (car (segment))))
        (should (eq 'harness-dim-face (prop 'face)))
        (should (string-match-p "waits for your answer.*mouse-1: make it non-interactive" (prop 'help-echo)))
        ;; Next to the permission mode.
        (should (string-match-p "Ask  interactive  " (substring-no-properties (header))))
        (click)
        (await t "switched on")
        (should (eq t (plist-get (harness-call 'session/get sid) :non-interactive)))
        (should (equal "non-interactive" (car (segment))))
        (should (eq 'harness-non-interactive-face (prop 'face)))
        (should (string-match-p "never waits for you.*mouse-1: make it interactive" (prop 'help-echo)))
        (click)
        (await nil "switched off")
        (should-not (plist-get (harness-call 'session/get sid) :non-interactive))
        (should (equal "interactive" (car (segment))))
        (harness-test-wait (lambda () (harness-ui-chat-test-find buf "non-interactive off")) 5 "the hint")
        (should (< (harness-ui-chat-test-find buf "non-interactive on")
                   (harness-ui-chat-test-find buf "non-interactive off")))))))

(ert-deftest harness-ui-chat-streaming-appends-cheaply ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (with-current-buffer buf
        ;; A node announcement followed by chunks: the first chunk is the
        ;; announced content and is not duplicated; later chunks append.
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-live" :kind "assistant" :content "Hello")))
        (harness-chat--apply-update (list :sessionUpdate "agent_message_chunk"
                                          :content (list :type "text" :text "Hello")
                                          :_harness (list :nodeId "n-live")))
        (harness-chat--apply-update (list :sessionUpdate "agent_message_chunk"
                                          :content (list :type "text" :text " world")
                                          :_harness (list :nodeId "n-live")))
        (let ((b (gethash "n-live" harness-chat--blocks)))
          (should (equal "Hello world" (harness-chat-block-content b)))
          ;; Appended blocks stay outside the compose box and its background.
          (should-not (memq harness-compose-overlay (overlays-at (harness-chat-block-start b))))
          (should (= 1 (hash-table-count harness-chat--render-timers)))
          ;; The first agent block of the turn opens with the sender line.
          (should (equal "Agent\nHello world"
                         (string-trim (buffer-substring-no-properties (harness-chat-block-start b)
                                                                      (harness-chat-block-end b)))))
          ;; The final node replaces the text with the Markdown rendering.
          (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                            :node (list :id "n-live" :kind "assistant" :content "Hello **world**")))
          (should (= 0 (hash-table-count harness-chat--render-timers)))
          (let ((pos (harness-ui-chat-test-find buf "world")))
            (should (harness-ui-chat-test-face-at (1- pos) 'bold))))
        ;; A chunk for an unknown node creates its block.
        (harness-chat--apply-update (list :sessionUpdate "agent_thought_chunk"
                                          :content (list :type "text" :text "hmm")
                                          :_harness (list :nodeId "n-think")))
        (should (equal "thinking" (harness-chat-block-kind (gethash "n-think" harness-chat--blocks))))
        (should (equal '("n-think" "n-live") harness-chat--order))))))

;;;; Bursts of messages

(defun harness-ui-chat-test-connect ()
  "Connect the UI and wait for the model catalogue.
The first one over a connection redraws every chat buffer; a test that
streams into a buffer of its own must not see it rebuilt halfway."
  (harness-ui-connection)
  (harness-test-wait (lambda () (eq harness-ui-connection (car harness-ui--models-seen))) 5 "the model catalogue"))

(defun harness-ui-chat-test-push (sid update)
  "Send UPDATE of session SID to the UI, as the harness does, through its client."
  (harness-acp--client-send (cl-find harness-ui-connection harness-acp--clients
                                     :key #'harness-acp-client-connection)
                            (list :jsonrpc "2.0" :method "session/update"
                                  :params (list :sessionId sid :update update))))

(defun harness-ui-chat-test-chunk (id text)
  "Return the update streaming TEXT into node ID."
  (list :sessionUpdate "agent_message_chunk" :content (list :type "text" :text text)
        :_harness (list :nodeId id)))

(ert-deftest harness-ui-chat-burst-scrolls-once-a-slice ()
  "A burst of streamed text scrolls the window following it a few times only.
Messages that piled up while Emacs was busy were handled in one go, and
each chunk scrolled the window it streamed into again: with four
sessions streaming, Emacs froze for seconds at a time (2026-10-07).
They are handled a slice at a time now (`harness-acp-receive-slice'),
and a window is scrolled once a slice, to the end of the text still."
  (harness-ui-chat-test-with
    (harness-ui-chat-test-connect)
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (w (selected-window))
           (n 300)
           (pins 0)
           (pin (symbol-function 'harness-chat--pin)))
      (set-window-buffer w buf)
      (with-current-buffer buf
        (set-window-point w harness-compose-end)
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-burst" :kind "assistant" :content ""))))
      (cl-letf (((symbol-function 'harness-chat--pin)
                 (lambda (window) (cl-incf pins) (funcall pin window))))
        (dotimes (i n)
          (harness-ui-chat-test-push sid (harness-ui-chat-test-chunk "n-burst" (format "line %d\n" i))))
        (harness-test-wait (lambda () (with-current-buffer buf
                                        (string-suffix-p (format "line %d\n" (1- n))
                                                         (harness-chat-block-content
                                                          (gethash "n-burst" harness-chat--blocks)))))
                           10 "the burst to be handled"))
      (with-current-buffer buf
        ;; Every chunk, in order.
        (should (equal (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 0 (1- n)) "")
                       (harness-chat-block-content (gethash "n-burst" harness-chat--blocks))))
        ;; The window scrolled a few times, not once a chunk ...
        (should (< 0 pins 20))
        ;; ... and shows the end of the buffer.
        (should (> (window-start w) (harness-chat-block-start (gethash "n-burst" harness-chat--blocks))))
        (should (<= (count-lines (window-start w) (point-max)) (window-body-height w)))))))

(ert-deftest harness-ui-chat-hidden-chat-renders-once-shown ()
  "A chat no window shows keeps streamed text as it came, and renders it once shown.
Rendering the Markdown of a message streaming in, again and again,
cost the UI as much for chats nobody looked at as for the one it showed."
  (harness-ui-chat-test-with
    (harness-ui-chat-test-connect)
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (w (selected-window)))
      (with-current-buffer buf
        (should-not (harness-chat--windows))
        (should-not harness-chat--redraw-pending)
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-hidden" :kind "assistant" :content "")))
        (harness-chat--apply-update (harness-ui-chat-test-chunk "n-hidden" "Hello **world**")))
      ;; The re-render came due with no window: the text is as it came.
      (harness-test-wait (lambda () (buffer-local-value 'harness-chat--stale buf)) 5 "the re-render to be due")
      (with-current-buffer buf
        (should (equal '("n-hidden") harness-chat--stale))
        (should (= 0 (hash-table-count harness-chat--render-timers)))
        (should (harness-ui-chat-test-find buf "Hello **world**"))
        ;; Shown, it is rendered.
        (set-window-buffer w buf)
        (harness-chat--on-window-buffer-change w)
        (should-not harness-chat--stale)
        (should-not (harness-ui-chat-test-find buf "**"))
        (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "world")) 'bold))
        ;; Streaming on while shown re-renders as before.
        (harness-chat--apply-update (harness-ui-chat-test-chunk "n-hidden" " and *more*"))
        (harness-test-wait (lambda () (with-current-buffer buf (not (harness-ui-chat-test-find buf "*more*"))))
                           5 "the re-render")
        (should-not harness-chat--stale)
        (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "more")) 'italic))))))

;;;; Very long messages

(ert-deftest harness-ui-chat-long-message-shows-a-page ()
  "A message of hundreds of KB shows one page, the rest behind a button.
In the buffer whole, redisplay wraps the enormous text and lays it out
on every redisplay, and `recenter' and `harness-ui-text-height' walk
all of it: opening or scrolling such a chat froze Emacs for seconds
(2026-10-09).  The tool output and the report view already capped what
they show; a message that long does too now."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Long message"))
           (buf (harness-ui-chat-test-open sid))
           ;; One enormous line, as the harness's own long messages are.
           (content (make-string 800000 ?x))
           (limit harness-chat--message-limit))
      (with-current-buffer buf
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-long" :kind "assistant" :content content)))
        (let ((block (gethash "n-long" harness-chat--blocks)))
          ;; The whole message is kept ...
          (should (equal content (harness-chat-block-content block)))
          ;; ... while the buffer holds one page of it, and the button.
          (should (< (buffer-size) (+ limit 2000)))
          (should (harness-ui-chat-test-find buf (format "show more (%d more chars)" (- 800000 limit))))
          ;; Pressing the button shows another page, not the whole message.
          (goto-char (harness-ui-chat-test-find buf "show more"))
          (harness-chat-push)
          (should (= (* 2 limit) (harness-chat-block-shown block)))
          (should (< (buffer-size) (+ (* 2 limit) 2000)))
          (should (harness-ui-chat-test-find buf (format "show more (%d more chars)" (- 800000 (* 2 limit))))))
        ;; A message one page and a bit long shows the rest, not more pages.
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-rest" :kind "assistant"
                                                      :content (make-string (+ limit 5000) ?y))))
        (should (harness-ui-chat-test-find buf (format "show the rest (%d more chars)" 5000)))))))

(ert-deftest harness-ui-chat-long-system-message-shows-a-page ()
  "The same for the enormous message the harness sends a worker itself.
A supervisor's step prompt, the plan and a report are user messages
with a sender (see `harness-node-sender'); one of them was the message
the user's Emacs froze on."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Long system message"))
           (buf (harness-ui-chat-test-open sid))
           (content (make-string 800000 ?s))
           (limit harness-chat--message-limit))
      (with-current-buffer buf
        (harness-chat--apply-update
         (list :sessionUpdate "_harness/node"
               :node (list :id "n-prompt" :kind "user" :content content
                           :meta (list :from (harness-sender-system "supervisor")))))
        (should (harness-ui-chat-test-find buf "System · supervisor"))
        (should (< (buffer-size) (+ limit 2000)))
        (should (harness-ui-chat-test-find buf (format "show more (%d more chars)" (- 800000 limit))))))))

(ert-deftest harness-ui-chat-streaming-a-long-message-stays-a-page ()
  "A long message streaming in is drawn a page at a time, not whole.
The chunks are appended to the buffer as they come and rendered
shortly after; appended whole, a message of hundreds of KB would be in
the buffer -- and laid out on every redisplay -- until then."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Streaming long message"))
           (buf (harness-ui-chat-test-open sid))
           (limit harness-chat--message-limit)
           (chunk (make-string 5000 ?z)))
      (with-current-buffer buf
        (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                          :node (list :id "n-stream" :kind "assistant" :content "")))
        (dotimes (_ 10)
          (harness-chat--apply-update (harness-ui-chat-test-chunk "n-stream" chunk)))
        (should (= (* 10 5000) (length (harness-chat-block-content (gethash "n-stream" harness-chat--blocks)))))
        (should (< (buffer-size) (+ limit 2000)))))))

;;;; The activity line

(defun harness-ui-chat-test-activity-line (buf)
  "Return the activity line BUF shows, or nil."
  (with-current-buffer buf
    (let ((ov harness-chat--activity-overlay))
      (and ov (overlay-buffer ov) (overlay-get ov 'before-string)))))

(defun harness-ui-chat-test-set-status (buf status)
  "Make BUF's session STATUS, as a `_harness/session' push would."
  (with-current-buffer buf
    (let ((session (plist-put (copy-sequence (harness-chat--session)) :status status)))
      (harness-ui-cache-session session)
      (harness-chat--apply-update (list :sessionUpdate "_harness/session" :session session)))))

(ert-deftest harness-ui-chat-activity-line-says-what-runs ()
  "While the session runs, the end of the transcript says what it does."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (cl-flet ((activity (&rest plist)
                  (with-current-buffer buf
                    (harness-chat--apply-update (list :sessionUpdate "_harness/activity" :activity plist))))
                (line () (harness-ui-chat-test-activity-line buf))
                (shows (regexp) (string-match-p regexp (or (harness-ui-chat-test-activity-line buf) ""))))
        (should-not (line))
        ;; Running before anything is known: still a live line.
        (harness-ui-chat-test-set-status buf "running")
        (should (shows "Working"))
        (activity :phase "waiting" :since (float-time))
        (should (shows "Waiting for the model"))
        (activity :phase "thinking" :since (- (float-time) 75))
        (should (shows "Thinking.* 1m15s"))
        ;; Tools go by their labels.
        (activity :phase "tool-input" :tool "bash" :chars 4200 :since (float-time))
        (should (shows "Preparing Bash.*4\\.2k chars"))
        (with-current-buffer buf
          (should (string-match-p "running.* preparing Bash" (harness-chat--mode-line))))
        ;; One the harness does not know goes by its name.
        (activity :phase "tool-input" :tool "write_file" :chars 4200 :since (float-time))
        (should (shows "Preparing write_file.*4\\.2k chars"))
        (activity :phase "tool" :tool "bash" :title "Bash: npm test" :checking t :since (float-time))
        (should (shows "Checking permission for Bash: npm test"))
        (activity :phase "tool" :tool "bash" :title "Bash: npm test" :detail "PASS b.test" :since (float-time))
        (should (shows "Running Bash: npm test.*PASS b\\.test"))
        (with-current-buffer buf
          (should (string-match-p "running.* Bash" (harness-chat--mode-line))))
        (activity :phase "tool" :tool "bash" :title "Bash: npm test" :count 3 :since (float-time))
        (should (shows "Running Bash: npm test and 2 more"))
        ;; A title from before tools had labels names the tool by its label too.
        (activity :phase "tool" :tool "bash" :title "bash npm test" :since (float-time))
        (should (shows "Running Bash: npm test"))
        ;; One line and a blank one, under the last block and above the
        ;; box, wherever blocks and the tail are drawn.
        (should (string-match-p "\\`[^\n]+\n\n\\'" (line)))
        ;; The line has a background of its own.  Both lines are drawn
        ;; over the default face, to the window's edge, so the box's
        ;; background, which an overlay string takes, shows in neither.
        (let* ((line (line))
               (ground '(:inherit default :extend t))
               (end (1- (length line))))
          (dotimes (pos end)
            (let ((faces (ensure-list (get-text-property pos 'face line))))
              (should (memq 'harness-chat-activity-face faces))
              (should (equal ground (car (last faces))))))
          (should (equal ground (get-text-property end 'face line))))
        (should (face-attribute 'harness-chat-activity-face :extend))
        (should-not (equal (face-attribute 'harness-chat-activity-face :background)
                           (face-attribute 'harness-compose-face :background)))
        (with-current-buffer buf
          (cl-flet ((at-end () (= (overlay-start harness-chat--activity-overlay)
                                  (marker-position harness-chat--transcript-end))))
            (should (at-end))
            (harness-chat--apply-update (list :sessionUpdate "_harness/node"
                                              :node (list :id "n-a" :kind "assistant" :content "Done")))
            (should (at-end))
            (harness-chat--render-tail)
            (should (at-end))
            (should (< (overlay-start harness-chat--activity-overlay) harness-compose-start))
            ;; The spinner turns without the buffer changing.
            (let ((before (line))
                  (tick (buffer-modified-tick)))
              (harness-chat--spinner-tick)
              (harness-chat--refresh-activity)
              (should-not (equal before (line)))
              (should (= tick (buffer-modified-tick))))))
        ;; Blocked: the panel says it; idle: nothing, and the turn is forgotten.
        (harness-ui-chat-test-set-status buf "blocked")
        (should-not (line))
        (harness-ui-chat-test-set-status buf "idle")
        (should-not (line))
        (with-current-buffer buf (should-not harness-chat--activity))))))

(ert-deftest harness-ui-chat-fake-cli-shows-every-gap ()
  "A turn through the real provider, against the fake CLI, never looks stalled.
The fake stops in each gap a real turn has: before the model answers,
while it writes a tool input, while it thinks (the CLI sends no
thinking text), and in the middle of its text.  In each the buffer says
what is going on, and text streamed so far is in the transcript before
the message is complete."
  (harness-ui-chat-test-with
    (let* ((gate (expand-file-name "gate" (harness-test-temp-dir)))
           (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_GATE=" gate) process-environment)))
      (harness-test-load-module 'provider-claude)
      (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
      (harness-define-tool "echo" :label "Echo" :description "echo" :kind 'read
                           :handler (lambda (input _ctx) (format "echo: %s" (plist-get input :text))))
      (unwind-protect
          (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                               :model "claude:claude-fable-5-1" :name "Gaps")
                                 :id))
                 (buf (harness-ui-chat-test-open sid)))
            (cl-flet ((open (n) (write-region "" nil (format "%s.%d" gate n) nil 'silent))
                      (wait-line (regexp what)
                        (harness-test-wait (lambda () (string-match-p regexp (or (harness-ui-chat-test-activity-line buf) "")))
                                           10 what)))
              (harness-ui-chat-test-type buf "slow-start slow-tool slow-think slow-text")
              (with-current-buffer buf (harness-chat-send))
              (wait-line "Waiting for the model" "waiting before the first event")
              (open 1)
              (wait-line "Preparing Echo.* 8 chars" "the tool input streaming")
              (open 2)
              ;; The call ran, and the model thinks without a word.
              (wait-line "Thinking" "thinking")
              (should (harness-ui-chat-test-blocks buf "tool-call"))
              (should-not (harness-ui-chat-test-blocks buf "thinking"))
              (open 3)
              ;; Half the reply is on screen while the turn still runs.
              (harness-test-wait (lambda () (harness-ui-chat-test-blocks buf "assistant")) 10 "the first delta")
              (let ((block (car (harness-ui-chat-test-blocks buf "assistant"))))
                (should (equal "Hel" (harness-chat-block-content block)))
                (should (harness-ui-chat-test-find buf "Hel")))
              (should (equal "running" (plist-get (harness-ui-session sid) :status)))
              (should (string-match-p "Writing" (harness-ui-chat-test-activity-line buf)))
              (should (= 0 (harness-ui-chat-test-turns-ended sid)))
              (open 4)
              (harness-test-wait (lambda () (= 1 (harness-ui-chat-test-turns-ended sid))) 10 "the turn to end")
              (harness-test-wait (lambda () (not (harness-ui-chat-test-activity-line buf))) 5 "the line to go")
              (should (equal "Hello" (harness-chat-block-content (car (harness-ui-chat-test-blocks buf "assistant")))))))
        (harness-provider-claude-close-all)))))

(defvar harness-brave-api-key)
(defvar harness-websearch-provider)
(defvar harness-websearch-builtin)
(defvar harness-tools-web--auth-source-seen)

(ert-deftest harness-ui-chat-cli-web-search-shows-as-web-search ()
  "Without a Brave key, Claude Code searches itself, and the chat shows a web_search call.
The call and its result appear as any tool call's would."
  (harness-ui-chat-test-with
    (harness-test-load-module 'provider-claude)
    (harness-test-load-module 'tools-web)
    (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
    (let ((process-environment (cons "BRAVE_API_KEY" process-environment))
          (auth-sources nil)
          (harness-brave-api-key nil)
          (harness-websearch-provider 'brave)
          (harness-websearch-builtin 'fallback)
          (harness-tools-web--auth-source-seen nil))
      (unwind-protect
          (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                               :model "claude:claude-fable-5-1" :name "Search")
                                 :id))
                 (buf (harness-ui-chat-test-open sid)))
            (harness-ui-chat-test-prompt buf "search the web")
            (let ((calls (harness-ui-chat-test-blocks buf "tool-call")))
              (should (= 1 (length calls)))
              ;; Named by web_search's label, as the harness's own search would be.
              (should (equal "Web search: emacs" (plist-get (harness-chat-block-node (car calls)) :title)))
              (should (harness-ui-chat-test-find buf "Web search emacs")))
            (should (harness-ui-chat-test-find buf "Web search results for query"))
            (should (harness-ui-chat-test-find buf "hello"))
            (when (getenv "HARNESS_SHOW_CHAT")
              (message "chat buffer:\n%s" (with-current-buffer buf (buffer-substring-no-properties
                                                                    (point-min) (point-max))))))
        (harness-provider-claude-close-all)))))

;;;; Scrolling

(ert-deftest harness-ui-chat-auto-scroll-predicate ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (w (selected-window)))
      (dotimes (i 80) (harness-call 'session/hint sid (format "line %d" i)))
      (harness-test-wait (lambda () (with-current-buffer buf (= 80 (length harness-chat--order)))) 5 "hints rendered")
      (set-window-buffer w buf)
      (with-current-buffer buf
        (set-window-point w harness-compose-end)
        (should (harness-chat--at-bottom-p w))
        (set-window-start w (point-min))
        (set-window-point w (point-min))
        (should-not (harness-chat--at-bottom-p w))
        ;; New content while scrolled up: no scrolling, but a notice.
        (should-not harness-chat--unseen)
        (harness-chat--append-local-block "hint" "later")
        (should harness-chat--unseen)
        (should (= (window-start w) (point-min)))
        (should (string-match-p "new messages" (harness-chat--header)))
        (harness-chat-scroll-to-bottom)
        (should-not harness-chat--unseen)
        (should (harness-chat--at-bottom-p w))
        ;; Redraws remember whether the window followed the bottom.
        (set-window-start w (point-min))
        (set-window-point w (point-min))
        (harness-chat--append-local-block "hint" "again")
        (should harness-chat--unseen)))))

(ert-deftest harness-ui-chat-scrolls-by-pixels-wiring ()
  "The wheel, C-v and M-v scroll the chat by pixels, C-M-v too.
An image is one line however tall, so scrolling by lines jumped past
it or stuck on it.  The wheel goes through `mwheel-scroll's scroll
functions, the keys through the remapped scroll commands; point's line
is left partly shown while the window is scrolled partway into a line."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window)))
      (set-window-buffer window buf)
      (with-current-buffer buf
        (should (local-variable-p 'mwheel-scroll-up-function))
        (should (eq mwheel-scroll-up-function #'harness-chat-scroll-forward))
        (should (eq mwheel-scroll-down-function #'harness-chat-scroll-back))
        (should (eq (key-binding (kbd "C-v")) #'harness-chat-scroll-up))
        (should (eq (key-binding [next]) #'harness-chat-scroll-up))
        (should (eq (key-binding (kbd "M-v")) #'harness-chat-scroll-down))
        (should (eq make-cursor-line-fully-visible #'harness-chat--cursor-line-fully-visible))
        (cl-letf (((symbol-function 'window-vscroll) (lambda (&rest _) 0)))
          (should (harness-chat--cursor-line-fully-visible window)))
        (cl-letf (((symbol-function 'window-vscroll) (lambda (&rest _) 40)))
          (should-not (harness-chat--cursor-line-fully-visible window))))
      ;; Other buffers keep their own.
      (with-temp-buffer
        (should-not (eq mwheel-scroll-up-function #'harness-chat-scroll-forward))
        (should-not (eq make-cursor-line-fully-visible #'harness-chat--cursor-line-fully-visible)))
      ;; C-M-v from another window runs the chat's own C-v there.
      (let ((other (split-window window nil 'below))
            (called nil))
        (unwind-protect
            (progn
              (set-window-buffer other buf)
              (with-temp-buffer
                (set-window-buffer window (current-buffer))
                (select-window window)
                (cl-letf (((symbol-function 'harness-chat-scroll-up)
                           (lambda (&rest args) (setq called (cons (window-buffer) args)))))
                  (scroll-other-window 3)))
              (should (equal called (list buf 3))))
          (delete-window other))))))

(ert-deftest harness-ui-chat-scrolls-by-pixels ()
  "The chat scrolls a line's height in pixels for each line asked for.
At either end, once nothing moves, it signals as `scroll-up' does,
which `mwheel-scroll' needs to stop, and C-v moves point there when
`scroll-error-top-bottom' says so.  A terminal scrolls by lines."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window))
           (vscroll 0) (steps nil))
      (set-window-buffer window buf)
      (with-current-buffer buf
        ;; A window 100 pixels high, lines of 18, and 1000 pixels to scroll.
        (cl-letf (((symbol-function 'display-graphic-p) #'always)
                  ((symbol-function 'default-line-height) (lambda () 18))
                  ((symbol-function 'window-text-height) (lambda (&rest _) 100))
                  ((symbol-function 'window-vscroll) (lambda (&rest _) vscroll))
                  ((symbol-function 'harness-chat--snap-start) #'ignore)
                  ((symbol-function 'harness-chat--point-into-view) #'ignore)
                  ((symbol-function 'harness-chat--hold-tall-start) #'ignore)
                  ((symbol-function 'harness-chat--scroll-pixels)
                   (lambda (pixels forward)
                     (push (if forward pixels (- pixels)) steps)
                     (setq vscroll (max 0 (min 1000 (if forward (+ vscroll pixels)
                                                      (- vscroll pixels))))))))
          ;; A wheel notch of three lines goes three lines' height.
          (harness-chat-scroll-forward 3)
          (should (equal steps '(54)))
          ;; More than the window, all of it.
          (setq steps nil)
          (harness-chat-scroll-forward 10)
          (should (equal steps '(180)))
          ;; Back; a negative count goes the other way; zero stays.
          (setq steps nil)
          (harness-chat-scroll-back 2)
          (harness-chat-scroll-forward -1)
          (harness-chat-scroll-forward 0)
          (should (equal (reverse steps) '(-36 -18)))
          ;; No count: the window less `next-screen-context-lines' lines.
          ;; C-v and M-v read their argument as `scroll-up-command' does.
          (setq steps nil)
          (let ((next-screen-context-lines 2))
            (harness-chat-scroll-forward)
            (harness-chat-scroll-up 2)
            (harness-chat-scroll-down '-)
            (harness-chat-scroll-up '(4))
            (harness-chat-scroll-down 1))
          (should (equal (reverse steps) '(64 36 64 72 -18)))
          ;; The end: what is left, then nothing moves and it says so.
          (setq vscroll 990)
          (harness-chat-scroll-forward 1)
          (should (= vscroll 1000))
          (should-error (harness-chat-scroll-forward 1) :type 'end-of-buffer)
          (let ((scroll-error-top-bottom nil))
            (goto-char (point-min))
            (should-error (harness-chat-scroll-up) :type 'end-of-buffer)
            (should (= (point) (point-min))))
          ;; C-v there moves point instead: ARG lines, or to the end.
          (let ((scroll-error-top-bottom t)
                (second (save-excursion (goto-char (point-min)) (forward-line 1) (point))))
            (should (< second (point-max)))
            (harness-chat-scroll-up 1)
            (should (= (point) second))
            (harness-chat-scroll-up)
            (should (= (point) (point-max)))
            (should-error (harness-chat-scroll-up) :type 'end-of-buffer))
          ;; The start likewise.
          (setq vscroll 0)
          (should-error (harness-chat-scroll-back 1) :type 'beginning-of-buffer)
          (let ((scroll-error-top-bottom t))
            (harness-chat-scroll-down)
            (should (= (point) (point-min)))))
        ;; A terminal draws no images: by lines, as ever.
        (let ((calls nil))
          (cl-letf (((symbol-function 'display-graphic-p) #'ignore)
                    ((symbol-function 'scroll-up) (lambda (&optional n) (push (list 'up n) calls)))
                    ((symbol-function 'scroll-down) (lambda (&optional n) (push (list 'down n) calls))))
            (harness-chat-scroll-forward 3)
            (harness-chat-scroll-back nil)
            (harness-chat-scroll-up 2))
          (should (equal (reverse calls) '((up 3) (down nil) (up 2)))))))))

(ert-deftest harness-ui-chat-scroll-snaps-to-whole-lines-of-text ()
  "Scrolling by pixels leaves text whole at the top, an image partway.
A line of text scrolled partway goes back to its top, or on to the next
line when more than half of it went; an image, two lines high or more,
stays where the scroll left it."
  (harness-ui-chat-test-with
    (with-temp-buffer
      (insert "line one\nline two\n")
      (let* ((next (save-excursion (goto-char (point-min)) (forward-line 1) (point)))
             (after next) (start 1) (vscroll 0) (height 18))
        (cl-letf (((symbol-function 'default-line-height) (lambda () 18))
                  ((symbol-function 'window-vscroll) (lambda (&rest _) vscroll))
                  ((symbol-function 'set-window-vscroll) (lambda (_w v &rest _) (setq vscroll v)))
                  ((symbol-function 'window-start) (lambda (&rest _) start))
                  ((symbol-function 'set-window-start) (lambda (_w pos &rest _) (setq start pos)))
                  ((symbol-function 'harness-chat--line-after) (lambda (_pos) after))
                  ((symbol-function 'harness-chat--line-height) (lambda (_pos) height)))
          ;; A third into a line of text: back to its top, either way.
          (goto-char (point-min))
          (dolist (forward '(t nil))
            (setq start 1 vscroll 6)
            (harness-chat--snap-start forward)
            (should (equal (list start vscroll) '(1 0))))
          ;; Two thirds, going forward: on to the next line, point with it.
          (setq vscroll 12)
          (harness-chat--snap-start t)
          (should (equal (list start vscroll) (list next 0)))
          (should (= (point) next))
          ;; Going back, the line shows whole instead.
          (setq start 1 vscroll 12)
          (harness-chat--snap-start nil)
          (should (equal (list start vscroll) '(1 0)))
          ;; An image stays partway, either way.
          (setq height 400)
          (dolist (forward '(t nil))
            (setq vscroll 120)
            (harness-chat--snap-start forward)
            (should (equal (list start vscroll) '(1 120))))
          ;; The last line has none after it: back to its top.
          (setq height 18 after nil vscroll 12)
          (harness-chat--snap-start t)
          (should (equal (list start vscroll) '(1 0))))))))

(ert-deftest harness-ui-chat-scroll-walks-screen-lines ()
  "Scrolling by pixels moves the window's start a screen line at a time.
Its vscroll takes up the rest, so a tall image goes by a pixel at a
time; going back, the line above is measured whole, which the precision
scroll function overshot.  It stops at the first line, and forward with
the last line of text at the top."
  (harness-ui-chat-test-with
    (with-temp-buffer
      (insert "abcdefghij")
      ;; Screen lines start at 1 to 6, the third an image 400 high; the
      ;; one after the sixth is the empty end of the buffer.
      (let ((heights '((1 . 18) (2 . 18) (3 . 400) (4 . 18) (5 . 18) (6 . 18)))
            (start 1) (vscroll 0) (forced nil))
        (cl-letf (((symbol-function 'window-start) (lambda (&rest _) start))
                  ((symbol-function 'window-vscroll) (lambda (&rest _) vscroll))
                  ((symbol-function 'set-window-start)
                   (lambda (_w pos &optional noforce) (setq start pos forced (not noforce))))
                  ((symbol-function 'set-window-vscroll) (lambda (_w v &rest _) (setq vscroll v)))
                  ((symbol-function 'harness-chat--line-height) (lambda (pos) (cdr (assq pos heights))))
                  ((symbol-function 'harness-chat--line-after)
                   (lambda (pos) (if (< pos 6) (1+ pos) (point-max))))
                  ((symbol-function 'harness-chat--line-before) (lambda (pos) (and (> pos 1) (1- pos)))))
          (cl-flet ((scroll (pixels forward)
                      (harness-chat--scroll-pixels pixels forward)
                      (list start vscroll)))
            ;; Two lines of text, then partway into the image, its start
            ;; unforced so that redisplay keeps the vscroll.
            (should (equal (scroll 54 t) '(3 18)))
            (should-not forced)
            ;; The rest of the image, then a line.
            (should (equal (scroll 400 t) '(5 0)))
            (should forced)
            ;; Back a line and into the image from its bottom.
            (should (equal (scroll 30 nil) '(3 388)))
            ;; Far forward: the last line stays at the top.
            (should (equal (scroll 1000 t) '(6 0)))
            (should (equal (scroll 18 t) '(6 0)))
            ;; Far back: the first line.
            (should (equal (scroll 1000 nil) '(1 0)))
            ;; From the line before the image scrolled out of view
            ;; (`harness-chat--hold-tall-start'): into the image, or
            ;; back into that line.
            (setq start 2 vscroll 18)
            (should (equal (scroll 18 t) '(3 18)))
            (setq start 2 vscroll 18)
            (should (equal (scroll 10 nil) '(2 8)))))))))

(ert-deftest harness-ui-chat-scroll-holds-tall-start ()
  "A line taller than the window, shown from its top with point on it, holds.
Redisplay recentered on point there once the window's start was no
longer forced, so the window starts at the line before instead,
scrolled out of view: it leaves a window with a vscroll alone."
  (harness-ui-chat-test-with
    (with-temp-buffer
      (insert "abcdefghij")
      ;; Screen lines start at 1 to 4, the third an image 400 high, in
      ;; a window 187 high.
      (let ((heights (copy-tree '((1 . 18) (2 . 18) (3 . 400) (4 . 18))))
            start vscroll forced)
        (cl-letf (((symbol-function 'window-start) (lambda (&rest _) start))
                  ((symbol-function 'window-vscroll) (lambda (&rest _) vscroll))
                  ((symbol-function 'window-text-height) (lambda (&rest _) 187))
                  ((symbol-function 'set-window-start)
                   (lambda (_w pos &optional noforce) (setq start pos forced (not noforce))))
                  ((symbol-function 'set-window-vscroll) (lambda (_w v &rest _) (setq vscroll v)))
                  ((symbol-function 'harness-chat--line-height) (lambda (pos) (cdr (assq pos heights))))
                  ((symbol-function 'harness-chat--line-before) (lambda (pos) (and (> pos 1) (1- pos)))))
          (cl-flet ((hold (from vs pt)
                      (setq start from vscroll vs forced 'unset)
                      (goto-char pt)
                      (harness-chat--hold-tall-start)
                      (list start vscroll forced (point))))
            ;; The image at the top, point on it: the line before, out of
            ;; view, its start not forced; point stays.
            (should (equal (hold 3 0 3) '(2 18 nil 3)))
            ;; Scrolled into the image already, point elsewhere, a line
            ;; that fits, or nothing before it: left alone.
            (should (equal (hold 3 40 3) '(3 40 unset 3)))
            (should (equal (hold 3 0 4) '(3 0 unset 4)))
            (should (equal (hold 2 0 2) '(2 0 unset 2)))
            (setf (alist-get 1 heights) 400)
            (should (equal (hold 1 0 1) '(1 0 unset 1)))))))))

(ert-deftest harness-ui-chat-scroll-shown-whole ()
  "A line shows whole when all of it is in the window.
Scrolled partway into a tall line, it also has to end above the bottom
edge: a line ending on it had redisplay recenter on point, keeping the
vscroll, which cut through the text at the top."
  (harness-ui-chat-test-with
    (let ((vscroll 0) (shown nil))
      ;; A header line of 17 over 527 of text: the edge is at 544.
      (cl-letf (((symbol-function 'pos-visible-in-window-p) (lambda (&rest _) shown))
                ((symbol-function 'window-vscroll) (lambda (&rest _) vscroll))
                ((symbol-function 'window-text-height) (lambda (&rest _) 527))
                ((symbol-function 'window-header-line-height) (lambda (&rest _) 17))
                ((symbol-function 'window-tab-line-height) (lambda (&rest _) 0))
                ((symbol-function 'harness-chat--line-height) (lambda (_pos) 17)))
        (cl-flet ((whole (vis) (setq shown vis) (and (harness-chat--shown-whole-p 1) t)))
          (should (whole '(8 510)))
          (should (whole '(8 527)))
          (should-not (whole '(0 536 0 9 8 8)))
          (should-not (whole nil))
          (setq vscroll 145)
          (should (whole '(8 510)))
          (should-not (whole '(8 527)))
          (should-not (whole '(0 536 0 9 8 8))))))))

(ert-deftest harness-ui-chat-scroll-keeps-point-in-view ()
  "Scrolling leaves point on a screen line the window shows whole.
Out of view, or partly, point would have redisplay recenter the window
and undo the scroll.  Below, it goes up to the last line shown whole;
above, down to the first; on a tall line scrolled partway at the top it
stays only when no line shows whole."
  (harness-ui-chat-test-with
    (with-temp-buffer
      (insert (make-string 30 ?x))
      ;; Screen lines start at 1, 3, 5...; the window starts at START,
      ;; shows the lines in WHOLE whole and BOTTOM's in part.
      (let ((start 5) (whole '(5 7 9 11)) (bottom 13))
        (cl-labels ((line-of (pos) (if (cl-oddp pos) pos (1- pos))))
          (cl-letf (((symbol-function 'window-start) (lambda (&rest _) start))
                    ((symbol-function 'harness-chat--line-start) #'line-of)
                    ((symbol-function 'harness-chat--line-after) (lambda (pos) (+ (line-of pos) 2)))
                    ((symbol-function 'harness-chat--line-before)
                     (lambda (pos) (and (> (line-of pos) 1) (- (line-of pos) 2))))
                    ((symbol-function 'harness-chat--shown-whole-p) (lambda (pos) (memq (line-of pos) whole)))
                    ((symbol-function 'harness-chat--bottom-line) (lambda () bottom)))
            (cl-flet ((from (pos) (goto-char pos) (harness-chat--point-into-view) (point)))
              ;; Shown whole: it stays.
              (should (= (from 8) 8))
              ;; Partly out at the bottom, or far below: the last whole line.
              (should (= (from 14) 11))
              (should (= (from 25) 11))
              ;; Above the window: its first line.
              (should (= (from 2) 5))
              ;; Scrolled into a tall line at the top: the line after it,
              ;; from above or from the tall line itself.
              (setq whole '(7 9 11))
              (should (= (from 2) 7))
              (should (= (from 6) 7))
              ;; The tall line fills the window: point stays on it.
              (setq whole nil)
              (should (= (from 25) 5))
              (should (= (from 2) 5)))))))))

;;;; Quoting to reply

(defun harness-ui-chat-test-quote (buf from &optional to)
  "Type C-c > in BUF, point at FROM, or the region from FROM to TO.
The key goes through the command loop, BUF in the selected window.
Return (TEXT . UNDER): what the box then holds, and whether the
window's point ends at the end of the box, under the quote."
  (with-current-buffer buf
    (save-window-excursion
      (set-window-buffer nil buf)
      (goto-char (or to from))
      (when to
        (setq-local transient-mark-mode t)
        (push-mark from t t))
      (execute-kbd-macro (kbd "C-c >"))
      (cons (harness-compose-text) (= (window-point) harness-compose-end)))))

(ert-deftest harness-ui-chat-quote-reply ()
  "C-c > quotes an agent's message in the box, as Markdown, to reply to it.
Without a region the response or plan point is on, whole, as written;
elsewhere -- the user's message, the box -- the one above point, so
from the box the last.  A region quotes what it selects as it shows,
read back into Markdown, and nothing a fold hides.  Point ends under
the quote, ready for the reply."
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session)))
      (harness-call 'session/append sid '(:kind user :content "fix the parser"))
      (harness-call 'session/append sid '(:kind thinking :content "The parser drops the last token."))
      (harness-call 'session/append sid '(:kind assistant :content "Fixed **the parser**: it was `parse-it`."))
      (harness-call 'session/append sid '(:kind user :content "and the tests?"))
      (harness-call 'session/append sid (list :kind 'plan :title "Tests" :content "1. Add a test\n2. Run it"))
      (harness-call 'session/append sid '(:kind assistant :content "Run them:\n\n```sh\nmake test\n```\n\nThey pass."))
      (let ((buf (harness-ui-chat-test-open sid))
            (fixed "> Fixed **the parser**: it was `parse-it`.\n\n"))
        (with-current-buffer buf
          (should (eq 'harness-compose-quote-reply (key-binding (kbd "C-c >"))))
          ;; From the box: the last message.
          (should (equal '("> Run them:\n>\n> ```sh\n> make test\n> ```\n>\n> They pass.\n\n" . t)
                         (harness-ui-chat-test-quote buf harness-compose-end)))
          (harness-compose-set "")
          ;; On a response: that one.
          (should (equal (cons fixed t) (harness-ui-chat-test-quote buf (harness-ui-chat-test-find buf "Fixed"))))
          ;; On the user's message after it: it again, after what the box holds.
          (should (equal (cons (concat fixed fixed) t)
                         (harness-ui-chat-test-quote buf (harness-ui-chat-test-find buf "and the tests"))))
          (harness-compose-set "")
          ;; On the plan: the plan.
          (should (equal '("> 1. Add a test\n> 2. Run it\n\n" . t)
                         (harness-ui-chat-test-quote buf (harness-ui-chat-test-find buf "Add a test"))))
          (harness-compose-set "")
          ;; A region: what it selects, the code block fenced again.
          (should (equal '("> Run them:\n>\n> ```sh\n> make test\n> ```\n\n" . t)
                         (harness-ui-chat-test-quote buf (- (harness-ui-chat-test-find buf "Run them:") 9)
                                                     (harness-ui-chat-test-find buf "make test"))))
          (should-not (region-active-p))
          (harness-compose-set "")
          ;; Over the folded thinking: what shows of it, its header, alone.
          (let ((text (car (harness-ui-chat-test-quote buf (- (harness-ui-chat-test-find buf "fix the parser") 14)
                                                       (harness-ui-chat-test-find buf "parse-it")))))
            (should (string-prefix-p "> fix the parser\n" text))
            (should (string-match-p "^> .*thinking (6 words)$" text))
            (should (string-match-p "^> Fixed the parser: it was `parse-it`$" text))
            (should-not (string-match-p "drops the last token" text))))))))

;;;; Queue

(ert-deftest harness-ui-chat-queue-add-edit-remove ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (harness-ui-chat-test-type buf "later")
      (with-current-buffer buf (harness-chat-queue))
      (harness-test-wait (lambda () (with-current-buffer buf (= 1 (length harness-chat--queue)))) 5 "queued")
      (with-current-buffer buf
        (should (equal "" (harness-compose-text)))
        (should (harness-ui-chat-test-find buf "queued for the next turn (1)"))
        (let ((pos (harness-ui-chat-test-find buf "later")))
          (should (harness-ui-chat-test-face-at (1- pos) 'harness-queue-face)))
        ;; Edit: the text comes back into the compose box; sending removes the item.
        (let ((qid (plist-get (car harness-chat--queue) :id)))
          (harness-chat-edit-queued qid)
          (should (equal "later" (harness-compose-text)))
          (should (equal qid harness-chat--editing))
          (harness-ui-chat-test-type buf " please")))
      (harness-ui-chat-test-prompt buf "")
      (with-current-buffer buf
        (should (null harness-chat--queue))
        (should (null (plist-get (harness-call 'session/get sid) :queue)))
        (should (harness-ui-chat-test-find buf "later please"))
        (should (equal "user" (harness-chat-block-kind (gethash (car (last harness-chat--order)) harness-chat--blocks)))))
      ;; Remove through the [×] button's command.
      (harness-ui-chat-test-type buf "drop me")
      (with-current-buffer buf (harness-chat-queue))
      (harness-test-wait (lambda () (with-current-buffer buf (= 1 (length harness-chat--queue)))) 5 "queued again")
      (with-current-buffer buf
        (harness-chat-remove-queued (plist-get (car harness-chat--queue) :id)))
      (harness-test-wait (lambda () (with-current-buffer buf (null harness-chat--queue))) 5 "removed")
      (should-not (harness-ui-chat-test-find buf "drop me")))))

(defvar harness-provider-demo-script-override)

(ert-deftest harness-ui-chat-queue-while-running ()
  "A message queued while the agent runs waits in the queue area, then is a turn of its own.
It is never added to the running turn."
  (harness-ui-chat-test-with
    (let* ((gate (harness-make-promise))
           (harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "hold" :input (:n 1))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn)))
           (sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (users (lambda () (mapcar (lambda (n) (plist-get n :content))
                                     (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                                       (harness-call 'session/nodes sid))))))
      ;; The turn waits in this tool until the test lets it go.
      (harness-define-tool "hold" :label "Hold" :description "hold" :kind 'read
                           :handler (lambda (_input _ctx) (harness-then gate (lambda (_) "held"))))
      (harness-ui-chat-test-type buf "go")
      (with-current-buffer buf (harness-chat-send))
      (harness-test-wait (lambda () (memq 'tool-call (mapcar (lambda (n) (plist-get n :kind))
                                                             (harness-call 'session/nodes sid))))
                         5 "the turn in its tool")
      (harness-ui-chat-test-type buf "for later")
      (with-current-buffer buf (harness-chat-queue))
      (harness-test-wait (lambda () (with-current-buffer buf (= 1 (length harness-chat--queue)))) 5 "queued")
      (should (harness-ui-chat-test-find buf "queued for the next turn (1)"))
      (should (harness-agent-running-p sid))
      (should (equal '("go") (funcall users)))
      (harness-resolve gate t)
      (harness-test-wait (lambda () (= 2 (harness-ui-chat-test-turns-ended sid))) 10 "both turns")
      (harness-test-wait (lambda () (with-current-buffer buf (null harness-chat--queue))) 5 "the queue area emptied")
      (should (equal '("go" "for later") (funcall users)))
      (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes sid)))
      (should-not (harness-ui-chat-test-find buf "queued for the next turn"))
      ;; Sending an empty queue starts nothing.
      (with-current-buffer buf (harness-chat-send-queue))
      (accept-process-output nil 0.2)
      (should-not (harness-agent-running-p sid))
      (should (= 2 (harness-ui-chat-test-turns-ended sid)))
      (should (equal '("go" "for later") (funcall users))))))

;;;; Pending panel

(ert-deftest harness-ui-chat-permission-panel ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (respond (lambda (r) (push r answers)))
           (params (list :sessionId sid
                         :toolCall (list :toolCallId "c1" :title "Bash: ls -la" :kind "execute"
                                         :rawInput '(:command "ls -la"))
                         :options harness-acp--permission-options
                         :_harness (list :pendingId "p1" :tool "bash" :paths '("/tmp") :reason "exec asks"))))
      ;; A request for another session is not ours.
      (should-not (harness-chat--on-permission (plist-put (copy-sequence params) :sessionId "other") respond))
      (should (harness-chat--on-permission params respond))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "Permission"))
        ;; The tool's label, set apart from what the call is about by its face.
        (let ((pos (harness-ui-chat-test-find buf "Bash ls -la")))
          (should pos)
          (should (harness-ui-chat-test-face-at (- pos (length "Bash ls -la")) 'harness-tool-title-face))
          (should (harness-ui-chat-test-face-at (1- pos) 'harness-tool-subject-face)))
        (should (harness-ui-chat-test-find buf "kind: execute"))
        (should (harness-ui-chat-test-find buf "/tmp"))
        (should (harness-ui-chat-test-find buf "exec asks"))
        (let ((pos (harness-ui-chat-test-find buf "[Allow]")))
          (should (harness-ui-chat-test-face-at (1- pos) 'harness-ui-panel-face))
          (goto-char (1- pos))
          (harness-chat-push))
        (should (equal '((:outcome (:outcome "selected" :optionId "allow-once"))) answers))
        (should (null harness-chat--pending))
        (should-not (harness-ui-chat-test-find buf "Permission"))
        ;; Keyboard answers: `s' on the panel, C-c C-n from anywhere.
        (harness-chat--on-permission (plist-put (copy-sequence params) :_harness (list :pendingId "p2" :tool "bash")) respond)
        (goto-char (harness-ui-chat-test-find buf "Permission"))
        (call-interactively (lookup-key harness-chat-panel-map (kbd "s")))
        (should (equal "allow-session" (plist-get (plist-get (car answers) :outcome) :optionId)))
        (harness-chat--on-permission (plist-put (copy-sequence params) :_harness (list :pendingId "p3" :tool "bash")) respond)
        (goto-char harness-compose-end)
        (harness-chat-deny-newest)
        (should (equal "deny-once" (plist-get (plist-get (car answers) :outcome) :optionId)))
        (should (null harness-chat--pending))))))

(ert-deftest harness-ui-chat-permission-panel-shows-a-long-command-whole ()
  "A command the panel's one line cuts short shows whole in place, and back.
TAB on the panel and its [Show all] / [Show less] button toggle it, the
command's further lines included; the panel's keys still answer it.  A
short command gets no toggle, and TAB keeps the chat's meaning there."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (first "cd ~/src/acme-api && python3 -m pip install 'httpx>=0.28' && python3 -m pytest tests/test_webhooks.py -x -q")
           (command (concat first "\nrm -rf build/ dist/"))
           (recorded nil)
           (pid nil)
           (toggle-at (lambda () (get-text-property (point) 'harness-ui-pending-input-toggle))))
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded)
                                 (harness-call 'session/pending-resolve session-id pending-id answer)
                                 answer))
      (setq pid (harness-call 'session/pending-add sid
                              (list :kind 'permission
                                    :payload (list :tool "bash" :kind 'exec
                                                   :title (concat "Bash: " (harness-first-line command 70))
                                                   :input (list :command command :timeout 600)
                                                   :options '(allow-once allow-session deny-once)))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          ;; One line, cut short, and the second line nowhere: the toggle
          ;; counts the lines it would show.
          (should (harness-ui-chat-test-find buf "command: cd ~/src/acme-api && python3 -m pip install 'httpx>=0.28' &…  timeout: 600  [Show all 2 lines] TAB\n"))
          (should-not (harness-ui-chat-test-find buf "rm -rf build/"))
          ;; TAB anywhere on the panel shows it whole, in place.
          (goto-char (harness-ui-chat-test-find buf "Permission"))
          (should (eq 'harness-ui-pending-toggle-input (key-binding (kbd "TAB"))))
          (should (eq 'harness-ui-pending-toggle-input (key-binding (kbd "<tab>"))))
          (call-interactively (key-binding (kbd "TAB")))
          (should (harness-ui-chat-test-find buf (concat "   command:  [Show less] TAB\n" first "\nrm -rf build/ dist/\n"
                                                         "   timeout: 600\n")))
          (should (harness-ui-chat-test-face-at (- (harness-ui-chat-test-find buf "rm -rf build/") 2)
                                                'harness-ui-output-face))
          (should (equal "     " (get-text-property (harness-ui-chat-test-find buf "rm -rf") 'line-prefix)))
          (should (harness-ui-pending-input-whole-p sid pid))
          ;; Point stays on the toggle, so TAB again puts it back on one line.
          (should (equal pid (funcall toggle-at)))
          (call-interactively (key-binding (kbd "TAB")))
          (should-not (harness-ui-chat-test-find buf "rm -rf build/"))
          (should (harness-ui-chat-test-find buf "[Show all 2 lines] TAB"))
          (should-not (harness-ui-pending-input-whole-p sid pid))
          (should (equal pid (funcall toggle-at)))
          ;; The button does the same.
          (goto-char (harness-ui-chat-test-find buf "[Show all"))
          (harness-chat-push)
          (should (harness-ui-chat-test-find buf "rm -rf build/ dist/\n"))
          (goto-char (harness-ui-chat-test-find buf "[Show less"))
          (harness-chat-push)
          (should-not (harness-ui-chat-test-find buf "rm -rf build/"))
          ;; Shown whole, the panel still answers with its keys.
          (call-interactively (key-binding (kbd "TAB")))
          (goto-char (harness-ui-chat-test-find buf "Permission"))
          (call-interactively (key-binding (kbd "y"))))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid pid "allow-once") (car recorded)))
        (harness-test-wait (lambda () (with-current-buffer buf (null harness-chat--pending))) 5 "the panel gone")
        ;; A command the line shows whole has no toggle, and TAB is the chat's.
        (harness-call 'session/pending-add sid
                      (list :kind 'permission
                            :payload (list :tool "bash" :kind 'exec :title "Bash: ls -la"
                                           :input '(:command "ls -la") :options '(allow-once deny-once))))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "the short one rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "command: ls -la\n"))
          (should-not (harness-ui-chat-test-find buf "[Show all"))
          (goto-char (harness-ui-chat-test-find buf "Permission"))
          (should (eq 'harness-chat-tab (key-binding (kbd "TAB"))))
          (should-error (harness-ui-pending-toggle-input) :type 'user-error))))))

(ert-deftest harness-ui-chat-directory-permission-panel ()
  "A call reaching outside the allowed directories offers the same buttons as any request."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (params (list :sessionId sid
                         :toolCall (list :toolCallId "c1" :title "Access ~/notes/" :kind "read"
                                         :rawInput '(:path "~/notes/todo.org"))
                         :options harness-acp--permission-options
                         :_harness (list :pendingId "d1" :tool "read_file" :dir "/home/u/notes/"
                                         :reason "Read file wants ~/notes/todo.org, which is outside the allowed directories"))))
      (should (harness-chat--on-permission params (lambda (r) (push r answers))))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "Access ~/notes/"))
        (should (harness-ui-chat-test-find buf "outside the allowed directories"))
        (should (harness-ui-chat-test-find buf "[Allow] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N"))
        ;; What an answer covers is in its tooltip: here, the directory.
        (should (equal "Let this call reach /home/u/notes/, this time (y)"
                       (get-text-property (1- (harness-ui-chat-test-find buf "[Allow]")) 'help-echo)))
        (should (equal "Allow /home/u/notes/ for this session (s)"
                       (get-text-property (1- (harness-ui-chat-test-find buf "[Allow for session]")) 'help-echo)))
        (goto-char (1- (harness-ui-chat-test-find buf "[Allow for session]")))
        (harness-chat-push)
        (should (equal "allow-session" (plist-get (plist-get (car answers) :outcome) :optionId)))
        (should (null harness-chat--pending))))))

(ert-deftest harness-ui-chat-directory-request-panel ()
  "An agent's own directory request offers the same buttons as any request, Allow included.
Its Allow grants the directory until the turn ends, and says so."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil)
           (all '("Allow" "Allow for session" "Always allow" "Deny" "Always deny"))
           ;; What the harness offers with an agent's own request
           ;; (`harness-perms-dir-request-options'), as with any other.
           (offered '(allow-once allow-session allow-always deny-once deny-always))
           (labels (lambda (r) (mapcar #'car (harness-chat--permission-buttons r))))
           (keys (lambda (r) (mapcar #'cadr (harness-chat--permission-buttons r)))))
      ;; Every kind of request has the same buttons, with the same keys.
      (dolist (r (list '(:kind "permission" :tool "bash")
                       '(:kind "permission" :tool "read_file" :dir "/d/")
                       '(:kind "permission" :tool "read_file" :dir "/d/" :pattern "/d/**")
                       '(:kind "permission" :tool "request_directory_access" :dir "/d/" :pattern "/d/**")
                       (list :kind "permission" :tool "request_directory_access" :dir "/d/"
                             :options offered)
                       (list :kind "permission" :tool "request_directory_access" :dir "/d/"
                             :options (harness-acp--offered-options
                                       (list :dir "/d/" :options offered)))))
        (should (equal all (funcall labels r)))
        (should (equal '("y" "s" "a" "n" "N") (funcall keys r))))
      ;; Option ids as symbols (in process), strings or a vector (from the
      ;; wire), or ACP option plists all narrow the buttons, which keep
      ;; their labels and keys.
      (dolist (options (list '(allow-session allow-always deny-once)
                             '("allow-session" "allow-always" "deny-once")
                             (vector "allow-session" "allow-always" "deny-once")
                             (harness-acp--offered-options '(:dir "/d/" :options (allow-session allow-always deny-once)))))
        (should (equal '(("Allow for session" "s" "allow-session") ("Always allow" "a" "allow-always")
                         ("Deny" "n" "deny-once"))
                       (harness-chat--permission-buttons (list :dir "/d/" :options options)))))
      ;; A pending request on the session renders with those buttons.
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded)
                                 (harness-call 'session/pending-resolve session-id pending-id answer)
                                 answer))
      (harness-call 'session/pending-add sid
                    (list :id "req" :kind 'permission
                          :payload (list :tool "request_directory_access" :kind 'meta
                                         :input '(:path "~/src/other") :dir "/home/u/src/other/"
                                         :pattern "/home/u/src/other/**"
                                         :title "Access ~/src/other/"
                                         :reason "The agent asks for access: read the API types"
                                         :options offered)))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "Access ~/src/other/"))
          (should (harness-ui-chat-test-find buf "The agent asks for access: read the API types"))
          (should (harness-ui-chat-test-find buf "[Allow] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N"))
          ;; Allow grants it until the turn ends, which its tooltip says.
          (should (equal "Allow /home/u/src/other/** until this turn ends (y)"
                         (get-text-property (1- (harness-ui-chat-test-find buf "[Allow]")) 'help-echo)))
          (should (equal "Always allow /home/u/src/other/**, in every session (a)"
                         (get-text-property (1- (harness-ui-chat-test-find buf "[Always allow]")) 'help-echo)))
          ;; Its y answers allow-once, as on any other request, and the
          ;; echo area says what that covered.
          (goto-char (harness-ui-chat-test-find buf "Permission"))
          (let ((shown nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
              (call-interactively (key-binding (kbd "y"))))
            (should (equal "Allowed /home/u/src/other/** until this turn ends" shown))))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "req" "allow-once") (car recorded)))))))

(ert-deftest harness-ui-chat-existing-pending-item-offers-buttons ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil))
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded) answer))
      (harness-call 'session/pending-add sid (list :id "pre" :kind 'permission
                                                   :payload (list :tool "bash" :title "Bash: echo" :kind 'exec
                                                                  :input '(:command "echo"))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "Bash echo"))
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow]")))
          (harness-chat-push))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "pre" "allow-always") (car recorded)))))))

(ert-deftest harness-ui-chat-permission-note-undoes-its-answer ()
  "The note of a lasting answer offers [Undo], which takes back what it recorded.
The note then shows how that went: struck through when undone, the
reason under it when the rule changed since.  Other hints have no
button."
  (harness-ui-chat-test-with
    (harness-test-load-module 'perms)
    (let ((harness-perms-rules nil)
          (shown nil))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (sym value) (set sym value))))
        (let* ((sid (harness-ui-chat-test-session))
               (buf (harness-ui-chat-test-open sid))
               (click (lambda (text)
                        (with-current-buffer buf
                          (goto-char (- (harness-ui-chat-test-find buf text) 2))
                          (setq shown nil)
                          (cl-letf (((symbol-function 'message)
                                     (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) shown)))))
                            (harness-chat-push)
                            (harness-test-wait (lambda () shown) 5 "the echo area"))))))
          (harness-call 'session/hint sid "Plan updated")
          (harness-perms--add-rule-noted sid '(:tool "bash" :behavior allow) 'always)
          (harness-perms--add-rule-noted sid '(:tool "web_fetch" :behavior deny) 'session)
          (harness-test-wait (lambda () (harness-ui-chat-test-find buf "Denying every web_fetch call for this session  [Undo]\n"))
                             5 "the notes")
          (with-current-buffer buf
            (should (harness-ui-chat-test-find buf "    Plan updated\n"))
            (let ((pos (harness-ui-chat-test-find buf "    Always allowing every bash call, in every session  [Undo]\n")))
              (should pos)
              (should (harness-ui-chat-test-face-at (- pos 3) 'button))
              (should (equal "Take back what this answer recorded; the call it answered stays allowed"
                             (get-text-property (- pos 3) 'help-echo))))
            (should (equal "Take back what this answer recorded; the call it answered stays denied"
                           (get-text-property (- (harness-ui-chat-test-find buf "for this session  [Undo]") 2)
                                              'help-echo))))
          ;; Undone: the rule is gone, the echo area says so, the note is struck through.
          (funcall click "in every session  [Undo]")
          (should (member "Undone: no longer always allowing every bash call, in every session" shown))
          (should-not harness-perms-rules)
          (harness-test-wait (lambda () (harness-ui-chat-test-find
                                         buf "    Always allowing every bash call, in every session  undone\n"))
                             5 "the note redrawn")
          (with-current-buffer buf
            (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "Always allowing"))
                                                  'harness-chat-undone-face))
            (should-not (harness-ui-chat-test-find buf "in every session  [Undo]")))
          ;; Changed since: the rule stays, and the note says why.
          (puthash sid (list '(:tool "web_fetch" :behavior allow)) harness-perms--session-rules)
          (funcall click "for this session  [Undo]")
          (should (member "Not undone: this session's rule for web_fetch has changed since, so it stays as it is" shown))
          (should (equal '((:tool "web_fetch" :behavior allow)) (gethash sid harness-perms--session-rules)))
          (harness-test-wait (lambda () (harness-ui-chat-test-find
                                         buf (concat "    Denying every web_fetch call for this session\n"
                                                     "    Not undone: this session's rule for web_fetch has changed since, so it stays as it is\n")))
                             5 "the reason")
          (should-not (harness-ui-chat-test-find buf "[Undo]")))))))

(ert-deftest harness-ui-chat-permission-pattern-is-editable ()
  "A prompt about paths shows the pattern it is answered for; e edits it, the answer carries it."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (respond (lambda (r) (push r answers)))
           (params (lambda (pid)
                     (list :sessionId sid
                           :toolCall (list :toolCallId pid :title "Access ~/notes/" :kind "read"
                                           :rawInput '(:path "~/notes/todo.org"))
                           :options harness-acp--permission-options
                           :_harness (list :pendingId pid :tool "read_file" :dir (expand-file-name "~/notes/")
                                           :pattern (expand-file-name "~/notes/**")
                                           :paths (list (expand-file-name "~/notes/todo.org"))
                                           :reason "Read file wants ~/notes/todo.org, which is outside the allowed directories")))))
      (should (harness-chat--on-permission (funcall params "d1") respond))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "pattern: ~/notes/**  [Edit] e"))
        ;; A directory prompt has the buttons of any request; their
        ;; tooltips speak of the pattern.
        (should (harness-ui-chat-test-find buf "[Allow] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N"))
        (should (equal "Always deny ~/notes/**, to every tool (N)"
                       (get-text-property (1- (harness-ui-chat-test-find buf "[Always deny]")) 'help-echo)))
        ;; e on the panel edits it, from the pattern shown; M-n offers others.
        (goto-char (harness-ui-chat-test-find buf "Permission"))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt initial _history defaults)
                     (should (equal "~/notes/**" initial))
                     (should (equal '("~/notes/todo.org" "~/notes/*.org" "~/notes/**" "~/**") defaults))
                     " ~/notes/*.org ")))
          ;; Typed, as the command loop reads it: a key of the panel's.
          (save-window-excursion
            (set-window-buffer nil buf)
            (execute-kbd-macro "e")))
        (should (equal "" (harness-compose-text)))
        (should (harness-ui-chat-test-find buf "pattern: ~/notes/*.org (edited)"))
        ;; Point stays on the panel, so its keys still answer it.
        (should (equal "d1" (get-text-property (point) 'harness-ui-pending)))
        (call-interactively (lookup-key harness-chat-panel-map (kbd "s")))
        (should (equal '(:outcome (:outcome "selected" :optionId "allow-session") :_harness (:pattern "~/notes/*.org"))
                       (car answers)))
        (should (null harness-chat--pending))
        ;; Unedited, the answer is the plain option; an empty edit goes back to the request's own.
        (harness-chat--on-permission (funcall params "d2") respond)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "~/elsewhere/**")))
          (harness-chat-edit-permission-pattern))
        (should (harness-ui-chat-test-find buf "pattern: ~/elsewhere/** (edited)"))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
          (harness-chat-edit-permission-pattern))
        (should (harness-ui-chat-test-find buf "pattern: ~/notes/**  [Edit]"))
        (goto-char (harness-ui-chat-test-find buf "Permission"))
        (call-interactively (lookup-key harness-chat-panel-map (kbd "N")))
        (should (equal '(:outcome (:outcome "selected" :optionId "deny-always")) (car answers)))
        ;; Without a request about a path outside there is nothing to edit.
        (harness-chat--on-permission (list :sessionId sid :toolCall '(:toolCallId "c3" :title "Bash: ls" :kind "execute")
                                           :options harness-acp--permission-options
                                           :_harness '(:pendingId "p3" :tool "bash"))
                                     respond)
        (should-not (harness-ui-chat-test-find buf "pattern:"))
        (should-error (harness-chat-edit-permission-pattern) :type 'user-error)
        ;; So its `e' types instead, into the box, and the request still waits.
        (goto-char (harness-ui-chat-test-find buf "Permission"))
        (should (equal "p3" (get-text-property (point) 'harness-ui-pending)))
        (save-window-excursion
          (set-window-buffer nil buf)
          (execute-kbd-macro "e"))
        (should (equal "e" (harness-compose-text)))
        (should harness-chat--pending)))))

(ert-deftest harness-ui-chat-tool-permission-has-no-pattern ()
  "A prompt about a call, not about a path outside, shows no pattern.
Its answers carry none, and C-c C-p edits the pattern of the request
about a path outside, though the prompt about the call is newer."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil)
           (panel-start (lambda (pid)
                          (let ((pos (point-min)))
                            (while (and pos (not (equal pid (get-text-property pos 'harness-ui-pending))))
                              (setq pos (next-single-property-change pos 'harness-ui-pending)))
                            (or pos (error "No panel for %s" pid)))))
           (panel (lambda (pid)
                    (let ((start (funcall panel-start pid)))
                      (buffer-substring-no-properties
                       start (or (next-single-property-change start 'harness-ui-pending) (point-max)))))))
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded)
                                 (harness-call 'session/pending-resolve session-id pending-id answer)
                                 answer))
      (harness-call 'session/pending-add sid
                    (list :id "d1" :kind 'permission
                          :payload (list :tool "read_file" :kind 'read :title "Access ~/notes/"
                                         :input '(:path "~/notes/todo.org")
                                         :paths (list (expand-file-name "~/notes/todo.org"))
                                         :dir (expand-file-name "~/notes/")
                                         :pattern (expand-file-name "~/notes/**")
                                         :reason "Read file wants ~/notes/todo.org, which is outside the allowed directories"
                                         :options '(allow-once allow-session allow-always deny-once deny-always))))
      (harness-call 'session/pending-add sid
                    (list :id "w1" :kind 'permission
                          :payload (list :tool "write_file" :kind 'write :title "Write file: lisp/a.el"
                                         :input '(:path "lisp/a.el")
                                         :paths (list (expand-file-name "~/proj/lisp/a.el"))
                                         :options '(allow-once allow-session allow-always deny-once deny-always))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf (= 2 (length harness-chat--pending))))
                           5 "pending rendered")
        (with-current-buffer buf
          (should (string-match-p "pattern: ~/notes/\\*\\*  \\[Edit\\] e\n" (funcall panel "d1")))
          (should-not (string-match-p "pattern:\\|\\[Edit\\]\\|remember" (funcall panel "w1")))
          (should (string-match-p "\\[Allow\\] y  \\[Allow for session\\] s" (funcall panel "w1")))
          ;; C-c C-p from the compose box edits the directory prompt's.
          (goto-char harness-compose-end)
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "~/notes/*.org")))
            (call-interactively (lookup-key harness-chat-mode-map (kbd "C-c C-p"))))
          (should (string-match-p "pattern: ~/notes/\\*\\.org (edited)" (funcall panel "d1")))
          (should-not (string-match-p "pattern:" (funcall panel "w1")))
          ;; The write's answer is the plain option.
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow]" (funcall panel-start "w1"))))
          (should (equal "w1" (get-text-property (point) 'harness-ui-pending)))
          (harness-chat-push))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "w1" "allow-always") (car recorded)))
        ;; The directory prompt's carries the edited pattern.
        (with-current-buffer buf
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow]")))
          (should (equal "d1" (get-text-property (point) 'harness-ui-pending)))
          (harness-chat-push))
        (harness-test-wait (lambda () (cdr recorded)) 5 "answered through the method")
        (should (equal (list sid "d1" '(:option "allow-always" :pattern "~/notes/*.org")) (car recorded)))))))

(ert-deftest harness-ui-chat-command-permission-says-where-it-runs ()
  "A shell command's prompt says where it runs and what it reaches.
Being about the call itself, it shows no pattern."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (proj (expand-file-name "~/proj/"))
           (params (lambda (pid command paths)
                     (list :sessionId sid
                           :toolCall (list :toolCallId pid :title (concat "Bash: " command) :kind "execute"
                                           :rawInput (list :command command))
                           :options harness-acp--permission-options
                           :_harness (list :pendingId pid :tool "bash" :cwd proj :paths paths
                                           :reason "The permission judge would deny this call: it reads other projects")))))
      ;; The command names a path outside: the prompt names it too.
      (should (harness-chat--on-permission
               (funcall params "p1" "ls -la ~/.claude/projects/x" (vector (expand-file-name "~/.claude/projects/x/")))
               #'ignore))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "kind: execute   runs in: ~/proj/\n   paths: ~/.claude/projects/x/\n"))
        (should-not (harness-ui-chat-test-find buf "pattern:"))
        (harness-chat-deny-newest))
      ;; It names none: it is about where it runs, said once.
      (should (harness-chat--on-permission
               (funcall params "p2" "git status" (list (directory-file-name proj)))
               #'ignore))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "kind: execute   runs in: ~/proj/\n"))
        (should-not (harness-ui-chat-test-find buf "paths:"))
        (should-not (harness-ui-chat-test-find buf "pattern:"))
        (harness-chat-deny-newest))
      ;; Any other call's paths stay on the line of its kind.
      (should (harness-chat--on-permission
               (list :sessionId sid
                     :toolCall (list :toolCallId "w1" :title "Write file: lisp/a.el" :kind "edit"
                                     :rawInput '(:path "lisp/a.el"))
                     :options harness-acp--permission-options
                     :_harness (list :pendingId "w1" :tool "write_file" :paths (list (concat proj "lisp/a.el"))))
               #'ignore))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "kind: edit   paths: ~/proj/lisp/a.el\n"))
        (should-not (harness-ui-chat-test-find buf "runs in:"))))))

(ert-deftest harness-ui-chat-question-panel ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (respond (lambda (r) (push r answers))))
      (should (harness-chat--on-question (list :sessionId sid :requestId "q1" :question "Which colour?"
                                               :options '("red" "green" "blue"))
                                         respond))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "Which colour?"))
        (goto-char (1- (harness-ui-chat-test-find buf "green")))
        (harness-chat-push)
        (should (equal '((:answer "green")) answers))
        (should (null harness-chat--pending))
        ;; A digit on the panel picks that option.
        (harness-chat--on-question (list :sessionId sid :requestId "q3" :question "Which shape?"
                                         :options '("circle" "square"))
                                   respond)
        (goto-char (harness-ui-chat-test-find buf "Which shape?"))
        (save-window-excursion
          ;; Keys reach the buffer of the selected window.
          (set-window-buffer nil buf)
          ;; A digit beyond the options has none to answer with: it types,
          ;; into the box, and the question still waits.
          (execute-kbd-macro "3")
          (should (equal "3" (harness-compose-text)))
          (should harness-chat--pending)
          (harness-compose-set "")
          (goto-char (harness-ui-chat-test-find buf "Which shape?"))
          (execute-kbd-macro "2"))
        (should (equal '(:answer "square") (car answers)))
        (should (null harness-chat--pending))
        ;; Free text goes through the compose box.
        (harness-chat--on-question (list :sessionId sid :requestId "q2" :question "Name?" :options nil) respond)
        (should (string-match-p "type an answer" (format "%s" (overlay-get harness-compose--placeholder 'before-string))))
        (harness-ui-chat-test-type buf "purple")
        (harness-chat-send)
        (should (equal '(:answer "purple") (car answers)))
        (should (null harness-chat--pending))
        (should (equal "" (harness-compose-text)))))))

(defun harness-ui-chat-test-nav (nav)
  "Return the position of the diagram tab or arrow NAV in the current buffer."
  (text-property-any (point-min) (point-max) 'harness-ui-pending-diagram-nav nav))

(ert-deftest harness-ui-chat-question-diagrams ()
  "Options with diagrams show one diagram at a time, in one area under the
options; tabs, arrows, n and p, C-c C-f and C-c C-b and point moving
onto an option switch it, and answering works as without diagrams."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (shown (lambda ()
                    (let ((seen (cl-loop for art in '("[left|main]" "[main|right]" "[tabs/main]") for i from 0
                                         when (harness-ui-chat-test-find buf art) collect i)))
                      (should (= 1 (length seen)))
                      (car seen)))))
      (should (harness-chat--on-question
               (list :sessionId sid :requestId "qd" :question "Which layout?"
                     :options '("Sidebar left" "Sidebar right" "Tabs")
                     :diagrams '((:type "ascii" :text "+-----------+\n[left|main]\n+-----------+")
                                 (:type "ascii" :text "[main|right]")
                                 (:type "ascii" :text "[tabs/main]")))
               (lambda (r) (push r answers))))
      (with-current-buffer buf
        ;; The first option's diagram, fixed width, its label bold in the list.
        (should (harness-ui-chat-test-find buf "Diagram"))
        (should (= 0 (funcall shown)))
        (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "[left|main]")) 'harness-ui-output-face))
        (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "Sidebar left")) 'bold))
        (should-not (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "Sidebar right")) 'bold))
        (should (harness-ui-chat-test-find buf "next diagram"))
        ;; From the compose box, which keeps its text and point.
        (harness-ui-chat-test-type buf "draft")
        (backward-char 2)
        (call-interactively (key-binding (kbd "C-c C-f")))
        (should (= 1 (funcall shown)))
        (should (harness-ui-chat-test-face-at (1- (harness-ui-chat-test-find buf "Sidebar right")) 'bold))
        (should (equal "draft" (harness-compose-text)))
        (should (= (point) (- harness-compose-end 2)))
        (call-interactively (key-binding (kbd "C-c C-b")))
        (call-interactively (key-binding (kbd "C-c C-b")))
        (should (= 2 (funcall shown)))          ; round from the first to the last
        ;; A tab shows its option's diagram, an arrow the next; point stays on it.
        (goto-char (harness-ui-chat-test-nav 1))
        (harness-chat-push)
        (should (= 1 (funcall shown)))
        (should (eql 1 (get-text-property (point) 'harness-ui-pending-diagram-nav)))
        (goto-char (harness-ui-chat-test-nav 'next))
        (harness-chat-push)
        (harness-chat-push)
        (should (= 0 (funcall shown)))
        (should (eq 'next (get-text-property (point) 'harness-ui-pending-diagram-nav)))
        ;; n and p on the panel.
        (goto-char (harness-ui-chat-test-find buf "Which layout?"))
        (call-interactively (lookup-key (get-text-property (point) 'keymap) "n"))
        (should (= 1 (funcall shown)))
        (call-interactively (lookup-key (get-text-property (point) 'keymap) "p"))
        (should (= 0 (funcall shown)))
        ;; Point moving onto an option shows its diagram, and stays on it.
        (goto-char (harness-ui-chat-test-find buf "Tabs"))
        (harness-chat--post-command)
        (should (= 2 (funcall shown)))
        (should (eql 2 (get-text-property (point) 'harness-ui-pending-option)))
        ;; Switched there, it stays switched: only a move counts.
        (call-interactively (lookup-key (get-text-property (point) 'keymap) "n"))
        (harness-chat--post-command)
        (should (= 0 (funcall shown)))
        (should (eql 2 (get-text-property (point) 'harness-ui-pending-option)))
        ;; A redraw of the whole tail keeps the diagram shown.
        (harness-chat--render-tail)
        (should (= 0 (funcall shown)))
        ;; A digit answers, with the label.
        (goto-char (harness-ui-chat-test-find buf "Which layout?"))
        (call-interactively (lookup-key (get-text-property (point) 'keymap) "2"))
        (should (equal '((:answer "Sidebar right")) answers))
        (should (null harness-chat--pending))
        (should-not (harness-ui-pending--diagrams (car (harness-ui-pending-items sid))))
        (should-not (harness-ui-chat-test-find buf "Diagram"))
        (should-error (harness-chat-next-diagram) :type 'user-error)
        ;; A question without diagrams has no area and no n, p.
        (harness-chat--on-question (list :sessionId sid :requestId "qp" :question "Which colour?"
                                         :options '("red" "green"))
                                   #'ignore)
        (should-not (harness-ui-chat-test-find buf "Diagram"))
        (goto-char (harness-ui-chat-test-find buf "Which colour?"))
        (should-not (lookup-key (get-text-property (point) 'keymap) "n"))
        (should-error (harness-chat-next-diagram) :type 'user-error)))))

(ert-deftest harness-ui-chat-question-diagrams-from-the-session ()
  "A question waiting when the buffer opens shows its diagrams from the
session's pending item; an image diagram shows the image, or a button
opening it where images cannot show or the file is remote."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (image (expand-file-name "layout.png" (harness-test-temp-dir))))
      (write-region "not really a png" nil image nil 'silent)
      (harness-call 'session/pending-add sid
                    (list :id "pq" :kind 'question
                          :payload (list :question "Which layout?" :options '("Drawn" "Remote" "Ascii")
                                         :diagrams (list (list :type "image" :path image :mime "image/png")
                                                         '(:type "image" :path "/ssh:far:/srv/x.png" :mime "image/png")
                                                         '(:type "ascii" :text "[ascii art]")))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "Which layout?"))
          (should (harness-ui-chat-test-find buf (format "[image %s]" (abbreviate-file-name image))))
          (harness-chat-next-diagram)
          (should (harness-ui-chat-test-find buf "[image /ssh:far:/srv/x.png]"))
          (harness-chat-next-diagram)
          (should (harness-ui-chat-test-find buf "[ascii art]"))
          (should-not (harness-ui-chat-test-find buf "[image ")))))))

;;;; Coalescing

(ert-deftest harness-ui-chat-coalesces-runs-of-tools ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (cwd (plist-get (harness-call 'session/get sid) :cwd)))
      (let ((harness-provider-demo-script-override
             `((:type text :delta "Reading around.\n")
               (:type tool-call :id "r1" :name "read_file" :input (:path "a.el"))
               (:type tool-call :id "r2" :name "read_file" :input (:path "b.el"))
               (:type tool-call :id "r3" :name "read_file" :input (:path "c.el"))
               (:type tool-call :id "r4" :name "grep" :input (:pattern "defun" :path ,cwd))
               (:type tool-call :id "r5" :name "glob" :input (:pattern "*.el" :path ,cwd))
               (:type text :delta "Done reading.")
               (:type done :stop-reason end-turn))))
        (harness-ui-chat-test-prompt buf "read things"))
      (with-current-buffer buf
        (should (member "read_file" harness-chat--coalescable))
        (should-not (member "bash" harness-chat--coalescable))
        (should (= 1 (hash-table-count harness-chat--groups)))
        (let* ((group (car (hash-table-values harness-chat--groups)))
               ;; Tools are counted by their labels.
               (summary (harness-ui-chat-test-find buf "5 tool calls: Read file ×3, Search files, Find files"))
               (first (gethash (car (harness-chat-group-members group)) harness-chat--blocks)))
          (should summary)
          (should (= 5 (length (harness-chat-group-members group))))
          (should (invisible-p (harness-chat-block-start first)))
          (should (invisible-p (harness-ui-chat-test-find buf "Read file c.el")))
          ;; The hidden stretch starts on a plain newline: one starting on
          ;; the first member's fold icon would still draw that icon.
          (let ((ov (harness-chat-group-overlay group)))
            (should (eq (char-after (overlay-start ov)) ?\n))
            (should-not (get-text-property (overlay-start ov) 'display))
            (should (= (overlay-end ov)
                       (1- (harness-chat-block-end
                            (gethash (car (last (harness-chat-group-members group))) harness-chat--blocks)))))
            (should-not (invisible-p (overlay-end ov))))
          ;; Expanding shows the individual, still collapsed, blocks.
          (harness-chat-toggle-group (harness-chat-group-id group))
          (should-not (invisible-p (harness-chat-block-start first)))
          (should (harness-chat-block-collapsed first))
          (should (invisible-p (1- (harness-ui-chat-test-find buf "read_file of a.el"))))
          (should (harness-ui-chat-test-find buf "[collapse]"))
          (harness-chat-toggle-group (harness-chat-group-id group))
          (should (invisible-p (harness-chat-block-start first))))
        ;; The summary comes before the run, after the intro text.
        (should (< (harness-ui-chat-test-find buf "Reading around")
                   (harness-ui-chat-test-find buf "5 tool calls")
                   (harness-ui-chat-test-find buf "Done reading"))))
      ;; glob, grep then bash: a run of two broken by a non-coalescable tool stays as is.
      (harness-ui-chat-test-prompt buf "run the tools")
      (with-current-buffer buf
        (should (= 1 (hash-table-count harness-chat--groups)))
        (should (= 8 (length (harness-ui-chat-test-blocks buf "tool-call"))))
        (should (harness-ui-chat-test-find buf "echo hello from bash"))
        ;; A redraw computes the same grouping over the fetched history.
        (harness-chat-redraw)
        (harness-test-wait (lambda () (not harness-chat--loading)) 5 "redrawn")
        (should (= 1 (hash-table-count harness-chat--groups)))
        (should (harness-ui-chat-test-find buf "5 tool calls: Read file ×3, Search files, Find files"))))))

(defun harness-ui-chat-test-check-groups (buf)
  "Check that every group of BUF is sound and return the groups, oldest first.
Its members are distinct blocks folded into it, oldest first, starting
and ending with a call, and its overlay hides them and nothing else."
  (with-current-buffer buf
    (let ((groups (sort (hash-table-values harness-chat--groups)
                        (lambda (a b) (< (harness-chat-group-start a) (harness-chat-group-start b))))))
      (dolist (g groups)
        (let* ((members (harness-chat-group-members g))
               (blocks (mapcar (lambda (m) (gethash m harness-chat--blocks)) members))
               (ov (harness-chat-group-overlay g)))
          (should (equal members (delete-dups (copy-sequence members))))
          (should (cl-every (lambda (b) (equal (harness-chat-block-group b) (harness-chat-group-id g))) blocks))
          (should (equal "tool-call" (harness-chat-block-kind (car blocks))))
          (should (equal "tool-call" (harness-chat-block-kind (car (last blocks)))))
          (should (cl-every (lambda (a b) (< (harness-chat-block-start a) (harness-chat-block-start b)))
                            blocks (cdr blocks)))
          (should (= (overlay-start ov) (1- (harness-chat-block-start (car blocks)))))
          (should (= (overlay-end ov) (1- (harness-chat-block-end (car (last blocks))))))))
      groups)))

(ert-deftest harness-ui-chat-coalesces-across-thinking ()
  "Thinking between coalescable calls folds into their group; around them it stays out.
A model that thinks before every call made runs of none."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (cwd (plist-get (harness-call 'session/get sid) :cwd)))
      (let ((harness-provider-demo-script-override
             `((:type thinking :delta "Where to start.")
               (:type tool-call :id "r1" :name "read_file" :input (:path "a.el"))
               (:type thinking :delta "Now the other one.")
               (:type tool-call :id "r2" :name "read_file" :input (:path "b.el"))
               (:type thinking :delta "And who calls it.")
               ;; The run reaches the threshold here, then grows by a call.
               (:type tool-call :id "r3" :name "grep" :input (:pattern "defun" :path ,cwd))
               (:type thinking :delta "And the files.")
               (:type tool-call :id "r4" :name "glob" :input (:pattern "*.el" :path ,cwd))
               (:type thinking :delta "Time to run it.")
               (:type tool-call :id "r5" :name "bash" :input (:command "echo ran"))
               (:type text :delta "Done.")
               (:type done :stop-reason end-turn))))
        (harness-ui-chat-test-prompt buf "read things"))
      (cl-flet ((check ()
                  (with-current-buffer buf
                    (let* ((groups (harness-ui-chat-test-check-groups buf))
                           (group (car groups))
                           (thoughts (harness-ui-chat-test-blocks buf "thinking"))
                           (calls (harness-ui-chat-test-blocks buf "tool-call"))
                           (summary (harness-ui-chat-test-find buf "4 tool calls: Read file ×2, Search files, Find files · thinking ×3")))
                      (should (= 1 (length groups)))
                      (should (= 5 (length thoughts)))
                      ;; The four reads and the three thoughts between them, in order.
                      (should (equal (harness-chat-group-members group)
                                     (mapcar #'harness-chat-block-id
                                             (list (nth 0 calls) (nth 1 thoughts) (nth 1 calls) (nth 2 thoughts)
                                                   (nth 2 calls) (nth 3 thoughts) (nth 3 calls)))))
                      (should summary)
                      (should-not (invisible-p summary))
                      (dolist (b (list (nth 1 thoughts) (nth 2 thoughts) (nth 3 thoughts) (nth 0 calls) (nth 3 calls)))
                        (should (invisible-p (harness-chat-block-start b))))
                      ;; The thinking that opens the turn and the one before
                      ;; the bash call stay out, around the summary.
                      (dolist (b (list (nth 0 thoughts) (nth 4 thoughts) (nth 4 calls)))
                        (should-not (harness-chat-block-group b))
                        (should-not (invisible-p (harness-chat-block-start b))))
                      (should (< (harness-chat-block-start (nth 0 thoughts))
                                 summary
                                 (harness-chat-block-start (nth 4 thoughts))))
                      ;; The turn's sender line stays on its first block.
                      (should (harness-chat-block-head (nth 0 thoughts)))
                      ;; Expanding shows the calls and the thoughts, still collapsed.
                      (harness-chat-toggle-group (harness-chat-group-id group))
                      (should-not (invisible-p (harness-chat-block-start (nth 2 thoughts))))
                      (should (harness-chat-block-collapsed (nth 2 thoughts)))
                      (harness-chat-toggle-group (harness-chat-group-id group))
                      (should (invisible-p (harness-chat-block-start (nth 2 thoughts))))))))
        ;; Grouped live, as the blocks arrived...
        (check)
        ;; ...and the same over the history a redraw loads.
        (with-current-buffer buf
          (harness-chat-redraw)
          (harness-test-wait (lambda () (not harness-chat--loading)) 5 "redrawn"))
        (check)))))

(ert-deftest harness-ui-chat-late-results-leave-runs-alone ()
  "A result for a call that is not the newest block does not regroup it.
Results and their updates (checkpoints) come in for older calls; one
used to fold its call into a run it is not part of, hiding the blocks
between them."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (with-current-buffer buf
        (cl-flet ((node (&rest plist)
                    (harness-chat--apply-update (list :sessionUpdate "_harness/node" :node plist)))
                  (read-call (id call path)
                    (harness-chat--apply-update
                     (list :sessionUpdate "_harness/node"
                           :node (list :id id :kind "tool-call" :tool "read_file" :call-id call
                                       :input (list :path path) :title (concat "read_file " path))))))
          (read-call "n-r1" "c1" "a.el")
          (read-call "n-r2" "c2" "b.el")
          (node :id "n-b" :kind "tool-call" :tool "bash" :call-id "c3" :input '(:command "ls") :title "bash ls")
          ;; Two reads and a bash call: no run.  The first read's result
          ;; comes last.
          (node :id "n-r1-out" :kind "tool-result" :call-id "c1" :output "a")
          (should (= 0 (hash-table-count harness-chat--groups)))
          (should-not (harness-chat-block-group (gethash "n-r1" harness-chat--blocks)))
          ;; A run after a message of the user.
          (node :id "n-u" :kind "user" :content "Read three more.")
          (read-call "n-r3" "c4" "c.el")
          (read-call "n-r4" "c5" "d.el")
          (read-call "n-r5" "c6" "e.el")
          (let* ((group (car (harness-ui-chat-test-check-groups buf)))
                 (members (copy-sequence (harness-chat-group-members group))))
            (should (= 1 (hash-table-count harness-chat--groups)))
            (should (equal '("n-r3" "n-r4" "n-r5") members))
            ;; The older read's result changes: it stays out of the run,
            ;; whose overlay still hides its members and nothing else.
            (node :id "n-r1-out" :kind "tool-result" :call-id "c1" :output "a, checked")
            (node :id "n-r2-out" :kind "tool-result" :call-id "c2" :output "b")
            (should (equal (list group) (harness-ui-chat-test-check-groups buf)))
            (should (equal members (harness-chat-group-members group)))
            (should-not (harness-chat-block-group (gethash "n-r1" harness-chat--blocks)))
            (should-not (invisible-p (harness-ui-chat-test-find buf "Read three more")))
            (should-not (invisible-p (harness-chat-block-start (gethash "n-b" harness-chat--blocks))))
            ;; A result for a grouped call counts in its summary.
            (node :id "n-r4-out" :kind "tool-result" :call-id "c5" :output "boom" :is-error t)
            (should (equal members (harness-chat-group-members group)))
            (should (string-match-p "3 tool calls: Read file ×3.*1 failed"
                                    (buffer-substring-no-properties (harness-chat-group-start group)
                                                                    (harness-chat-group-end group))))))))))

(ert-deftest harness-ui-chat-call-waiting-on-the-user-stays-out-of-groups ()
  "A coalescable call waiting for the user's permission is not folded away.
It used to fold into the run it ended, so the call the session waited
on hid behind a summary line.  Once answered, it folds in with its run."
  (harness-ui-chat-test-with
    (let ((waiting nil))
      ;; Reading outside the project asks the user, as the directory jail does.
      (harness-add-filter 'permission/decide
                          (lambda (decision next request)
                            (if (not (equal (plist-get (plist-get request :input) :path) "/outside/x.el"))
                                (funcall next decision)
                              (let* ((sid (plist-get (plist-get request :session) :id))
                                     (pending (list :kind 'permission
                                                    :payload (list :tool "read_file" :kind 'read
                                                                   :input (plist-get request :input)
                                                                   :call-id (plist-get request :call-id)
                                                                   :title "Access /outside/")))
                                     (pid (harness-call 'session/pending-add sid pending)))
                                (setq waiting next)
                                (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid)))))
                          5)
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (harness-call 'session/pending-resolve session-id pending-id answer)
                                 (funcall waiting (list :behavior 'allow :final t))
                                 answer))
      (let* ((sid (harness-ui-chat-test-session))
             (buf (harness-ui-chat-test-open sid))
             (cwd (plist-get (harness-call 'session/get sid) :cwd))
             (harness-provider-demo-script-override
              `((:type tool-call :id "r1" :name "list_dir" :input (:path ,cwd))
                (:type tool-call :id "r2" :name "glob" :input (:pattern "*.el" :path ,cwd))
                (:type tool-call :id "r3" :name "read_file" :input (:path "/outside/x.el"))
                (:type done :stop-reason end-turn))))
        (harness-ui-chat-test-type buf "read things")
        (with-current-buffer buf (harness-chat-send))
        (harness-test-wait (lambda () (with-current-buffer buf
                                        (and harness-chat--pending
                                             (= 3 (length (harness-ui-chat-test-blocks buf "tool-call"))))))
                           5 "waiting on the user")
        (with-current-buffer buf
          (let ((read (car (last (harness-ui-chat-test-blocks buf "tool-call")))))
            ;; The three reads would be a run, but it ends on the call the
            ;; session waits on: no group hides it.
            (should (equal "/outside/x.el" (plist-get (plist-get (harness-chat-block-node read) :input) :path)))
            (should (harness-chat--waiting-p read))
            (should (= 0 (hash-table-count harness-chat--groups)))
            (should-not (invisible-p (harness-chat-block-start read)))
            (harness-chat--answer-permission (plist-get (car harness-chat--pending) :id) "allow-once")))
        (harness-test-wait (lambda () (equal "idle" (plist-get (harness-ui-session sid) :status))) 10 "turn ended")
        (with-current-buffer buf
          (let ((calls (harness-ui-chat-test-blocks buf "tool-call"))
                (groups (harness-ui-chat-test-check-groups buf)))
            (should (cl-every #'harness-chat-block-result calls))
            (should (= 1 (length groups)))
            (should (equal (mapcar #'harness-chat-block-id calls)
                           (harness-chat-group-members (car groups))))))))))

(ert-deftest harness-ui-chat-answered-call-rejoins-its-run-and-open-groups-stay-open ()
  "A call waiting on the user regroups the transcript as a fresh load would.
Answered after another call of the same step came in, it is no longer
the newest block, and used to stay out of its run for good.  Taking it
out of a run the user had opened used to open every other group too,
and either change closed the groups the user had opened."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (with-current-buffer buf
        (cl-labels ((node (&rest plist)
                      (harness-chat--apply-update (list :sessionUpdate "_harness/node" :node plist)))
                    (read (id call path &optional result)
                      (node :id id :kind "tool-call" :tool "read_file" :call-id call
                            :input (list :path path) :title (concat "read_file " path))
                      (when result (node :id (concat id "-out") :kind "tool-result" :call-id call :output "ok")))
                    (group-of (id)
                      (gethash (harness-chat-block-group (gethash id harness-chat--blocks)) harness-chat--groups))
                    (members (id) (harness-chat-group-members (group-of id)))
                    (open-p (id)
                      ;; Shown, and its summary offers to collapse it.
                      (let ((g (group-of id)))
                        (and (harness-chat-group-expanded g)
                             (not (overlay-get (harness-chat-group-overlay g) 'invisible))
                             (string-match-p "\\[collapse\\]"
                                             (buffer-substring-no-properties (harness-chat-group-start g)
                                                                             (harness-chat-group-end g))))))
                    (toggle (id) (harness-chat-toggle-group (harness-chat-group-id (group-of id)))))
          (read "n-a1" "a1" "a.el" t)
          (read "n-a2" "a2" "b.el" t)
          (read "n-a3" "a3" "c.el" t)
          (node :id "n-u" :kind "user" :content "Now the rest.")
          (read "n-r1" "c1" "d.el" t)
          (read "n-r2" "c2" "e.el" t)
          (read "n-r3" "c3" "f.el" t)
          (read "n-r4" "c4" "/outside/x.el")
          (should (equal '("n-r1" "n-r2" "n-r3" "n-r4") (members "n-r1")))
          ;; The user watches the run; its last read asks for permission.
          (toggle "n-r1")
          (harness-ui-pending-add sid (list :id "p4" :kind "permission" :call-id "c4" :created (float-time)
                                            :title "Access /outside/" :tool "read_file" :tool-kind "read"
                                            :input '(:path "/outside/x.el")))
          (should (harness-chat--waiting-p (gethash "n-r4" harness-chat--blocks)))
          (should-not (harness-chat-block-group (gethash "n-r4" harness-chat--blocks)))
          ;; The rest of the run stays open, the other group folded.
          (should (equal '("n-r1" "n-r2" "n-r3") (members "n-r1")))
          (should (open-p "n-r1"))
          (should-not (open-p "n-a1"))
          ;; Another call of the step finishes while the read waits.
          (read "n-r5" "c5" "g.el" t)
          (should-not (harness-chat-block-group (gethash "n-r5" harness-chat--blocks)))
          (toggle "n-r1")
          (toggle "n-a1")
          ;; Answered, the read folds into its run with the call after it,
          ;; and the group the user opened stays open.
          (harness-ui-pending-remove sid "p4")
          (node :id "n-r4-out" :kind "tool-result" :call-id "c4" :output "ok")
          (should (equal '("n-r1" "n-r2" "n-r3" "n-r4" "n-r5") (members "n-r1")))
          (should-not (open-p "n-r1"))
          (should (open-p "n-a1"))
          (should (= 2 (length (harness-ui-chat-test-check-groups buf))))
          (should-not (invisible-p (harness-ui-chat-test-find buf "Now the rest"))))))))

;;;; Images and videos in the transcript

(defun harness-ui-chat-test--video (dir name seconds)
  "Write a file that looks like a video at DIR/NAME, in the media module's
eyes: a real thumbnail and a known duration, so no ffmpeg or ffprobe runs."
  (let* ((path (expand-file-name name dir))
         (thumb (harness-ui-media-thumbnail-path path)))
    (with-temp-file path (insert "not really a video"))
    (write-region "thumb" nil thumb nil 'silent)
    (puthash path seconds harness-ui-media--durations)
    path))

(defun harness-ui-chat-test--png (dir name)
  "Write a file that looks like a PNG at DIR/NAME."
  (let ((path (expand-file-name name dir)))
    (write-region "not really a png" nil path nil 'silent)
    path))

(defun harness-ui-chat-test--media-pos (mime)
  "Return the first position in the current buffer carrying media MIME."
  (car (harness-ui-chat-test--media-positions mime)))

(defun harness-ui-chat-test--media-positions (mime)
  "Return every position in the current buffer carrying media MIME."
  (let ((pos (point-min)) found)
    (while (< pos (point-max))
      (when (equal mime (get-text-property pos 'harness-ui-media-mime))
        (push pos found))
      (setq pos (next-single-property-change pos 'harness-ui-media-mime nil (point-max))))
    (nreverse found)))

(ert-deftest harness-ui-chat-shows-what-a-read-brought ()
  "An image a tool read shows in the transcript, and so does a video,
each above the fold: they are visible while the call is collapsed, and
the call's text stays folded."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (image (harness-ui-chat-test--png (harness-test-temp-dir) "shot.png"))
           (video (harness-ui-chat-test--video (harness-test-temp-dir) "clip.mp4" 42)))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id "m1"
                                              :input '(:path "shot.png") :title "Read file: shot.png"))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "m1"
                                              :output "Image shot.png (image/png, 17 B) attached."
                                              :attachments (list (list :path image :mime "image/png"
                                                                       :size 17 :name "shot.png"))))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id "m2"
                                              :input '(:path "clip.mp4") :title "Read file: clip.mp4"))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "m2"
                                              :output "Video clip.mp4 (video/mp4, 76 B) is shown to the user in the chat."
                                              :attachments (list (list :path video :mime "video/mp4"
                                                                       :size 76 :name "clip.mp4"))))
      (let* ((buf (harness-ui-chat-test-open sid))
             (blocks (with-current-buffer buf (harness-ui-chat-test-blocks buf "tool-call")))
             (image-block (car blocks))
             (video-block (cadr blocks)))
        (with-current-buffer buf
          (should (equal 2 (length blocks)))
          ;; The image is drawn, before the fold, so a collapsed call still
          ;; shows it; the call's text output stays hidden under the fold.
          (let ((pos (harness-ui-chat-test-find buf "[image ")))
            (should pos)
            (should-not (invisible-p (1- pos)))
            (should (< (1- pos) (overlay-start (harness-chat-block-fold image-block)))))
          ;; The video, likewise: its rendering (its name and Play button,
          ;; here with no graphic display) sits above the fold.
          (let ((pos (harness-ui-chat-test--media-pos "video/mp4")))
            (should pos)
            (should-not (invisible-p pos))
            (should (< pos (overlay-start (harness-chat-block-fold video-block)))))
          (should (harness-ui-chat-test-find buf "Play"))
          (should (harness-ui-chat-test-find buf "0:42"))
          (should (harness-chat-block-collapsed image-block))
          ;; The call's own output, which the fold hides, is there for search.
          (should (invisible-p (1- (harness-ui-chat-test-find buf "Image shot.png (image/png, 17 B) attached.")))))))))

(ert-deftest harness-ui-chat-sent-images-keep-their-tokens ()
  "An image attached in the box is sent with its label, and shown under its token.
The text keeps [image 1] where the image was attached.  The model gets
the label with the image, and the transcript styles the token in the
text as the box showed it and puts it over the image too."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (png (expand-file-name "shot.png" (harness-test-temp-dir))))
      (let ((coding-system-for-write 'binary)) (write-region harness-test-png nil png nil 'silent))
      (with-current-buffer buf
        (harness-ui-chat-test-type buf "the button in")
        (harness-compose-add-attachment png)
        (should (equal "the button in [image 1] " (harness-compose-text))))
      (harness-ui-chat-test-prompt buf "is cut off")
      (let ((node (car (harness-call 'session/nodes sid))))
        (should (equal "the button in [image 1] is cut off" (plist-get node :content)))
        (should (equal '(("text" nil) ("image" "image 1"))
                       (mapcar (lambda (b) (list (plist-get b :type) (plist-get b :label))) (plist-get node :blocks))))
        (should (equal (base64-encode-string harness-test-png t) (plist-get (cadr (plist-get node :blocks)) :data))))
      (with-current-buffer buf
        (let* ((text "the button in [image 1] is cut off")
               (end (harness-ui-chat-test-find buf text))
               (token (and end (+ (- end (length text)) (length "the button in ")))))
          (should end)
          (should (harness-ui-chat-test-face-at token 'harness-compose-token-face))
          (should (harness-ui-chat-test-face-at (+ token 8) 'harness-compose-token-face))
          (should-not (harness-ui-chat-test-face-at (1- token) 'harness-compose-token-face))
          (should-not (harness-ui-chat-test-face-at (+ token 9) 'harness-compose-token-face))
          ;; Over the image, its token, on a line of its own.
          (let ((caption (harness-ui-chat-test-find buf "\n[image 1]\n[image]" end)))
            (should caption)
            (should (harness-ui-chat-test-face-at (- caption (length "[image 1]\n[image]"))
                                                  'harness-compose-token-face))))))))

(ert-deftest harness-ui-chat-media-rerender-keeps-it-visible ()
  "When the media module redraws a video (a thumbnail landing, or a
player advancing), the chat redraws the block, so the fold never
collapses onto the picture and hides it.  Every block showing the
video is redrawn, not just the first."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (video (harness-ui-chat-test--video (harness-test-temp-dir) "clip.mp4" 42)))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id "m1"
                                              :input '(:path "clip.mp4") :title "Read file: clip.mp4"))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "m1"
                                              :output "Video clip.mp4 (video/mp4, 76 B) is shown to the user."
                                              :attachments (list (list :path video :mime "video/mp4"
                                                                       :size 76 :name "clip.mp4"))))
      ;; The same video, in the message that attached it: another block.
      (harness-call 'session/append sid
                    (list :kind 'user :content "and this one"
                          :blocks (list (list :type "file" :path video :mime "video/mp4"
                                              :size 76 :name "clip.mp4"))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (with-current-buffer buf
          (let* ((block (car (harness-ui-chat-test-blocks buf "tool-call")))
                 (before (harness-ui-chat-test--media-pos "video/mp4")))
            (should before)
            (should-not (invisible-p before))
            (should (= 2 (length (harness-ui-chat-test--media-positions "video/mp4"))))
            ;; The chat claims the redraw, and redraws both blocks.
            (should (harness-chat--rerender-media video))
            (let ((positions (harness-ui-chat-test--media-positions "video/mp4")))
              (should (= 2 (length positions)))
              (dolist (pos positions) (should-not (invisible-p pos)))
              (should (< (car positions) (overlay-start (harness-chat-block-fold block)))))
            (should (= 2 (cl-count-if (lambda (l) (string-match-p "Play" l))
                                      (split-string
                                       (buffer-substring-no-properties (point-min) (point-max)) "\n"))))
            ;; Without a chat block showing it, the module edits in place.
            (should-not (harness-chat--rerender-media "/tmp/nowhere.mp4"))))))))

(ert-deftest harness-ui-chat-media-reads-stay-out-of-groups ()
  "A read whose result carries a picture is not folded into a coalesced
group, even when its call arrived while the group was forming; the
calls around it regroup."
  (harness-ui-chat-test-with
    (let* ((harness-chat--coalesce-threshold 2)
           (image (harness-ui-chat-test--png (harness-test-temp-dir) "shot.png"))
           (sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      ;; read_file brings an image for shot.png, text for anything else.
      (harness-define-tool "read_file" :label "Read file" :description "read" :kind 'read :coalescable t
                           :subject (lambda (input) (plist-get input :path))
                           :handler (lambda (input _ctx)
                                      (if (equal (plist-get input :path) "shot.png")
                                          (harness-tool-ok "Image shot.png (image/png, 17 B) attached."
                                                           :attachments (list (list :path image :mime "image/png"
                                                                                    :size 17 :name "shot.png")))
                                        (format "read_file of %s" (plist-get input :path)))))
      (let ((harness-provider-demo-script-override
             '((:type tool-call :id "r1" :name "read_file" :input (:path "a.el"))
               (:type tool-call :id "r2" :name "read_file" :input (:path "b.el"))
               (:type tool-call :id "r3" :name "read_file" :input (:path "shot.png"))
               (:type tool-call :id "r4" :name "read_file" :input (:path "c.el"))
               (:type tool-call :id "r5" :name "read_file" :input (:path "d.el"))
               (:type text :delta "Done.")
               (:type done :stop-reason end-turn))))
        (harness-ui-chat-test-prompt buf "read them"))
      (with-current-buffer buf
        ;; Two groups: r1 with r2 before the image, r4 with r5 after it.
        (should (= 2 (hash-table-count harness-chat--groups)))
        (let* ((shot (cl-find-if (lambda (b) (string-match-p "shot.png"
                                                             (plist-get (harness-chat-block-node b) :title)))
                                 (harness-ui-chat-test-blocks buf "tool-call")))
               (pos (save-excursion (goto-char (harness-chat-block-start shot))
                                    (search-forward "[image " (harness-chat-block-end shot)))))
          (should shot)
          ;; It is not in a group, and its picture shows.
          (should-not (harness-chat-block-group shot))
          (should-not (invisible-p (1- pos)))
          (should-not (invisible-p (harness-chat-block-start shot)))
          ;; The picture stays visible when the groups are expanded, and
          ;; neither group holds it.
          (dolist (g (hash-table-values harness-chat--groups))
            (harness-chat-toggle-group (harness-chat-group-id g))
            (should-not (member (harness-chat-block-id shot) (harness-chat-group-members g))))
          (should-not (invisible-p (1- pos)))
          (should (= 2 (hash-table-count harness-chat--groups)))
          (should (harness-ui-chat-test-find buf "2 tool calls: Read file ×2")))
        ;; A redraw from the fetched history keeps the same shape.
        (harness-chat-redraw)
        (harness-test-wait (lambda () (not harness-chat--loading)) 5 "redrawn")
        (should (= 2 (hash-table-count harness-chat--groups)))
        (let ((shot (cl-find-if (lambda (b) (string-match-p "shot.png"
                                                            (plist-get (harness-chat-block-node b) :title)))
                                (harness-ui-chat-test-blocks buf "tool-call"))))
          (should-not (harness-chat-block-group shot))
          (should-not (invisible-p (1- (save-excursion (goto-char (harness-chat-block-start shot))
                                                       (search-forward "[image " (harness-chat-block-end shot)))))))))))

(ert-deftest harness-ui-chat-shows-a-video-a-person-attached ()
  "A video attached to a user message shows the video UI in the message."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (video (harness-ui-chat-test--video (harness-test-temp-dir) "trip.mp4" 90)))
      (harness-call 'session/append sid
                    (list :kind 'user :content "watch this"
                          :blocks (list (list :type "file" :path video :mime "video/mp4"
                                              :size 76 :name "trip.mp4"))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (with-current-buffer buf
          (let ((pos (harness-ui-chat-test-find buf "trip.mp4")))
            (should pos)
            (should-not (invisible-p (1- pos)))
            (should (harness-ui-chat-test-find buf "Play"))
            (should (harness-ui-chat-test-find buf "1:30"))))))))

;;;; Failed and denied tool calls

(defun harness-ui-chat-test-block-text (block)
  "Return the text of BLOCK without properties."
  (buffer-substring-no-properties (harness-chat-block-start block) (harness-chat-block-end block)))

(defun harness-ui-chat-test-faces-in (block text)
  "Return the faces at TEXT inside BLOCK, as a list."
  (let ((pos (save-excursion
               (goto-char (harness-chat-block-start block))
               (search-forward text (harness-chat-block-end block))
               (match-beginning 0))))
    (ensure-list (get-text-property pos 'face))))

(ert-deftest harness-ui-chat-tells-denied-calls-from-failed-ones ()
  ;; A call the permission system refused never ran: it reads "denied"
  ;; behind a yellow circle, on a background of its own, while a call
  ;; that ran and reported an error reads "failed" behind a red
  ;; triangle, and one that ran has a green circle.  A coalesced group
  ;; counts the failed and denied ones, also when a member's result
  ;; arrives after the group formed.
  (harness-ui-chat-test-with
    (harness-add-filter 'permission/decide
                        (lambda (decision next request)
                          (funcall next (if (equal (plist-get request :tool) "glob")
                                            (list :behavior 'deny :final t :reason "the test refuses glob")
                                          decision)))
                        5)
    (harness-define-tool "grep" :label "Search files" :description "grep" :kind 'read :coalescable t
                         :handler (lambda (_input _ctx) (harness-tool-error "grep: no such file")))
    (let* ((harness-chat--coalesce-threshold 2)
           (sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (success (harness-ui-icon 'harness-icon-success))
           (caution (harness-ui-icon 'harness-icon-caution))
           (failure (harness-ui-icon 'harness-icon-failure)))
      ;; glob is denied, grep fails, bash runs.
      (harness-ui-chat-test-prompt buf "run the tools")
      (with-current-buffer buf
        (cl-flet ((check ()
                    (let* ((calls (harness-ui-chat-test-blocks buf "tool-call"))
                           (call (lambda (tool) (cl-find tool calls :test #'equal
                                                         :key (lambda (b) (plist-get (harness-chat-block-node b) :tool)))))
                           (glob (funcall call "glob"))
                           (grep (funcall call "grep"))
                           (bash (funcall call "bash")))
                      (should (eq 'denied (harness-ui-tool-outcome (harness-chat-block-result glob))))
                      (should (eq 'failed (harness-ui-tool-outcome (harness-chat-block-result grep))))
                      (should (eq 'ok (harness-ui-tool-outcome (harness-chat-block-result bash))))
                      ;; The old check mark, cross and circled slash are gone.
                      (dolist (b (list glob grep bash))
                        (should-not (string-match-p "[\N{U+2713}\N{U+2717}\N{U+2298}]"
                                                    (harness-ui-chat-test-block-text b))))
                      ;; The denied call: a yellow circle, its background, and
                      ;; the permission system's reason where output would be.
                      (let ((text (harness-ui-chat-test-block-text glob)))
                        (should (string-search (concat caution " denied") text))
                        ;; (Not "failed" anywhere: the temporary path in the
                        ;; title may hold that word.)
                        (should-not (string-search (concat failure " failed") text))
                        (should (string-match-p "^ *reason$" text))
                        (should-not (string-search "output (" text))
                        (should (string-search "Denied: the test refuses glob" text)))
                      (should (eq 'harness-caution-face
                                  (car (harness-ui-chat-test-faces-in glob (concat caution " denied")))))
                      (should (eq 'harness-caution-face (car (harness-ui-chat-test-faces-in glob "denied\n"))))
                      (should (memq 'harness-tool-denied-face (harness-ui-chat-test-faces-in glob "Find files")))
                      (should-not (memq 'harness-tool-error-face (harness-ui-chat-test-faces-in glob "Find files")))
                      ;; The failed call: a red triangle, a red status and background.
                      (let ((text (harness-ui-chat-test-block-text grep)))
                        (should (string-search (concat failure " failed") text))
                        (should-not (string-search (concat caution " denied") text))
                        (should (string-search "output (" text))
                        (should (string-search "grep: no such file" text)))
                      (should (eq 'harness-failure-face
                                  (car (harness-ui-chat-test-faces-in grep (concat failure " failed")))))
                      (should (eq 'harness-failure-face (car (harness-ui-chat-test-faces-in grep "failed\n"))))
                      (should (memq 'harness-tool-error-face (harness-ui-chat-test-faces-in grep "Search files")))
                      ;; The call that ran: a green circle, alone.
                      (should (string-search (concat success "\n") (harness-ui-chat-test-block-text bash)))
                      (should (eq 'harness-success-face
                                  (car (harness-ui-chat-test-faces-in bash (concat success "\n")))))
                      (should (memq 'harness-tool-face (harness-ui-chat-test-faces-in bash "Bash")))
                      ;; glob and grep fold into a group whose summary counts both.
                      (should (= 1 (hash-table-count harness-chat--groups)))
                      (let ((summary (harness-ui-chat-test-find buf "2 tool calls: Find files, Search files")))
                        (should summary)
                        (should (harness-ui-chat-test-find buf (concat failure " 1 failed") summary))
                        (should (harness-ui-chat-test-find buf (concat caution " 1 denied") summary))
                        (should (< (harness-ui-chat-test-find buf (concat caution " 1 denied") summary)
                                   (harness-ui-chat-test-find buf "[expand]" summary)))))))
          (check)
          ;; A redraw renders the same from the fetched history.
          (harness-chat-redraw)
          (harness-test-wait (lambda () (not harness-chat--loading)) 5 "redrawn")
          (check))))))

(ert-deftest harness-ui-chat-tool-status-reads-like-a-japanese-table ()
  ;; A green circle when the call ran, a yellow one while it runs or
  ;; when it was refused, a red triangle when it failed; the word after
  ;; the icon takes its colour.  A call left without a result once the
  ;; session stopped has a neutral dash.
  (harness-ui-chat-test-with
    (let ((status "running"))
      (cl-letf (((symbol-function 'harness-chat--session) (lambda () (list :status status))))
        (pcase-dolist (`(,result ,icon ,face ,word)
                       '((nil harness-icon-caution harness-caution-face "running")
                         ((:output "fine" :is-error :false) harness-icon-success harness-success-face nil)
                         ((:output "exit 1" :is-error t) harness-icon-failure harness-failure-face "failed")
                         ((:output "Denied: no" :is-error t :meta (:denied t))
                          harness-icon-caution harness-caution-face "denied")))
          (let ((s (harness-chat--tool-status result)))
            (should (equal (if word (concat (harness-ui-icon icon) " " word) (harness-ui-icon icon)) s))
            (should (eq face (get-text-property 0 'face s)))
            (should (eq face (get-text-property (1- (length s)) 'face s)))
            (should (stringp (get-text-property 0 'help-echo s)))))
        (setq status "idle")
        (let ((s (harness-chat--tool-status nil)))
          (should (equal "\N{U+2013} no result" s))
          (should (eq 'harness-dim-face (get-text-property 0 'face s))))))))

;;;; History

;; Markers still delimit every block exactly.
(defun harness-ui-chat-test-check-markers ()
  "Assert that the block markers of the current buffer tile the transcript."
  (let ((prev (marker-position harness-chat--transcript-start)))
    (dolist (id (reverse harness-chat--order))
      (let ((b (gethash id harness-chat--blocks)))
        (should (= prev (marker-position (harness-chat-block-start b))))
        (setq prev (marker-position (harness-chat-block-end b)))))
    (should (= prev (marker-position harness-chat--transcript-end)))))

(defun harness-ui-chat-test-oldest-content ()
  "Return the content of the oldest rendered node."
  (plist-get (harness-chat-block-node (gethash (car (last harness-chat--order)) harness-chat--blocks)) :content))

(ert-deftest harness-ui-chat-lazy-history ()
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session "Long"))
          (w (selected-window)))
      (dotimes (i 150) (harness-call 'session/hint sid (format "hint number %d" i)))
      (let ((buf (harness-ui-chat-test-open sid)))
        (with-current-buffer buf
          (should (= 60 (length harness-chat--order)))
          (should harness-chat--has-more)
          (should-not (harness-ui-chat-test-find buf "Show earlier messages"))
          (should (harness-ui-chat-test-find buf "hint number 90"))
          (should-not (harness-ui-chat-test-find buf "hint number 89"))
          (let ((pos (harness-ui-chat-test-find buf "hint number 149")))
            (should (harness-ui-chat-test-face-at (1- pos) 'harness-hint-face)))
          ;; Scrolling to the top loads the older page by itself.
          (set-window-buffer w buf)
          (set-window-start w (point-min))
          (set-window-point w (point-min))
          (harness-chat--manage-history))
        (harness-test-wait (lambda () (with-current-buffer buf (= 150 (length harness-chat--order)))) 5 "older page")
        (with-current-buffer buf
          (should-not harness-chat--has-more)
          (should (< (harness-ui-chat-test-find buf "hint number 0")
                     (harness-ui-chat-test-find buf "hint number 89")
                     (harness-ui-chat-test-find buf "hint number 90")
                     (harness-ui-chat-test-find buf "hint number 149")))
          (should (equal "hint number 0" (harness-ui-chat-test-oldest-content)))
          ;; The window still shows what it showed before the page arrived.
          (should (equal "hint number 90"
                         (plist-get (harness-chat-block-node
                                     (gethash (get-text-property (window-start w) 'harness-chat-node)
                                              harness-chat--blocks))
                                    :content)))
          (harness-ui-chat-test-check-markers))))))

(ert-deftest harness-ui-chat-history-unloads ()
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session "Long"))
          (w (selected-window))
          (kept nil)
          (harness-chat--history-limit 20)
          (harness-chat--history-page 20))
      (dotimes (i 100) (harness-call 'session/hint sid (format "hint number %d" i)))
      (let ((buf (harness-ui-chat-test-open sid)))
        (set-window-buffer w buf)
        ;; Keep scrolling to the top until the whole history is loaded.
        (harness-test-wait (lambda ()
                             (with-current-buffer buf
                               (set-window-start w (point-min))
                               (set-window-point w (point-min))
                               (harness-chat--manage-history)
                               (not harness-chat--has-more)))
                           10 "whole history")
        (with-current-buffer buf
          (should (= 100 (length harness-chat--order)))
          ;; Back at the bottom, all but a page of what lies above is dropped.
          (harness-chat-scroll-to-bottom)
          (harness-chat--manage-history)
          (should (< (length harness-chat--order) 100))
          (should harness-chat--has-more)
          (should-not (harness-ui-chat-test-find buf "hint number 0"))
          (should (harness-ui-chat-test-find buf "hint number 99"))
          (should (= (length harness-chat--order) (hash-table-count harness-chat--blocks)))
          (harness-ui-chat-test-check-markers)
          ;; Scrolling up again brings it back.
          (setq kept (length harness-chat--order))
          (set-window-start w (point-min))
          (set-window-point w (point-min))
          (harness-chat--manage-history))
        (harness-test-wait (lambda () (with-current-buffer buf (not harness-chat--fetching))) 5 "reloaded")
        (with-current-buffer buf
          (should (= (+ kept 20) (length harness-chat--order)))
          (harness-ui-chat-test-check-markers))))))

(ert-deftest harness-ui-chat-history-page-joins-split-results ()
  "A result whose call is on the page before it joins the call when that page loads.
The newest page can start with the result of a call made just before
it, which shows alone until the older page comes.  It used to stay
alone after that: the call said it had no result, and the stray block
split the run of reads around it, so part of the run stayed unfolded."
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session "Split"))
          (w (selected-window))
          (harness-chat--history-limit 5))
      (harness-call 'session/append sid (list :kind 'user :content "read them"))
      (dotimes (i 6)
        (let ((call (format "c%d" i)))
          (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id call
                                                  :input (list :path (format "f%d.el" i))
                                                  :title (format "Read file: f%d.el" i)))
          (harness-call 'session/append sid (list :kind 'tool-result :call-id call
                                                  :output (format "contents %d" i)))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (with-current-buffer buf
          ;; The newest five nodes start with the result of the fourth call.
          (should harness-chat--has-more)
          (should (equal "tool-result" (harness-chat-block-kind (gethash (harness-chat--oldest-id) harness-chat--blocks))))
          (set-window-buffer w buf)
          (set-window-start w (point-min))
          (set-window-point w (point-min))
          (harness-chat--manage-history))
        (harness-test-wait (lambda () (with-current-buffer buf (not harness-chat--has-more))) 5 "older page")
        (with-current-buffer buf
          (let ((calls (harness-ui-chat-test-blocks buf "tool-call"))
                (groups (harness-ui-chat-test-check-groups buf)))
            (should-not (harness-ui-chat-test-blocks buf "tool-result"))
            (should-not (harness-ui-chat-test-find buf "result of an earlier tool call"))
            (should-not (harness-ui-chat-test-find buf "no result"))
            (should (= 7 (length harness-chat--order)))
            (should (= 6 (length calls)))
            (should (equal "contents 3" (plist-get (harness-chat-block-result (nth 3 calls)) :output)))
            (should (cl-every #'harness-chat-block-result calls))
            (should-not harness-chat--unfinished)
            ;; Every node still finds its block: the result its call's.
            (should (= 13 (hash-table-count harness-chat--blocks)))
            ;; The six reads are one run, folded under one summary.
            (should (= 1 (length groups)))
            (should (equal (mapcar #'harness-chat-block-id calls)
                           (harness-chat-group-members (car groups))))
            (should (harness-ui-chat-test-find buf "6 tool calls"))))))))

;;;; Redraw and deletion

(ert-deftest harness-ui-chat-redraw-keeps-compose ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (harness-ui-chat-test-prompt buf "hello there")
      (harness-ui-chat-test-type buf "a draft in progress")
      (with-current-buffer buf
        (harness-compose-add-attachment (expand-file-name "harness-ui-chat-test.el" (expand-file-name "test" harness-test-root)))
        (should (harness-ui-chat-test-find buf "chat-test.el")))
      ;; Shown in a window, as a hidden chat is rebuilt once one shows it.
      (set-window-buffer (selected-window) buf)
      (let ((generation (buffer-local-value 'harness-chat--generation buf)))
        (run-hooks 'harness-ui-redraw-hook)
        (should (> (buffer-local-value 'harness-chat--generation buf) generation)))
      (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-chat--order))) 5 "redrawn")
      (with-current-buffer buf
        (should (equal "a draft in progress" (harness-compose-text)))
        (should (= 1 (length harness-compose-attachments)))
        (should (harness-ui-chat-test-find buf "hello there"))
        (should (harness-ui-chat-test-find buf "You said"))
        (should (harness-compose-in-p (point)))
        (let ((blocks (harness-compose-attachment-block (car harness-compose-attachments))))
          (should (equal "resource_link" (plist-get blocks :type)))
          (should (string-prefix-p "file://" (plist-get blocks :uri))))
        (harness-compose-remove-attachment (plist-get (car harness-compose-attachments) :path))
        (should (null harness-compose-attachments))))))

(ert-deftest harness-ui-chat-redraw-waits-for-a-window ()
  "A redraw rebuilds the chats windows show, and each other one once shown.
Every chat buffer fetched and rendered its whole transcript again at
once, even when nothing showed it, whenever the model catalogue came."
  (harness-ui-chat-test-with
    (harness-ui-chat-test-connect)
    (let* ((shown (harness-ui-chat-test-open (harness-ui-chat-test-session "Shown")))
           (hidden (harness-ui-chat-test-open (harness-ui-chat-test-session "Hidden")))
           (w (selected-window))
           (loads nil)
           (load (symbol-function 'harness-chat--load)))
      (harness-ui-chat-test-prompt hidden "hello there")
      (set-window-buffer w shown)
      (cl-letf (((symbol-function 'harness-chat--load)
                 (lambda (&rest args) (push (current-buffer) loads) (apply load args))))
        (run-hooks 'harness-ui-redraw-hook)
        (should (equal loads (list shown)))
        (should (buffer-local-value 'harness-chat--redraw-pending hidden))
        (should-not (buffer-local-value 'harness-chat--redraw-pending shown))
        ;; Shown, the other is rebuilt, from a timer (Emacs is redisplaying).
        (set-window-buffer w hidden)
        (with-current-buffer hidden
          (harness-chat--on-window-buffer-change w)
          (should-not harness-chat--redraw-pending))
        (should (equal loads (list shown)))
        (harness-test-wait (lambda () (memq hidden loads)) 5 "the hidden chat to be rebuilt")
        (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading hidden))) 5 "its load")
        ;; Once only.
        (with-current-buffer hidden (harness-chat--on-window-buffer-change w))
        (accept-process-output nil 0.05)
        (should (equal loads (list hidden shown)))
        (should (harness-ui-chat-test-find hidden "hello there"))))))

(ert-deftest harness-ui-chat-dropped-link-is-sent-as-an-image ()
  ;; A link dropped on a chat downloads behind a chip in the tail; the
  ;; message waits for it, then carries the image.
  (skip-unless (executable-find "curl"))
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (server (harness-test-http-serve
                    `(("/cat.png" 200 (("Content-Type" . "image/png")) ,harness-test-png :chunks 2 :delay 0.3)))))
      (unwind-protect
          (save-window-excursion
            (set-window-buffer (selected-window) buf)
            (dnd-handle-multiple-urls (selected-window) (list (harness-test-http-url server "/cat.png")) 'private)
            (with-current-buffer buf
              (should (text-property-not-all harness-chat--transcript-end (point-max) 'harness-compose-pending nil))
              (harness-ui-chat-test-type buf "what is this?")
              (should-error (harness-chat-send) :type 'user-error)
              (should (equal "what is this?" (harness-compose-text)))
              (harness-test-wait (lambda () (not (plist-get (car harness-compose-attachments) :pending))) 10 "the download")
              (should (harness-ui-chat-test-find buf "cat.png (")))
            (harness-ui-chat-test-prompt buf "")
            (let ((user (cl-find 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
              (should (cl-some (lambda (b) (equal "image" (plist-get b :type))) (plist-get user :blocks))))
            (with-current-buffer buf (should-not harness-compose-attachments)))
        (delete-process server)))))

(ert-deftest harness-ui-chat-session-deleted ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid)))
      (harness-call 'session/delete sid)
      (harness-test-wait (lambda () (with-current-buffer buf harness-chat--dead)) 5 "deleted")
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "session deleted"))
        (harness-ui-chat-test-type buf "anyone there?")
        (should-error (harness-chat-send) :type 'user-error)))))

(ert-deftest harness-ui-chat-send-functions-see-each-message ()
  ;; Every message sent or queued from the box runs
  ;; `harness-chat-send-functions' with its text as typed and its
  ;; attachments; a function that signals stops neither the message nor
  ;; the others.  A host can replace the empty box's usual hint.
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (file (expand-file-name "harness-ui-chat-test.el" (expand-file-name "test" harness-test-root)))
           (seen nil))
      (with-current-buffer buf
        (should (equal "Message\N{U+2026}" (harness-chat--placeholder)))
        (setq-local harness-chat-placeholder "Ask away")
        (should (equal "Ask away" (harness-chat--placeholder)))
        (add-hook 'harness-chat-send-functions (lambda (text atts) (push (list text atts) seen)) nil t)
        (add-hook 'harness-chat-send-functions (lambda (&rest _) (error "A broken hook")) nil t))
      (harness-ui-chat-test-prompt buf "  first message  ")
      (should (equal '(("first message" nil)) seen))
      (should (harness-ui-chat-test-find buf "first message"))
      (with-current-buffer buf
        (harness-ui-chat-test-type buf "for later")
        (harness-compose-add-attachment file)
        (harness-chat-queue))
      (should (equal "for later" (car (car seen))))
      (should (equal (list file) (mapcar (lambda (a) (plist-get a :path)) (cadr (car seen)))))
      (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :queue)) 5 "the queued message")
      ;; An answer to a question is not a message.
      (with-current-buffer buf
        (setq seen nil)
        (cl-letf (((symbol-function 'harness-chat--active-question) (lambda () (list :id "q1")))
                  ((symbol-function 'harness-chat--answer-question) #'ignore))
          (harness-ui-chat-test-type buf "red")
          (harness-chat-send)))
      (should-not seen))))

(ert-deftest harness-ui-chat-panel-functions-show-a-panel ()
  "A buffer-local panel function puts its string in the tail, read-only.
It runs on every render, right above the attachments and the box, and
buttons in it work.  Clearing the hook takes the panel away again."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (clicked nil))
      (with-current-buffer buf
        (should-not (harness-ui-chat-test-find buf "review banner"))
        (add-hook 'harness-chat-panel-functions
                  (lambda ()
                    (concat " review banner  "
                            (propertize "[Verify]" 'harness-chat-action (lambda () (setq clicked t)))
                            "\n"))
                  nil t)
        (harness-chat--render-tail)
        (let ((pos (harness-ui-chat-test-find buf "review banner")))
          (should pos)
          (should (< pos harness-compose-start))
          (should (harness-ui-chat-test-face-at pos 'harness-chat-panel-face))
          (should (get-text-property pos 'read-only))
          (goto-char (1- (harness-ui-chat-test-find buf "[Verify]")))
          (harness-chat-push))
        (should clicked)
        (setq-local harness-chat-panel-functions nil)
        (harness-chat--render-tail)
        (should-not (harness-ui-chat-test-find buf "review banner"))))))

(ert-deftest harness-ui-chat-send-function-takes-the-message ()
  "A buffer-local send function takes the box's message, not the session.
It gets the text and attachments as typed and the box empties; an answer
to a waiting question still goes through the question instead."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (file (expand-file-name "harness-ui-chat-test.el" (expand-file-name "test" harness-test-root)))
           (sent nil)
           (answers nil))
      (with-current-buffer buf
        (setq-local harness-chat-send-function (lambda (text atts) (push (list text atts) sent)))
        (harness-ui-chat-test-type buf "  looks good  ")
        (harness-compose-add-attachment file)
        (harness-chat-send)
        (should (equal "looks good" (car (car sent))))
        (should (equal (list file) (mapcar (lambda (a) (plist-get a :path)) (cadr (car sent)))))
        (should (equal "" (harness-compose-text)))
        (should-not harness-compose-attachments)
        ;; Nothing reached the session, not even a first message.
        (accept-process-output nil 0.2)
        (should-not (harness-call 'session/nodes sid))
        ;; An empty box still signals.
        (should-error (harness-chat-send) :type 'user-error)
        ;; A waiting question wins over the send function.
        (cl-letf (((symbol-function 'harness-chat--answer-question)
                   (lambda (pid answer) (push (list pid answer) answers)))
                  ((symbol-function 'harness-chat--remove-pending) #'ignore))
          (harness-chat--add-pending (list :id "q1" :kind "question" :question "Which?"))
          (harness-ui-chat-test-type buf "red")
          (harness-chat-send))
        (should (equal '(("q1" "red")) answers))
        (should (= 1 (length sent)))))))

(ert-deftest harness-ui-chat-shows-the-path-after-a-checkout ()
  "A chat whose session's head moves shows the path to the new head.
After a checkout at an earlier message, the branch left behind goes
from the buffer: it shows what the next message continues."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (first (plist-get (harness-call 'session/append sid '(:kind user :content "the first question")) :id))
           (reply (plist-get (harness-call 'session/append sid '(:kind assistant :content "the first answer")) :id)))
      (ignore first)
      (harness-call 'session/append sid '(:kind user :content "a question left behind"))
      (harness-call 'session/append sid '(:kind assistant :content "an answer left behind"))
      (let ((buf (harness-ui-chat-test-open sid)))
        (should (harness-ui-chat-test-find buf "an answer left behind"))
        (harness-call 'session/set-head sid reply)
        (harness-test-wait (lambda () (and (not (harness-ui-chat-test-find buf "left behind"))
                                           (not (buffer-local-value 'harness-chat--loading buf))))
                           5 "the chat to show the new path")
        (should (harness-ui-chat-test-find buf "the first question"))
        (should (harness-ui-chat-test-find buf "the first answer"))
        (with-current-buffer buf (should (harness-compose-live-p)))))))

(ert-deftest harness-ui-chat-inactive-session-reanimates-on-send ()
  ;; An inactive session opens as it is, with a notice and its compose box;
  ;; the first message sent from it resumes it and the notice goes away.
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session)))
      ;; The UI reopens the sessions of chat buffers that were open when it
      ;; connected; an inactive session is opened here, so wait for that
      ;; connect first or the hook would resume it, which this test is not
      ;; about (in the UI, a session cannot be opened before it connects).
      (harness-test-wait (lambda () (harness-ui-session sid)) 5 "UI connected")
      (harness-call 'session/deactivate sid)
      (harness-open-session sid)
      (let ((buf (harness-chat--buffer-for sid)))
        (harness-test-wait (lambda () (with-current-buffer buf
                                        (and (not harness-chat--loading) harness-compose-end harness-chat--inactive)))
                           5 "inactive session shown")
        (should (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
        (with-current-buffer buf
          (should (harness-compose-live-p))
          (should (harness-ui-chat-test-find buf "This session is inactive"))
          (should (string-match-p "resumes this session"
                                  (format "%s" (overlay-get harness-compose--placeholder 'before-string))))
          (should (string-match-p "inactive" (harness-chat--mode-line))))
        (harness-ui-chat-test-prompt buf "are you there?")
        (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
        (with-current-buffer buf
          (should-not harness-chat--inactive)
          (should-not (harness-ui-chat-test-find buf "This session is inactive"))
          (should (harness-ui-chat-test-find buf "are you there?")))))))

(ert-deftest harness-ui-chat-render-failure-keeps-compose ()
  ;; A block whose renderer signals shows unformatted; the blocks after it
  ;; and the compose box still draw (a Markdown bug once left none).
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session)))
      (harness-call 'session/append sid (list :kind 'user :content "hi"))
      (harness-call 'session/append sid (list :kind 'assistant :content "**bad** markdown"))
      (harness-call 'session/hint sid "after the bad block")
      (cl-letf (((symbol-function 'harness-ui-markdown-render)
                 (lambda (_text) (signal 'wrong-type-argument '(stringp nil)))))
        (let ((buf (harness-ui-chat-test-open sid)))
          (with-current-buffer buf
            (should (harness-compose-live-p))
            (should (harness-ui-chat-test-find buf "**bad** markdown"))
            (should (harness-ui-chat-test-find buf "shown unformatted"))
            (should (harness-ui-chat-test-find buf "after the bad block"))
            (harness-ui-chat-test-type buf "still works")
            (should (equal "still works" (harness-compose-text)))))))))

(ert-deftest harness-ui-chat-link-click-opens-it ()
  "A click on a link in a response opens it; the transcript stays as it was.
A URL goes to `browse-url', a file name opens beside the chat, taken in
the session's directory.  The click used to paste the primary selection
into the response where it landed, read-only as the transcript is."
  (harness-ui-chat-test-with
    (let* ((cwd (harness-test-temp-dir))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "demo:scripted") :id))
           (opened nil))
      (with-temp-file (expand-file-name "notes.md" cwd) (insert "one\ntwo\nthree\n"))
      (harness-call 'session/append sid '(:kind user :content "where is it written down?"))
      (harness-call 'session/append sid '(:kind assistant :content "In [the manual](https://www.gnu.org/software/emacs/manual/) and [the notes](notes.md#L2)."))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf (file-equal-p default-directory cwd)))
                           5 "the session's directory")
        (save-window-excursion
          (switch-to-buffer buf)
          (delete-other-windows)
          (let ((text (buffer-string)))
            (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened)))
                      ((symbol-function 'gui-get-primary-selection)
                       (lambda () "Open private configuration C-c f P")))
              (harness-test-click (harness-ui-chat-test-find buf "the man"))
              (should (equal '("https://www.gnu.org/software/emacs/manual/") opened))
              (harness-test-click (harness-ui-chat-test-find buf "the no")))
            (let ((notes (window-buffer (selected-window))))
              (unwind-protect
                  (progn
                    (should (equal (expand-file-name "notes.md" cwd) (buffer-file-name notes)))
                    (should (= 2 (with-current-buffer notes (line-number-at-pos))))
                    (should (eq buf (window-buffer (next-window)))))
                (unless (eq notes buf) (kill-buffer notes))))
            (with-current-buffer buf
              (should (equal text (buffer-string))))))))))

(ert-deftest harness-ui-chat-completion-sources ()
  (harness-ui-chat-test-with
    ;; Only projects are listed, so the session runs in a repository.
    (let* ((cwd (harness-test-temp-dir))
           (_ (let ((default-directory cwd)) (call-process "git" nil nil nil "init" "-q")))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "demo:scripted") :id))
           (buf (harness-ui-chat-test-open sid)))
      (with-temp-file (expand-file-name "notes.txt" cwd) (insert "x"))
      (with-current-buffer buf
        (setq harness-compose--files nil)
        (harness-compose-fetch-completions)
        (harness-test-wait (lambda () harness-compose--files) 5 "files fetched")
        (should (member "notes.txt" harness-compose--files))
        (harness-ui-chat-test-type buf "see @not")
        (let ((capf (harness-compose-completion-at-point)))
          (should capf)
          (should (= (nth 1 capf) (point)))
          (should (equal "not" (buffer-substring (nth 0 capf) (nth 1 capf))))
          (should (member "notes.txt" (all-completions "not" (nth 2 capf))))
          ;; The @ starts completion: popups needing a few characters show at once.
          (should (eq t (plist-get (nthcdr 3 capf) :company-prefix-length)))
          ;; Choosing a file turns the token into an attachment chip.
          (delete-region (nth 0 capf) (nth 1 capf))
          (insert "notes.txt")
          (funcall (plist-get (nthcdr 3 capf) :exit-function) "notes.txt" 'finished)
          (should (equal "see " (harness-compose-text)))
          (should (equal (expand-file-name "notes.txt" cwd) (plist-get (car harness-compose-attachments) :path)))
          (should (equal "text/plain" (plist-get (car harness-compose-attachments) :mime)))
          (should (harness-ui-chat-test-find buf "notes.txt (1 B)")))
        ;; A slash at the start completes skills; elsewhere it does not.
        (setq harness-compose--skills '("review" "deploy"))
        (harness-chat--clear-compose)
        (harness-ui-chat-test-type buf "/rev")
        (should (member "review" (all-completions "rev" (nth 2 (harness-compose-completion-at-point)))))
        (harness-chat--clear-compose)
        (harness-ui-chat-test-type buf "a /rev")
        (should-not (harness-compose-completion-at-point))
        (should (harness-compose-skill-reference-p "please /review this"))
        (should-not (harness-compose-skill-reference-p "a/review"))))))

(defun harness-ui-chat-test-matches (input table)
  "Return the candidates of TABLE that INPUT completes to, without properties."
  (let ((all (completion-all-completions input table nil (length input))))
    (when (consp all) (setcdr (last all) nil))
    (mapcar #'substring-no-properties all)))

(ert-deftest harness-ui-chat-completion-files-arrive-late ()
  ;; An @ token typed before the project's files are listed is offered
  ;; them once they are, by the table it already has, and the completion
  ;; UI is asked again: it found nothing the first time.
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (listing (harness-make-promise))
           (asked nil))
      (set-window-buffer (selected-window) buf)
      (with-current-buffer buf
        (setq harness-compose--files nil)
        (cl-letf (((symbol-function 'harness-files-list-limited) (lambda (&rest _) listing))
                  ((symbol-function 'harness-compose--corfu-delay) (lambda () 0.01))
                  ((symbol-function 'harness-compose--popup) (lambda () (push (harness-compose--token) asked))))
          (harness-ui-chat-test-type buf "see @harn")
          (let ((table (nth 2 (harness-compose-completion-at-point))))
            (should-not (harness-ui-chat-test-matches "" table))
            (harness-resolve listing '("notes.txt" "harness.el" "lisp/ui/harness-ui-compose.el"))
            ;; Part of a name finds files in subdirectories too.
            (should (equal '("harness.el" "lisp/ui/harness-ui-compose.el")
                           (sort (harness-ui-chat-test-matches "harn" table) #'string<)))
            (harness-test-wait (lambda () asked) 5 "the completion UI asked again")
            (should (equal '((9 . "@harn")) asked))))))))

(ert-deftest harness-ui-chat-completion-survives-redraws ()
  ;; Popups that show as you type (corfu, company) give up when the
  ;; buffer changed after the key, and a chat changes whenever its
  ;; session streams.  Once the token stops changing the box asks them
  ;; again, whatever changed outside it; a command that leaves the token
  ;; as it was, or leaves it, asks nothing.
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (asked nil))
      (set-window-buffer (selected-window) buf)
      (with-current-buffer buf
        (setq harness-compose--files '("notes.txt" "src/harness-thing.el"))
        (cl-letf (((symbol-function 'harness-compose--corfu-delay) (lambda () 0.05))
                  ((symbol-function 'harness-compose--popup) (lambda () (push (harness-compose--token) asked))))
          (harness-ui-chat-test-type buf "see @har")
          (harness-compose--after-command)
          (harness-chat--append-local-block "hint" "a reply streams in above the box")
          (harness-test-wait (lambda () asked) 5 "the completion UI asked again")
          (should (equal '((8 . "@har")) asked))
          (setq asked nil)
          (harness-compose--after-command)
          (insert "n")
          (harness-compose--after-command)
          (insert " ")
          (harness-compose--after-command)
          (accept-process-output nil 0.3)
          (should-not asked))))))

(ert-deftest harness-ui-chat-completion-popup-asks-idle-uis ()
  ;; The box asks corfu and company, each when it pops up as you type
  ;; and is not showing already, after the longest of their delays.
  (let ((calls nil))
    (with-temp-buffer
      (cl-letf (((symbol-function 'corfu-auto--complete-deferred) (lambda (&rest _) (push 'corfu calls)))
                ((symbol-function 'company-idle-begin)
                 (lambda (buf win tick pos)
                   (should (equal (list buf win tick pos)
                                  (list (current-buffer) (selected-window) (buffer-chars-modified-tick) (point))))
                   (push 'company calls))))
        (should-not (harness-compose--corfu-delay))
        (should-not (harness-compose--company-delay))
        (harness-compose--popup)
        (should-not calls)
        (setq-local corfu-mode t corfu-auto t corfu-auto-delay 0.2
                    company-mode t company-idle-delay (lambda () 0.3) company-candidates nil)
        (should (= 0.2 (harness-compose--corfu-delay)))
        (should (= 0.3 (harness-compose--company-delay)))
        (harness-compose--popup)
        (should (equal '(company corfu) calls))
        (setq calls nil)
        (let ((completion-in-region-mode t))
          (setq-local company-candidates '("notes.txt"))
          (harness-compose--popup))
        (should-not calls)
        ;; Company without an idle delay pops up only when asked to.
        (setq-local company-idle-delay nil company-candidates nil)
        (harness-compose--popup)
        (should (equal '(corfu) calls))))))

(ert-deftest harness-ui-chat-attach-command-finds-project-files ()
  ;; C-c C-a reads a project file by part of its name, from any
  ;; subdirectory, over the files @ completes; a listing still running
  ;; fills the candidates in.  With a prefix argument, or when the
  ;; project lists no files, any file is read instead.
  (harness-ui-chat-test-with
    (let* ((cwd (harness-test-temp-dir))
           (deep (expand-file-name "lisp/ui/harness-ui-compose.el" cwd))
           (_ (progn (let ((default-directory cwd)) (call-process "git" nil nil nil "init" "-q"))
                     (make-directory (file-name-directory deep) t)
                     (with-temp-file deep (insert ";; x"))
                     (with-temp-file (expand-file-name "notes.txt" cwd) (insert "x"))))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "demo:scripted") :id))
           (buf (harness-ui-chat-test-open sid))
           (other (make-temp-file "harness-attach-"))
           (seen nil))
      (unwind-protect
          (with-current-buffer buf
            (harness-test-wait (lambda () (member "lisp/ui/harness-ui-compose.el" harness-compose--files))
                               5 "files listed")
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt table &rest _)
                         (setq seen (list :category (completion-metadata-get (completion-metadata "" table nil) 'category)
                                          :matches (harness-ui-chat-test-matches "compose" table)))
                         (car (plist-get seen :matches))))
                      ((symbol-function 'read-file-name) (lambda (&rest _) (error "Browsed"))))
              (call-interactively #'harness-compose-add-attachment))
            (should (eq 'harness-compose-file (plist-get seen :category)))
            (should (equal '("lisp/ui/harness-ui-compose.el") (plist-get seen :matches)))
            (should (equal (list deep) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
            ;; The list is still being made: the candidates come once it is.
            (setq harness-compose--files nil harness-compose-attachments nil)
            (let ((listing (harness-make-promise)))
              (cl-letf (((symbol-function 'harness-files-list-limited) (lambda (&rest _) listing))
                        ((symbol-function 'completing-read)
                         (lambda (_prompt table &rest _)
                           (should-not (harness-ui-chat-test-matches "" table))
                           (harness-resolve listing '("notes.txt" "lisp/ui/harness-ui-compose.el"))
                           (car (harness-ui-chat-test-matches "notes" table))))
                        ((symbol-function 'read-file-name) (lambda (&rest _) (error "Browsed"))))
                (call-interactively #'harness-compose-add-attachment)))
            (should (equal (list (expand-file-name "notes.txt" cwd))
                           (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
            ;; Any file: with a prefix argument, or outside a project.
            (setq harness-compose-attachments nil)
            (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) other))
                      ((symbol-function 'completing-read) (lambda (&rest _) (error "Completed"))))
              (let ((current-prefix-arg '(4)))
                (call-interactively #'harness-compose-add-attachment))
              (should (equal (list other) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
              (setq harness-compose-attachments nil)
              (cl-letf (((symbol-function 'harness-files-list-limited) (lambda (&rest _) (harness-resolved nil))))
                (call-interactively #'harness-compose-add-attachment))
              (should (equal (list other) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))))
        (delete-file other)))))

(ert-deftest harness-ui-chat-test-compose-keys ()
  "C-c C-c sends, RET adds a newline, C-c C-k cancels."
  (should (eq (lookup-key harness-chat-mode-map (kbd "C-c C-c")) #'harness-chat-send))
  (should (eq (lookup-key harness-chat-mode-map (kbd "RET")) #'harness-compose-newline))
  (should (eq (lookup-key harness-chat-mode-map (kbd "C-c C-k")) #'harness-chat-cancel)))

(ert-deftest harness-ui-chat-segment-icons-not-highlighted ()
  ;; An SVG icon keeps its own background, so the hover highlight skips it.
  (let* ((icon (propertize " " 'display '(image :type svg :file "thinking.svg")))
         (seg (harness-chat--segment (concat icon " max") #'ignore "help")))
    (should-not (get-text-property 0 'mouse-face seg))
    (should (get-text-property 0 'local-map seg))
    (should (eq 'mode-line-highlight (get-text-property 2 'mouse-face seg)))))

(ert-deftest harness-ui-chat-menu-button-names-the-real-keys ()
  ;; `?' types into the compose box, so the [menu] tooltip tells the menu's
  ;; keys, and they follow a prefix moved off the default C-c h.
  (harness-ui-chat-test-with
    (let ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
          (w (selected-window))
          (prefix harness-ui-prefix-key))
      (set-window-buffer w buf)
      (with-current-buffer buf
        (goto-char harness-compose-end)
        (should (eq 'self-insert-command (key-binding "?")))
        (let* ((header (harness-chat--header))
               (pos (string-search "[menu]" header))
               (help (get-text-property pos 'help-echo header)))
          (should (functionp help))
          (should (equal "The harness menu (C-c h ?)" (funcall help w header pos)))
          (unwind-protect
              (progn
                (setopt harness-ui-prefix-key "C-c x")
                (should (eq 'harness-menu (key-binding (kbd "C-c x ?"))))
                (should (equal "The harness menu (C-c x ?)" (funcall help w header pos))))
            (setopt harness-ui-prefix-key prefix)))))))

;; Doom's solaire-mode bakes the buffer's base colour into every image,
;; which drew the icons of a tool block as dark boxes.
(ert-deftest harness-ui-chat-icons-show-face-background ()
  (cl-letf (((symbol-function 'icon-string)
             (lambda (_) (propertize " " 'display '(image :type svg :file "tool.svg" :background "#12111E" :scale 1))))
            (harness-ui--icons (make-hash-table :test 'equal)))
    (let ((spec (get-text-property 0 'display (harness-ui-icon 'harness-icon-tool))))
      (should (equal spec '(image :type svg :file "tool.svg" :scale 1))))))

(ert-deftest harness-ui-chat-summary-skips-title-values ()
  ;; The summary line leaves out what the title already shows.
  (should-not (harness-chat--input-summary '(:command "ls -la") "Bash: ls -la"))
  (should (equal (harness-chat--input-summary '(:pattern "defun" :glob "*.el") "Search files: defun in .")
                 "glob: *.el"))
  (should (equal (harness-chat--input-summary '(:question "Which?" :options ("A" "B")) "Question: Which?")
                 "options: A, B"))
  ;; Options with diagrams read as their labels.
  (should (equal (harness-chat--input-summary '(:question "Which?" :options ((:label "A" :diagram "+-+\n|A|")
                                                                            (:label "B" :image "b.png")))
                                              "ask_user Which?")
                 "options: A, B"))
  (let ((long "/home/someone/projects/a-rather-long-directory-name/sub"))
    (should-not (harness-chat--input-summary (list :path long) (concat "Find files: *.el in " long "/"))))
  (should (equal (harness-chat--input-summary '(:path "a.el")) "path: a.el"))
  ;; Other objects, the items of a todo list, read as their count, not as
  ;; a Lisp form: one the title already shows leaves no line at all.
  (let ((todos '((:id "1" :text "Read the code" :status "done")
                 (:id "2" :text "Fix it" :status "in-progress"))))
    (should-not (harness-chat--input-summary (list :todos todos) "Todo list: 2 items"))
    (should (equal (harness-chat--input-summary (list :todos (vconcat todos))) "todos: 2 items"))
    (should (equal (harness-chat--input-summary (list :todos (list (car todos)))) "todos: 1 item"))))

(ert-deftest harness-ui-chat-input-listing-of-objects ()
  "A list of objects in a tool's input, such as options with diagrams or
todos, lists one key per line rather than as a Lisp form."
  (harness-ui-chat-test-with
    (should (equal (harness-chat--format-objects '((:label "A" :diagram "+-+\n|A|\n+-+\n") "B" (:id "t1" :text "Read")))
                   "- label: A\n  diagram:\n    +-+\n    |A|\n    +-+\n- B\n- id: t1\n  text: Read\n"))
    (let ((listing (harness-chat--input-listing '(:question "Which?" :options ((:label "A" :image "a.png"))))))
      (should (string-match-p "^question: Which\\?\noptions:\n- label: A\n  image: a.png\n\\'" listing)))
    ;; Lists of plain values stay as they were.
    (should (equal (harness-chat--input-listing '(:options ("red" "green"))) "options: (\"red\" \"green\")\n"))))

(ert-deftest harness-ui-chat-reopens-shown-sessions-on-connect ()
  "A harness that starts again has every session closed; chat buffers
reopen the ones they showed open, and leave closed one they showed closed."
  (harness-ui-chat-test-with
    (let ((shown (harness-ui-chat-test-session "shown"))
          (hidden (harness-ui-chat-test-session "hidden"))
          (closed (harness-ui-chat-test-session "closed")))
      (harness-ui-chat-test-open shown)
      ;; Opened as it is: inactive until a message resumes it.
      (harness-call 'session/deactivate closed)
      (let ((buf (harness-ui-chat-test-open closed)))
        (harness-test-wait (lambda () (buffer-local-value 'harness-chat--inactive buf))
                           5 "the closed session shown closed"))
      ;; The harness goes away and starts again with every session closed,
      ;; as it loads them; the UI hears of it only as it connects again.
      (harness-acp-close harness-ui-connection)
      (harness-call 'session/deactivate shown)
      (harness-call 'session/deactivate hidden)
      (harness-ui-connect nil)
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get shown) :status)))
                         5 "the shown session to reopen")
      (should (eq 'inactive (plist-get (harness-call 'session/get hidden) :status)))
      (should (eq 'inactive (plist-get (harness-call 'session/get closed) :status))))))

(ert-deftest harness-ui-chat-connect-remote-and-back ()
  "Switching to a harness over TCP with a chat buffer open opens one
connection: what the buffer asks while it connects waits for it.  Going
back works too, a malformed address keeps the UI where it was, and the
connection let go of is never reported as closed."
  (harness-ui-chat-test-with
    (let* ((port (plist-get (harness-call 'acp/start :port 0) :port))
           (address (format "127.0.0.1:%d" port))
           (buf (harness-ui-chat-test-open (harness-ui-chat-test-session "remote")))
           (tcp-connects 0)
           (messages nil)
           (count-connects (lambda (connect &optional to)
                             (prog1 (funcall connect to)
                               (when to (cl-incf tcp-connects)))))
           (record (lambda (format-string &rest args)
                     (when format-string (push (apply #'format format-string args) messages))))
           ;; Reloaded: a failed load shows an error in place of the transcript.
           (loaded (lambda ()
                     (with-current-buffer buf
                       (and (not harness-chat--loading) harness-compose-end
                            (harness-ui-chat-test-find buf "are you remote?")
                            t)))))
      (advice-add 'harness-acp-connect :around count-connects)
      (advice-add 'message :before record)
      (unwind-protect
          (progn
            (harness-ui-chat-test-prompt buf "are you remote?")
            (harness-test-wait loaded 5 "the first turn shown")
            (harness-connect-remote address)
            (should (equal address harness-ui-connection-address))
            ;; The chat buffer reloads over the new connection as it connects.
            (harness-test-wait loaded 5 "the chat reloaded over TCP")
            (should (listp (harness-test-await (harness-ui-request "_harness/session/list"))))
            (should (eq 'tcp (harness-acp-connection-kind harness-ui-connection)))
            (should (= 1 tcp-connects))
            (should-not (harness-ui-chat-test-find buf "could not load the session"))
            ;; Back to the harness in this Emacs.
            (let ((harness-process nil)) (harness-connect-remote ""))
            (should-not harness-ui-connection-address)
            (should (eq 'local (harness-acp-connection-kind harness-ui-connection)))
            (should (listp (harness-test-await (harness-ui-request "_harness/session/list"))))
            (harness-test-wait loaded 5 "the chat reloaded in-process")
            ;; No port: nothing to connect to, so the UI stays with this harness.
            (should-error (harness-connect-remote "localhost") :type 'user-error)
            (should-not harness-ui-connection-address)
            (should (listp (harness-test-await (harness-ui-request "_harness/session/list"))))
            (harness-test-wait loaded 5 "the chat reloaded after the failed switch")
            (should (= 1 tcp-connects))
            (accept-process-output nil 0.2)
            (should-not (cl-find-if (lambda (m) (string-match-p "connection closed\\|initialize failed" m))
                                    messages)))
        (advice-remove 'message record)
        (advice-remove 'harness-acp-connect count-connects)
        (harness-call 'acp/stop)
        ;; Whatever failed, the next test's UI connects in-process.
        (setq harness-ui-connection-address nil)))))

(ert-deftest harness-ui-chat-session-record-applies-while-loading ()
  "The session record is no transcript: a change of it that arrives while
the transcript reloads (every buffer does, after a reload or a
reconnect) applies at once instead of being dropped.  A deletion that
arrives meanwhile applies once the transcript is in."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Loading"))
           (buf (harness-ui-chat-test-open sid)))
      (with-current-buffer buf
        (let ((session (copy-sequence harness-chat--session)))
          (setq harness-chat--loading t)
          (harness-chat--on-update sid (list :sessionUpdate "_harness/session"
                                             :session (plist-put session :queue '((:id "q1" :text "next")))))
          (should (equal '((:id "q1" :text "next")) harness-chat--queue))
          (should-not harness-chat--deferred)
          (setq harness-chat--loading nil))
        (harness-chat--load)
        (should harness-chat--loading)
        (harness-chat--on-update sid '(:sessionUpdate "_harness/session_deleted"))
        (should-not harness-chat--dead)
        (harness-test-wait (lambda () (not harness-chat--loading)) 5 "the transcript loaded")
        (should harness-chat--dead)))))

(ert-deftest harness-ui-chat-hl-line-skips-compose ()
  ;; hl-line would paint over the compose background, so it stops short of it.
  (harness-ui-chat-test-with
    (let ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session))))
      (with-current-buffer buf
        (goto-char (point-min))
        (should (harness-compose-hl-line-range))
        (goto-char harness-compose-end)
        (let ((range (harness-compose-hl-line-range)))
          (should (consp range))
          (should (= (car range) (cdr range))))))))

(declare-function harness-compose-unscroll "harness-ui-compose")
(declare-function harness-compose-pad-window "harness-ui-compose")

(ert-deftest harness-ui-chat-compose-wraps ()
  "The box wraps long lines, also in a side window, and never scrolls sideways."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window))
           (side (split-window window 40 'right)))
      (unwind-protect
          (with-current-buffer buf
            (set-window-buffer side buf)
            ;; Narrower than `truncate-partial-width-windows', which would truncate.
            (should (< (window-total-width side) (default-value 'truncate-partial-width-windows)))
            (should-not truncate-partial-width-windows)
            (harness-ui-chat-test-type buf (mapconcat #'identity (make-list 40 "word") " "))
            (should (> (count-screen-lines harness-compose-start harness-compose-end t side) 3))
            (should (equal "  " (get-char-property (1- harness-compose-end) 'wrap-prefix)))
            (set-window-hscroll side 5)
            (harness-compose-unscroll side)
            (should (= 0 (window-hscroll side))))
        (delete-window side)))))

(ert-deftest harness-ui-chat-compose-c-a-c-k-clears ()
  "C-a stops after the prompt, so C-a C-k clears the box."
  (harness-ui-chat-test-with
    (harness-test-compose-c-a-c-k (harness-ui-chat-test-open (harness-ui-chat-test-session)))))

(ert-deftest harness-ui-chat-box-stays-at-the-bottom ()
  "A box grown past the window keeps its last line above the window's spare last line."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window)))
      (set-window-buffer window buf)
      (with-current-buffer buf
        (harness-ui-chat-test-type buf (mapconcat #'identity (make-list 40 "a line") "\n"))
        (set-window-point window (point))
        (harness-compose-pad-window window)
        (should (> (window-start window) (point-min)))
        (should (= (- (window-body-height window t) (frame-char-height))
                   (cdr (window-text-pixel-size window (window-start window) harness-compose-end))))))))

(ert-deftest harness-ui-chat-todos-show-in-header-and-panel ()
  "A session's todo list is conspicuous without opening its tool block:
a progress segment in the header, the items in a panel above the box."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session "Todos"))
           (buf (harness-ui-chat-test-open sid)))
      (harness-call 'session/set-todos sid
                    '((:id "1" :text "Survey the project" :status "done")
                      (:id "2" :text "Make the change" :status "in-progress")
                      (:id "3" :text "Check the result" :status "pending")))
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (and harness-chat--todos
                                           (harness-ui-chat-test-find buf "Check the result"))))
                         5 "the todo list to show")
      (with-current-buffer buf
        ;; The header names the progress and the item in hand.
        (let* ((header (harness-chat--header))
               (segment (harness-ui-chat-test-segment header #'harness-chat-toggle-todos)))
          (should segment)
          (should (string-match-p "1/3" (car segment)))
          (should (string-match-p "Make the change" (car segment)))
          (let ((help (get-text-property (cadr segment) 'help-echo header)))
            (should (string-match-p "\\[x\\] Survey the project" help))
            (should (string-match-p "\\[~\\] Make the change" help))
            (should (string-match-p "\\[ \\] Check the result" help))))
        ;; The panel shows every item; the one in progress is bold.
        (should (harness-ui-chat-test-find buf "Survey the project"))
        (should (harness-ui-chat-test-find buf "Check the result"))
        (should (harness-ui-chat-test-face-at
                 (1- (harness-ui-chat-test-find buf "Make the change")) 'bold))
        ;; Folding leaves the title line; unfolding brings the items back.
        (harness-chat-toggle-todos)
        (should-not (harness-ui-chat-test-find buf "Check the result"))
        (should (harness-ui-chat-test-find buf "1/3"))
        (harness-chat-toggle-todos)
        (should (harness-ui-chat-test-find buf "Check the result"))
        ;; Clearing the list takes the segment and the panel away.
        (harness-call 'session/set-todos sid nil)
        (harness-test-wait (lambda () (with-current-buffer buf (null harness-chat--todos)))
                           5 "the list to clear")
        (with-current-buffer buf
          (should-not (harness-ui-chat-test-segment (harness-chat--header)
                                                    #'harness-chat-toggle-todos))
          (should-not (harness-ui-chat-test-find buf "Check the result")))))))

(ert-deftest harness-ui-chat-todos-follow-todo-write ()
  "The demo work script's `todo_write' calls keep the view current:
the panel ends on the finished list, and it agrees with the session's
own, which the task board shows."
  (harness-ui-chat-test-with
    ;; The tool that replaces the list; the harness serves it in production.
    (harness-test-load-module 'tools-agent)
    (let* ((sid (harness-ui-chat-test-session "Work"))
           (buf (harness-ui-chat-test-open sid)))
      (harness-ui-chat-test-prompt buf "please work through this project")
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (equal 3 (length harness-chat--todos))))
                         5 "the finished todo list")
      (with-current-buffer buf
        (should (equal '("done" "done" "done")
                       (mapcar (lambda (item) (plist-get item :status)) harness-chat--todos)))
        (should (string-match-p "3/3" (harness-chat--header)))
        (should (harness-ui-chat-test-find buf "Survey the project"))
        (should (harness-ui-chat-test-find buf "Check the result"))
        ;; What the view shows is the session's list, item for item.
        (should (equal (mapcar (lambda (item) (plist-get item :text))
                               (plist-get (harness-ui-session sid) :todos))
                       (mapcar (lambda (item) (plist-get item :text)) harness-chat--todos)))))))

(ert-deftest harness-ui-chat-todos-take-the-plan-update ()
  "An ACP `plan' update alone fills the header and the panel.
It is the live signal of a `todo_write' call, with ACP's own status
spellings; the chat used to drop it.  A long list is capped."
  (harness-ui-chat-test-with
    (let ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session "Plan"))))
      (with-current-buffer buf
        (harness-chat--on-plan
         (list :entries (append (list (list :content "item 1" :status "completed")
                                      (list :content "item 2" :status "in_progress"))
                                (cl-loop for i from 3 to 25
                                         collect (list :content (format "item %d" i) :status "pending")))))
        (should (equal 25 (length harness-chat--todos)))
        (let ((header (harness-chat--header)))
          (should (string-match-p "1/25" header))
          (should (string-match-p "item 2" header)))
        ;; The panel lists the cap, then counts the rest.
        (should (harness-ui-chat-test-find buf "item 20"))
        (should (harness-ui-chat-test-find buf "… 5 more"))
        (should-not (harness-ui-chat-test-find buf "item 21"))))))
(ert-deftest harness-ui-chat-box-grows-past-a-short-window ()
  "A box grown past the window stays above its spare line, point in it.
Measured as on a graphical frame, a transcript whose line at the
window's bottom is tall, an image say, once seemed to fit: the window
was forced back to the top, and redisplay moved point out of the box."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window)))
      (set-window-buffer window buf)
      (harness-test-compose-grows-past-the-window buf window 1))))

;;;; The fullscreen layout

(defvar harness-ui--fullscreen-layouts)
(declare-function harness-ui--fullscreen-layout "harness-ui")
(declare-function harness-ui--main-window "harness-ui")

(ert-deftest harness-ui-chat-fullscreen-keeps-the-session-in-sight ()
  "The session in sight shows beside an overview that takes the fullscreen
layout, and C-c C-z there buries it, back to the user's buffer."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (file (get-buffer-create "fullscreen chat test file"))
           (view (get-buffer-create "*harness fullscreen chat test view*")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer file)
            (let ((main (selected-window)))
              (harness-ui-display-buffer buf 'right)
              ;; An overview with no session of its own to show.
              (with-current-buffer view (setq-local harness-ui-overview-function #'ignore))
              (harness-ui-display-buffer view 'fullscreen)
              (should (eq buf (window-buffer main)))
              (should (= 2 (length (window-list))))
              (select-window main)
              (should (eq 'harness-ui-bury (key-binding (kbd "C-c C-z"))))
              (call-interactively (key-binding (kbd "C-c C-z")))
              (should (eq file (window-buffer main)))
              (should (harness-ui--fullscreen-layout))))
        (clrhash harness-ui--fullscreen-layouts)
        (let ((ignore-window-parameters t))
          (ignore-errors (delete-other-windows (harness-ui--main-window))))
        (kill-buffer file)
        (kill-buffer view)))))

(ert-deftest harness-ui-chat-redisplay-does-not-measure-a-huge-line ()
  "The redisplay helper answers without looking at a huge line whole.
A chat line can be megabytes long (a model wrote a whole file, or an
error carried a request body), and measuring it on every redisplay is
what made redisplay expensive; the helper looks a bounded distance
either way along the line instead."
  (with-temp-buffer
    (insert "short line\n")
    (should (harness-chat--line-at-most-p (point-min) 10000))
    (erase-buffer)
    (insert (make-string 5000 ?x) "\n" "tail\n")
    (should (harness-chat--line-at-most-p 1 10000))
    (erase-buffer)
    (insert (make-string 40000 ?x) "\n" "tail\n")
    ;; Anywhere on the huge line, from either end.
    (should-not (harness-chat--line-at-most-p 1 10000))
    (should-not (harness-chat--line-at-most-p 20000 10000))
    (should-not (harness-chat--line-at-most-p 40000 10000))
    ;; The line after it is ordinary again.
    (should (harness-chat--line-at-most-p 40002 10000))))

(ert-deftest harness-ui-chat-redisplay-leaves-a-huge-line-alone ()
  "A line too long to show whole is left where it is.
Asking redisplay to bring such a line fully into view would rescan it on
every redisplay; the window, not scrolled, is told yes only for a line
it can show."
  (harness-ui-chat-test-with
    (let* ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
           (window (selected-window))
           (huge (get-buffer-create " *harness-chat-huge-line*")))
      (unwind-protect
          (progn
            (with-current-buffer huge
              (insert (make-string 40000 ?x) "\n" "tail\n")
              (goto-char (point-min)))
            (set-window-buffer window huge)
            (set-window-point window (point-min))
            (should-not (harness-chat--cursor-line-fully-visible window))
            (with-current-buffer buf (goto-char (point-min)))
            (set-window-buffer window buf)
            (set-window-point window (point-min))
            (should (harness-chat--cursor-line-fully-visible window)))
        (set-window-buffer window buf)
        (kill-buffer huge)))))

(provide 'harness-ui-chat-test)
;;; harness-ui-chat-test.el ends here
