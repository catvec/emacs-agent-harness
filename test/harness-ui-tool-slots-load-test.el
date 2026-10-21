;;; harness-ui-tool-slots-load-test.el --- Tests for the held-back tool slots in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; The line pinned above a chat's compose box while the machine's load
;; holds the tool slots back (lisp/ui/harness-ui-tool-slots-load.el): it
;; shows while the limit is under the baseline, in every chat, says how
;; many slots there are and the load that took them, follows the
;; harness's announcements and is asked for when the UI connects.  The
;; harness half is the real tool-slots-load module over the in-process
;; connection, its load stubbed the way its own tests stub it; the chat
;; is the real chat.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-ui--sessions)
(defvar harness-provider-demo--delay)
(defvar harness-chat--buffers)
(defvar harness-chat--blocks)
(defvar harness-chat--loading)
(defvar harness-chat--transcript-end)
(defvar harness-chat-panel-functions)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-tool-slots-count)
(defvar harness-tool-slots-burst)
(defvar harness-tool-slots-load-function)
(defvar harness-tool-slots-load--timer)
(defvar harness-tool-slots-load--limit)
(defvar harness-tool-slots-load--changed-at)
(defvar harness-tool-slots-load--changed-pressure)
(defvar harness-tool-slots-load--changed-text)
(defvar harness-ui-tool-slots-load--state)
(declare-function harness-chat-buffer "harness-ui-chat" (session-id))
(declare-function harness-ui-connect "harness-ui" (&optional address))
(declare-function harness-compose-redraw "harness-ui-compose" ())
(declare-function harness-tool-slots-load--tick "harness-tool-slots-load" ())
(declare-function harness-tool-slots-load--shutdown "harness-tool-slots-load" ())
(declare-function harness-ui-tool-slots-load--held "harness-ui-tool-slots-load" (state))
(declare-function harness-ui-tool-slots-load--store "harness-ui-tool-slots-load" (state))
(declare-function harness-ui-tool-slots-load--connected "harness-ui-tool-slots-load" ())
(declare-function harness-ui-tool-slots-load--on-event "harness-ui-tool-slots-load" (event args))
(declare-function harness-ui-tool-slots-load--shutdown "harness-ui-tool-slots-load" ())
(declare-function harness-ui-tool-slots-load--panel "harness-ui-tool-slots-load" ())

(defmacro harness-ui-tool-slots-load-test-with (&rest body)
  "Load the harness half of the tool slots, the chat and the panel, then run BODY.
The harness's machine has eight slots and no timer of its own: the
tests take the load's readings themselves (`--move').  The UI is not
connected until a chat opens, or a test says."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp
                          priority tool-slots tool-slots-load))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil)
     (when (timerp harness-tool-slots-load--timer)
       (cancel-timer harness-tool-slots-load--timer))
     (setq harness-tool-slots-load--timer nil
           harness-tool-slots-load--limit nil
           harness-tool-slots-load--changed-at nil
           harness-tool-slots-load--changed-pressure nil
           harness-tool-slots-load--changed-text nil
           harness-tool-slots-load-function (lambda (&optional _window) 0.1))
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (harness-tool-slots-count 8)
           (harness-tool-slots-burst 0)
           (default-directory dir))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       (harness-test-load-module 'ui-tool-slots-load)
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (harness-ui-tool-slots-load--shutdown)
         (when (timerp harness-tool-slots-load--timer)
           (cancel-timer harness-tool-slots-load--timer))
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-tool-slots-load-test--move (per-processor)
  "Move the machine's load to PER-PROCESSOR and take a reading, as the module's timer would.
The reading is let through the cooldown and the deadband, so it changes
the slots whenever the load asks for another number."
  (setq harness-tool-slots-load-function
        (lambda (&optional _window) (* per-processor (max 1 (num-processors))))
        harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil)
  (harness-tool-slots-load--tick))

