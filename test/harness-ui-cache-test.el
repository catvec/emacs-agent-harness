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
(defvar harness-ui-switch--prompt)
(defvar harness-compose-redraw-function)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-acp--drop-client "harness-acp")

;;;; What the panel shows, the clock fixed

(defun harness-ui-cache-test--session (&rest overrides)
  "Return an idle session plist whose cache lapsed at 1300, with OVERRIDES."
  (harness-plist-merge
   (list :id "s1" :status "idle" :model "test:m"
         :usage '(:context 84000 :cache-at 1000.0)
         :cache '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m"))
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

(ert-deftest harness-ui-cache-state-after-a-switch ()
  "Switched to another model, a session finds nothing cached for it: the
panel shows at once, whatever the time, naming the model whose cache it
was, until a request caches the conversation for the new model or the
session switches back while the old cache lasts."
  (let ((s (harness-ui-cache-test--session :model "test:other")))
    (should (equal "test:m" (plist-get (harness-ui-cache--state s 1000.0) :from)))
    (should (equal (harness-ui-cache--state s 1000.0) (harness-ui-cache--state s 90000.0)))
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :model "test:other" :status "running")
                                         1000.0))
    ;; Back on the cache's model while it lasts: nothing to say.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session) 1000.0))
    (should-not (plist-get (harness-ui-cache--state (harness-ui-cache-test--session) 2000.0) :from))
    ;; A cache that names no model is the session's own.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session
                                          :model "test:other" :cache '(:at 1000.0 :ttl 300 :expires 1300.0))
                                         1000.0))))

