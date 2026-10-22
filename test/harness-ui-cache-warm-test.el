;;; harness-ui-cache-warm-test.el --- Tests for a prompt cache kept warm, in the UI  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI's half of keeping a session's prompt cache warm
;; (harness-ui-cache-warm.el): the cache of the warm states the harness
;; announces, the flame and the coarse countdown in a chat's header line,
;; the timer that redraws them only while one shows, the reports that the
;; user is active in a chat, and the period the user sets by hand
;; (`harness-cache-keep-warm', /warm, K).  The unit tests fix the clock and
;; stand in for the harness: `harness-ui-call' only records what the UI
;; asks, and the test answers it, or fails it.  The last tests run the
;; module against the harness's bus over the in-process ACP connection,
;; with the cache methods the real harness has, so the names the UI asks
;; with are those the harness answers to.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-chat)
(require 'harness-ui-cache-warm)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-acp-extra-method-prefixes)
(defvar harness-acp-extra-events)
(defvar harness-chat-commands)
(defvar harness-chat-mode-hook)
(defvar harness-chat-header-end-functions)
(defvar harness-ui--sessions)
(defvar harness-ui-event-functions)
(defvar harness-ui-connected-hook)
(defvar harness-ui-map)
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-chat--header "harness-ui-chat")

(defvar harness-ui-cache-warm-test--calls nil
  "The requests the UI made, newest first, each (METHOD PARAMS CALLBACK ON-ERROR).")

