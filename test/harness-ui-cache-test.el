;;; harness-ui-cache-test.el --- Tests for the expired prompt cache panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel above a session's compose box once its prompt cache has
;; expired: when it shows (a session waiting past its cache's lifetime,
;; never a new one or one that used no cache), what it says, and that it
;; comes on its own, drawn by its timer, and goes once a request is sent.
;; It stays away while a prompt the UI sent has no answer yet, whatever
;; the record of the session reads -- the UI may be behind the harness --
;; and comes back with the answer, or the failure, once the cache lapsed.
;; A cache a redaction dropped shows from the drop on, headed so, with no
;; cached price to compare with; the other caches' words stay as they
;; were.  The unit tests fix the clock; the others run the state layer
;; and the demo provider with a cache that lasts a second or two, or,
;; for the redaction, a fake hosted loop (Claude Code, Copilot).

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-cache)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-providers)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui--models)
(defvar harness-ui--live)
(defvar harness-ui--prompts)
(defvar harness-ui-prompt-functions)
(defvar harness-ui-session-id)
(defvar harness-chat-panel-functions)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat--buffers)
(defvar harness-compose-end)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(defvar harness-ui-handoff--prompt)
(defvar harness-compose-redraw-function)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-define-tool "harness-tools")
(declare-function harness-tool-ok "harness-tools" (content &rest props))
(declare-function harness-provider--forget "harness-provider" (id))

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
user: idle or closed.  Never before, never while its turn runs (a
session blocked on an answer is in the middle of one), never without a
cache."
  (let ((s (harness-ui-cache-test--session)))
    (should-not (harness-ui-cache--state s 1299.9))
    (should (harness-ui-cache--state s 1300.0))
    (should (= 84000 (plist-get (harness-ui-cache--state s 2000.0) :context)))
    (should (harness-ui-cache--state (harness-ui-cache-test--session :status "inactive") 2000.0))
    ;; A status as the harness process has it, a symbol.
    (should (harness-ui-cache--state (harness-ui-cache-test--session :status 'idle) 2000.0))
    ;; A blocked session waits on an answer, which is the middle of its
    ;; turn: the next request is that turn's, not the user's next message.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :status "blocked") 2000.0))
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :status 'blocked) 2000.0))
    ;; A running session's requests keep the cache.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :status "running") 2000.0))
    ;; A new session, or one whose requests used no cache.
    (should-not (harness-ui-cache--state (harness-ui-cache-test--session :cache nil) 2000.0))
    (should-not (harness-ui-cache--state nil 2000.0))
    ;; It reads the same however late it is asked, so nothing redraws it.
    (should (equal (harness-ui-cache--state s 1400.0) (harness-ui-cache--state s 90000.0)))))

