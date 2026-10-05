;;; harness-ui-review-test.el --- Tests for the review banner and report popout  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task in review, in its own session and on its board: the banner
;; above the compose box that verifies or sends the work back, and the
;; report popout that shows the final message and the evidence.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'text-property-search)

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
(defvar harness-compose-map)
(defvar harness-chat--loading)
(defvar harness-chat--transcript-end)
(defvar harness-compose-redraw-function)
(defvar harness-ui-popout-key)
(defvar harness-ui-review-minor-mode)
(defvar harness-ui-popout--parent)
(defvar harness-ui-popout--max-height)
(defvar harness-ui-report-max-height)
(defvar harness-ui-report--reports)
(declare-function harness-ui-popout--header "harness-ui-popout")
(declare-function harness-ui-popout-pixel-width "harness-ui-popout")
(declare-function harness-ui-report--placeholder "harness-ui-report")
(declare-function harness-ui-report--image-max-height "harness-ui-report")
(declare-function harness-ui-report--image-width "harness-ui-report")
(declare-function harness-ui-review--send "harness-ui-review")
(declare-function harness-compose-live-p "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
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
(defvar harness-chat-placeholder)
(defvar harness-chat-send-function)
(defvar harness-ui-review--feedback-hint)
(defvar harness-tasks--reject-message)
(defvar harness-ui-session-id)
(declare-function harness-acp--normalise "harness-acp")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-ui-review--chat-buffer "harness-ui-review")
(declare-function harness-ui-review--on-event "harness-ui-review")

(defconst harness-ui-review-test--image
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"180\"><rect width=\"320\" height=\"180\" fill=\"#1f3a22\"/></svg>\n"
  "The image the fixture's task hands in, as shot.svg in its directory.")

(defvar harness-ui-review-test--script nil
  "The script of the fixture's provider, or nil for the one handing in.")