(defmacro harness-ui-cache-warm-test-with (&rest body)
  "Run BODY with no warm state, no timer, and a harness that only listens.
`harness-ui-call' records the request in `harness-ui-cache-warm-test--calls'
and answers nothing: a test answers it by calling its callback, or fails it
by calling its error handler."
  (declare (indent 0))
  `(let ((harness-ui-cache-warm--states (make-hash-table :test 'equal))
         (harness-ui-cache-warm--timer nil)
         (harness-ui-cache-warm--unavailable nil)
         (harness-ui-cache-warm-functions nil)
         (harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui-cache-warm-test--calls nil))
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params callback &optional on-error)
                  (push (list method params callback on-error) harness-ui-cache-warm-test--calls)
                  nil)))
       (unwind-protect (progn ,@body)
         (when (timerp harness-ui-cache-warm--timer)
           (cancel-timer harness-ui-cache-warm--timer))))))

(defun harness-ui-cache-warm-test--state (now &rest overrides)
  "Return the warm state of session s1 at NOW, as the harness sends it, with OVERRIDES.
It is kept warm for 12 more minutes (the warming period of a five-minute
cache with the user active a moment ago), after two refreshes."
  (harness-plist-merge
   (list :session-id "s1" :warming t :supported t
         :until (+ now 720) :manual-until nil :active-at (- now 5)
         :next (+ now 290) :expires (+ now 300) :ttl 300 :refreshes 2)
   overrides))

(defun harness-ui-cache-warm-test--icon ()
  "The flame's text, as it reads in batch: its symbol fallback."
  (substring-no-properties (harness-ui-icon 'harness-icon-flame)))

(defun harness-ui-cache-warm-test--last-call (&optional method)
  "Return the newest request the UI made, of METHOD when given."
  (cl-find-if (lambda (call) (or (null method) (equal method (car call))))
              harness-ui-cache-warm-test--calls))

(defun harness-ui-cache-warm-test--said (thunk)
  "Run THUNK and return what it put in the echo area, oldest first."
  (let (shown)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (when format-string (push (apply #'format format-string args) shown)))))
      (funcall thunk))
    (nreverse shown)))

;;;; Periods

(ert-deftest harness-ui-cache-warm-parse-duration-reads-periods ()
  "A period is minutes by default and says its unit otherwise: 30m, 1h, 1h30m,
a number of minutes after hours, decimals, words.  off, stop and 0 say
there is none, and no period is longer than 24 hours."
  (dolist (case '(("30m" . 1800) ("30M" . 1800) (" 20 minutes " . 1200) ("5 mins" . 300)
                  ("1h" . 3600) ("1H" . 3600) ("2 hrs" . 7200) ("1h30m" . 5400) ("1h 30m" . 5400)
                  ("1h30" . 5400) ("1 hour 15 minutes" . 4500) ("1 hour and 15 minutes" . 4500)
                  ("1,5h" . 5400) ("1h, 30m" . 5400) ("1h,30m" . 5400)
                  ("90" . 5400) ("1.5h" . 5400) ("0.5h" . 1800) ("45s" . 45)
                  ("1d" . 86400) ("2d" . 86400) ("25h" . 86400) ("24h" . 86400)
                  ("off" . 0) ("OFF" . 0) ("stop" . 0) ("none" . 0) ("no" . 0) ("clear" . 0)
                  ("cancel" . 0) ("0" . 0) ("0m" . 0)))
    (should (equal (cdr case) (harness-ui-cache-warm-parse-duration (car case))))))

(ert-deftest harness-ui-cache-warm-parse-duration-refuses-what-is-no-period ()
  "Text that says no period is a `user-error' that names it and gives examples,
and a number with no unit after minutes or seconds is not guessed at."
  (dolist (text '("" "   " "abc" "h" "-5m" "1m30" "1h30m45" "30 parsecs" "m30" "1h and"))
    (should-error (harness-ui-cache-warm-parse-duration text) :type 'user-error))
  (should-error (harness-ui-cache-warm-parse-duration nil) :type 'user-error)
  (should (string-match-p "Cannot read “abc” as a period: try 30m, 1h30m or off"
                          (cadr (should-error (harness-ui-cache-warm-parse-duration " abc ")
                                              :type 'user-error))))
  (should (string-match-p "Say how long"
                          (cadr (should-error (harness-ui-cache-warm-parse-duration "")
                                              :type 'user-error)))))

(ert-deftest harness-ui-cache-warm-countdown-is-coarse ()
  "A countdown reads in whole minutes, rounded up, and in hours and minutes
from an hour; under a minute it says so.  It changes once a minute."
  (dolist (case '((-5 . "<1m") (0 . "<1m") (1 . "<1m") (59 . "<1m") (59.9 . "<1m")
                  (60 . "1m") (61 . "2m") (119 . "2m") (120 . "2m") (121 . "3m")
                  (720 . "12m") (719.9 . "12m") (3540 . "59m") (3541 . "1h") (3599 . "1h")
                  (3600 . "1h") (3601 . "1h01m") (3660 . "1h01m") (3661 . "1h02m")
                  (4800 . "1h20m") (4860 . "1h21m")
                  (7200 . "2h") (7260 . "2h01m") (86400 . "24h")))
    (should (equal (cdr case) (harness-ui-cache-warm-countdown (car case))))))

;;;; The states

(ert-deftest harness-ui-cache-warm-read-tidies-what-came-over-json ()
  "A state read from the wire has t or nil for its booleans, numbers or nil
for its times, and a count: whatever the harness sent that is none of
those becomes nothing, and a state without `:supported' is of a session
that can be kept warm.  What is no state is nil."
  (let ((read (harness-ui-cache-warm--read
               "s9" '(:session-id "s1" :warming t :supported :false :until 1500.5 :manual-until 1400
                      :active-at "yesterday" :next 1290.0 :expires 1300.0 :ttl 300 :refreshes 3))))
    (should (equal '(:session-id "s1" :warming t :supported nil :tool nil :until 1500.5 :manual-until 1400
                     :active-at nil :next 1290.0 :expires 1300.0 :ttl 300 :refreshes 3
                     :max-refreshes nil :refresh-cost nil :resend-cost nil :blocked nil)
                   read)))
  (let ((read (harness-ui-cache-warm--read "s9" '(:warming :false :refreshes -1 :ttl "300"))))
    (should (equal "s9" (plist-get read :session-id)))
    (should-not (plist-get read :warming))
    (should (plist-get read :supported))
    (should (= 0 (plist-get read :refreshes)))
    (should-not (plist-get read :ttl)))
  (should-not (harness-ui-cache-warm--read "s1" nil))
  (should-not (harness-ui-cache-warm--read "s1" "warm"))
  (should-not (harness-ui-cache-warm--read "s1" '("not" "a" "plist"))))

(ert-deftest harness-ui-cache-warm-read-takes-the-harness-prices-and-reasons ()
  "A state tells whether a tool call is waited on, how many refreshes pay, what
one costs against sending the conversation again, and why nothing is kept
warm.  What is not of the type -- a price that is a word, a reason that is
blank -- is nothing."
  (let ((read (harness-ui-cache-warm--read
               "s1" '(:warming :false :tool t :max-refreshes 12 :refresh-cost 0.0169 :resend-cost 0.4225
                      :blocked "  A refresh would cost about what sending it again does.  "))))
    (should (eq t (plist-get read :tool)))
    (should (= 12 (plist-get read :max-refreshes)))
    (should (= 0.0169 (plist-get read :refresh-cost)))
    (should (= 0.4225 (plist-get read :resend-cost)))
    (should (equal "A refresh would cost about what sending it again does." (plist-get read :blocked))))
  (let ((read (harness-ui-cache-warm--read
               "s1" '(:tool :false :max-refreshes "12" :refresh-cost "free" :resend-cost :false :blocked 5))))
    (should-not (plist-get read :tool))
    (should-not (plist-get read :max-refreshes))
    (should-not (plist-get read :refresh-cost))
    (should-not (plist-get read :resend-cost))
    (should-not (plist-get read :blocked)))
  (should-not (plist-get (harness-ui-cache-warm--read "s1" '(:blocked "   ")) :blocked))
  (should (= 0 (plist-get (harness-ui-cache-warm--read "s1" '(:max-refreshes 0)) :max-refreshes))))

(ert-deftest harness-ui-cache-warm-cache-follows-the-harness ()
  "`cache/warm-changed' brings a session's state, nil once it has none;
a session deleted has none either; every change runs the hook, and
after a reload the states are fetched again."
  (harness-ui-cache-warm-test-with
    (let ((seen nil) (now (float-time)))
      (add-hook 'harness-ui-cache-warm-functions
                (lambda (sid state) (push (list sid (and state (plist-get state :refreshes))) seen)))
      (should-not (harness-ui-cache-warm-state "s1"))
      (harness-ui-cache-warm--on-event
       "cache/warm-changed" (list "s1" (harness-ui-cache-warm-test--state now)))
      (should (plist-get (harness-ui-cache-warm-state "s1") :warming))
      (should (= (+ now 720) (plist-get (harness-ui-cache-warm-state "s1") :until)))
      (should (equal '(("s1" 2)) seen))
      ;; Another session's state is its own.
      (harness-ui-cache-warm--on-event
       "cache/warm-changed" (list "s2" (harness-ui-cache-warm-test--state now :session-id "s2" :refreshes 0)))
      (should (equal '(("s2" 0) ("s1" 2)) seen))
      (should (harness-ui-cache-warm-state "s2"))
      ;; The period ended.
      (harness-ui-cache-warm--on-event "cache/warm-changed" (list "s1" nil))
      (should-not (harness-ui-cache-warm-state "s1"))
      (should (equal '("s1" nil) (car seen)))
      ;; A deleted session has none.
      (harness-ui-cache-warm--on-event "session/deleted" (list "s2" '(:id "s2")))
      (should-not (harness-ui-cache-warm-state "s2"))
      ;; Events that are none of its business.
      (let ((count (length seen)))
        (harness-ui-cache-warm--on-event "decision/changed" (list '(:id "d-1")))
        (harness-ui-cache-warm--on-event "cache/warm-changed" nil)
        (harness-ui-cache-warm--on-event "cache/warm-changed" (list 42 nil))
        (should (= count (length seen))))
      ;; A reload fetches them all again.
      (harness-ui-cache-warm--on-event "harness/reloaded" nil)
      (should (equal "_harness/cache/warm-list" (car (harness-ui-cache-warm-test--last-call)))))))

(ert-deftest harness-ui-cache-warm-refresh-replaces-the-cache ()
  "The states are fetched whole: what the harness lists replaces the cache,
the hook runs with nil, and a state it no longer lists is gone.  A harness
without the module answers that it has no such method, which leaves the
cache and stops the reports; any other failure only leaves the cache."
  (harness-ui-cache-warm-test-with
    (let ((now (float-time)) (seen nil) (got nil))
      (add-hook 'harness-ui-cache-warm-functions (lambda (sid state) (push (list sid state) seen)))
      (harness-ui-cache-warm--changed "s-old" (harness-ui-cache-warm-test--state now :session-id "s-old"))
      (setq seen nil)
      (harness-ui-cache-warm-refresh (lambda (states) (setq got states)))
      (pcase-let ((`(,method ,params ,callback ,on-error) (harness-ui-cache-warm-test--last-call)))
        (should (equal "_harness/cache/warm-list" method))
        (should-not params)
        ;; Booleans as the wire has them, and a vector, as JSON arrays arrive.
        (funcall callback (vector (harness-ui-cache-warm-test--state now :warming :false)
                                  (harness-ui-cache-warm-test--state now :session-id "s2")
                                  '(:warming t)))
        (should (equal '(nil nil) (car seen)))
        (should (= 3 (length got)))
        (should-not (harness-ui-cache-warm-state "s-old"))
        (should-not (plist-get (harness-ui-cache-warm-state "s1") :warming))
        (should (plist-get (harness-ui-cache-warm-state "s2") :warming))
        ;; A state that names no session is left out.
        (should (= 2 (hash-table-count harness-ui-cache-warm--states)))
        ;; Failing leaves what is cached.
        (funcall on-error '(acp-error -32603 "boom" nil))
        (should-not harness-ui-cache-warm--unavailable)
        (should (= 2 (hash-table-count harness-ui-cache-warm--states)))
        (funcall on-error '(acp-error -32601 "Method not found: cache/warm-list" nil))
        (should harness-ui-cache-warm--unavailable)
        (should (= 2 (hash-table-count harness-ui-cache-warm--states)))))))

;;;; The header

(defmacro harness-ui-cache-warm-test-with-chat (sid &rest body)
  "Run BODY in a buffer that stands in for the chat of session SID.
Its header line shows the flame, and it is in the selected window."
  (declare (indent 1))
  `(let ((harness-chat-header-end-functions (list #'harness-ui-cache-warm--header)))
     (with-temp-buffer
       (setq-local harness-ui-session-id ,sid)
       (save-window-excursion
         (set-window-buffer (selected-window) (current-buffer))
         ,@body))))

(ert-deftest harness-ui-cache-warm-header-shows-the-flame-and-a-coarse-countdown ()
  "While a session's cache is kept warm and the warming period has not
ended, its header says so: the flame and the time left, coarsely, in the
warm face -- dim in the last minute.  Not before it is announced, not for
another session, and not once the period is over, whatever the state
still says."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm-test-with-chat "s1"
      (let ((now (float-time)) (icon (harness-ui-cache-warm-test--icon)))
        (should-not (harness-ui-cache-warm--header))
        ;; A little under twelve minutes left reads twelve.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (+ now 690)))
        (let* ((segment (harness-ui-cache-warm--header))
               (text (car segment)))
          (should (equal (concat "  " icon " 12m") (substring-no-properties text)))
          (should (= harness-ui-cache-warm--header-priority (cadr segment)))
          ;; Above the spend (10), below the thinking level (20).
          (should (< 10 (cadr segment) 20))
          (should (eq 'harness-chat-warm-face (get-text-property 2 'face text)))
          (should (functionp (get-text-property 2 'help-echo text)))
          (should (keymapp (get-text-property 2 'local-map text))))
        ;; An hour and more.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (+ now 4790)))
        (should (equal (concat "  " icon " 1h20m") (substring-no-properties (car (harness-ui-cache-warm--header)))))
        ;; The last minute is dim.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (+ now 40)))
        (let ((text (car (harness-ui-cache-warm--header))))
          (should (equal (concat "  " icon " <1m") (substring-no-properties text)))
          (should (eq 'harness-dim-face (get-text-property 2 'face text))))
        ;; The period is over, though the state has not been replaced.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (- now 1)))
        (should-not (harness-ui-cache-warm--header))
        ;; Not warming now: a cold cache has nothing to keep warm.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :warming :false))
        (should-not (harness-ui-cache-warm--header))
        ;; Another session's state is not this chat's.
        (harness-ui-cache-warm--changed "s2" (harness-ui-cache-warm-test--state now :session-id "s2"))
        (should-not (harness-ui-cache-warm--header))
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now))
        (should (harness-ui-cache-warm--header))))
    ;; A buffer with no session shows none.
    (with-temp-buffer
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state (float-time)))
      (should-not (harness-ui-cache-warm--header)))))

(ert-deftest harness-ui-cache-warm-header-while-a-tool-runs-and-while-blocked ()
  "The flame shows while a turn waits on a tool call with nobody about, and the
tooltip says so, and what a refresh costs against sending the conversation
again.  When the harness keeps nothing warm for a reason though the user
set a period, a dim flame that says \"off\" shows until the period ends, and
the tooltip gives the reason; with no period of the user's own, or once it
ended, nothing shows."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm-test-with-chat "s1"
      (let* ((now (float-time))
             (icon (harness-ui-cache-warm-test--icon))
             (clock (lambda (time) (harness-ui-format-clock time now)))
             (header (lambda () (car (harness-ui-cache-warm--header))))
             (help (lambda () (funcall (get-text-property 2 'help-echo (funcall header)) nil nil 0)))
             (reason "A refresh would cost about what sending the conversation again does."))
        ;; A tool call, and the user gone.
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :tool t :active-at nil :until (+ now 1700)
                                                :refresh-cost 0.0169 :resend-cost 0.4225))
        (should (equal (concat "  " icon " 29m") (substring-no-properties (funcall header))))
        (should (eq 'harness-chat-warm-face (get-text-property 2 'face (funcall header))))
        (should (string-match-p "waiting on a tool call" (funcall help)))
        (should (string-search (format "Kept warm until %s at the latest." (funcall clock (+ now 1700))) (funcall help)))
        (should (string-search "A refresh costs about $0.017; sending the whole conversation again uncached, about $0.422."
                               (funcall help)))
        (should-not (string-search "as you were active" (funcall help)))
        ;; Not a tool call: the other words, and no prices the harness did not give.
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now))
        (should-not (string-match-p "tool call" (funcall help)))
        (should-not (string-search "A refresh costs" (funcall help)))
        ;; Blocked while the user's period runs.
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :warming :false :until nil :manual-until (+ now 1800)
                                                :blocked reason))
        (should (equal (concat "  " icon " off") (substring-no-properties (funcall header))))
        (should (eq 'harness-dim-face (get-text-property 2 'face (funcall header))))
        (should (= harness-ui-cache-warm--header-priority (cadr (harness-ui-cache-warm--header))))
        (should (equal (format "The harness is not keeping this session's prompt cache warm: %s.\nThe period you set lasts until %s.%s"
                               (string-trim-right reason "[.]+")
                               (funcall clock (+ now 1800))
                               "\nmouse-1: keep it warm for a period of your own, or stop")
                       (funcall help)))
        ;; The flame is a countdown to nothing, so the timer runs to take it away at the end.
        (should harness-ui-cache-warm--timer)
        ;; No period of the user's own, or one that ended, or no reason: nothing.
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :warming :false :until nil :manual-until nil :blocked reason))
        (should-not (harness-ui-cache-warm--header))
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :warming :false :until nil :manual-until (- now 1) :blocked reason))
        (should-not (harness-ui-cache-warm--header))
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :warming :false :until nil :manual-until (+ now 1800)))
        (should-not (harness-ui-cache-warm--header))
        (should-not harness-ui-cache-warm--timer)))))

(ert-deftest harness-ui-cache-warm-tooltip-says-until-when ()
  "The tooltip says what keeping the cache warm is, until when and why,
when the next refresh is due and how many were made, and what a click does.
The period you set says so."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm-test-with-chat "s1"
      (let ((now (float-time)))
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now))
        (let ((help (funcall (get-text-property 2 'help-echo (car (harness-ui-cache-warm--header))) nil nil 0)))
          (should (string-match-p "prompt cache is being kept warm" help))
          (should (string-search (format "Warm until %s, as you were active." (harness-ui-format-clock (+ now 720) now)) help))
          (should (string-search (format "Next refresh at %s." (harness-ui-format-clock (+ now 290) now)) help))
          (should (string-search "2 so far." help))
          (should (string-search "mouse-1: keep it warm for a period of your own, or stop" help)))
        (harness-ui-cache-warm--changed
         "s1" (harness-ui-cache-warm-test--state now :until (+ now 1800) :manual-until (+ now 1800) :refreshes 0))
        (let ((help (funcall (get-text-property 2 'help-echo (car (harness-ui-cache-warm--header))) nil nil 0)))
          (should (string-search ", the period you set." help))
          (should-not (string-search "so far" help)))
        ;; Hovering after it ended says nothing is kept warm.
        (harness-ui-cache-warm--changed "s1" nil)
        (should (string-match-p "is not being kept warm"
                                (harness-ui-cache-warm--help nil nil 0)))))))

(ert-deftest harness-ui-cache-warm-click-asks-for-a-period ()
  "A click on the flame runs `harness-cache-keep-warm', in the window clicked."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm-test-with-chat "s1"
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state (float-time)))
      (let* ((text (car (harness-ui-cache-warm--header)))
             (map (get-text-property 2 'local-map text))
             (ran nil))
        (should (eq map (harness-chat--segment-map #'harness-cache-keep-warm)))
        (cl-letf (((symbol-function 'harness-cache-keep-warm) (lambda () (interactive) (setq ran t))))
          (funcall (lookup-key map [header-line mouse-1])
                   (list 'mouse-1 (list (selected-window) 'header-line '(0 . 0) 0))))
        (should ran)))))

(ert-deftest harness-ui-cache-warm-flame-gives-way-after-the-spend ()
  "In a narrow window the spend makes room first, then the flame, then the
rest of the session's own segments."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm-test-with-chat "s1"
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state (float-time)))
      (let* ((icon (regexp-quote (harness-ui-cache-warm-test--icon)))
             (full (harness-chat--header most-positive-fixnum))
             (gone (lambda (regexp)
                     ;; The widest header without REGEXP.
                     (cl-loop for width downfrom (harness-ui-header-string-width full) to 1
                              unless (string-match-p regexp (harness-chat--header width))
                              return width))))
        (should (string-match-p (concat "  " icon " 12m  \\[menu\\]") full))
        (should (> (funcall gone "\\$0") (funcall gone icon) (funcall gone "unnamed")))))))

;;;; The timer

(ert-deftest harness-ui-cache-warm-timer-runs-only-while-a-countdown-shows ()
  "One timer redraws the countdowns every fifteen seconds while one shows,
and none runs otherwise: not for a state that is not warming, not once the
state goes, and not once the period ended by the clock."
  (harness-ui-cache-warm-test-with
    (let ((now (float-time)))
      (should-not harness-ui-cache-warm--timer)
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :warming :false))
      (should-not harness-ui-cache-warm--timer)
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (- now 5)))
      (should-not harness-ui-cache-warm--timer)
      ;; A countdown shows: the timer runs, redrawing every fifteen seconds.
      (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now))
      (let ((timer harness-ui-cache-warm--timer))
        (should (memq timer timer-list))
        (should (eq #'harness-ui-cache-warm--tick (timer--function timer)))
        (should (= 15 (timer--repeat-delay timer)))
        ;; A second one does not start another.
        (harness-ui-cache-warm--changed "s2" (harness-ui-cache-warm-test--state now :session-id "s2"))
        (should (eq timer harness-ui-cache-warm--timer))
        (should (= 1 (cl-count #'harness-ui-cache-warm--tick timer-list :key #'timer--function)))
        ;; While one still shows, the end of the other does not stop it.
        (harness-ui-cache-warm--changed "s1" nil)
        (should (eq timer harness-ui-cache-warm--timer))
        (should (memq timer timer-list))
        ;; None shows: it stops.
        (harness-ui-cache-warm--changed "s2" nil)
        (should-not harness-ui-cache-warm--timer)
        (should-not (memq timer timer-list))
        (should (= 0 (cl-count #'harness-ui-cache-warm--tick timer-list :key #'timer--function))))
      ;; A tick finding every period over redraws, and stops the timer.
      (let ((redrawn 0))
        (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now :until (+ now 20)))
        (should harness-ui-cache-warm--timer)
        (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&rest _) (cl-incf redrawn)))
                  ((symbol-function 'float-time) (lambda (&rest _) (+ now 100))))
          (harness-ui-cache-warm--tick))
        (should (= 1 redrawn))
        (should-not harness-ui-cache-warm--timer)))))

;;;; Reporting that the user is active

(ert-deftest harness-ui-cache-warm-reports-the-user-active-now-and-then ()
  "A command run in a chat that is in the selected window reports the user
active, at most every twenty seconds.  Nothing is reported for a buffer
that is not in the selected window, one with no session, or after the
harness said it has no such method; the state it answers with is taken in."
  (harness-ui-cache-warm-test-with
    (let ((clock 1000.0) (now (float-time)))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) clock)))
        (with-temp-buffer
          (setq-local harness-ui-session-id "s1")
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (let ((reports (lambda ()
                             (cl-count "_harness/cache/active" harness-ui-cache-warm-test--calls
                                       :key #'car :test #'equal))))
              ;; The first command reports; the next ones within twenty seconds do not.
              (harness-ui-cache-warm--note-activity)
              (should (= 1 (funcall reports)))
              (should (equal '(:session-id "s1")
                             (cadr (harness-ui-cache-warm-test--last-call "_harness/cache/active"))))
              (setq clock 1005.0)
              (harness-ui-cache-warm--note-activity)
              (setq clock 1019.9)
              (harness-ui-cache-warm--note-activity)
              (should (= 1 (funcall reports)))
              ;; Twenty seconds on, the next does.
              (setq clock 1020.0)
              (harness-ui-cache-warm--note-activity)
              (should (= 2 (funcall reports)))
              (setq clock 1039.0)
              (harness-ui-cache-warm--note-activity)
              (should (= 2 (funcall reports)))
              ;; The state the harness answers with is taken in; a failure is quiet.
              (pcase-let ((`(,_ ,_ ,callback ,on-error) (harness-ui-cache-warm-test--last-call)))
                (funcall callback (harness-ui-cache-warm-test--state now))
                (should (plist-get (harness-ui-cache-warm-state "s1") :warming))
                ;; Another answer than a state changes nothing: nothing, or the
                ;; presence the harness answers with (the state comes as an event).
                (funcall callback nil)
                (should (plist-get (harness-ui-cache-warm-state "s1") :warming))
                (funcall callback '(:session-id "s1" :around t :until 2000.0 :active-at 1000.0))
                (should (plist-get (harness-ui-cache-warm-state "s1") :warming))
                (should-not (harness-ui-cache-warm-test--said (lambda () (funcall on-error '(acp-error -32603 "boom" nil)))))
                (should-not harness-ui-cache-warm--unavailable)
                ;; No such method: nothing more is reported.
                (should-not (harness-ui-cache-warm-test--said
                             (lambda () (funcall on-error '(acp-error -32601 "Method not found: cache/active" nil)))))
                (should harness-ui-cache-warm--unavailable))
              (setq clock 1100.0)
              (harness-ui-cache-warm--note-activity)
              (should (= 2 (funcall reports))))))
        ;; A buffer in no window, or in a window that is not the selected one.
        (setq harness-ui-cache-warm--unavailable nil)
        (let ((before (length harness-ui-cache-warm-test--calls)))
          (with-temp-buffer
            (setq-local harness-ui-session-id "s1")
            (harness-ui-cache-warm--note-activity))
          (with-temp-buffer
            (set-window-buffer (selected-window) (current-buffer))
            (harness-ui-cache-warm--note-activity))
          (should (= before (length harness-ui-cache-warm-test--calls))))))))

(ert-deftest harness-ui-cache-warm-activity-is-reported-from-chat-buffers ()
  "A chat buffer reports through its own `post-command-hook': the module adds
it when a chat mode starts, to the chats open already, and takes it out
again when it stops."
  (let ((harness-chat-mode-hook nil)
        (harness-chat-header-end-functions nil)
        (harness-ui-event-functions nil)
        (harness-ui-connected-hook nil)
        (harness-chat-commands nil)
        (harness-ui-cache-warm--states (make-hash-table :test 'equal))
        (harness-ui-cache-warm--timer nil))
    (with-temp-buffer
      (should-not (memq #'harness-ui-cache-warm--note-activity post-command-hook))
      (harness-ui-cache-warm--setup)
      (should (memq #'harness-ui-cache-warm--note-activity post-command-hook))
      (should (local-variable-p 'post-command-hook))
      (harness-ui-cache-warm--shutdown)
      (should-not (memq #'harness-ui-cache-warm--note-activity post-command-hook)))
    ;; A chat open before the module started is included.
    (with-temp-buffer
      (harness-chat-mode)
      (unwind-protect
          (progn
            (harness-ui-cache-warm--init)
            (should (memq #'harness-ui-cache-warm--note-activity post-command-hook))
            (should (memq #'harness-ui-cache-warm--setup harness-chat-mode-hook))
            (harness-ui-cache-warm--shutdown)
            (should-not (memq #'harness-ui-cache-warm--note-activity post-command-hook))
            (should-not (memq #'harness-ui-cache-warm--setup harness-chat-mode-hook)))
        (harness-ui-cache-warm--shutdown)))))

;;;; Setting a period by hand

(ert-deftest harness-ui-cache-warm-asks-how-long ()
  "Interactively, the command asks how long with the presets to choose from,
in order, and a default of 30m; the prompt names the period in effect.  What
is answered goes to the harness as seconds."
  (harness-ui-cache-warm-test-with
    (let ((asked nil) (now (float-time)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table _pred _req _init _hist def)
                   (setq asked (list prompt (all-completions "" table)
                                     (completion-metadata-get (completion-metadata "" table nil)
                                                             'display-sort-function)
                                     def))
                   "1h30m")))
        (with-temp-buffer
          (setq-local harness-ui-session-id "s1")
          (call-interactively #'harness-cache-keep-warm)
          (should (equal "Keep the prompt cache warm for (default 30m): " (car asked)))
          (should (equal '("15m" "30m" "1h" "2h" "off") (cadr asked)))
          (should (eq 'identity (nth 2 asked)))
          (should (equal "30m" (nth 3 asked)))
          (pcase-let ((`(,method ,params ,_ ,_) (harness-ui-cache-warm-test--last-call)))
            (should (equal "_harness/cache/keep-warm" method))
            (should (equal '(:session-id "s1" :seconds 5400) params)))
          ;; With a period in effect the prompt says until when.
          (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state now))
          (call-interactively #'harness-cache-keep-warm)
          (should (equal (format "Keep the prompt cache warm, now until %s, for (default 30m): "
                                 (harness-ui-format-clock (+ now 720) now))
                         (car asked)))))
      ;; Called from Lisp with no period, it asks as well; with one, it does not.
      (let ((answers nil))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (push 'asked answers) "off")))
          (harness-cache-keep-warm "s1")
          (should (equal '(:session-id "s1" :seconds 0) (cadr (harness-ui-cache-warm-test--last-call))))
          (harness-cache-keep-warm "s1" 900)
          (should (equal '(:session-id "s1" :seconds 900) (cadr (harness-ui-cache-warm-test--last-call))))
          (should (= 1 (length answers)))))
      ;; An answer that is no period is a `user-error', and asks the harness nothing.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "soon")))
        (let ((before (length harness-ui-cache-warm-test--calls)))
          (should-error (with-temp-buffer
                          (setq-local harness-ui-session-id "s1")
                          (call-interactively #'harness-cache-keep-warm))
                        :type 'user-error)
          (should (= before (length harness-ui-cache-warm-test--calls))))))))

(defun harness-ui-cache-warm-test--keep (seconds state &optional estimate)
  "Ask to keep session s1's cache warm for SECONDS; answer as the harness does.
STATE is what the harness answers with, ESTIMATE what `compaction/estimate'
answers when the UI asks it (a failure when nil).  Return what the echo
area said, oldest first, and leave the requests it made, and only
those, in `harness-ui-cache-warm-test--calls'."
  (setq harness-ui-cache-warm-test--calls nil)
  (harness-ui-cache-warm-test--said
   (lambda ()
     (harness-cache-keep-warm "s1" seconds)
     (funcall (nth 2 (harness-ui-cache-warm-test--last-call "_harness/cache/keep-warm")) state)
     (when-let* ((call (harness-ui-cache-warm-test--last-call "_harness/compaction/estimate")))
       (if estimate
           (funcall (nth 2 call) estimate)
         (funcall (nth 3 call) '(acp-error -32603 "no estimate" nil)))))))

(ert-deftest harness-ui-cache-warm-says-what-it-asked-for ()
  "The echo area says until when the cache is kept warm and about how many
refreshes that takes -- counted from the state the harness answers with,
whose lifetime and lead set the interval -- with what they cost when the
harness can say it, or the cost of reading the context once if it asks
for that, and what carrying on would cost; the state is kept."
  (harness-ui-cache-warm-test-with
    (let ((now (float-time))
          (until (lambda (time now) (harness-ui-format-clock time now))))
      ;; 30 minutes of a five-minute cache: six refreshes.  The harness names no
      ;; price for one, so the UI asks what reading the context from the cache costs.
      (let ((said (harness-ui-cache-warm-test--keep
                   1800 (harness-ui-cache-warm-test--state now :until (+ now 1800) :manual-until (+ now 1800))
                   '(:context 84500 :carry-on-cached 0.0169))))
        (should (equal "_harness/cache/keep-warm"
                       (car (cl-find "_harness/cache/keep-warm" harness-ui-cache-warm-test--calls
                                     :key #'car :test #'equal))))
        (should (equal '(:session-id "s1" :seconds 1800)
                       (cadr (harness-ui-cache-warm-test--last-call "_harness/cache/keep-warm"))))
        (should (equal '(:session-id "s1") (cadr (harness-ui-cache-warm-test--last-call "_harness/compaction/estimate"))))
        (should (= (+ now 1800) (plist-get (harness-ui-cache-warm-state "s1") :until)))
        (should (equal (list (format "Keeping the prompt cache warm until %s (about 6 refreshes, ~$0.101 at cache-read prices)"
                                     (funcall until (+ now 1800) now)))
                       said)))
      ;; The harness prices a refresh and the conversation sent again: nothing is asked.
      (let ((said (harness-ui-cache-warm-test--keep
                   1800 (harness-ui-cache-warm-test--state
                         now :until (+ now 1800) :manual-until (+ now 1800)
                         :max-refreshes 12 :refresh-cost 0.0169 :resend-cost 0.4225))))
        (should-not (harness-ui-cache-warm-test--last-call "_harness/compaction/estimate"))
        (should (equal (list (format "Keeping the prompt cache warm until %s (about 6 refreshes, ~$0.101 at cache-read prices, against ~$0.422 to send it all again uncached)"
                                     (funcall until (+ now 1800) now)))
                       said)))
      ;; More refreshes than pay: the harness stops where they stop paying, and the
      ;; count is the most it names.
      (let ((said (harness-ui-cache-warm-test--keep
                   7200 (harness-ui-cache-warm-test--state
                         now :until (+ now 3480) :manual-until (+ now 7200)
                         :max-refreshes 12 :refresh-cost 0.0169 :resend-cost 0.4225))))
        (should (equal (list (format "Keeping the prompt cache warm until %s (about 12 refreshes, ~$0.203 at cache-read prices, against ~$0.422 to send it all again uncached); longer would cost more than sending the conversation again"
                                     (funcall until (+ now 3480) now)))
                       said)))
      ;; A price that cannot be had: the count alone.
      (let ((said (harness-ui-cache-warm-test--keep
                   3600 (harness-ui-cache-warm-test--state
                         now :until (+ now 3600) :manual-until (+ now 3600) :ttl 3600
                         :next (+ now 3540) :expires (+ now 3600)))))
        (should (equal (list (format "Keeping the prompt cache warm until %s (about 1 refresh)"
                                     (funcall until (+ now 3600) now)))
                       said)))
      ;; A period too short for a refresh to fall in it.
      (let ((said (harness-ui-cache-warm-test--keep
                   120 (harness-ui-cache-warm-test--state now :until (+ now 120) :manual-until (+ now 120)))))
        (should (equal (list (format "Keeping the prompt cache warm until %s (the cache lapses before a refresh is due)"
                                     (funcall until (+ now 120) now)))
                       said)))
      ;; The most a period can be is said.
      (let ((said (harness-ui-cache-warm-test--keep
                   86400 (harness-ui-cache-warm-test--state
                          now :until (+ now 86400) :manual-until (+ now 86400) :max-refreshes 500))))
        (should (string-suffix-p "; a period is kept 24 hours at most" (car said))))
      ;; The harness will not keep it warm: it says why, in its words.
      (let ((said (harness-ui-cache-warm-test--keep
                   1800 (harness-ui-cache-warm-test--state
                         now :warming :false :until nil :manual-until (+ now 1800)
                         :blocked "A refresh would cost about what sending the conversation again does."))))
        (should (equal '("Not keeping the prompt cache warm: A refresh would cost about what sending the conversation again does")
                       said)))
      ;; A period of the user's own over a cache that lapsed: nothing to keep warm yet.
      (let ((said (harness-ui-cache-warm-test--keep
                   1800 (harness-ui-cache-warm-test--state
                         now :warming :false :until (+ now 1800) :manual-until (+ now 1800)))))
        (should (equal (list (format "Nothing is cached to keep warm: the next message sends the whole conversation again; the cache is kept warm after it, until %s"
                                     (funcall until (+ now 1800) now)))
                       said)))
      ;; A provider that cannot refresh a cache.
      (let ((said (harness-ui-cache-warm-test--keep
                   1800 (harness-ui-cache-warm-test--state now :warming :false :supported :false))))
        (should (equal '("Nothing to keep warm: this session's provider has no way to refresh its prompt cache")
                       said)))
      ;; Ending the period: said, and the state the harness answers with is kept.
      (let ((said (harness-ui-cache-warm-test--keep 0 nil)))
        (should (equal '("Stopped keeping the prompt cache warm") said))
        (should-not (harness-ui-cache-warm-state "s1")))
      ;; Still warm because the user was active: say so.
      (let ((said (harness-ui-cache-warm-test--keep 0 (harness-ui-cache-warm-test--state now))))
        (should (equal (list (format "Stopped the period you set; the prompt cache is kept warm until %s all the same, as you were active"
                                     (funcall until (+ now 720) now)))
                       said))))))

(ert-deftest harness-ui-cache-warm-counts-refreshes-from-the-state ()
  "The first refresh is due at `:next' and one falls every lifetime less the
lead the harness keeps before the cache lapses, so a five-minute cache is
refreshed every 290 seconds and a one-hour cache every 3540; the limit the
harness names is the most counted, and a state that says nothing is a
five-minute cache."
  (let* ((now (float-time))
         (five (harness-ui-cache-warm-test--state now))
         (limit (lambda (state n) (plist-put (copy-sequence state) :max-refreshes n)))
         (hour (list :ttl 3600 :next (+ now 3540) :expires (+ now 3600))))
    (should (= 6 (harness-ui-cache-warm--refreshes 1800 five)))
    (should (= 12 (harness-ui-cache-warm--refreshes 3480 five)))
    (should (= 1 (harness-ui-cache-warm--refreshes 300 five)))
    (should (= 0 (harness-ui-cache-warm--refreshes 120 five)))
    (should (= 0 (harness-ui-cache-warm--refreshes 0 five)))
    (should (= 12 (harness-ui-cache-warm--refreshes 3480 (funcall limit five 20))))
    (should (= 4 (harness-ui-cache-warm--refreshes 86400 (funcall limit five 4))))
    (should (= 1 (harness-ui-cache-warm--refreshes 3600 hour)))
    (should (= 2 (harness-ui-cache-warm--refreshes 7200 hour)))
    ;; No `:next': the first is due after one interval.
    (should (= 6 (harness-ui-cache-warm--refreshes 1800 '(:ttl 300))))
    (should (= 6 (harness-ui-cache-warm--refreshes 1800 nil)))
    (should (= 12 (harness-ui-cache-warm--refreshes 3600 '(:ttl 300))))))

(ert-deftest harness-ui-cache-warm-says-why-it-failed ()
  "A harness without the module, any other failure, and a connection the UI
let go of on purpose, which is none."
  (harness-ui-cache-warm-test-with
    (let ((fail (lambda (err)
                  (harness-ui-cache-warm-test--said
                   (lambda ()
                     (harness-cache-keep-warm "s1" 600)
                     (funcall (nth 3 (harness-ui-cache-warm-test--last-call)) err))))))
      (should (equal '("Cannot keep the cache warm: the harness has no cache-warming module (enable cache-warm)")
                     (funcall fail '(acp-error -32601 "Method not found: cache/keep-warm" nil))))
      (should (equal '("Keeping the prompt cache warm failed: Session not found")
                     (funcall fail '(acp-error -32603 "Session not found" nil))))
      (should-not (funcall fail (list 'acp-error -32003 "connection replaced" (list :closed "replaced")))))))

(ert-deftest harness-ui-cache-warm-chat-command-sets-a-period ()
  "/warm DURATION keeps the cache of the chat's session warm for it, /warm off
stops, a bare /warm asks, and a period that cannot be read signals, which
keeps the text in the message box.  It is one of the chat's commands."
  (harness-ui-cache-warm-test-with
    (let ((harness-chat-commands nil)
          (harness-chat-header-end-functions nil)
          (harness-chat-mode-hook nil)
          (harness-ui-event-functions nil)
          (harness-ui-connected-hook nil))
      (unwind-protect
          (progn
            (harness-ui-cache-warm--init)
            (should (eq #'harness-ui-cache-warm--chat-command (cdr (assoc "warm" harness-chat-commands))))
            (with-temp-buffer
              (setq-local harness-ui-session-id "s1")
              (let ((sent (lambda () (cadr (harness-ui-cache-warm-test--last-call "_harness/cache/keep-warm")))))
                (harness-ui-cache-warm--chat-command "45m")
                (should (equal '(:session-id "s1" :seconds 2700) (funcall sent)))
                (harness-ui-cache-warm--chat-command "1h30m")
                (should (equal '(:session-id "s1" :seconds 5400) (funcall sent)))
                (harness-ui-cache-warm--chat-command "off")
                (should (equal '(:session-id "s1" :seconds 0) (funcall sent)))
                (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "2h")))
                  (harness-ui-cache-warm--chat-command "")
                  (should (equal '(:session-id "s1" :seconds 7200) (funcall sent))))
                (let ((before (length harness-ui-cache-warm-test--calls)))
                  (should-error (harness-ui-cache-warm--chat-command "whenever") :type 'user-error)
                  (should (= before (length harness-ui-cache-warm-test--calls)))))))
        (harness-ui-cache-warm--shutdown)))))

;;;; The module

(ert-deftest harness-ui-cache-warm-module-binds-k-and-the-menu-entry ()
  "The module binds K under the harness prefix and puts \"Keep cache warm\" in
the harness menu, after Fork session, once however often it starts; stopping
it takes them away, and a key another module bound is left alone."
  (let ((harness-chat-commands nil)
        (harness-chat-header-end-functions nil)
        (harness-chat-mode-hook nil)
        (harness-ui-event-functions nil)
        (harness-ui-connected-hook nil)
        (harness-ui-cache-warm--states (make-hash-table :test 'equal))
        (harness-ui-cache-warm--timer nil))
    (unwind-protect
        (progn
          (should-not (lookup-key harness-ui-map (kbd "K")))
          (harness-ui-cache-warm--init)
          (harness-ui-cache-warm--init)
          (should (eq #'harness-cache-keep-warm (lookup-key harness-ui-map (kbd "K"))))
          (should (eq 'harness-cache-keep-warm (harness-ui-cache-warm--suffix-command "K")))
          (should (equal "Keep cache warm"
                         (plist-get (cdr (transient-get-suffix 'harness-menu "K")) :description)))
          (should (memq #'harness-ui-cache-warm--header harness-chat-header-end-functions))
          (should (memq #'harness-ui-cache-warm--on-event harness-ui-event-functions))
          (should (memq #'harness-ui-cache-warm--on-connected harness-ui-connected-hook))
          ;; Taken away once, though it was put in twice: no second entry is left.
          (harness-ui-cache-warm--shutdown)
          (should-not (lookup-key harness-ui-map (kbd "K")))
          (should-not (harness-ui-cache-warm--suffix-command "K"))
          (should-not (cdr (assoc "warm" harness-chat-commands)))
          (should-not (memq #'harness-ui-cache-warm--header harness-chat-header-end-functions))
          (should-not (memq #'harness-ui-cache-warm--on-event harness-ui-event-functions))
          ;; Another module's K stays.
          (define-key harness-ui-map (kbd "K") #'ignore)
          (harness-ui-cache-warm--shutdown)
          (should (eq #'ignore (lookup-key harness-ui-map (kbd "K")))))
      (define-key harness-ui-map (kbd "K") nil t)
      (harness-ui-cache-warm--shutdown))))

(ert-deftest harness-ui-cache-warm-connecting-again-forgets-the-states ()
  "A UI that connects to a harness forgets what it knew of the one before,
asks the new one for its own, and reports to it again, though the old one
had no cache-warming module."
  (harness-ui-cache-warm-test-with
    (harness-ui-cache-warm--changed "s1" (harness-ui-cache-warm-test--state (float-time)))
    (setq harness-ui-cache-warm--unavailable t)
    (should harness-ui-cache-warm--timer)
    (harness-ui-cache-warm--on-connected)
    (should-not harness-ui-cache-warm--unavailable)
    (should-not (harness-ui-cache-warm-state "s1"))
    (should-not harness-ui-cache-warm--timer)
    (should (equal "_harness/cache/warm-list" (car (harness-ui-cache-warm-test--last-call))))))

;;;; Against the harness's bus

(defvar harness-ui-cache-warm-test--server nil
  "What the stand-in harness knows: session id -> its entry (:seconds N :active N).")

(defun harness-ui-cache-warm-test--server-state (sid)
  "Return the warm state the stand-in harness holds of session SID."
  (let* ((now (float-time))
         (seconds (plist-get (gethash sid harness-ui-cache-warm-test--server) :seconds)))
    (list :session-id sid :warming t :supported t
          :until (+ now (or seconds 720)) :manual-until (and seconds (+ now seconds))
          :active-at now :next (+ now 290) :expires (+ now 300) :ttl 300 :refreshes 0)))

(defun harness-ui-cache-warm-test--register-methods ()
  "Give the bus the methods the cache-warming module of the harness has.
Their argument lists are the ones the UI asks with: its parameters
name them."
  (harness-register-method
   'cache/active
   (lambda (session-id &optional seconds)
     (ignore seconds)
     (let ((entry (copy-sequence (gethash session-id harness-ui-cache-warm-test--server))))
       (puthash session-id (plist-put entry :active (1+ (or (plist-get entry :active) 0)))
                harness-ui-cache-warm-test--server))
     (harness-ui-cache-warm-test--server-state session-id)))
  (harness-register-method
   'cache/keep-warm
   (lambda (session-id seconds)
     (puthash session-id (list :seconds (and (numberp seconds) (> seconds 0) seconds))
              harness-ui-cache-warm-test--server)
     (harness-ui-cache-warm-test--server-state session-id)))
  (harness-register-method
   'cache/warm
   (lambda (session-id)
     (and (gethash session-id harness-ui-cache-warm-test--server)
          (harness-ui-cache-warm-test--server-state session-id))))
  (harness-register-method
   'cache/warm-list
   (lambda ()
     (let (out)
       (maphash (lambda (sid _) (push (harness-ui-cache-warm-test--server-state sid) out))
                harness-ui-cache-warm-test--server)
       (harness-json-array out)))))

(defmacro harness-ui-cache-warm-test-with-harness (&rest body)
  "Run BODY with the cache methods on the bus and the UI connected to it.
The harness is the in-process one, the cache-warming module the UI has is
started, and what the UI shows of the states is what it was told."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--clients nil)
     (let ((harness-acp--server-enabled nil)
           (harness-acp-extra-method-prefixes (cons "cache/" harness-acp-extra-method-prefixes))
           (harness-acp-extra-events (cons 'cache/warm-changed harness-acp-extra-events))
           (harness-acp-token nil)
           (default-directory dir)
           (harness-chat-commands nil)
           (harness-chat-header-end-functions nil)
           (harness-chat-mode-hook nil)
           (harness-ui-event-functions nil)
           (harness-ui-connected-hook nil)
           (harness-ui-cache-warm-test--server (make-hash-table :test 'equal))
           (harness-ui-cache-warm--states (make-hash-table :test 'equal))
           (harness-ui-cache-warm--timer nil)
           (harness-ui-cache-warm--unavailable nil)
           (harness-ui-cache-warm-functions nil)
           (harness-ui--sessions (make-hash-table :test 'equal)))
       (dolist (m '(store acp))
         (harness-test-load-module m))
       (harness-ui-cache-warm-test--register-methods)
       (unwind-protect
           (progn
             (harness-test-load-module 'ui)
             (harness-ui-cache-warm--init)
             ,@body)
         (harness-ui-cache-warm--shutdown)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(ert-deftest harness-ui-cache-warm-follows-the-harness-over-acp ()
  "The UI fetches the states the harness lists, hears the one it announces,
and a state the harness takes away goes: the names it asks with and the
state it reads are those of the harness's methods and events."
  (harness-ui-cache-warm-test-with-harness
    (puthash "s1" (list :seconds 1800) harness-ui-cache-warm-test--server)
    (let ((got nil))
      (harness-ui-cache-warm-refresh (lambda (states) (setq got states)))
      (harness-test-wait (lambda () got) 5 "the states fetched")
      (let ((state (harness-ui-cache-warm-state "s1")))
        (should (plist-get state :warming))
        (should (plist-get state :supported))
        (should (= 300 (plist-get state :ttl)))
        (should (= 0 (plist-get state :refreshes)))
        (should (numberp (plist-get state :manual-until)))
        (should (< 1700 (- (plist-get state :until) (float-time)) 1801)))
      ;; Announced by the harness.
      (harness-emit 'cache/warm-changed "s2" (harness-ui-cache-warm-test--server-state "s2"))
      (harness-test-wait (lambda () (harness-ui-cache-warm-state "s2")) 5 "the announcement")
      (should (plist-get (harness-ui-cache-warm-state "s2") :warming))
      (should harness-ui-cache-warm--timer)
      ;; Taken away.
      (harness-emit 'cache/warm-changed "s2" nil)
      (harness-test-wait (lambda () (not (harness-ui-cache-warm-state "s2"))) 5 "the state to go")
      (should (harness-ui-cache-warm-state "s1")))))

(ert-deftest harness-ui-cache-warm-sets-a-period-over-acp ()
  "Asking for a period reaches the harness as the session and the seconds, and
the state it answers with is what the header shows; a price that cannot be
had, no module of the harness estimating compactions here, only loses the
price."
  (harness-ui-cache-warm-test-with-harness
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when format-string (push (apply #'format format-string args) said)))))
        (harness-cache-keep-warm "s3" 900)
        (harness-test-wait (lambda () (cl-find-if (lambda (m) (string-prefix-p "Keeping the prompt cache warm until" m)) said))
                           5 "what was asked for said"))
      (should (= 900 (plist-get (gethash "s3" harness-ui-cache-warm-test--server) :seconds)))
      (let ((state (harness-ui-cache-warm-state "s3")))
        (should (plist-get state :warming))
        (should (< 800 (- (plist-get state :manual-until) (float-time)) 901)))
      (should (cl-find-if (lambda (m) (string-match-p "(about 3 refreshes)\\'" m)) said))
      (with-temp-buffer
        (setq-local harness-ui-session-id "s3")
        (should (string-match-p " 1[56]m\\'" (substring-no-properties (car (harness-ui-cache-warm--header))))))
      ;; Ended: the stand-in harness goes on warming, as the user was active.
      (setq said nil)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when format-string (push (apply #'format format-string args) said)))))
        (harness-cache-keep-warm "s3" 0)
        (harness-test-wait (lambda () said) 5 "the end said"))
      (should (= 1 (length said)))
      (should (string-prefix-p "Stopped the period you set; the prompt cache is kept warm until " (car said)))
      (should-not (plist-get (gethash "s3" harness-ui-cache-warm-test--server) :seconds)))))

(ert-deftest harness-ui-cache-warm-reports-activity-over-acp ()
  "A command in a chat reports the user active to the harness, which answers with
the session's state; a harness without the method makes the UI stop asking,
and says nothing."
  (harness-ui-cache-warm-test-with-harness
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when format-string (push (apply #'format format-string args) said)))))
        (with-temp-buffer
          (setq-local harness-ui-session-id "s4")
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (harness-ui-cache-warm--note-activity)
            (harness-test-wait (lambda () (harness-ui-cache-warm-state "s4")) 5 "the state of the report")
            (should (= 1 (plist-get (gethash "s4" harness-ui-cache-warm-test--server) :active)))
            ;; Twenty seconds have not passed: not again.
            (harness-ui-cache-warm--note-activity)
            (accept-process-output nil 0.1)
            (should (= 1 (plist-get (gethash "s4" harness-ui-cache-warm-test--server) :active)))))
        ;; A harness whose cache-warming module is not there.
        (harness-unregister-method 'cache/active)
        (with-temp-buffer
          (setq-local harness-ui-session-id "s5")
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (harness-ui-cache-warm--note-activity)
            (harness-test-wait (lambda () harness-ui-cache-warm--unavailable) 5 "the UI to give up")))
        (accept-process-output nil 0.1)
        (should-not (cl-find-if (lambda (m) (string-match-p "cache" m)) said))))))

(provide 'harness-ui-cache-warm-test)
;;; harness-ui-cache-warm-test.el ends here
