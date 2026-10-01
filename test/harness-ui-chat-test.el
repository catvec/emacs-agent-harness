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

(defvar harness-ui-chat-test-events nil "Recorded (EVENT . ARGS), newest first.")

(defun harness-ui-chat-test-record-event (event args)
  "Record EVENT with ARGS."
  (push (cons event args) harness-ui-chat-test-events))

(defmacro harness-ui-chat-test-with (&rest body)
  "Load the state layer, the demo provider, ACP and the chat UI, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-ui-chat-test-events nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (name '("list_dir" "read_file" "glob" "grep"))
         (harness-define-tool name :description name :kind 'read :coalescable t
                              :title (let ((n name)) (lambda (input) (format "%s %s" n (or (plist-get input :path) (plist-get input :pattern) ""))))
                              :handler (let ((n name)) (lambda (input _ctx) (format "%s of %s" n (plist-get input :path))))))
       (harness-define-tool "bash" :description "bash" :kind 'exec
                            :handler (lambda (input _ctx) (format "ran %s" (plist-get input :command))))
       (harness-define-tool "ask_user" :description "ask" :kind 'meta
                            :handler (lambda (input _ctx) (format "answer to %s: red" (plist-get input :question))))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
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
          (should (string-match-p "list_dir" (plist-get (harness-chat-block-node (car tools)) :title)))
          (should-not (harness-ui-chat-test-blocks buf "tool-result"))
          (let ((title-pos (harness-ui-chat-test-find buf "list_dir")))
            (should (harness-ui-chat-test-face-at (1- title-pos) 'harness-tool-face)))
          (should (harness-ui-chat-test-find buf "✓"))
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
        (let ((header (harness-chat--header)))
          (should (string-match-p "Tour" header))
          (should (string-match-p "demo" header))
          (should (string-match-p "\\$0.0042" header))
          (should (string-match-p "2.0k/" header)))
        (should (string-match-p "idle" (harness-chat--mode-line)))
        (should (equal "" (harness-compose-text)))))))

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

;;;; Pending panel

