;;; harness-ui-cache-test.el --- Tests for the expired prompt cache panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel above a session's compose box once its prompt cache has
;; expired: when it shows (a session waiting past its cache's lifetime,
;; never a new one or one that used no cache), what it says, and that it
;; comes on its own, drawn by its timer, and goes once a request is sent.
;; The unit tests fix the clock; the others run the state layer and the
;; demo provider with a cache that lasts a second or two.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-cache)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui--models)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat--buffers)
(defvar harness-compose-end)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-acp--drop-client "harness-acp")

;;;; What the panel shows, the clock fixed

(defun harness-ui-cache-test--session (&rest overrides)
  "Return an idle session plist whose cache lapsed at 1300, with OVERRIDES."
  (harness-plist-merge
   (list :id "s1" :status "idle" :model "test:m"
         :usage '(:context 84000 :cache-at 1000.0)
         :cache '(:at 1000.0 :ttl 300 :expires 1300.0))
   overrides))

(defun harness-ui-cache-test--local (hour minute &optional day)
  "Return the float time of HOUR:MINUTE local time on DAY (7) Oct 2026."
  (float-time (encode-time (list 0 minute hour (or day 7) 10 2026 nil -1 nil))))

(defun harness-ui-cache-test--banner (session now)
  "Return the text of the panel SESSION shows at NOW, or nil."
  (when-let* ((state (harness-ui-cache--state session now)))
    (substring-no-properties (harness-ui-cache--banner state now))))

(ert-deftest harness-ui-cache-state-shows-once-the-cache-lapsed ()
  "The panel shows once the cache lapsed while the session waits for the
user: idle, closed, or blocked on an answer.  Never before, never while
it runs, never without a cache."
  (let ((s (harness-ui-cache-test--session)))
    (should-not (harness-ui-cache--state s 1299.9))
    (should (harness-ui-cache--state s 1300.0))
    (should (= 84000 (plist-get (harness-ui-cache--state s 2000.0) :context)))
    (should (harness-ui-cache--state (harness-ui-cache-test--session :status "inactive") 2000.0))
    (should (plist-get (harness-ui-cache--state (harness-ui-cache-test--session :status "blocked") 2000.0)
                       :blocked))
    ;; A status as the harness process has it, a symbol.
    (should (harness-ui-cache--state (harness-ui-cache-test--session :status 'idle) 2000.0))
    ;; A running session's requests keep the cache.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :status "running") 2000.0))
    ;; A new session, or one whose requests used no cache.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :cache nil) 2000.0))
    (should-not (harness-ui-cache--state nil 2000.0))
    ;; It reads the same however late it is asked, so nothing redraws it.
    (should (equal (harness-ui-cache--state s 1400.0) (harness-ui-cache--state s 90000.0)))))

(ert-deftest harness-ui-cache-banner-says-what-the-next-message-costs ()
  "The panel says when the cache lapsed, how long it lasts, how much
context the next message sends uncached and what that costs against
cached, at list prices: clock times, never an age that goes stale."
  (let ((harness-ui--models (make-hash-table :test 'equal))
        (expires (harness-ui-cache-test--local 14 7)))
    (puthash "test:m" '(:id "test:m" :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
             harness-ui--models)
    (puthash "test:plain" '(:id "test:plain" :pricing (:input 2.0 :output 8.0 :cache-read 0.5))
             harness-ui--models)
    (let* ((cache (list :at (- expires 300) :ttl 300 :expires expires))
           (s (harness-ui-cache-test--session :cache cache))
           (text (harness-ui-cache-test--banner s (+ expires 600))))
      (should (string-match-p "Prompt cache expired  at 14:07, 5 minutes after its last use$" text))
      ;; 84000 tokens written to the cache again at 3.75, against read at 0.3.
      (should (string-match-p "^   Your next message re-sends ~84\\.0k tokens uncached: about \\$0\\.315 instead of \\$0\\.025, at list prices\\.$"
                              text))
      ;; Drawn on a later day, the time says its day.
      (should (string-match-p "at Oct 7, 14:07, 5 minutes"
                              (harness-ui-cache-test--banner s (harness-ui-cache-test--local 9 0 8))))
      ;; The hour Claude Code keeps a subscription's cache.
      (should (string-match-p "at 14:07, 1 hour after its last use"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session :cache (list :at (- expires 3600) :ttl 3600
                                                                            :expires expires))
                               (+ expires 60))))
      ;; Blocked on an answer, the request that answering sends.
      (should (string-match-p "The next request re-sends ~84\\.0k"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session :cache cache :status "blocked")
                               (+ expires 60))))
      ;; A model priced without cache writes sends it again at its input price.
      (should (string-match-p "about \\$0\\.168 instead of \\$0\\.042"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session :cache cache :model "test:plain")
                               (+ expires 60))))
      ;; A model the catalogue does not price: no cost.
      (should (string-match-p "re-sends ~84\\.0k tokens uncached\\.$"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session :cache cache :model "nobody:m")
                               (+ expires 60))))
      ;; The tooltip explains.
      (let ((banner (harness-ui-cache--banner (harness-ui-cache--state s (+ expires 60)) (+ expires 60))))
        (should (string-match-p "cached for 5 minutes after a request uses it"
                                (get-text-property 0 'help-echo banner)))
        (should (get-text-property 0 'harness-ui-cache-panel banner))))))

(ert-deftest harness-ui-cache-duration-in-words ()
  "Cache lifetimes read as words."
  (should (equal "5 minutes" (harness-ui-cache--duration 300)))
  (should (equal "1 hour" (harness-ui-cache--duration 3600)))
  (should (equal "3 hours" (harness-ui-cache--duration 10800)))
  (should (equal "90 seconds" (harness-ui-cache--duration 90)))
  (should (equal "1 second" (harness-ui-cache--duration 0.4)))
  (should (equal "2 days" (harness-ui-cache--duration 172800))))

;;;; In a chat, on time

(defconst harness-ui-cache-test--cached
  '((:type text :delta "Done.")
    (:type usage :input 300 :output 20 :cache-read 84000 :cache-write 200 :context 84500)
    (:type done :stop-reason end-turn))
  "A reply whose request read the prompt cache.")

(defconst harness-ui-cache-test--uncached
  '((:type text :delta "Done.")
    (:type usage :input 400 :output 30 :context 430)
    (:type done :stop-reason end-turn))
  "A reply whose request used no prompt cache.")

(defmacro harness-ui-cache-test-with (&rest body)
  "Load the state layer, the demo provider and the chat with the cache panel, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-ui-cache-test--cached)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (harness-cache-ttl-overrides nil)
           (default-directory dir))
       (dolist (m '(ui ui-compose ui-markdown ui-chat ui-cache))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-cache-test--open (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (with-current-buffer buffer
                                    (and (not harness-chat--loading) harness-compose-end)))
                       5 "the session to load")
    buffer))

(defun harness-ui-cache-test--status (sid)
  "Return SID's status as the UI last heard it, a string."
  (format "%s" (plist-get (harness-ui-session sid) :status)))

(defun harness-ui-cache-test--send (buffer text)
  "Send TEXT from BUFFER's compose box, as typed there; return when it ran.
That is once the UI heard of the session idle again, with the usage of
the request."
  (with-current-buffer buffer
    (let* ((sid harness-ui-session-id)
           (turns (or (plist-get (plist-get (harness-ui-session sid) :usage) :turns) 0)))
      (goto-char harness-compose-end)
      (insert text)
      (harness-chat-send)
      (harness-test-wait (lambda () (let ((s (harness-ui-session sid)))
                                      (and (equal "idle" (format "%s" (plist-get s :status)))
                                           (> (or (plist-get (plist-get s :usage) :turns) 0) turns))))
                         10 "the turn to end"))))

(defun harness-ui-cache-test--shows-p (buffer)
  "Non-nil when BUFFER shows the cache panel."
  (with-current-buffer buffer
    (text-property-any (point-min) (point-max) 'harness-ui-cache-panel t)))

(defun harness-ui-cache-test--text (buffer)
  "Return BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-cache-test--idle (seconds)
  "Let timers and processes run for SECONDS, with no input."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.02)
      (sit-for 0.005))))

(ert-deftest harness-ui-cache-panel-comes-on-its-own-and-goes-on-send ()
  "Past its cache's lifetime an idle session shows the panel without any
input, drawn by its buffer's timer.  Sending hides it while the request
runs; that request keeps the cache, so it shows again only once the
cache lapses again."
  (harness-ui-cache-test-with
    (let* ((harness-cache-ttl 2)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      ;; A new session: no cache, no timer, no panel.
      (with-current-buffer buffer (should-not harness-ui-cache--timer))
      (should-not (harness-ui-cache-test--shows-p buffer))
      (harness-ui-cache-test--send buffer "first")
      (let ((cache (plist-get (harness-ui-session sid) :cache)))
        (should (= 2 (plist-get cache :ttl)))
        ;; Still cached: no panel yet, and the timer is set for the moment it lapses.
        (should (< (float-time) (plist-get cache :expires)))
        (should-not (harness-ui-cache-test--shows-p buffer))
        (with-current-buffer buffer
          (should (timerp harness-ui-cache--timer))
          (should (= (plist-get cache :expires) harness-ui-cache--due))))
      ;; It comes on its own.
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel")
      (should (>= (float-time) (plist-get (plist-get (harness-ui-session sid) :cache) :expires)))
      (should (string-match-p "Prompt cache expired  at [0-9:]+, 2 seconds after its last use"
                              (harness-ui-cache-test--text buffer)))
      (should (string-match-p "Your next message re-sends ~84\\.5k tokens uncached"
                              (harness-ui-cache-test--text buffer)))
      (with-current-buffer buffer (should-not harness-ui-cache--timer))
      ;; Sent again, it goes while the request runs.
      (let ((harness-provider-demo--delay 0.4))
        (with-current-buffer buffer
          (goto-char harness-compose-end)
          (insert "again")
          (harness-chat-send))
        (harness-test-wait (lambda () (not (harness-ui-cache-test--shows-p buffer))) 5 "the panel to go")
        (should (equal "running" (harness-ui-cache-test--status sid)))
        (harness-test-wait (lambda () (equal "idle" (harness-ui-cache-test--status sid))) 10 "the turn to end"))
      ;; The request kept the cache: no panel until it lapses again.
      (harness-test-wait (lambda () (with-current-buffer buffer (timerp harness-ui-cache--timer)))
                         5 "the timer to be set again")
      (should-not (harness-ui-cache-test--shows-p buffer))
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel again")
      ;; A buffer opened once it lapsed shows it at once.
      (kill-buffer buffer)
      (should (harness-ui-cache-test--shows-p (harness-ui-cache-test--open sid))))))

(ert-deftest harness-ui-cache-panel-never-shows-without-a-cache ()
  "A new session and one whose requests used no cache never show the
panel, however long they wait; one that used the cache does, meanwhile."
  (harness-ui-cache-test-with
    (let* ((harness-cache-ttl 1)
           (new (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (plain (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                             :id))
           (cached (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                              :id))
           (new-buffer (harness-ui-cache-test--open new))
           (plain-buffer (harness-ui-cache-test--open plain))
           (cached-buffer (harness-ui-cache-test--open cached)))
      (let ((harness-provider-demo-script-override harness-ui-cache-test--uncached))
        (harness-ui-cache-test--send plain-buffer "no cache here"))
      (harness-ui-cache-test--send cached-buffer "cached")
      (should-not (plist-get (harness-ui-session new) :cache))
      (should-not (plist-get (harness-ui-session plain) :cache))
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p cached-buffer)) 10 "the cache panel")
      ;; Well past the lifetime.
      (harness-ui-cache-test--idle 1.5)
      (dolist (buffer (list new-buffer plain-buffer))
        (should-not (harness-ui-cache-test--shows-p buffer))
        (should-not (string-match-p "Prompt cache expired" (harness-ui-cache-test--text buffer)))
        (with-current-buffer buffer (should-not harness-ui-cache--timer))))))

(ert-deftest harness-ui-cache-timer-goes-with-the-buffer ()
  "Killing a chat buffer stops its cache timer."
  (harness-ui-cache-test-with
    (let* ((harness-cache-ttl 60)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (harness-ui-cache-test--send buffer "first")
      (let ((timer (buffer-local-value 'harness-ui-cache--timer buffer)))
        (should (memq timer timer-list))
        (kill-buffer buffer)
        (should-not (memq timer timer-list))))))

(provide 'harness-ui-cache-test)
;;; harness-ui-cache-test.el ends here
