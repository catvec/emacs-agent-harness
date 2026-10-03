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
(defvar harness-chat--loading)
(defvar harness-ui-popout-key)
(defvar harness-ui-popout--parent)
(defvar harness-ui-popout--max-height)
(defvar harness-ui-report-max-height)
(defvar harness-ui-review-mode)
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
(declare-function harness-ui-review-verify "harness-ui-review")
(declare-function harness-ui-review-reject "harness-ui-review")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-compose-text "harness-ui-compose")

(defconst harness-ui-review-test--image
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"180\"><rect width=\"320\" height=\"180\" fill=\"#1f3a22\"/></svg>\n"
  "The image the fixture's task hands in, as shot.svg in its directory.")

(defmacro harness-ui-review-test-with (&rest body)
  "Like the board tests, with review on and a task that hands a report in.
The provider's script makes the task call hand_in, so the task reaches
review with a report, an image among its evidence; BODY gets `board',
`id' and `sid'."
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
                                        (:image "shot.svg" :caption "the board, fixed")
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
        (should (string-match-p "\[Verify\]" (buffer-string)))
        (should (string-match-p "\[Send back\]" (buffer-string)))
        (should (string-match-p "\[Report\]" (buffer-string)))
        ;; It reads as the board's Ready for review: the review background,
        ;; not the chat panel's, so accepting work looks the same in both.
        (let* ((pos (string-match "Ready for review" (buffer-string)))
               (faces (get-text-property pos 'face)))
          (should (cl-some (lambda (f) (eq f 'harness-chat-review-face))
                           (if (listp faces) faces (list faces)))))
        ;; The keys reach the banner's commands.
        (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
        (should (eq 'harness-ui-review-reject (key-binding (kbd "C-c C-R"))))
        (call-interactively (key-binding (kbd "C-c C-v"))))
      (harness-test-wait (lambda () (not (eq 'review (plist-get (harness-call 'task/get id) :state))))
                         10 "the task to leave review")
      (harness-test-wait (lambda () (not (string-match-p "Ready for review"
                                                         (harness-ui-review-test--text chat))))
                         5 "the banner to go")
      ;; The keys go with it: C-c C-v attaches the clipboard again, as
      ;; in any chat.
      (with-current-buffer chat
        (goto-char harness-compose-end)
        (should-not harness-ui-review-mode)
        (should (eq 'harness-compose-attach-clipboard (key-binding (kbd "C-c C-v"))))))))

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

(defun harness-ui-review-test--report (board id)
  "Pop out the report of task ID as BOARD's [Report] does; return its buffer.
The board's record is the one the wire gives, as the UI sees it."
  (harness-ui-report-popout (with-current-buffer board (harness-ui-tasks--find id)))
  (let ((popout (harness-ui-popout-buffer (list 'report id))))
    (harness-ui-review-test--wait-text popout "Handed in")
    popout))

(ert-deftest harness-ui-review-report-popout-verifies ()
  "A report of a task in review ends with its session's banner and a box:
C-c C-v, anywhere in the popout, accepts the work, and the banner goes."
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
        (should (eq 'harness-ui-review-reject (key-binding (kbd "C-c C-R"))))
        (goto-char harness-compose-end)
        (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
        (call-interactively (key-binding (kbd "C-c C-v"))))
      (harness-test-wait (lambda () (not (eq 'review (plist-get (harness-call 'task/get id) :state))))
                         10 "the task to leave review")
      ;; The report stays; its banner, its box and their keys go.
      (harness-test-wait (lambda () (not (string-match-p "Ready for review" (harness-ui-review-test--text popout))))
                         5 "the banner to go")
      (with-current-buffer popout
        (should (string-match-p "Evidence (4)" (buffer-string)))
        (should-not (harness-compose-live-p))
        (should-not harness-ui-review-mode)
        (should-error (harness-ui-review-verify) :type 'user-error)))))

(ert-deftest harness-ui-review-report-popout-sends-back ()
  "[Send back] in a report goes to its box, whose C-c C-c sends the task
back with what it holds; once handed in again, the banner is back."
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
      ;; Back at work, then, this fixture's script handing in again, back
      ;; for review: the popout follows it.
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                         10 "the task to come back for review")
      (harness-ui-review-test--wait-text popout "Ready for review")
      ;; An empty box sends nothing back.
      (with-current-buffer popout
        (should-error (harness-ui-review--send "  " nil) :type 'user-error)))))

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

(provide 'harness-ui-review-test)
;;; harness-ui-review-test.el ends here