(ert-deftest harness-ui-cache-banner-after-a-switch ()
  "Switched, the panel says whose cache it was, and what the new model's
first request costs uncached against cached, at its own list prices."
  (let ((harness-ui--models (make-hash-table :test 'equal)))
    (puthash "test:m" '(:id "test:m" :label "Model M" :provider-label "Test"
                        :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
             harness-ui--models)
    (puthash "test:other" '(:id "test:other" :label "Model O" :provider-label "Test"
                            :pricing (:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25))
             harness-ui--models)
    (let* ((s (harness-ui-cache-test--session :model "test:other"))
           (text (harness-ui-cache-test--banner s 1100.0)))
      (should (string-match-p (format "Prompt cache cold  cached for %s, not %s$"
                                      (regexp-quote (harness-ui-model-label "test:m"))
                                      (regexp-quote (harness-ui-model-label "test:other")))
                              text))
      ;; 84000 tokens written to the new model's cache at 1.25, against read at 0.1.
      (should (string-match-p "^   Your next message re-sends ~84\\.0k tokens uncached: about \\$0\\.105 instead of \\$0\\.0084, at list prices\\.$"
                              text))
      (should (string-match-p "for one model only"
                              (get-text-property 0 'help-echo (harness-ui-cache--banner
                                                               (harness-ui-cache--state s 1100.0) 1100.0)))))))

(ert-deftest harness-ui-cache-stays-away-while-the-switch-banner-asks ()
  "While the switch banner asks how to hand over, the panel does not show:
what the next message sends depends on the answer, which the banner
weighs.  The moment the cache lapses still draws the tail again, so the
banner says it did."
  (with-temp-buffer
    (let ((s (harness-ui-cache-test--session))
          (drawn 0))
      (should (harness-ui-cache--current s 2000.0))
      (setq-local harness-ui-switch--prompt '(:checks nil))
      (should-not (harness-ui-cache--current s 2000.0))
      (setq-local harness-compose-redraw-function (lambda () (cl-incf drawn)))
      (cl-letf (((symbol-function 'harness-compose-redraw)
                 (lambda () (funcall harness-compose-redraw-function))))
        (harness-ui-cache--lapse (current-buffer)))
      (should (= 1 drawn)))))

(ert-deftest harness-ui-cache-cost-when-writes-cost-nothing ()
  "A provider that does not charge for cache writes (DeepSeek, priced 0
for them) charges the input for what is sent again uncached."
  (let ((harness-ui--models (make-hash-table :test 'equal)))
    (puthash "test:ds" '(:id "test:ds" :pricing (:input 0.15 :output 0.6 :cache-read 0.003 :cache-write 0.0))
             harness-ui--models)
    (should (string-match-p "^   Your next message re-sends ~84\\.0k tokens uncached: about \\$0\\.013 instead of \\$0\\.0003, at list prices\\.$"
                            (harness-ui-cache-test--banner
                             (harness-ui-cache-test--session
                              :model "test:ds" :cache '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:ds"))
                             2000.0)))))

(defconst harness-ui-cache-test--estimate
  '(:context 84000 :model "test:m" :model-label "Big" :cached nil :carry-on 0.315 :compacting nil
    :kinds ((:kind "summary" :model "test:m" :model-label "Big" :input 84041 :output 2000
                   :cached nil :cost 0.462705 :after 2000)
            (:kind "brief" :model "test:small" :model-label "Small" :input 725 :output 2000
                   :cached nil :cost 0.01090625 :after 2000)
            (:kind "transcript" :cost 0.0 :after 84)))
  "What compacting costs, as `compaction/estimate' answers over ACP.")

(ert-deftest harness-ui-cache-offers-to-compact ()
  "Below what the next message costs, the panel offers to compact the
conversation first: a button for each kind, the cheap brief summary
first, with what it costs as the harness estimates it, and its key on
that line.  Before the estimate comes the buttons only name the kinds.
A session blocked inside a turn is offered nothing; while a compaction
the panel started runs, the line says so."
  (require 'harness-ui-chat)
  (with-temp-buffer
    (let ((state (harness-ui-cache--state (harness-ui-cache-test--session) 2000.0))
          (case-fold-search nil)
          (chosen nil))
      ;; Nobody to ask (no session here): the kinds, and the free one's cost.
      (should (equal "   Compact it first   b  Brief summary   s  Summary   t  Transcript file (free)\n"
                     (substring-no-properties (harness-ui-cache--offer state))))
      (setq harness-ui-cache--estimate (cons state harness-ui-cache-test--estimate))
      (let ((line (harness-ui-cache--offer state)))
        (should (equal (concat "   Compact it first   b  Brief summary (~$0.011)   s  Summary (~$0.463)"
                               "   t  Transcript file (free)\n")
                       (substring-no-properties line)))
        ;; Each key on the line compacts as its kind, and so does a click.
        (cl-letf (((symbol-function 'harness-ui-cache--compact) (lambda (_buffer kind) (push kind chosen))))
          (dolist (key '("b" "s" "t"))
            (funcall (lookup-key (get-text-property 0 'keymap line) key)))
          (funcall (get-text-property (string-match "Summary" line) 'harness-chat-action line)))
        (should (equal '(summary transcript summary brief) chosen))
        ;; A button's tooltip says what it does.
        (should (string-prefix-p "Brief summary (~$0.011): Small reads only the first and last messages"
                                 (get-text-property (string-match "Brief summary" line) 'help-echo line)))
        ;; Last on the panel, which it is part of.
        (let ((banner (harness-ui-cache--banner state 2000.0 line)))
          (should (string-suffix-p (substring-no-properties line) (substring-no-properties banner)))
          (should (get-text-property (1- (length banner)) 'harness-ui-cache-panel banner))
          (should (string-match-p "lapsed at" (get-text-property 0 'help-echo banner)))
          (should (string-prefix-p "Summary (~$0.463): Big reads"
                                   (get-text-property (string-match "Summary" banner) 'help-echo banner)))))
      ;; Blocked on an answer: the turn is not over.
      (should-not (harness-ui-cache--offer (plist-put (copy-sequence state) :blocked t)))
      (setq harness-ui-cache--compacting 'brief)
      (should (equal "   Compacting the conversation into a brief summary…\n"
                     (substring-no-properties (harness-ui-cache--offer state)))))))

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

(ert-deftest harness-ui-cache-panel-after-a-switch ()
  "Switched to another model after a cached turn, the session shows the
panel at once: the new model has nothing of the conversation cached.
Switched back while the cache lasts, it goes, and the timer is set for
the lapse again; the new model's first request caches the conversation
for it, and the panel goes for good."
  (harness-ui-cache-test-with
    (let* ((harness-cache-ttl 600)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (harness-ui-cache-test--send buffer "first")
      (should-not (harness-ui-cache-test--shows-p buffer))
      (harness-call 'session/update sid :model "demo:other" :silent t)
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 5 "the cache panel")
      (should (string-match-p "Prompt cache cold  cached for .*, not " (harness-ui-cache-test--text buffer)))
      (should (string-match-p "Your next message re-sends ~84\\.5k tokens uncached"
                              (harness-ui-cache-test--text buffer)))
      (with-current-buffer buffer (should-not harness-ui-cache--timer))
      (harness-call 'session/update sid :model "demo:scripted" :silent t)
      (harness-test-wait (lambda () (not (harness-ui-cache-test--shows-p buffer))) 5 "the panel to go")
      (with-current-buffer buffer (should (timerp harness-ui-cache--timer)))
      (harness-call 'session/update sid :model "demo:other" :silent t)
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 5 "the cache panel again")
      (harness-ui-cache-test--send buffer "on the other model")
      (should-not (harness-ui-cache-test--shows-p buffer))
      (should (equal "demo:other" (plist-get (plist-get (harness-ui-session sid) :cache) :model))))))

(ert-deftest harness-ui-cache-panel-compacts-the-conversation ()
  "Once the cache lapsed, the panel offers to compact the conversation,
saying what each kind costs once the harness has estimated it.  A key on
that line compacts it: the panel says so while it runs, and goes once
the conversation is compacted, as nothing of it is cached any more."
  (harness-ui-cache-test-with
    (harness-test-load-module 'compaction)
    (harness-test-load-module 'ui-compact)
    (let* ((harness-cache-ttl 1)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (harness-ui-cache-test--send buffer "first")
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel")
      ;; The demo model is priced: the estimate gives both summaries a cost.
      (harness-test-wait (lambda () (string-match-p "Brief summary (~\\$" (harness-ui-cache-test--text buffer)))
                         5 "the costs")
      (should (string-match-p (concat "\n   Compact it first   b  Brief summary (~\\$[0-9.]+)   s  Summary (~\\$[0-9.]+)"
                                      "   t  Transcript file (free)\n")
                              (harness-ui-cache-test--text buffer)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "Compact it first")
        (execute-kbd-macro "t")
        (should (string-match-p "\n   Compacting the conversation into a transcript file…\n"
                                (harness-ui-cache-test--text buffer))))
      (harness-test-wait (lambda () (not (harness-ui-cache-test--shows-p buffer))) 5 "the panel to go")
      (should (equal "transcript"
                     (harness-node-compaction-kind
                      (cl-find 'compaction (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))
      (should-not (plist-get (harness-ui-session sid) :cache))
      (with-current-buffer buffer (should-not harness-ui-cache--compacting))
      (harness-test-wait (lambda () (string-match-p "context compacted into a transcript file"
                                                    (harness-ui-cache-test--text buffer)))
                         5 "the compaction in the chat"))))

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
