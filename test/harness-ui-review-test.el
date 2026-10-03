;;; harness-ui-review-test.el --- Tests for the review banner and report popout  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task in review, in its own session and on its board: the banner
;; above the compose box that verifies or sends the work back, and the
;; report popout that shows the final message and the evidence.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-chat--loading)
(defvar harness-chat--transcript-end)
(defvar harness-compose-redraw-function)
(defvar harness-ui-popout-key)
(defvar harness-ui-review-minor-mode)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-ui-report-popout "harness-ui-report")
(declare-function harness-ui-report-string "harness-ui-report")
(declare-function harness-ui-report--insert "harness-ui-report")
(declare-function harness-ui-review-verify "harness-ui-review")
(declare-function harness-ui-review-reject "harness-ui-review")
(declare-function harness-ui-review--on-event "harness-ui-review")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-compose-text "harness-ui-compose")

(defmacro harness-ui-review-test-with (&rest body)
  "Like the board tests, with review on and a task that hands a report in.
The provider's script makes the task call hand_in, so the task reaches
review with a report; BODY gets `board', `id' and `sid'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     ;; After the clears: the fixture must not wipe the tool's registration.
     (harness-test-load-module 'tools-handin)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "All done.\n")
              (:type tool-call :id "h1" :name "hand_in"
                     :input (:summary "# Done\n\nThe flaky test is fixed."
                             :evidence ("a note" (:code "(fix-flaky)" :language "elisp"
                                             :caption "the fix")
                                        (:tool_call "h1"))))
              (:type text :delta " this must not matter")))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-ui-default-position 'full)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-popout ui-tasks ui-chat ui-report ui-review))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (let* ((board (harness-tasks dir))
              (id (progn (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                             5 "the board to load")
                         (with-current-buffer board
                           (goto-char harness-compose-end)
                           (insert "Fix the flaky test")
                           (harness-ui-tasks-submit)
                           (harness-test-wait
                            (lambda () (equal "review" (plist-get (car harness-ui-tasks--tasks) :state)))
                            10 "the task to wait for review")
                           (plist-get (car harness-ui-tasks--tasks) :id))))
              (sid (plist-get (harness-call 'task/get id) :session)))
         (unwind-protect
             (progn ,@body)
           (dolist (b (buffer-list))
             (when (memq (buffer-local-value 'major-mode b)
                         '(harness-ui-popout-mode harness-chat-mode harness-ui-tasks-mode))
               (ignore-errors (kill-buffer b))))
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

(defun harness-ui-review-test--open-session (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer))) 5 "the session to load")
    buffer))

(defun harness-ui-review-test--text (buffer)
  "BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-review-test--wait-text (buffer regexp)
  "Wait until BUFFER's text matches REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-review-test--text buffer)))
                     5 (format "the buffer to show %s" regexp)))

(ert-deftest harness-ui-review-banner-shows-and-verifies ()
  "A task in review says so in its session, and its [Verify] accepts the work."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (with-current-buffer chat
        (should (string-match-p "this session is a task waiting for you" (buffer-string)))
        (should (string-match-p "Fix the flaky test" (buffer-string)))
        (should (string-search "[Verify]  C-c C-v" (buffer-string)))
        (should (string-search "[Send back]  C-c C-x" (buffer-string)))
        (should (string-search "[Report]" (buffer-string)))
        ;; It reads as the board's Ready for review: the review background,
        ;; not the chat panel's, so accepting work looks the same in both.
        (let* ((pos (string-match "Ready for review" (buffer-string)))
               (faces (get-text-property pos 'face)))
          (should (cl-some (lambda (f) (eq f 'harness-chat-review-face))
                           (if (listp faces) faces (list faces)))))
        ;; The keys reach the banner's commands, with no Shift to hold,
        ;; and leave the chat's own C-c C-r its redraw.
        (should harness-ui-review-minor-mode)
        (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
        (should (eq 'harness-ui-review-reject (key-binding (kbd "C-c C-x"))))
        (should (eq 'harness-chat-redraw (key-binding (kbd "C-c C-r"))))
        (call-interactively (key-binding (kbd "C-c C-v"))))
      (harness-test-wait (lambda () (not (eq 'review (plist-get (harness-call 'task/get id) :state))))
                         10 "the task to leave review")
      (harness-test-wait (lambda () (not (string-match-p "Ready for review"
                                                         (harness-ui-review-test--text chat))))
                         5 "the banner to go")
      ;; With the banner gone, so are its keys: C-c C-v attaches the clipboard again.
      (with-current-buffer chat
        (should-not harness-ui-review-minor-mode)
        (should (eq 'harness-compose-attach-clipboard (key-binding (kbd "C-c C-v"))))
        (should-not (key-binding (kbd "C-c C-x")))))))

(ert-deftest harness-ui-review-banner-sends-back-with-the-box ()
  "The banner's box writes the feedback: C-c C-c sends the task back to work."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (with-current-buffer chat
        (goto-char harness-compose-end)
        (insert "it still flakes on CI")
        (call-interactively #'harness-chat-send))
      ;; The feedback reaches the task; the session works on it and, this
      ;; fixture's script handing in again, the task waits for review anew.
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (should (equal '("it still flakes on CI")
                     (mapcar (lambda (round) (plist-get round :text))
                             (plist-get (harness-call 'task/get id) :feedback))))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                         10 "the task to come back for review")
      (harness-ui-review-test--wait-text chat "Ready for review")
      ;; An empty box cannot send it back.
      (with-current-buffer chat
        (should-error (harness-ui-review--send "  " nil) :type 'user-error)))))

(ert-deftest harness-ui-review-report-popout ()
  "[Report], and the board's item at point, show the report: the summary and the evidence."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (with-current-buffer chat
        (harness-ui-report-popout (harness-call 'task/get id)))
      (let* ((key (list 'report id))
             (popout (harness-ui-popout-buffer key)))
        (should (harness-ui-popout-buffer key))
        (harness-test-wait (lambda () (string-match-p "Handed in" (harness-ui-review-test--text popout)))
                           5 "the report to draw")
        (let ((text (harness-ui-review-test--text popout)))
          (should (string-match-p "the flaky test is fixed" text))
          (should (string-match-p "Evidence (3)" text))
          (should (string-match-p "a note" text))
          (should (string-match-p "(fix-flaky)" text))
          (should (string-match-p "the fix" text))
          ;; A referenced call reads as the link it is.
          (should (string-match-p "\[tool call\]" text))
          (should (string-match-p "\[Open in the session\]" text))
          (should (string-match-p "Hand in the finished work" text)))
        ;; The board offers it: a [Report] button on the card that has a
        ;; report, and the item at point -- the shared command a view's
        ;; SPC delegates to -- popping the same report out again.
        (harness-ui-popout-close key)
        (with-current-buffer board
          (harness-ui-tasks--render)
          (should (string-search "[Report]" (buffer-string)))
          (goto-char (point-min))
          (search-forward "Fix the flaky test")
          (call-interactively #'harness-ui-popout-at-point))
        (should (harness-ui-popout-buffer key))))))

(defvar harness-ui-review--tasks)

(defun harness-ui-review-test--tail (buffer)
  "The text of BUFFER under its transcript: its panels and the box."
  (with-current-buffer buffer
    (buffer-substring-no-properties harness-chat--transcript-end (point-max))))

(defun harness-ui-review-test--wait-report (buffer)
  "Wait until the banner of BUFFER shows the report."
  (harness-test-wait (lambda () (string-search "Handed in" (harness-ui-review-test--tail buffer)))
                     5 "the report to show in the banner"))

(ert-deftest harness-ui-review-banner-shows-the-report-in-full ()
  "Inside the task's session the report is not behind a button: the banner
shows it in full, expanded, between its heading and its buttons."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid)))
      (harness-ui-review-test--wait-report chat)
      (let* ((tail (harness-ui-review-test--tail chat))
             (at (lambda (text) (or (string-search text tail) (error "%S is not in the banner" text)))))
        ;; In reading order: the heading, the report, then the buttons.
        (should (< (funcall at "Ready for review") (funcall at "Handed in")
                   (funcall at "The flaky test is fixed.") (funcall at "Evidence (3)")
                   (funcall at "a note") (funcall at "(fix-flaky)") (funcall at "the fix")
                   (funcall at "[tool call]") (funcall at "[Open in the session]")
                   (funcall at "[Verify]")))
        ;; Each piece of evidence starts a line of its own.
        (should (string-match-p "^a note$" tail))
        (should (string-match-p "^(fix-flaky)$" tail))
        ;; Expanded: nothing waits behind a [show all].
        (should-not (string-search "[show all" tail)))
      (with-current-buffer chat
        (let* ((pos (save-excursion (goto-char harness-chat--transcript-end)
                                    (search-forward "Handed in")
                                    (match-beginning 0)))
               (prefix (get-text-property pos 'line-prefix)))
          ;; Indented under the heading, on the banner's background.
          (should (string-prefix-p "   " prefix))
          (should (memq 'harness-chat-review-face (ensure-list (get-text-property 0 'face prefix))))
          (should (memq 'harness-chat-review-face (ensure-list (get-text-property pos 'face)))))))))

(ert-deftest harness-ui-review-report-opens-the-call-in-the-transcript ()
  "[Open in the session] of a referenced call takes point to the call in
the transcript, from the banner's report and from the popout alike:
never to the copy of the report under the transcript."
  (harness-ui-review-test-with
    (let* ((chat (harness-ui-review-test--open-session sid))
           (evidence (append (plist-get (plist-get (harness-call 'task/get id) :report) :evidence) nil))
           (node (plist-get (car (last evidence)) :id)))
      (should (stringp node))
      (harness-ui-review-test--wait-report chat)
      (with-current-buffer chat
        (goto-char harness-chat--transcript-end)
        (search-forward "[Open in the session]")
        (push-button (match-beginning 0))
        (should (< (point) harness-chat--transcript-end))
        (should (equal node (get-text-property (point) 'harness-chat-node)))
        (goto-char (point-max)))
      (with-current-buffer (harness-ui-report-popout (harness-call 'task/get id))
        (goto-char (point-min))
        (search-forward "[Open in the session]")
        (push-button (match-beginning 0)))
      (with-current-buffer chat
        (should (< (point) harness-chat--transcript-end))
        (should (equal node (get-text-property (point) 'harness-chat-node)))))))

(ert-deftest harness-ui-review-banner-follows-task-events ()
  "The banner follows the task events of its session, which carry a copy
of the session's id, and only a change it shows draws the tail again:
a reader of a long report keeps their place."
  (harness-ui-review-test-with
    (let* ((chat (harness-ui-review-test--open-session sid))
           (task (progn (harness-ui-review-test--wait-report chat)
                        (gethash sid harness-ui-review--tasks)))
           (draws 0)
           (event (lambda (&rest changes)
                    ;; As the wire has it: a fresh record and a fresh id.
                    (let ((record (plist-put (copy-sequence task) :session (copy-sequence sid))))
                      (while changes
                        (setq record (plist-put record (pop changes) (pop changes))))
                      (harness-ui-review--on-event "task/changed" (list record))))))
      (should (equal "review" (plist-get task :state)))
      (with-current-buffer chat
        (let ((draw harness-compose-redraw-function))
          (setq-local harness-compose-redraw-function (lambda () (cl-incf draws) (funcall draw)))))
      ;; Out of review: the banner and its report go at once.
      (funcall event :state "active")
      (should (= draws 1))
      (should-not (string-search "Ready for review" (harness-ui-review-test--tail chat)))
      (should-not (string-search "Handed in" (harness-ui-review-test--tail chat)))
      ;; A change the banner does not show draws nothing.
      (funcall event :state "active" :merge-status "queued")
      (should (= draws 1))
      ;; Back in review, they are back.
      (funcall event)
      (should (= draws 2))
      (should (string-search "Handed in" (harness-ui-review-test--tail chat)))
      (funcall event :finished 1.0)
      (should (= draws 2))
      ;; A new report replaces the old one.
      (funcall event :report (list :summary "Second try." :at 2.0
                                   :evidence (list (list :kind "note" :text "again"))))
      (should (= draws 3))
      (should (string-search "Second try." (harness-ui-review-test--tail chat)))
      (should-not (string-search "The flaky test is fixed." (harness-ui-review-test--tail chat))))))

(ert-deftest harness-ui-review-report-string-is-the-report-in-full ()
  "The session's drawing of a report is the popout's, expanded: a call's
whole output where the popout caps it.  A button sits after its
indentation with nothing after it, and each piece of evidence starts a
line of its own."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-acp--server-enabled nil))
      (dolist (m '(acp ui ui-compose ui-markdown ui-popout ui-tasks ui-report))
        (harness-test-load-module m)))
    (let* ((output (concat (make-string 2000 ?x) "\nend of the output\n"))
           (task (list :id "t-report" :session "s-report" :prompt "Fix it" :state "review"
                       :report (list :summary "# Done\n\nIt works." :at 1.0
                                     :evidence (list (list :kind "note" :text "a note")
                                                     (list :kind "code" :code "(fix)" :language "elisp"
                                                           :caption "the fix")
                                                     (list :kind "tool-call" :id "n-1" :call-id "c-report"
                                                           :tool "bash" :title "bash: make test"
                                                           :input "{\"command\":\"make test\"}"
                                                           :output output)))))
           (full (harness-ui-report-string task))
           (capped (with-temp-buffer (harness-ui-report--insert task) (buffer-string))))
      (should (string-search "end of the output" full))
      (should-not (string-search "[show all" full))
      (should (string-match-p "^  \\[show all ([0-9]+ more chars)\\]$" capped))
      (should-not (string-search "end of the output" capped))
      (dolist (text (list full capped))
        (should (string-match-p "^It works\\.$" text))
        (should (string-match-p "^a note$" text))
        (should (string-match-p "^(fix)$" text))
        (should (string-match-p "^  the fix$" text))
        (should (string-match-p "^  \\[Open in the session\\]$" text))
        ;; A blank line between pieces of evidence, a caption with its own.
        (should (string-match-p "^a note\n\n" text))
        (should (string-match-p "^(fix)\n  the fix\n\n  \\[tool call\\]" text)))
      ;; None after the last: what follows the report keeps its own spacing.
      (should (string-suffix-p "  [Open in the session]\n" full))
      ;; No report, nothing to draw.
      (should-not (harness-ui-report-string (list :id "t-none"))))))

(provide 'harness-ui-review-test)
;;; harness-ui-review-test.el ends here