(defmacro harness-ui-review-test-with (&rest body)
  "Like the board tests, with review on and a task that hands a report in.
The provider's script makes the task call hand_in, so the task reaches
review with a report, an image among its evidence; BODY gets `board',
`id' and `sid'.  `harness-ui-review-test--script', bound around it,
gives the task another script."
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
            (or harness-ui-review-test--script
                '((:type text :delta "All done.\n")
                  (:type tool-call :id "h1" :name "hand_in"
                         :input (:summary "# Done\n\nThe flaky test is fixed."
                                 :evidence ("a note" (:code "(fix-flaky)" :language "elisp"
                                                 :caption "the fix")
                                            (:image "shot.svg" :caption "the board, fixed")
                                            (:tool_call "h1"))))
                  (:type text :delta " this must not matter"))))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-ui-default-position 'full)
           (harness-acp-token nil)
           (default-directory dir))
       (with-temp-file (expand-file-name "shot.svg" dir) (insert harness-ui-review-test--image))
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
         (ignore sid)
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

(defun harness-ui-review-test--push (buffer label)
  "Push the button LABEL in BUFFER, as a click on it does."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (pos)
        (while (and (not pos) (search-forward label nil t))
          (when (button-at (match-beginning 0)) (setq pos (match-beginning 0))))
        (unless pos (error "No %s button in %s" label (buffer-name)))
        (push-button pos)))))

(defun harness-ui-review-test--feedback (id)
  "The feedback task ID was sent back with, as texts."
  (mapcar (lambda (round) (plist-get round :text)) (plist-get (harness-call 'task/get id) :feedback)))

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
        ;; C-c C-v is the banner's and no longer the box's too: pasting
        ;; an image is C-y.
        (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
        (should-not (lookup-key harness-compose-map (kbd "C-c C-v")))
        (call-interactively (key-binding (kbd "C-c C-v"))))
      (harness-test-wait (lambda () (not (eq 'review (plist-get (harness-call 'task/get id) :state))))
                         10 "the task to leave review")
      (harness-test-wait (lambda () (not (string-match-p "Ready for review"
                                                         (harness-ui-review-test--text chat))))
                         5 "the banner to go")
      ;; With the banner gone, so are its keys: C-c C-v is nothing there,
      ;; the box pasting with C-y.
      (with-current-buffer chat
        (should-not harness-ui-review-minor-mode)
        (should-not (key-binding (kbd "C-c C-v")))
        (should-not (key-binding (kbd "C-c C-x")))))))

(ert-deftest harness-ui-review-banner-sends-back-with-the-box ()
  "The banner's box writes the feedback: C-c C-c sends the task back to work.
The box sends as it always does: the harness takes a message to a task
in review for the feedback that sends it back, [Send back] pressed or
not.  The banner goes as soon as the task is back at work."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (with-current-buffer chat
        ;; [Send back] says what the box is for; the box itself is the chat's.
        (harness-ui-review-reject)
        (should (equal harness-ui-review--feedback-hint harness-chat-placeholder))
        (should-not harness-chat-send-function)
        ;; An empty box sends nothing.
        (should-error (harness-chat-send) :type 'user-error)
        ;; A slower turn, so the test sees the session at work on the feedback.
        (setq harness-provider-demo--delay 0.3)
        (goto-char harness-compose-end)
        (insert "it still flakes on CI")
        (call-interactively #'harness-chat-send))
      ;; The feedback reaches the task, which is at work again: the banner
      ;; goes, and the box asks for a message again.
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (harness-test-wait (lambda () (not (string-match-p "Ready for review" (harness-ui-review-test--text chat))))
                         5 "the banner to go while the session works")
      (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
      (with-current-buffer chat (should-not harness-chat-placeholder))
      (should (equal '("it still flakes on CI")
                     (mapcar (lambda (round) (plist-get round :text))
                             (plist-get (harness-call 'task/get id) :feedback))))
      ;; The agent got it as the user sending the work back.
      (harness-test-wait (lambda () (harness-ui-review-test--last-user sid "it still flakes on CI"))
                         5 "the feedback in the transcript")
      (should (string-prefix-p harness-tasks--reject-message
                               (harness-ui-review-test--last-user sid "it still flakes on CI")))
      ;; This fixture's script hands in again: the task waits for review anew.
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                         10 "the task to come back for review")
      (harness-ui-review-test--wait-text chat "Ready for review"))))

(defun harness-ui-review-test--last-user (sid text)
  "The content of SID's last user message when it ends in TEXT, else nil."
  (let ((content (plist-get (car (last (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                                         (harness-call 'session/nodes sid))))
                            :content)))
    (and (stringp content) (string-suffix-p text content) content)))

(ert-deftest harness-ui-review-banner-follows-events-from-another-process ()
  "The banner follows a `task/changed' whose session id is a string of its own.
From a harness in its own process every event is parsed afresh, so the
id it carries is never the very string the chat buffer holds: the buffer
is found all the same, and the banner goes once the task leaves review."
  (harness-ui-review-test-with
    (let* ((chat (harness-ui-review-test--open-session sid))
           (fresh (copy-sequence sid)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (should-not (eq fresh (buffer-local-value 'harness-ui-session-id chat)))
      (should (eq chat (harness-ui-review--chat-buffer fresh)))
      ;; The task goes back to work elsewhere; the news arrives as over TCP.
      (let ((task (copy-sequence (harness-acp--normalise (harness-call 'task/get id)))))
        (setq task (plist-put task :session fresh))
        (setq task (plist-put task :state "active"))
        (setq task (plist-put task :column "active"))
        (harness-ui-review--on-event "task/changed" (list task)))
      (should-not (string-match-p "Ready for review" (harness-ui-review-test--text chat))))))

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
          (should (string-match-p "Evidence (4)" text))
          (should (string-match-p "the board, fixed" text))
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
                   (funcall at "The flaky test is fixed.") (funcall at "Evidence (4)")
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

(defun harness-ui-review-test--report (board id)
  "Pop out the report of task ID as BOARD's [Report] does; return its buffer.
The board's record is the one the wire gives, as the UI sees it."
  (harness-ui-report-popout (with-current-buffer board (harness-ui-tasks--find id)))
  (let ((popout (harness-ui-popout-buffer (list 'report id))))
    (harness-ui-review-test--wait-text popout "Handed in")
    popout))

(ert-deftest harness-ui-review-report-popout-verifies ()
  "A report of a task in review ends with its session's banner and a box:
C-c C-v, anywhere in the popout, accepts the work, and the popout closes."
  (harness-ui-review-test-with
    (let ((popout (harness-ui-review-test--report board id)))
      (with-current-buffer popout
        (let ((text (buffer-string)))
          (should (string-match-p "Ready for review" text))
          (should (string-match-p "this task is waiting for you" text))
          (should (string-match-p "\\[Verify\\]" text))
          (should (string-match-p "\\[Send back\\]" text))
          (should (string-match-p "C-c C-c in the box sends what you write back to this task" text))
          ;; The report shows already: its banner has no [Report].
          (should-not (string-match-p "\\[Report\\]" text))
          ;; After the evidence, on the review background, as in the session.
          (let ((at (string-match "Ready for review" text)))
            (should (< (string-match "Evidence (4)" text) at))
            (should (memq 'harness-chat-review-face (ensure-list (get-text-property (1+ at) 'face))))))
        ;; Under it, the box takes the feedback.
        (should (harness-compose-live-p))
        (should (equal "What should change? C-c C-c sends it back" (harness-ui-report--placeholder)))
        ;; The keys work on the content and in the box.
        (goto-char (point-min))
        (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
        (should (eq 'harness-ui-review-reject (key-binding (kbd "C-c C-x"))))
        (goto-char harness-compose-end)
        (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
        (call-interactively (key-binding (kbd "C-c C-v"))))
      (harness-test-wait (lambda () (not (eq 'review (plist-get (harness-call 'task/get id) :state))))
                         10 "the task to leave review")
      ;; The popout closes with the decision: its buffer and its window go.
      (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close")
      (should-not (harness-ui-popout-buffer (list 'report id)))
      (should (harness-json-true-p (plist-get (harness-call 'task/get id) :verified))))))

(ert-deftest harness-ui-review-report-popout-sends-back ()
  "[Send back] in a report goes to its box, whose C-c C-c sends the task
back with what it holds, closing the popout; once handed in again, the
report opens anew."
  (harness-ui-review-test-with
    (let ((popout (harness-ui-review-test--report board id)))
      (with-current-buffer popout
        (goto-char (point-min))
        (search-forward "[Send back]")
        (push-button (1- (point)))
        (should (harness-compose-in-p))
        (insert "the chart is cut off")
        (call-interactively (key-binding (kbd "C-c C-c"))))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (should (equal '("the chart is cut off")
                     (mapcar (lambda (round) (plist-get round :text))
                             (plist-get (harness-call 'task/get id) :feedback))))
      ;; The popout closes with the send back: its buffer and its window go.
      (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close")
      (should-not (harness-ui-popout-buffer (list 'report id)))
      ;; Back at work, then, this fixture's script handing in again, back
      ;; for review: the report opens anew, with its banner.
      (harness-test-wait (lambda ()
                           (let ((task (harness-call 'task/get id)))
                             (and (eq 'review (plist-get task :state))
                                  (plist-get task :report))))
                         10 "the task to come back for review")
      (harness-ui-report-popout (harness-call 'task/get id))
      (let ((again (harness-ui-popout-buffer (list 'report id))))
        (harness-ui-review-test--wait-text again "Ready for review")
        ;; An empty box sends nothing back.
        (with-current-buffer again
          (should-error (harness-ui-review--send "  " nil) :type 'user-error))))))

(ert-deftest harness-ui-review-report-image-shows-larger ()
  "An image of a report is as wide as the popout and much of the frame
high; RET on it shows it larger in a popout of its own, and q goes back."
  (harness-ui-review-test-with
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
      (let* ((popout (harness-ui-review-test--report board id))
             (window (get-buffer-window popout))
             (file (expand-file-name "shot.svg" dir)))
        ;; The report grows taller than other popouts, for its images.
        (should (= harness-ui-report-max-height (buffer-local-value 'harness-ui-popout--max-height popout)))
        (with-current-buffer popout
          (goto-char (point-min))
          (let ((match (text-property-search-forward 'display nil
                                                     (lambda (_ value) (eq 'image (car-safe value))))))
            (should match)
            (goto-char (prop-match-beginning match))
            (let ((image (cdr (get-text-property (point) 'display))))
              (should (equal file (plist-get image :file)))
              ;; Not a fraction of the width as before: the popout's, less a column.
              (should (= (- (harness-ui-popout-pixel-width) (frame-char-width)) (plist-get image :max-width)))
              (should (= (harness-ui-report--image-width) (plist-get image :max-width)))
              (should (= (harness-ui-report--image-max-height) (plist-get image :max-height))))
            (should (string-match-p "view it larger" (get-text-property (point) 'help-echo)))
            (execute-kbd-macro (kbd "RET"))))
        (let ((viewer (harness-ui-popout-buffer (list 'image file))))
          (should viewer)
          ;; In the report's window, which it gives back.
          (should (eq viewer (window-buffer window)))
          (with-current-buffer viewer
            (should (equal (list 'report id) harness-ui-popout--parent))
            (should (string-search "shot.svg" (harness-ui-popout--header)))
            (should (string-search "[back]" (harness-ui-popout--header)))
            (goto-char (point-min))
            (execute-kbd-macro (kbd "q")))
          (should-not (buffer-live-p viewer))
          (should (eq popout (window-buffer window))))))))

(ert-deftest harness-ui-review-verify-closes-the-report ()
  "[Verify] in the session's banner closes the report its [Report] popped out.
The popout goes as the task turns verified: its buffer and its window."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid))
          (key (list 'report id)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (let ((windows (length (window-list nil 'nomini))))
        (harness-ui-review-test--push chat "[Report]")
        (let ((popout (harness-ui-popout-buffer key)))
          (should popout)
          (should (get-buffer-window popout))
          (harness-ui-review-test--push chat "[Verify]")
          (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close"))
        (should-not (harness-ui-popout-buffer key))
        (should (= windows (length (window-list nil 'nomini)))))
      (should (harness-json-true-p (plist-get (harness-call 'task/get id) :verified))))))

(ert-deftest harness-ui-review-board-verify-closes-the-report ()
  "[Verify] on the board's card closes the report its [Report] popped out."
  (harness-ui-review-test-with
    (let ((key (list 'report id)))
      (with-current-buffer board (harness-ui-tasks--render))
      (harness-ui-review-test--push board "[Report]")
      (let ((popout (harness-ui-popout-buffer key)))
        (should popout)
        (harness-ui-review-test--push board "[Verify]")
        (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close"))
      (should-not (harness-ui-popout-buffer key))
      (should (harness-json-true-p (plist-get (harness-call 'task/get id) :verified))))))

(ert-deftest harness-ui-review-send-back-closes-the-report ()
  "Sending the work back from the session's banner closes the report too.
[Send back] leaves it open while the feedback is written; sending that
closes it."
  (harness-ui-review-test-with
    (let ((chat (harness-ui-review-test--open-session sid))
          (key (list 'report id)))
      (harness-ui-review-test--wait-text chat "Ready for review")
      (harness-ui-review-test--push chat "[Report]")
      (let ((popout (harness-ui-popout-buffer key)))
        (should popout)
        (harness-ui-review-test--push chat "[Send back]")
        (should (buffer-live-p popout))
        (with-current-buffer chat
          (goto-char harness-compose-end)
          (insert "it still flakes on CI")
          (call-interactively #'harness-chat-send))
        (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close"))
      (should-not (harness-ui-popout-buffer key))
      (should (equal '("it still flakes on CI") (harness-ui-review-test--feedback id))))))

(ert-deftest harness-ui-review-board-send-back-closes-the-report ()
  "Sending the work back from the board's card closes the report its [Report] popped out."
  (harness-ui-review-test-with
    (let ((key (list 'report id)))
      (with-current-buffer board (harness-ui-tasks--render))
      (harness-ui-review-test--push board "[Report]")
      (let ((popout (harness-ui-popout-buffer key)))
        (should popout)
        (harness-ui-review-test--push board "[Send back]")
        (should (buffer-live-p popout))
        (with-current-buffer board
          (goto-char harness-compose-end)
          (insert "it still flakes on CI")
          (harness-ui-tasks-submit))
        (harness-test-wait (lambda () (not (buffer-live-p popout))) 5 "the report to close"))
      (should-not (harness-ui-popout-buffer key))
      (should (equal '("it still flakes on CI") (harness-ui-review-test--feedback id))))))

(ert-deftest harness-ui-review-report-after-send-back-stays-open ()
  "A report opened once the task was sent back stays open as it works again.
It follows the task back to review, and closes once that review is decided."
  (harness-ui-review-test-with
    (let ((key (list 'report id)))
      (harness-call 'task/reject id "it still flakes on CI")
      (harness-ui-report-popout (harness-call 'task/get id))
      (should (harness-ui-popout-buffer key))
      ;; The session works on the feedback and, this fixture's script
      ;; handing in again, the task waits for review anew.
      (harness-test-wait (lambda () (or (not (harness-ui-popout-buffer key))
                                        (equal "review" (plist-get (gethash key harness-ui-report--reports) :state))))
                         10 "the popout to follow the task back to review")
      (should (harness-ui-popout-buffer key))
      (harness-call 'task/verify id)
      (harness-test-wait (lambda () (null (harness-ui-popout-buffer key))) 5 "the report to close"))))

(ert-deftest harness-ui-review-done-report-stays-open ()
  "The report of a task verified before it popped out stays open as the task changes."
  (harness-ui-review-test-with
    (let ((key (list 'report id)))
      (harness-call 'task/verify id)
      (with-current-buffer board
        (harness-test-wait (lambda () (equal "done" (plist-get (harness-ui-tasks--find id) :state)))
                           10 "the board to see the task done")
        (harness-ui-report-popout (harness-ui-tasks--find id)))
      (should (harness-ui-popout-buffer key))
      (harness-call 'task/archive id)
      (harness-test-wait (lambda () (or (not (harness-ui-popout-buffer key))
                                        (harness-json-true-p
                                         (plist-get (gethash key harness-ui-report--reports) :archived))))
                         5 "the popout to follow the task")
      (should (harness-ui-popout-buffer key)))))

(ert-deftest harness-ui-review-missing-report-says-so ()
  "A task whose turn ended without hand_in says so wherever it is reviewed.
Its card offers [No report] where [Report] would be, never a review
with nothing to read; the popout says it was not handed in, shows the
session's last message and still verifies; the session's banner says it
in a line, the message being right above, with no [Report]."
  (let ((harness-ui-review-test--script
         '((:type text :delta "I think the flaky test passes now.\n")
           (:type done :stop-reason end-turn))))
    (harness-ui-review-test-with
      (let ((key (list 'report id)))
        (with-current-buffer board
          (harness-ui-tasks--render)
          (harness-ui-review-test--wait-text board "\\[No report\\]")
          (should-not (string-search "[Report]" (buffer-string))))
        (harness-ui-review-test--push board "[No report]")
        (should (harness-ui-popout-buffer key))
        (let ((popout (harness-ui-popout-buffer key)))
          (harness-ui-review-test--wait-text popout "Not handed in")
          (let ((text (harness-ui-review-test--text popout)))
            (should (string-search "Its turn ended without hand_in" text))
            (should (string-search "Its last message" text))
            (should (string-search "I think the flaky test passes now." text))
            (should (string-search "[Open the session]" text))
            (should-not (string-search "Handed in" text))
            (should-not (string-search "Evidence (" text))
            ;; It is reviewed from there as any report.
            (should (string-search "Ready for review" text))
            (should (string-search "[Verify]" text)))
          (harness-ui-popout-close key))
        (let ((chat (harness-ui-review-test--open-session sid)))
          (harness-ui-review-test--wait-text chat "Ready for review")
          (harness-test-wait (lambda () (string-search "It handed no report in"
                                                       (harness-ui-review-test--tail chat)))
                             5 "the banner to say no report was handed in")
          (let ((tail (harness-ui-review-test--tail chat)))
            (should-not (string-search "[Report]" tail))
            (should-not (string-search "Not handed in" tail))
            (should (string-search "[Verify]" tail))))))))

(provide 'harness-ui-review-test)
;;; harness-ui-review-test.el ends here