(ert-deftest harness-ui-cache-state-while-a-turn-runs ()
  "A turn still running keeps the panel away, whatever status the cache
reads: a stale `idle' and a `blocked' session waiting on a tool approval
alike are mid-turn, and the panel speaks of the user's next message.
The live token figures the UI keeps say the turn runs; once they go and
the turn ended with the cache lapsed, the panel is back."
  (let* ((idle (harness-ui-cache-test--session :id "s-run"))
         (approval (harness-ui-cache-test--session
                    :id "s-run" :status "blocked"
                    :pending (list (list :id "p1" :kind "permission"
                                         :payload '(:tool "Bash" :command "make test"))))))
    (cl-letf (((symbol-function 'harness-ui-session-live)
               (lambda (id) (and (equal id "s-run")
                                 '(:context 84000 :output 10 :estimated 0)))))
      (should-not (harness-ui-cache--state idle 2000.0))
      (should-not (harness-ui-cache--state approval 2000.0))
      (should-not (harness-ui-cache--current approval 2000.0)))
    ;; The turn ended: the figures go and the panel comes back.
    (should (harness-ui-cache--state idle 2000.0))))

(ert-deftest harness-ui-cache-state-live-figures-kept-while-running ()
  "The live figures the UI keeps are what say a turn runs, so the panel
stays away while they are there and comes back once they go."
  (let ((s (harness-ui-cache-test--session :id "s-live")))
    (puthash "s-live" '(:context 84000 :output 10 :estimated 0) harness-ui--live)
    (unwind-protect
        (should-not (harness-ui-cache--state s 2000.0))
      (remhash "s-live" harness-ui--live))
    (should (harness-ui-cache--state s 2000.0))))

;;;; A prompt in flight

(defun harness-ui-cache-test--prompt (sid &optional on-error)
  "Send SID a prompt that nothing answers yet; return the promise of its answer.
The request goes nowhere: it is the promise the test settles, resolving it
as the harness does when the turn ends, rejecting it as a failure.
ON-ERROR handles the failure, as the sender of the prompt would."
  (let ((answer (harness-make-promise)))
    (cl-letf (((symbol-function 'harness-ui-request) (lambda (&rest _) answer)))
      (harness-ui-call-turn sid "session/prompt" (list :sessionId sid :prompt nil) #'ignore on-error))
    answer))

(ert-deftest harness-ui-cache-state-while-a-prompt-is-in-flight ()
  "A prompt the UI sent that has no answer yet keeps the panel away,
whatever the record of the session reads: idle, with the cache stamp of
the turn before, lapsed.  The UI may be behind the harness, which runs
the turn that prompt started, and the cache panel must not say the cache
expired about a session the user just messaged.  Once the answer came
and the record still says lapsed, the panel is back."
  (let ((harness-ui--prompts (make-hash-table :test 'equal))
        (s (harness-ui-cache-test--session :id "s-sent")))
    (should (harness-ui-cache--state s 2000.0))
    (let ((answer (harness-ui-cache-test--prompt "s-sent")))
      (should (harness-ui-prompt-in-flight-p "s-sent"))
      (should-not (harness-ui-cache--state s 2000.0))
      (should-not (harness-ui-cache--current s 2000.0))
      ;; However late it is.
      (should-not (harness-ui-cache--state s 90000.0))
      ;; A session it was not sent to waits for the user as it did.
      (should-not (harness-ui-prompt-in-flight-p "s-other"))
      (should (harness-ui-cache--state (harness-ui-cache-test--session :id "s-other") 2000.0))
      (harness-resolve answer '(:stopReason "end_turn")))
    (should-not (harness-ui-prompt-in-flight-p "s-sent"))
    (should (harness-ui-cache--state s 2000.0))))

(ert-deftest harness-ui-cache-state-counts-every-prompt-in-flight ()
  "A message sent while a turn runs steers it, and is answered when the
turn ends, as the message that started it: the session runs until the
last of its prompts is answered."
  (let ((harness-ui--prompts (make-hash-table :test 'equal))
        (s (harness-ui-cache-test--session :id "s-two")))
    (let ((first (harness-ui-cache-test--prompt "s-two"))
          (second (harness-ui-cache-test--prompt "s-two")))
      (harness-resolve second '(:stopReason "end_turn"))
      (should (harness-ui-prompt-in-flight-p "s-two"))
      (should-not (harness-ui-cache--state s 2000.0))
      (harness-resolve first '(:stopReason "end_turn"))
      ;; An answer counts once: the promise settled already.
      (harness-resolve first '(:stopReason "end_turn")))
    (should-not (harness-ui-prompt-in-flight-p "s-two"))
    (should (harness-ui-cache--state s 2000.0))))

(ert-deftest harness-ui-cache-state-after-a-prompt-failed ()
  "A prompt that failed is none in flight: the session is not counted as
running for good.  The failure goes to whoever sent the prompt, or else
to the echo area, but for that of a connection the UI let go of on
purpose, which is none."
  (let ((harness-ui--prompts (make-hash-table :test 'equal))
        (s (harness-ui-cache-test--session :id "s-fail"))
        (failures nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args) (push (apply #'format format-string args) messages))))
      ;; The sender handles it.
      (let ((answer (harness-ui-cache-test--prompt "s-fail" (lambda (err) (push err failures)))))
        (should-not (harness-ui-cache--state s 2000.0))
        (harness-reject answer '(acp-error -32603 "no model" nil)))
      (should-not (harness-ui-prompt-in-flight-p "s-fail"))
      (should (equal '((acp-error -32603 "no model" nil)) failures))
      (should-not messages)
      (should (harness-ui-cache--state s 2000.0))
      ;; Nobody does: the echo area says so, as for any request.
      (harness-reject (harness-ui-cache-test--prompt "s-fail") '(acp-error -32603 "no model" nil))
      (should (equal '("Harness: session/prompt failed: no model") messages))
      (should-not (harness-ui-prompt-in-flight-p "s-fail"))
      (should (harness-ui-cache--state s 2000.0))
      ;; The connection was replaced on purpose: the prompt is no longer
      ;; waiting on an answer, and nothing failed.
      (setq messages nil)
      (harness-reject (harness-ui-cache-test--prompt "s-fail")
                      (list 'acp-error -32003 "connection replaced" (list :closed "replaced")))
      (should-not messages)
      (should-not (harness-ui-prompt-in-flight-p "s-fail"))
      (should (harness-ui-cache--state s 2000.0)))))

(ert-deftest harness-ui-cache-state-callbacks-run-once-the-prompt-settled ()
  "The answer and the failure of a prompt reach their callbacks after the
UI let the prompt go, so what they draw is drawn without it."
  (let ((harness-ui--prompts (make-hash-table :test 'equal))
        (seen nil))
    (let ((answer (harness-make-promise)))
      (cl-letf (((symbol-function 'harness-ui-request) (lambda (&rest _) answer)))
        (harness-ui-call-turn "s-cb" "session/prompt" nil
                              (lambda (value) (push (list 'answered value (harness-ui-prompt-in-flight-p "s-cb")) seen))
                              (lambda (err) (push (list 'failed err (harness-ui-prompt-in-flight-p "s-cb")) seen))))
      (should (harness-ui-prompt-in-flight-p "s-cb"))
      (harness-resolve answer '(:stopReason "end_turn")))
    (let ((answer (harness-make-promise)))
      (cl-letf (((symbol-function 'harness-ui-request) (lambda (&rest _) answer)))
        (harness-ui-call-turn "s-cb" "session/prompt" nil
                              (lambda (value) (push (list 'answered value (harness-ui-prompt-in-flight-p "s-cb")) seen))
                              (lambda (err) (push (list 'failed err (harness-ui-prompt-in-flight-p "s-cb")) seen))))
      (harness-reject answer '(acp-error -32603 "no model" nil)))
    (should (equal '((failed (acp-error -32603 "no model" nil) nil)
                     (answered (:stopReason "end_turn") nil))
                   seen))))

(ert-deftest harness-ui-cache-state-after-the-session-was-deleted ()
  "A session that was deleted answers no prompt: the UI forgets the
prompts in flight to it with the session, and an answer that comes later
changes nothing."
  (let* ((harness-ui--prompts (make-hash-table :test 'equal))
         (harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui--live (make-hash-table :test 'equal))
         (other (harness-ui-cache-test--prompt "s-other")))
    (let ((answer (harness-ui-cache-test--prompt "s-gone")))
      (should (harness-ui-prompt-in-flight-p "s-gone"))
      (harness-ui--forget-session "s-gone")
      (should-not (harness-ui-prompt-in-flight-p "s-gone"))
      ;; Another session keeps its own.
      (should (harness-ui-prompt-in-flight-p "s-other"))
      (harness-resolve answer '(:stopReason "end_turn"))
      (should-not (harness-ui-prompt-in-flight-p "s-gone")))
    (harness-resolve other '(:stopReason "end_turn"))
    (should-not (harness-ui-prompt-in-flight-p "s-other"))))

(ert-deftest harness-ui-cache-every-request-for-a-turn-is-tracked ()
  "The UI sends a prompt, or the queue, only through `harness-ui-call-turn',
which keeps it in flight until it is answered.  Sent any other way, the
panel would go by the record of a UI that may be behind the harness."
  (let ((found 0))
    (dolist (file (directory-files (expand-file-name "lisp/ui" harness-test-root) t "\\`harness-.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "\"\\(?:session/prompt\\|_harness/agent/send-queue\\)\"" nil t)
          (cl-incf found)
          (should (string-match-p "(harness-ui-call-turn "
                                  (buffer-substring-no-properties (line-beginning-position) (point)))))))
    ;; The chat sends and sends the queue, the BTW asks.
    (should (>= found 3))))

(ert-deftest harness-ui-cache-reads-the-newest-record ()
  "The panel reads the newest record the UI took in -- the UI's cache,
which the session list and a fetch fill as well as every update -- not
the chat buffer's own copy of the last update, which can be older.  Once
the cache has forgotten the session, that copy serves."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (old (harness-ui-cache-test--session :id "s-rec"))
        (new (harness-ui-cache-test--session
              :id "s-rec" :cache '(:at 5000.0 :ttl 300 :expires 5300.0 :model "test:m"))))
    (with-temp-buffer
      (setq-local harness-ui-session-id "s-rec")
      (setq-local harness-chat--session old)
      (should (eq old (harness-ui-cache--session)))
      (should (harness-ui-cache--state (harness-ui-cache--session) 5100.0))
      ;; The session list brought a newer record, which the chat did not take in.
      (puthash "s-rec" new harness-ui--sessions)
      (should (eq new (harness-ui-cache--session)))
      (should-not (harness-ui-cache--state (harness-ui-cache--session) 5100.0))
      (should (harness-ui-cache--state (harness-ui-cache--session) 5300.0))
      ;; Deleted: the copy is what is left of it.
      (remhash "s-rec" harness-ui--sessions)
      (should (eq old (harness-ui-cache--session))))))

;;;; The panel of a chat buffer, followed

(defvar harness-ui-cache-test--drawn nil
  "What each drawing of the stand-in chat buffer's tail showed, newest first.
The panel's text, or nil for none.")

(defmacro harness-ui-cache-test-with-chat (sid &rest body)
  "Run BODY in a buffer that stands in for the chat buffer of session SID.
The buffer shows the cache panel.  Drawing its tail asks the panel and
puts what it answered on `harness-ui-cache-test--drawn'.  The UI's
sessions, live figures and prompts in flight are empty, and a prompt
sent or answered tells the panel (`harness-ui-prompt-functions').  Nobody
is asked what compacting costs."
  (declare (indent 1))
  `(progn
     (require 'harness-ui-chat)
     (let ((harness-ui--sessions (make-hash-table :test 'equal))
           (harness-ui--live (make-hash-table :test 'equal))
           (harness-ui--prompts (make-hash-table :test 'equal))
           (harness-chat--buffers (make-hash-table :test 'equal))
           (harness-ui-prompt-functions (list #'harness-ui-cache--on-prompt))
           (harness-ui-cache-test--drawn nil))
       (cl-letf (((symbol-function 'harness-ui-cache--estimate) #'ignore))
         (with-temp-buffer
           (setq-local harness-ui-session-id ,sid)
           (setq-local harness-chat-panel-functions nil)
           (harness-ui-cache--setup)
           (setq-local harness-compose-redraw-function
                       (lambda () (push (harness-ui-cache--panel) harness-ui-cache-test--drawn)))
           (puthash ,sid (current-buffer) harness-chat--buffers)
           (unwind-protect (progn ,@body)
             (harness-ui-cache--cancel)))))))

(defun harness-ui-cache-test--drawings ()
  "Return whether each drawing of the stand-in chat buffer's tail showed a panel.
A list of t and nil, newest first."
  (mapcar (lambda (drawing) (and drawing t)) harness-ui-cache-test--drawn))

(ert-deftest harness-ui-cache-newer-record-takes-the-panel-away-and-moves-the-timer ()
  "A `_harness/session' update that brings a newer cache stamp replaces
what the panel reads: the panel goes, and the buffer's timer is set for
the moment the new cache lapses -- moved when it lapses at another one,
left alone when the update changes nothing the panel says."
  (harness-ui-cache-test-with-chat "s-upd"
    (let* ((now (float-time))
           (stamp (lambda (at) (list :at at :ttl 300 :expires (+ at 300) :model "test:m")))
           (record (lambda (at) (harness-ui-cache-test--session :id "s-upd" :cache (funcall stamp at))))
           (update (lambda (session)
                     (puthash "s-upd" session harness-ui--sessions)
                     (harness-ui-cache--on-update
                      "s-upd" (list :sessionUpdate "_harness/session" :session session)))))
      ;; Lapsed a while ago: the panel shows, and there is no timer to set.
      (puthash "s-upd" (funcall record (- now 1000)) harness-ui--sessions)
      (harness-ui-cache--sync)
      (should (equal '(t) (harness-ui-cache-test--drawings)))
      (should-not harness-ui-cache--timer)
      ;; A request used the cache: the update goes, the timer is set.
      (funcall update (funcall record now))
      (should (equal '(nil t) (harness-ui-cache-test--drawings)))
      (should-not harness-ui-cache--shown)
      (should (= (+ now 300) harness-ui-cache--due))
      (let ((first harness-ui-cache--timer))
        (should (memq first timer-list))
        ;; A later one: the timer moves with it.
        (funcall update (funcall record (+ now 100)))
        (should (= (+ now 400) harness-ui-cache--due))
        (should (memq harness-ui-cache--timer timer-list))
        (should-not (memq first timer-list))
        (should-not (eq first harness-ui-cache--timer)))
      ;; Nothing the panel says changed: not drawn again, nor is the timer set again.
      (let ((drawn (length harness-ui-cache-test--drawn))
            (timer harness-ui-cache--timer))
        (funcall update (funcall record (+ now 100)))
        (harness-ui-cache--on-update "s-upd" '(:sessionUpdate "plan"))
        (should (= drawn (length harness-ui-cache-test--drawn)))
        (should (eq timer harness-ui-cache--timer)))
      ;; And the next one lapsed again: the update brings the panel back, with no timer.
      (funcall update (funcall record (- now 1000)))
      (should (equal '(t nil t) (harness-ui-cache-test--drawings)))
      (should-not harness-ui-cache--timer))))

(ert-deftest harness-ui-cache-panel-follows-the-prompts-in-flight ()
  "The panel goes as a message is sent, without waiting for the news that
the session runs, and is back with the answer once the cache lapsed,
which the record says; a message that failed brings it back as well.  A
turn that used the cache leaves nothing to draw again."
  (harness-ui-cache-test-with-chat "s-msg"
    (puthash "s-msg" (harness-ui-cache-test--session :id "s-msg") harness-ui--sessions)
    (harness-ui-cache--sync)
    (should (equal '(t) (harness-ui-cache-test--drawings)))
    ;; Sent: the record still says idle, and the panel is gone.
    (let ((answer (harness-ui-cache-test--prompt "s-msg")))
      (should (equal '(nil t) (harness-ui-cache-test--drawings)))
      (should-not harness-ui-cache--shown)
      ;; The turn ended with the cache lapsed still: the panel is back.
      (harness-resolve answer '(:stopReason "end_turn"))
      (should (equal '(t nil t) (harness-ui-cache-test--drawings)))
      (should harness-ui-cache--shown))
    ;; A message that failed.
    (let ((answer (harness-ui-cache-test--prompt "s-msg" #'ignore)))
      (should (equal '(nil t nil t) (harness-ui-cache-test--drawings)))
      (harness-reject answer '(acp-error -32603 "no model" nil))
      (should (equal '(t nil t nil t) (harness-ui-cache-test--drawings))))
    ;; A turn that used the cache: its record is in before its answer, and
    ;; the panel, away while it ran, has nothing to say.
    (let ((answer (harness-ui-cache-test--prompt "s-msg"))
          (now (float-time)))
      (puthash "s-msg" (harness-ui-cache-test--session
                        :id "s-msg" :cache (list :at now :ttl 300 :expires (+ now 300) :model "test:m"))
               harness-ui--sessions)
      (harness-resolve answer '(:stopReason "end_turn"))
      (should (equal '(nil t nil t nil t) (harness-ui-cache-test--drawings)))
      (should-not harness-ui-cache--shown))))

(ert-deftest harness-ui-cache-prompts-of-a-session-without-a-chat-draw-nothing ()
  "A prompt to a session no chat buffer shows draws nothing, and a hook
function that signals does not stop the prompt from being kept or let go."
  (harness-ui-cache-test-with-chat "s-here"
    (puthash "s-there" (harness-ui-cache-test--session :id "s-there") harness-ui--sessions)
    (let ((answer (harness-ui-cache-test--prompt "s-there")))
      (harness-resolve answer '(:stopReason "end_turn")))
    (should-not harness-ui-cache-test--drawn)
    ;; A hook function that signals does not stop the prompt.
    (let ((harness-ui-prompt-functions (list (lambda (_sid) (error "Broken hook")))))
      (let ((answer (harness-ui-cache-test--prompt "s-there")))
        (should (harness-ui-prompt-in-flight-p "s-there"))
        (harness-resolve answer '(:stopReason "end_turn"))
        (should-not (harness-ui-prompt-in-flight-p "s-there"))))))

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

(ert-deftest harness-ui-cache-no-other-model-without-the-session-model ()
  "A record that lacks its model says nothing of a switch, as the server's
cache model does: no other model's cache is named for it, so its panel
waits for the cache to lapse, as for a session on the cache's own model."
  (should-not (harness-ui-cache--other-model '(:cache (:model "claude:opus" :at 1.0 :ttl 300 :expires 301.0))))
  (should-not (harness-ui-cache--other-model '(:model nil :cache (:model "claude:opus"))))
  (should-not (harness-ui-cache--other-model '(:model "claude:opus" :cache (:model "claude:opus"))))
  (should (equal "claude:opus"
                 (harness-ui-cache--other-model '(:model "claude:sonnet" :cache (:model "claude:opus")))))
  ;; Idle, its cache still warm, and no model: nothing yet, and the panel
  ;; shows once the cache lapses, as it does for any session.
  (let ((s (harness-plist-remove
            (harness-ui-cache-test--session
             :cache '(:at 1000.0 :ttl 300 :expires 99000.0 :model "test:m"))
            :model)))
    (should-not (harness-ui-cache--state s 2000.0))
    (should (harness-ui-cache--state s 99000.0))))

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

;;;; A cache a redaction dropped

(defun harness-ui-cache-test--dropped (&rest overrides)
  "Return an idle session whose cache a redaction dropped at 1100, with OVERRIDES.
Its stamp, at 1000, would have kept the cache until 1300.  The cache is
as `session/get' reports it then: its `:expires' is the drop, and
`:dropped' says why."
  (apply #'harness-ui-cache-test--session
         :cache '(:at 1000.0 :ttl 300 :expires 1100.0 :model "test:m" :dropped 1100.0)
         overrides))

(ert-deftest harness-ui-cache-state-shows-a-dropped-cache-from-the-drop-on ()
  "A cache a redaction dropped has lapsed from the moment of the drop, 200
seconds before the clock of its stamp ran out, and the state says why
\(`:dropped').  The panel waits for the user as it does for a lapsed
cache.  States that read the same are `equal', whenever they are asked."
  (let ((s (harness-ui-cache-test--dropped)))
    (should-not (harness-ui-cache--state s 1099.9))
    (should (equal '(:at 1000.0 :ttl 300 :expires 1100.0 :context 84000 :model "test:m" :from nil
                         :dropped 1100.0)
                   (harness-ui-cache--state s 1100.0)))
    (should (= 1100.0 (plist-get (harness-ui-cache--state s 1200.0) :dropped)))
    (should (equal (harness-ui-cache--state s 1200.0) (harness-ui-cache--state s 90000.0)))
    ;; Closed, or waiting on the user, it shows; mid-turn, or blocked on an answer, it does not.
    (should (harness-ui-cache--state (harness-ui-cache-test--dropped :status "inactive") 2000.0))
    (should-not (harness-ui-cache--state (harness-ui-cache-test--dropped :status "running") 2000.0))
    (should-not (harness-ui-cache--state (harness-ui-cache-test--dropped :status "blocked") 2000.0))
    ;; A cache that lapsed by itself names no drop, and a drop that is no time is not read.
    (dolist (cache (list '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m")
                         '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m" :dropped nil)
                         '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m" :dropped :null)
                         '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m" :dropped :false)
                         '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m" :dropped "later")))
      (let ((state (harness-ui-cache--state (harness-ui-cache-test--session :cache cache) 2000.0)))
        (should state)
        (should-not (plist-member state :dropped))))))

(ert-deftest harness-ui-cache-banner-says-a-redaction-dropped-the-cache ()
  "A cache a redaction dropped is headed so, with the clock time of the drop
and no lifetime or age: it did not lapse.  The line under it names what
the next message costs uncached, and compares it with no cached price,
as none can be had; the tooltip says what the redaction did and what the
next message does.  Clock times only, with the day when it is not today's."
  (let ((harness-ui--models (make-hash-table :test 'equal))
        (dropped (harness-ui-cache-test--local 14 3))
        (icon (harness-ui-icon 'harness-icon-clock)))
    (puthash "test:m" '(:id "test:m" :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
             harness-ui--models)
    (puthash "test:plain" '(:id "test:plain" :pricing (:input 2.0 :output 8.0 :cache-read 0.5))
             harness-ui--models)
    ;; Stamped at 14:02, the cache had until 14:07: the redaction took it at 14:03.
    (let* ((cache (list :at (- dropped 60) :ttl 300 :expires dropped :model "test:m" :dropped dropped))
           (s (harness-ui-cache-test--session :cache cache))
           (now (+ dropped 600))
           (banner (harness-ui-cache--banner (harness-ui-cache--state s now) now)))
      ;; 84000 tokens written to the cache again at 3.75: what carrying on costs.
      (should (equal (concat " " icon " Prompt cache dropped  at 14:03, by a redaction\n"
                             "   Your next message re-sends ~84.0k tokens uncached: about $0.315, at list prices.\n")
                     (substring-no-properties banner)))
      (should (equal (concat "A redaction took a secret out of this conversation at "
                             (format-time-string "%H:%M:%S" dropped)
                             " and dropped the provider's copy of it, and its prompt cache with it.\n"
                             "Your next message sends the whole context, 84.0k tokens, at the uncached rate,"
                             " and caches it again.")
                     (get-text-property 0 'help-echo banner)))
      (should (get-text-property 0 'harness-ui-cache-panel banner))
      ;; Nothing of the lapsed cache's words, nor of a price to compare with.
      (should-not (string-match-p "expired\\|lapsed\\|instead of\\|after its last use"
                                  (concat banner (get-text-property 0 'help-echo banner))))
      ;; Drawn on a later day, the time says its day.
      (should (string-match-p "dropped  at Oct 7, 14:03, by a redaction$"
                              (harness-ui-cache-test--banner s (harness-ui-cache-test--local 9 0 8))))
      ;; A model priced without cache writes sends it again at its input price.
      (should (string-match-p "tokens uncached: about \\$0\\.168, at list prices\\.$"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session
                                :model "test:plain" :cache (list :at (- dropped 60) :ttl 300 :expires dropped
                                                                 :dropped dropped))
                               now)))
      ;; A model the catalogue does not price: no cost.
      (should (string-match-p "re-sends ~84\\.0k tokens uncached\\.$"
                              (harness-ui-cache-test--banner
                               (harness-ui-cache-test--session
                                :model "nobody:m" :cache (list :at (- dropped 60) :ttl 300 :expires dropped
                                                               :dropped dropped))
                               now))))))

(ert-deftest harness-ui-cache-banner-keeps-the-words-of-the-other-caches ()
  "A cache that lapsed by itself, and one held for another model, are told
in the words they always were, a cost compared with the cached price
included: a drop is a cache of its own kind, and changes nothing here.
A cache dropped and held for another model reads as the other model's,
as the new model has none of it either way."
  (let ((harness-ui--models (make-hash-table :test 'equal))
        (expires (harness-ui-cache-test--local 14 7))
        (icon (harness-ui-icon 'harness-icon-clock)))
    (puthash "test:m" '(:id "test:m" :label "Model M" :provider-label "Test"
                        :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
             harness-ui--models)
    (puthash "test:other" '(:id "test:other" :label "Model O" :provider-label "Test"
                            :pricing (:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25))
             harness-ui--models)
    ;; Lapsed: the heading, the cost against the cached price, the tooltip, the state.
    (let* ((now (+ expires 600))
           (cache (list :at (- expires 300) :ttl 300 :expires expires :model "test:m"))
           (state (harness-ui-cache--state (harness-ui-cache-test--session :cache cache) now))
           (banner (harness-ui-cache--banner state now)))
      (should (equal (list :at (- expires 300) :ttl 300 :expires expires :context 84000 :model "test:m" :from nil)
                     state))
      (should (equal (concat " " icon " Prompt cache expired  at 14:07, 5 minutes after its last use\n"
                             "   Your next message re-sends ~84.0k tokens uncached:"
                             " about $0.315 instead of $0.025, at list prices.\n")
                     (substring-no-properties banner)))
      (should (equal (concat "The provider keeps the start of a conversation cached for 5 minutes"
                             " after a request uses it.\n"
                             "This session's requests last used the cache at "
                             (format-time-string "%H:%M:%S" (- expires 300)) ", so it lapsed at "
                             (format-time-string "%H:%M:%S" expires) ".\n"
                             "Your next message sends the whole context, 84.0k tokens, at the uncached rate,"
                             " and caches it again.")
                     (get-text-property 0 'help-echo banner))))
    ;; Another model's: the same, whether or not the redaction dropped it as well.
    (dolist (cache '((:at 1000.0 :ttl 300 :expires 1300.0 :model "test:m")
                     (:at 1000.0 :ttl 300 :expires 1100.0 :model "test:m" :dropped 1100.0)))
      (let* ((state (harness-ui-cache--state (harness-ui-cache-test--session :model "test:other" :cache cache)
                                             1200.0))
             (banner (harness-ui-cache--banner state 1200.0))
             (model-m (harness-ui-model-label "test:m"))
             (model-o (harness-ui-model-label "test:other")))
        (should (equal "test:m" (plist-get state :from)))
        (should (equal (concat " " icon " Prompt cache cold  cached for " model-m ", not " model-o "\n"
                               "   Your next message re-sends ~84.0k tokens uncached:"
                               " about $0.105 instead of $0.0084, at list prices.\n")
                       (substring-no-properties banner)))
        (should (equal (concat "A provider caches a conversation for one model only.\n"
                               "This session's requests last used the cache of " model-m ", at "
                               (format-time-string "%H:%M:%S" 1000.0) "; " model-o " has none of it.\n"
                               "Your next message sends the whole context, 84.0k tokens, at the uncached rate,"
                               " and caches it again.")
                       (get-text-property 0 'help-echo banner)))))))

(ert-deftest harness-ui-cache-stays-away-while-the-switch-banner-asks ()
  "While the switch banner asks how to hand over, the panel does not show:
what the next message sends depends on the answer, which the banner
weighs.  The moment the cache lapses still draws the tail again, so the
banner says it did."
  (with-temp-buffer
    (let ((s (harness-ui-cache-test--session))
          (drawn 0))
      (should (harness-ui-cache--current s 2000.0))
      (setq-local harness-ui-handoff--prompt '(:checks nil))
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
            (:kind "transcript" :cost 0.0 :after 84)
            (:kind "fresh" :cost 0.0 :after 90)
            (:kind "truncate" :cost 0.0 :after 3000 :kept 3 :dropped 17
                   :kept-tokens 2000 :dropped-tokens 84000)))
  "What compacting costs, as `compaction/estimate' answers over ACP.")

(ert-deftest harness-ui-cache-offers-to-compact ()
  "Below what the next message costs, the panel offers to compact the
conversation first: a button for each kind, the cheap brief summary
first, with what it costs as the harness estimates it, and its key on
that line.  Before the estimate comes the buttons only name the kinds.
While a compaction the panel started runs, the line says so."
  (require 'harness-ui-chat)
  (with-temp-buffer
    (let ((state (harness-ui-cache--state (harness-ui-cache-test--session) 2000.0))
          (case-fold-search nil)
          (chosen nil))
      ;; Nobody to ask (no session here): the kinds, and the free one's cost.
      ;; The line under them says how to press a key from the compose box.
      (should (equal (concat "   Compact it first   b  Brief summary   s  Summary   t  Transcript file (free)"
                             "   f  Fresh start (free)   c  Cut old context (free)\n"
                             "   from the box: C-c . b\n")
                     (substring-no-properties (harness-ui-cache--offer state))))
      (setq harness-ui-cache--estimate (cons state harness-ui-cache-test--estimate))
      (let ((line (harness-ui-cache--offer state)))
        (should (equal (concat "   Compact it first   b  Brief summary (~$0.011)   s  Summary (~$0.463)"
                               "   t  Transcript file (free)   f  Fresh start (free)"
                               "   c  Cut old context (free)\n"
                               "   from the box: C-c . b\n")
                       (substring-no-properties line)))
        ;; Both lines are a panel of the compose box (`harness-compose-panel-key'),
        ;; and the keys answer on either.
        (should (cl-loop for i from 0 below (length line)
                         always (eq 'cache (get-text-property i 'harness-compose-panel line))))
        (should (eq (lookup-key (get-text-property 0 'keymap line) "t")
                    (lookup-key (get-text-property (string-match "from the box" line) 'keymap line) "t")))
        ;; Each key on the line compacts as its kind, and so does a click.
        (cl-letf (((symbol-function 'harness-ui-cache--compact) (lambda (_buffer kind) (push kind chosen))))
          (dolist (key '("b" "s" "t" "f" "c"))
            (funcall (lookup-key (get-text-property 0 'keymap line) key)))
          (funcall (get-text-property (string-match "Summary" line) 'harness-chat-action line)))
        (should (equal '(summary truncate fresh transcript summary brief) chosen))
        ;; A button's tooltip says what it does.
        (should (string-prefix-p "Brief summary (~$0.011): Small reads the conversation's narrative"
                                 (get-text-property (string-match "Brief summary" line) 'help-echo line)))
        ;; Last on the panel, which it is part of.
        (let ((banner (harness-ui-cache--banner state 2000.0 line)))
          (should (string-suffix-p (substring-no-properties line) (substring-no-properties banner)))
          (should (get-text-property (1- (length banner)) 'harness-ui-cache-panel banner))
          (should (string-match-p "lapsed at" (get-text-property 0 'help-echo banner)))
          (should (string-prefix-p "Summary (~$0.463): Big reads"
                                   (get-text-property (string-match "Summary" banner) 'help-echo banner)))))
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
       (clrhash harness-ui--live)
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
      ;; Sent again, it goes with the message, before the UI has heard the
      ;; session runs, and stays away while the request runs.
      (let ((harness-provider-demo--delay 0.4))
        (with-current-buffer buffer
          (goto-char harness-compose-end)
          (insert "again")
          (harness-chat-send))
        (should-not (harness-ui-cache-test--shows-p buffer))
        (harness-test-wait (lambda () (equal "running" (harness-ui-cache-test--status sid))) 5 "the session to run")
        (should-not (harness-ui-cache-test--shows-p buffer))
        (harness-test-wait (lambda () (equal "idle" (harness-ui-cache-test--status sid))) 10 "the turn to end"))
      ;; The request kept the cache: no panel until it lapses again.
      (harness-test-wait (lambda () (with-current-buffer buffer (timerp harness-ui-cache--timer)))
                         5 "the timer to be set again")
      (should-not (harness-ui-cache-test--shows-p buffer))
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel again")
      ;; A buffer opened once it lapsed shows it at once.
      (kill-buffer buffer)
      (should (harness-ui-cache-test--shows-p (harness-ui-cache-test--open sid))))))

(ert-deftest harness-ui-cache-panel-shows-for-a-session-whose-turn-a-tool-ended ()
  "A session handed in (`hand_in' ends its turn) says its cache expired like any.
Its provider, a hosted loop such as Claude Code, reports what the turn
used -- and with it when its last request used the cache -- only once
the turn is over, which the tool's end did before the provider could:
that report was dropped, and the session read 0 tokens and $0, had no
cache, and its chat never said the cache lapsed.  Reported after the
cancel, it stamps the session's cache, and the panel comes when it
lapses, without any input, as for a session whose turn ended by itself."
  (harness-ui-cache-test-with
    (harness-add-filter 'permission/decide
                        (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (harness-define-tool "finish" :label "Finish" :description "hand the work in" :kind 'meta
                         :handler (lambda (_input _ctx) (harness-tool-ok "Handed in." :end-turn t)))
    (harness-define-provider 'late
      :label "Late"
      :complete
      (lambda (request)
        (let ((on-event (plist-get request :on-event)))
          (funcall on-event '(:type start))
          (run-at-time 0.005 nil
                       (lambda ()
                         (funcall on-event (list :type 'tool-call :id "c1" :name "finish"
                                                 :input '(:why "done") :respond #'ignore))))
          (list :cancel (lambda ()
                          ;; What the CLI says once it has answered the interrupt.
                          (run-at-time 0.05 nil
                                       (lambda ()
                                         (funcall on-event (list :type 'usage :input 300 :output 20
                                                                 :cache-read 84000 :cache-write 200
                                                                 :context 84500 :cache-at (float-time)
                                                                 :cache-ttl 3))
                                         (funcall on-event '(:type done :stop-reason cancelled))))))))
      :capabilities '(:hosted-loop t))
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "late:loop")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (unwind-protect
          (progn
            (harness-ui-cache-test--send buffer "hand it in")
            ;; Its usage, and its cache, arrive after the turn ended.
            (harness-test-wait (lambda () (plist-get (harness-ui-session sid) :cache)) 10
                               "the cache of the turn a tool ended")
            (let* ((session (harness-ui-session sid))
                   (expires (plist-get (plist-get session :cache) :expires))
                   (shown (harness-ui-cache-test--shows-p buffer)))
              (should (= 84500 (plist-get (plist-get session :usage) :context)))
              (should (= 3 (plist-get (plist-get session :cache) :ttl)))
              ;; Not before the cache lapses (unless a slow machine took that long).
              (when (< (float-time) expires)
                (should-not shown)))
            ;; The panel comes by itself once the cache lapsed.
            (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel")
            (should (>= (float-time) (plist-get (plist-get (harness-ui-session sid) :cache) :expires)))
            (should (string-match-p "Prompt cache expired  at [0-9:]+, 3 seconds after its last use"
                                    (harness-ui-cache-test--text buffer)))
            (should (string-match-p "Your next message re-sends ~84\\.5k tokens uncached"
                                    (harness-ui-cache-test--text buffer))))
        (remhash 'late harness-providers)
        (harness-provider--forget 'late)))))

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

(defun harness-ui-cache-test--define-hosted ()
  "Define `hosted', a fake hosted loop, and wait for the UI to list its model.
A hosted loop (Claude Code, Copilot) keeps the conversation itself.  It
answers every request with a conversation state, a reply and usage that
wrote 400 tokens of cache, and its model is priced in the catalogue."
  (harness-define-provider 'hosted
    :label "Hosted"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "Hosted M" :context-window 200000
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.4 :cache-write 5.0)))))
    :complete (lambda (req)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type provider-state :state (:conv "c1")))
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type usage :input 30 :output 5
                                                           :cache-write 400 :context 430))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))
    :capabilities '(:hosted-loop t :resume t :fork t))
  (harness-test-wait (lambda () (gethash "hosted:m" harness-ui--models)) 5 "the UI to list the hosted model"))

(ert-deftest harness-ui-cache-panel-comes-at-once-when-a-redaction-drops-the-cache ()
  "A redaction resets a hosted session's provider conversation, and the
provider's cache of it goes with it.  The cache would have lasted ten
minutes more, but the panel shows at once, headed so, with no timer
waiting for a lapse and no cached price to compare with, and keeps
offering to compact.  The next message opens a new conversation whose
first request writes a cache of its own: the panel goes, and a timer
is set for the new lapse."
  (harness-ui-cache-test-with
    (harness-ui-cache-test--define-hosted)
    (unwind-protect
        (let* ((harness-cache-ttl 600)
               (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m")
                               :id))
               (buffer (harness-ui-cache-test--open sid)))
          (harness-ui-cache-test--send buffer "first")
          ;; Warm for ten minutes: no panel, a timer for the lapse.
          (let ((cache (plist-get (harness-ui-session sid) :cache)))
            (should (= 600 (plist-get cache :ttl)))
            (should-not (plist-get cache :dropped))
            (should-not (harness-ui-cache-test--shows-p buffer))
            (with-current-buffer buffer
              (should (timerp harness-ui-cache--timer))
              (should (= (plist-get cache :expires) harness-ui-cache--due))))
          ;; The redaction drops the provider conversation, and the cache with it.
          (should (equal '(:checkpoints 0 :cache-dropped t) (harness-call 'session/reset-provider sid)))
          (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 5 "the cache panel")
          (let ((cache (plist-get (harness-ui-session sid) :cache)))
            (should (numberp (plist-get cache :dropped)))
            (should (= (plist-get cache :dropped) (plist-get cache :expires)))
            (should (< (plist-get cache :dropped) (+ (plist-get cache :at) 600)))
            (with-current-buffer buffer (should-not harness-ui-cache--timer)))
          (let ((text (harness-ui-cache-test--text buffer)))
            (should (string-match-p "Prompt cache dropped  at [0-9:]+, by a redaction\n" text))
            (should (string-match-p (concat "\n   Your next message re-sends ~430 tokens uncached:"
                                            " about \\$[0-9.]+, at list prices\\.\n")
                                    text))
            (should-not (string-match-p "Prompt cache expired\\|instead of" text))
            (should (string-match-p "\n   Compact it first   b  Brief summary" text)))
          (with-current-buffer buffer
            (let ((help (get-text-property (harness-ui-cache-test--shows-p buffer) 'help-echo)))
              (should (string-match-p "\\`A redaction took a secret out of this conversation at [0-9:]+ and dropped the provider's copy of it, and its prompt cache with it\\.\n"
                                      help))
              (should (string-suffix-p "caches it again." help))))
          ;; The next message's request writes the new conversation's cache.
          (harness-ui-cache-test--send buffer "carry on")
          (should-not (plist-get (plist-get (harness-ui-session sid) :cache) :dropped))
          (harness-test-wait (lambda () (not (harness-ui-cache-test--shows-p buffer))) 5 "the panel to go")
          (with-current-buffer buffer (should (timerp harness-ui-cache--timer)))
          (should-not (string-match-p "Prompt cache dropped" (harness-ui-cache-test--text buffer)))
          ;; A buffer opened later does not show the old drop either.
          (kill-buffer buffer)
          (should-not (harness-ui-cache-test--shows-p (harness-ui-cache-test--open sid))))
      (remhash 'hosted harness-providers)
      (harness-provider--forget 'hosted))))

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
                                      "   t  Transcript file (free)   f  Fresh start (free)"
                                      "   c  Cut old context (free)\n")
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

(ert-deftest harness-ui-cache-panel-keys-can-be-pressed-from-the-box ()
  "The offer's keys type in the compose box; C-c . and a key press it there.
The offer says so under its buttons.  The draft stays in the box and so
does point, at the offset it had, though the tail is drawn again."
  (harness-ui-cache-test-with
    (harness-test-load-module 'compaction)
    (harness-test-load-module 'ui-compact)
    (let* ((harness-cache-ttl 1)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (harness-ui-cache-test--send buffer "first")
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel")
      (should (string-match-p "\n   from the box: C-c \\. b\n" (harness-ui-cache-test--text buffer)))
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "draft")
        (goto-char (+ harness-compose-start 2))
        ;; Typed in the box, t types.
        (execute-kbd-macro "t")
        (should (equal "drtaft" (harness-compose-text)))
        (goto-char (+ harness-compose-start 2))
        ;; Pressed from it, t compacts as a transcript file.
        (execute-kbd-macro (kbd "C-c . t"))
        (should (string-match-p "\n   Compacting the conversation into a transcript file…\n"
                                (harness-ui-cache-test--text buffer)))
        (should (equal "drtaft" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 2))))
      (harness-test-wait (lambda () (not (harness-ui-cache-test--shows-p buffer))) 5 "the panel to go")
      (should (equal "transcript"
                     (harness-node-compaction-kind
                      (cl-find 'compaction (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))
      (with-current-buffer buffer (should (equal "drtaft" (harness-compose-text)))))))

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

;;;; A UI behind the harness

(defconst harness-ui-cache-test--held
  '((:type wait :seconds 60)
    (:type text :delta "Never said.")
    (:type done :stop-reason end-turn))
  "A reply that waits a minute before it says a word: a turn the test holds.
The test ends it by cancelling the turn (`harness-ui-cache-test--end-turn').")

(defun harness-ui-cache-test--submit (buffer text)
  "Type TEXT in BUFFER's compose box and send it, without waiting for the turn."
  (with-current-buffer buffer
    (goto-char harness-compose-end)
    (insert text)
    (harness-chat-send)))

(defun harness-ui-cache-test--end-turn (sid)
  "Cancel the turn running in session SID, and wait for it to be over."
  (harness-call 'agent/cancel sid)
  (harness-test-wait (lambda () (not (harness-agent-running-p sid))) 10 "the held turn to end"))

(ert-deftest harness-ui-cache-panel-stays-away-while-a-prompt-is-in-flight ()
  "A UI that is behind the harness -- it reads its socket when input
comes -- still holds the session idle, with the cache stamp of the turn
before, while the turn the user's message started runs.  The panel
must not say the cache expired about a session the user just messaged:
it goes with the message, and stays away, whatever the record reads and
whenever its timer fires, until the answer comes; then, the cache having
lapsed, it is back."
  (harness-ui-cache-test-with
    (let* ((harness-cache-ttl 1)
           (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid)))
      (harness-ui-cache-test--send buffer "first")
      (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel")
      (let ((stale (harness-ui-session sid))
            (harness-provider-demo-script-override harness-ui-cache-test--held))
        (should (equal "idle" (harness-ui-cache-test--status sid)))
        ;; The message goes out, and the panel goes with it: the UI has
        ;; not heard a word of the harness since.
        (harness-ui-cache-test--submit buffer "again")
        (should (harness-ui-prompt-in-flight-p sid))
        (should-not (harness-ui-cache-test--shows-p buffer))
        ;; The record the UI holds is still the old one: idle, lapsed.  Its
        ;; timer fires, the tail is drawn, and the panel does not show.
        (harness-ui-cache-session stale)
        (should (equal "idle" (harness-ui-cache-test--status sid)))
        (harness-ui-cache--lapse buffer)
        (should-not (harness-ui-cache-test--shows-p buffer))
        (with-current-buffer buffer (harness-ui-cache--sync))
        (should-not (harness-ui-cache-test--shows-p buffer))
        ;; The harness catches up: the session runs, and the panel is away.
        (harness-test-wait (lambda () (equal "running" (harness-ui-cache-test--status sid))) 5
                           "the session to run")
        (harness-ui-cache-test--idle 0.2)
        (should-not (harness-ui-cache-test--shows-p buffer))
        (should (harness-ui-prompt-in-flight-p sid))
        ;; The turn ends: the answer comes, and the cache, lapsed since
        ;; the turn before, makes the panel return.
        (harness-ui-cache-test--end-turn sid)
        (harness-test-wait (lambda () (not (harness-ui-prompt-in-flight-p sid))) 10 "the prompt's answer")
        (harness-test-wait (lambda () (harness-ui-cache-test--shows-p buffer)) 10 "the cache panel again")
        (should (string-match-p "Prompt cache expired" (harness-ui-cache-test--text buffer)))))))

(ert-deftest harness-ui-cache-prompt-ends-with-its-connection ()
  "A connection that closes rejects the requests pending on it: a prompt
in flight on it is none any more, and the session is not counted as
running for good.  The failure is reported in the chat, as that of any
message that did not go through."
  (harness-ui-cache-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid))
           (harness-provider-demo-script-override harness-ui-cache-test--held))
      (harness-ui-cache-test--submit buffer "hold on")
      (should (harness-ui-prompt-in-flight-p sid))
      (harness-acp-close harness-ui-connection)
      (harness-test-wait (lambda () (not (harness-ui-prompt-in-flight-p sid))) 5
                         "the prompt to end with its connection")
      (harness-test-wait (lambda () (string-match-p "send failed: connection closed"
                                                    (harness-ui-cache-test--text buffer)))
                         5 "the failure in the chat")
      ;; The harness still runs the turn.
      (harness-ui-cache-test--end-turn sid))))

(ert-deftest harness-ui-cache-prompt-ends-when-the-ui-connects-again ()
  "A UI that connects again lets go of its connection on purpose: the
requests pending on it are rejected as replaced, so the prompt in flight
on it is none any more -- the UI hears the session's status from the
harness afresh -- and nothing is reported as failed: the message went,
and its turn runs."
  (harness-ui-cache-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")
                           :id))
           (buffer (harness-ui-cache-test--open sid))
           (harness-provider-demo-script-override harness-ui-cache-test--held))
      (harness-ui-cache-test--submit buffer "hold on")
      (should (harness-ui-prompt-in-flight-p sid))
      (harness-ui-connect harness-ui-connection-address)
      (harness-test-wait (lambda () (not (harness-ui-prompt-in-flight-p sid))) 5
                         "the prompt to end with its connection")
      ;; The UI asks the harness what the session does, and is told.
      (harness-test-wait (lambda () (equal "running" (harness-ui-cache-test--status sid))) 5
                         "the session to run")
      (harness-ui-cache-test--idle 0.2)
      (should-not (string-match-p "failed" (harness-ui-cache-test--text buffer)))
      (harness-ui-cache-test--end-turn sid))))

(provide 'harness-ui-cache-test)
;;; harness-ui-cache-test.el ends here