(defun harness-ui-tool-slots-load-test--open (&optional name)
  "Open the chat of a new session called NAME and wait until it is drawn.
Return its buffer."
  (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                       :model "demo:scripted" :name (or name "Slots test"))
                         :id))
         (buf (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buf
                                    (and (not harness-chat--loading) harness-compose-end)))
                       10 "the chat drawn")
    buf))

(defun harness-ui-tool-slots-load-test--panel (buf)
  "Return the position of the held-back slots' line in chat BUF, or nil."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (and (re-search-forward "Tool slots limited to " nil t)
           (match-beginning 0)))))

(defun harness-ui-tool-slots-load-test--line (buf)
  "Return the held-back slots' line in chat BUF, as plain text, or nil."
  (when-let* ((pos (harness-ui-tool-slots-load-test--panel buf)))
    (with-current-buffer buf
      (save-excursion
        (goto-char pos)
        (buffer-substring-no-properties pos (line-end-position))))))

(ert-deftest harness-ui-tool-slots-load-the-panel-shows-while-the-slots-are-held-back ()
  "A chat shows how many slots there are while the load holds them back.
One line above the compose box says how many calls may run at once of
how many would, and the load that decided it, in a face of its own, with
what the sessions were told for a tooltip.  Another number draws it
again, and all the slots back take it away."
  (harness-ui-tool-slots-load-test-with
    (let ((buf (harness-ui-tool-slots-load-test--open)))
      (should-not (harness-ui-tool-slots-load-test--panel buf))
      (harness-ui-tool-slots-load-test--move 1.5)
      (harness-test-wait (lambda () (harness-ui-tool-slots-load-test--panel buf)) 10 "the panel")
      (with-current-buffer buf
        (let ((pos (harness-ui-tool-slots-load-test--panel buf)))
          (should (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                         (harness-ui-tool-slots-load-test--line buf)))
          ;; In the tail, above the compose box and below the transcript.
          (should (>= pos (marker-position harness-chat--transcript-end)))
          (should (< pos (marker-position harness-compose-start)))
          ;; The panel's own background, so it stands apart from the
          ;; sub-agents beside it; the icon leads the line.
          (should (memq 'harness-chat-slots-face
                        (ensure-list (get-text-property pos 'face))))
          (save-excursion
            (goto-char pos)
            (should (string-match-p "\\`\\S-* Tool slots"
                                    (buffer-substring-no-properties
                                     (line-beginning-position) (line-end-position)))))
          ;; What the sessions were told, and when.
          (should (string-match-p
                   "\\`Tool slots reduced from 8 to 4: system load 1.5x on this machine (at [0-9:]+)\\'"
                   (get-text-property pos 'help-echo)))))
      ;; Another number draws the line again.
      (harness-ui-tool-slots-load-test--move 2.0)
      (harness-test-wait (lambda () (equal "Tool slots limited to 1 of 8: system load 2.0x on this machine"
                                           (harness-ui-tool-slots-load-test--line buf)))
                         10 "the line redrawn")
      (should (= 1 (with-current-buffer buf
                     (how-many "Tool slots limited to" (point-min) (point-max)))))
      ;; Raised, and still held back: the number now.
      (harness-ui-tool-slots-load-test--move 1.5)
      (harness-test-wait (lambda () (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                                           (harness-ui-tool-slots-load-test--line buf)))
                         10 "the line redrawn")
      ;; All the slots back: nothing to show.
      (harness-ui-tool-slots-load-test--move 0.2)
      (harness-test-wait (lambda () (not (harness-ui-tool-slots-load-test--panel buf)))
                         10 "the panel gone")
      (should-not harness-ui-tool-slots-load--state))))

(ert-deftest harness-ui-tool-slots-load-every-chat-shows-it ()
  "Every open chat shows the line, one opened later at once, and one asks at connect.
The slots are the machine's, not a session's.  A UI that connects to a
harness whose slots are held back asks how they stand, having let go of
what the last harness said."
  (harness-ui-tool-slots-load-test-with
    (let ((one (harness-ui-tool-slots-load-test--open "One")))
      (harness-ui-tool-slots-load-test--move 1.5)
      (harness-test-wait (lambda () (harness-ui-tool-slots-load-test--panel one)) 10 "the first chat")
      (let ((two (harness-ui-tool-slots-load-test--open "Two")))
        ;; Opened with the slots held back: drawn with the rest of the tail.
        (should (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                       (harness-ui-tool-slots-load-test--line two)))
        ;; Connecting again: the state is asked for, not assumed.
        (setq harness-ui-tool-slots-load--state
              (harness-ui-tool-slots-load--held '(:limit 2 :baseline 9 :pressure 3.0)))
        (harness-ui-tool-slots-load--store nil)
        (should-not (harness-ui-tool-slots-load-test--panel one))
        (should-not (harness-ui-tool-slots-load-test--panel two))
        (harness-ui-tool-slots-load--connected)
        (harness-test-wait (lambda () (and (harness-ui-tool-slots-load-test--panel one)
                                           (harness-ui-tool-slots-load-test--panel two)))
                           10 "the state asked for")
        (should (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                       (harness-ui-tool-slots-load-test--line one)))
        ;; After the harness reloaded: asked for again, and what it says now holds.
        (setq harness-ui-tool-slots-load--state
              (harness-ui-tool-slots-load--held '(:limit 2 :baseline 9 :pressure 3.0)))
        (harness-ui-tool-slots-load--on-event "harness/reloaded" nil)
        (harness-test-wait (lambda () (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                                             (harness-ui-tool-slots-load-test--line one)))
                           10 "the state asked for after a reload")))))

(ert-deftest harness-ui-tool-slots-load-only-held-back-slots-show ()
  "The state shows only while the limit is under the baseline, and is read as numbers.
All the slots, a state that is none and one without numbers show
nothing; the load, the text and the time are left nil when the harness
has none."
  (harness-ui-tool-slots-load-test-with
    (should-not (harness-ui-tool-slots-load--held nil))
    (should-not (harness-ui-tool-slots-load--held '(:limit 8 :baseline 8)))
    (should-not (harness-ui-tool-slots-load--held '(:limit 9 :baseline 8)))
    (should-not (harness-ui-tool-slots-load--held '(:limit "4" :baseline 8)))
    (should-not (harness-ui-tool-slots-load--held '(:limit 4)))
    (should-not (harness-ui-tool-slots-load--held "slots"))
    (should (equal '(:limit 4 :baseline 8 :pressure nil :text nil :at nil)
                   (harness-ui-tool-slots-load--held '(:limit 4 :baseline 8))))
    ;; Whole numbers arrive as floats where JSON made them so.
    (should (equal '(:limit 4 :baseline 8 :pressure 1.5 :text "Tool slots reduced" :at 100.5)
                   (harness-ui-tool-slots-load--held
                    '(:limit 4.0 :baseline 8.0 :pressure 1.5 :text "Tool slots reduced" :at 100.5))))
    (should (equal '(:limit 4 :baseline 8 :pressure nil :text nil :at nil)
                   (harness-ui-tool-slots-load--held
                    '(:limit 4 :baseline 8 :pressure "high" :text "" :at "now"))))))

(ert-deftest harness-ui-tool-slots-load-a-state-that-reads-the-same-draws-nothing ()
  "The chats are drawn again when what they show changed, and not otherwise.
An answer repeating what an announcement said, or all the slots said
twice, is no change."
  (harness-ui-tool-slots-load-test-with
    (let ((drawn 0))
      (cl-letf (((symbol-function 'harness-ui-tool-slots-load--redraw)
                 (lambda () (cl-incf drawn))))
        (harness-ui-tool-slots-load--store '(:limit 8 :baseline 8))
        (should (= 0 drawn))
        (harness-ui-tool-slots-load--store '(:limit 4 :baseline 8 :pressure 1.5))
        (should (= 1 drawn))
        (harness-ui-tool-slots-load--store '(:limit 4 :baseline 8 :pressure 1.5))
        (should (= 1 drawn))
        (harness-ui-tool-slots-load--store '(:limit 4.0 :baseline 8.0 :pressure 1.5))
        (should (= 1 drawn))
        ;; The same number at another load is another line.
        (harness-ui-tool-slots-load--store '(:limit 4 :baseline 8 :pressure 1.6))
        (should (= 2 drawn))
        (harness-ui-tool-slots-load--store '(:limit 8 :baseline 8))
        (should (= 3 drawn))
        (harness-ui-tool-slots-load--store nil)
        (should (= 3 drawn))))))

(ert-deftest harness-ui-tool-slots-load-the-watch-ending-takes-the-line-away ()
  "A harness that stops the watch while the slots are held back takes the line away.
The module stopping gives the slots back, and says so to the UIs, though
it tells the sessions nothing."
  (harness-ui-tool-slots-load-test-with
    (let ((buf (harness-ui-tool-slots-load-test--open)))
      (harness-ui-tool-slots-load-test--move 1.5)
      (harness-test-wait (lambda () (harness-ui-tool-slots-load-test--panel buf)) 10 "the panel")
      (harness-tool-slots-load--shutdown)
      (harness-test-wait (lambda () (not (harness-ui-tool-slots-load-test--panel buf)))
                         10 "the panel gone")
      (should-not harness-ui-tool-slots-load--state))))

(ert-deftest harness-ui-tool-slots-load-the-module-stopping-takes-the-line-away ()
  "Stopping the UI's module draws every chat without the line, and stops following.
The panel goes out of the chats' own panel lists, and a change the
harness announces later changes nothing."
  (harness-ui-tool-slots-load-test-with
    (let ((buf (harness-ui-tool-slots-load-test--open)))
      (harness-ui-tool-slots-load-test--move 1.5)
      (harness-test-wait (lambda () (harness-ui-tool-slots-load-test--panel buf)) 10 "the panel")
      (with-current-buffer buf
        (should (memq #'harness-ui-tool-slots-load--panel harness-chat-panel-functions)))
      (harness-ui-tool-slots-load--shutdown)
      (should-not (harness-ui-tool-slots-load-test--panel buf))
      (with-current-buffer buf
        (should-not (memq #'harness-ui-tool-slots-load--panel harness-chat-panel-functions)))
      ;; Not followed any more.
      (harness-ui-tool-slots-load-test--move 2.0)
      (accept-process-output nil 0.3)
      (should-not (harness-ui-tool-slots-load-test--panel buf))
      (should-not harness-ui-tool-slots-load--state))))

(ert-deftest harness-ui-tool-slots-load-a-panel-that-fails-draws-nothing ()
  "The panel is decoration: when it cannot be drawn, the rest of the tail is.
A state the panel cannot make a line of leaves the chat as it was, the
compose box included, rather than signal while the tail is drawn."
  (harness-ui-tool-slots-load-test-with
    (let ((buf (harness-ui-tool-slots-load-test--open)))
      (cl-letf (((symbol-function 'harness-ui-tool-slots-load--render)
                 (lambda (&rest _) (error "No line"))))
        (with-current-buffer buf
          (setq harness-ui-tool-slots-load--state
                (harness-ui-tool-slots-load--held '(:limit 4 :baseline 8 :pressure 1.5)))
          (should-not (harness-ui-tool-slots-load--panel))
          (harness-compose-redraw)
          (should harness-compose-end)))
      (should-not (harness-ui-tool-slots-load-test--panel buf))
      ;; Drawn as it is without the failure.
      (with-current-buffer buf (harness-compose-redraw))
      (should (equal "Tool slots limited to 4 of 8: system load 1.5x on this machine"
                     (harness-ui-tool-slots-load-test--line buf))))))

(provide 'harness-ui-tool-slots-load-test)
;;; harness-ui-tool-slots-load-test.el ends here