(ert-deftest harness-ui-chat-permission-panel ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (respond (lambda (r) (push r answers)))
           (params (list :sessionId sid
                         :toolCall (list :toolCallId "c1" :title "bash ls -la" :kind "execute"
                                         :rawInput '(:command "ls -la"))
                         :options harness-acp--permission-options
                         :_harness (list :pendingId "p1" :tool "bash" :paths '("/tmp") :reason "exec asks"))))
      ;; A request for another session is not ours.
      (should-not (harness-chat--on-permission (plist-put (copy-sequence params) :sessionId "other") respond))
      (should (harness-chat--on-permission params respond))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "Permission"))
        (should (harness-ui-chat-test-find buf "bash ls -la"))
        (should (harness-ui-chat-test-find buf "kind: execute"))
        (should (harness-ui-chat-test-find buf "/tmp"))
        (should (harness-ui-chat-test-find buf "exec asks"))
        (let ((pos (harness-ui-chat-test-find buf "[Allow]")))
          (should (harness-ui-chat-test-face-at (1- pos) 'harness-chat-panel-face))
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

(ert-deftest harness-ui-chat-directory-permission-panel ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (buf (harness-ui-chat-test-open sid))
           (answers nil)
           (params (list :sessionId sid
                         :toolCall (list :toolCallId "c1" :title "Access ~/notes/" :kind "read"
                                         :rawInput '(:path "~/notes/todo.org"))
                         :options harness-acp--dir-permission-options
                         :_harness (list :pendingId "d1" :tool "read_file" :dir "/home/u/notes/"
                                         :reason "read_file wants ~/notes/todo.org, which is outside the allowed directories"))))
      (should (harness-chat--on-permission params (lambda (r) (push r answers))))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "Access ~/notes/"))
        (should (harness-ui-chat-test-find buf "outside the allowed directories"))
        (should (harness-ui-chat-test-find buf "[Allow directory for session]"))
        (should (harness-ui-chat-test-find buf "[Always allow directory]"))
        (should-not (harness-ui-chat-test-find buf "[Always deny]"))
        (goto-char (1- (harness-ui-chat-test-find buf "[Allow directory for session]")))
        (harness-chat-push)
        (should (equal "allow-session" (plist-get (plist-get (car answers) :outcome) :optionId)))
        (should (null harness-chat--pending))))))

(ert-deftest harness-ui-chat-directory-request-panel ()
  "An agent's own directory request offers no \"Allow once\"."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil)
           (labels (lambda (r) (mapcar #'car (harness-chat--permission-buttons r)))))
      ;; Without options every button of the kind is offered.
      (should (equal '("Allow" "Allow for session" "Always allow" "Deny" "Always deny")
                     (funcall labels '(:kind "permission"))))
      (should (equal '("Allow once" "Allow directory for session" "Always allow directory" "Deny")
                     (funcall labels '(:dir "/d/"))))
      ;; Option ids as symbols (in process), strings or a vector (from the
      ;; wire), or ACP option plists all narrow the buttons.
      (dolist (options (list '(allow-session allow-always deny-once)
                             '("allow-session" "allow-always" "deny-once")
                             (vector "allow-session" "allow-always" "deny-once")
                             (harness-acp--offered-options '(:dir "/d/" :options (allow-session allow-always deny-once)))))
        (should (equal '("Allow directory for session" "Always allow directory" "Deny")
                       (funcall labels (list :dir "/d/" :options options)))))
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
                                         :title "Access ~/src/other/"
                                         :reason "The agent asks for access: read the API types"
                                         :options '(allow-session allow-always deny-once))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "Access ~/src/other/"))
          (should (harness-ui-chat-test-find buf "The agent asks for access: read the API types"))
          (should (harness-ui-chat-test-find buf "[Allow directory for session]"))
          (should (harness-ui-chat-test-find buf "[Always allow directory]"))
          (should (harness-ui-chat-test-find buf "[Deny]"))
          (should-not (harness-ui-chat-test-find buf "[Allow once]"))
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow directory]")))
          (harness-chat-push))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "req" "allow-always") (car recorded)))))))

(ert-deftest harness-ui-chat-existing-pending-item-offers-buttons ()
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil))
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded) answer))
      (harness-call 'session/pending-add sid (list :id "pre" :kind 'permission
                                                   :payload (list :tool "bash" :title "bash echo" :kind 'exec
                                                                  :input '(:command "echo"))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "bash echo"))
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow]")))
          (harness-chat-push))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "pre" "allow-always") (car recorded)))))))

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
        (call-interactively (lookup-key (get-text-property (point) 'keymap) "2"))
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
               (summary (harness-ui-chat-test-find buf "5 tool calls: read_file ×3, grep, glob"))
               (first (gethash (car (harness-chat-group-members group)) harness-chat--blocks)))
          (should summary)
          (should (= 5 (length (harness-chat-group-members group))))
          (should (invisible-p (harness-chat-block-start first)))
          (should (invisible-p (harness-ui-chat-test-find buf "read_file c.el")))
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
        (should (harness-ui-chat-test-find buf "5 tool calls: read_file ×3, grep, glob"))))))

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
          (harness-chat-history-limit 20)
          (harness-chat-history-page 20))
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
      (run-hooks 'harness-ui-redraw-hook)
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

(ert-deftest harness-ui-chat-inactive-session-reanimates-on-send ()
  ;; An inactive session opens as it is, with a notice and its compose box;
  ;; the first message sent from it resumes it and the notice goes away.
  (harness-ui-chat-test-with
    (let ((sid (harness-ui-chat-test-session)))
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
  ;; keys, and they follow a prefix moved off the default C-c a.
  (harness-ui-chat-test-with
    (let ((buf (harness-ui-chat-test-open (harness-ui-chat-test-session)))
          (w (selected-window)))
      (set-window-buffer w buf)
      (with-current-buffer buf
        (goto-char harness-compose-end)
        (should (eq 'self-insert-command (key-binding "?")))
        (let* ((header (harness-chat--header))
               (pos (string-search "[menu]" header))
               (help (get-text-property pos 'help-echo header)))
          (should (functionp help))
          (should (equal "The harness menu (C-c a ?)" (funcall help w header pos)))
          ;; What `harness-ui-prefix-key' set to C-c h amounts to.
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c h") harness-ui-map)
            (setq-local minor-mode-overriding-map-alist (list (cons 'harness-global-mode map)))
            (should (eq 'harness-menu (key-binding (kbd "C-c h ?"))))
            (should (equal "The harness menu (C-c h ?)" (funcall help w header pos)))))))))

;; Doom's solaire-mode bakes the buffer's base colour into every image,
;; which drew the icons of a tool block as dark boxes.
(ert-deftest harness-ui-chat-icons-show-face-background ()
  (cl-letf (((symbol-function 'icon-string)
             (lambda (_) (propertize " " 'display '(image :type svg :file "tool.svg" :background "#12111E" :scale 1)))))
    (let ((spec (get-text-property 0 'display (harness-ui-icon 'harness-icon-tool))))
      (should (equal spec '(image :type svg :file "tool.svg" :scale 1))))))

(ert-deftest harness-ui-chat-summary-skips-title-values ()
  ;; The summary line leaves out what the title already shows.
  (should-not (harness-chat--input-summary '(:command "ls -la") "bash ls -la"))
  (should (equal (harness-chat--input-summary '(:pattern "defun" :glob "*.el") "grep defun in .")
                 "glob: *.el"))
  (should (equal (harness-chat--input-summary '(:question "Which?" :options ("A" "B")) "ask_user Which?")
                 "options: A, B"))
  (let ((long "/home/someone/projects/a-rather-long-directory-name/sub"))
    (should-not (harness-chat--input-summary (list :path long) (concat "glob *.el in " long "/"))))
  (should (equal (harness-chat--input-summary '(:path "a.el")) "path: a.el")))

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

(provide 'harness-ui-chat-test)
;;; harness-ui-chat-test.el ends here
