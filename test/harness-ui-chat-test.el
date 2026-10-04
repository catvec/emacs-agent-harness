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
(declare-function harness-provider-claude-close-all "harness-provider-claude")

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
          (should (string-match-p "2.0k/" header)))
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
               (lambda (name) (propertize " " 'display (list 'image :type 'svg :file (format "%s.svg" name))))))
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
                                         :reason "Read file wants ~/notes/todo.org, which is outside the allowed directories"))))
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
      (should (equal '("Allow once" "Allow directory for session" "Always allow directory" "Deny"
                       "Always deny directory")
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
                           :options harness-acp--dir-permission-options
                           :_harness (list :pendingId pid :tool "read_file" :dir (expand-file-name "~/notes/")
                                           :pattern (expand-file-name "~/notes/**")
                                           :paths (list (expand-file-name "~/notes/todo.org"))
                                           :reason "Read file wants ~/notes/todo.org, which is outside the allowed directories")))))
      (should (harness-chat--on-permission (funcall params "d1") respond))
      (with-current-buffer buf
        (should (harness-ui-chat-test-find buf "pattern: ~/notes/**  [Edit] e"))
        ;; A directory prompt's buttons speak of the pattern, not of a directory.
        (should (harness-ui-chat-test-find buf "[Allow once] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N"))
        ;; e on the panel edits it, from the pattern shown; M-n offers others.
        (goto-char (harness-ui-chat-test-find buf "Permission"))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt initial _history defaults)
                     (should (equal "~/notes/**" initial))
                     (should (equal '("~/notes/todo.org" "~/notes/*.org" "~/notes/**" "~/**") defaults))
                     " ~/notes/*.org ")))
          (call-interactively (lookup-key harness-chat-panel-map (kbd "e"))))
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
        ;; Without a request about paths there is nothing to edit.
        (harness-chat--on-permission (list :sessionId sid :toolCall '(:toolCallId "c3" :title "Bash: ls" :kind "execute")
                                           :options harness-acp--permission-options
                                           :_harness '(:pendingId "p3" :tool "bash"))
                                     respond)
        (should-not (harness-ui-chat-test-find buf "pattern:"))
        (should-error (harness-chat-edit-permission-pattern) :type 'user-error)))))

(ert-deftest harness-ui-chat-tool-permission-pattern ()
  "A tool call's prompt says which answers its pattern is remembered for."
  (harness-ui-chat-test-with
    (let* ((sid (harness-ui-chat-test-session))
           (recorded nil))
      (harness-register-method 'permission/answer
                               (lambda (session-id pending-id answer)
                                 (push (list session-id pending-id answer) recorded)
                                 (harness-call 'session/pending-resolve session-id pending-id answer)
                                 answer))
      (harness-call 'session/pending-add sid
                    (list :id "w1" :kind 'permission
                          :payload (list :tool "write_file" :kind 'write :title "Write file: lisp/a.el"
                                         :input '(:path "lisp/a.el")
                                         :paths (list (expand-file-name "~/proj/lisp/a.el"))
                                         :pattern (expand-file-name "~/proj/lisp/**")
                                         :options '(allow-once allow-session allow-always deny-once deny-always))))
      (let ((buf (harness-ui-chat-test-open sid)))
        (harness-test-wait (lambda () (with-current-buffer buf harness-chat--pending)) 5 "pending rendered")
        (with-current-buffer buf
          (should (harness-ui-chat-test-find buf "pattern: ~/proj/lisp/**  [Edit] e   s, a, N remember the answer for it"))
          (should (harness-ui-chat-test-find buf "[Allow] y  [Allow for session] s"))
          ;; C-c C-p edits it from the compose box.
          (goto-char harness-compose-end)
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "~/proj/**")))
            (call-interactively (lookup-key harness-chat-mode-map (kbd "C-c C-p"))))
          (should (harness-ui-chat-test-find buf "pattern: ~/proj/** (edited)"))
          (goto-char (1- (harness-ui-chat-test-find buf "[Always allow]")))
          (harness-chat-push))
        (harness-test-wait (lambda () recorded) 5 "answered through the method")
        (should (equal (list sid "w1" '(:option "allow-always" :pattern "~/proj/**")) (car recorded)))))))

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
             (lambda (_) (propertize " " 'display '(image :type svg :file "tool.svg" :background "#12111E" :scale 1)))))
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
  (should (equal (harness-chat--input-summary '(:path "a.el")) "path: a.el")))

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

(provide 'harness-ui-chat-test)
;;; harness-ui-chat-test.el ends here
