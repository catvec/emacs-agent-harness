;;; harness-ui-cache-warm.el --- A session's prompt cache kept warm: the flame, /warm  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it, and a message that comes after the cache lapsed
;; sends the whole conversation again, uncached (see harness-ui-cache.el).
;; For a session the user is working in the harness can keep the cache
;; from lapsing (harness-cache-warm.el): just before it would, it sends
;; the conversation again, which reads the cache and starts its lifetime
;; over, and it goes on doing that for as long as the user has been
;; active in the session and for a while after -- the warming period --
;; or for a period the user sets by hand.  This file is the UI's half.
;;
;; While a session's cache is being kept warm, its chat's header line
;; shows a flame and a coarse countdown to the end of the warming period:
;; "12m", "1h20m", "<1m".  So it does while a turn waits on a tool call,
;; which the harness keeps the cache warm for whether or not the user is
;; about.  The harness announces each session's warm state
;; (`cache/warm-changed'; the UI fetches them all when it connects and
;; after a reload), and one timer redraws the countdowns every fifteen
;; seconds while any is shown, and stops when none is.  Nothing polls the
;; harness.  Hovering the flame says why the cache is kept warm and until
;; when, when it is refreshed next, and what a refresh costs against
;; sending the conversation again, when the harness says; a click asks for
;; a period of your own (below).
;;
;; The harness never keeps a cache warm for longer than that costs less
;; than sending the conversation uncached once, nor a turn's wait on a
;; tool for more than a day.  When that leaves nothing
;; to keep warm although the user asked for a period, the flame stays, dim,
;; and says "off" in place of a countdown until the period ends; hovering
;; gives the harness's reason.
;;
;; The harness can only know the user is active in a session when the
;; user sends it a message or answers it, so this file tells it the rest:
;; typing in a chat's message box, and any command run in a chat buffer
;; while it is in the selected window, are reported to the harness
;; (`cache/active') at most every twenty seconds.  A harness without the
;; cache-warming module answers that it has no such method, which the UI
;; takes for good until it connects again: nothing more is reported, and
;; nothing is said.
;;
;; The user can say a period by hand when the harness has not noticed
;; they are around -- they know they will be back in twenty minutes, say
;; -- with `harness-cache-keep-warm' (K under the harness prefix key and in
;; its menu, the flame in the header, or /warm DURATION in a chat's
;; message box: /warm 30m, /warm 1h30m, /warm 90, /warm off).  It asks
;; how long, offers 15m, 30m, 1h, 2h and off, and says in the echo area
;; what it asked the harness for: until when -- sooner than the period
;; when more refreshes would cost more than sending the conversation again
;; -- about how many refreshes, and, when the harness can price them (or
;; the UI can ask what reading the cache costs), what they cost against
;; sending it all again, or why nothing is kept warm.  The period is kept
;; at most 24 hours.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-header-end-functions)
(defvar harness-chat-mode-hook)
(defvar harness-chat-commands)
(defvar harness-acp-error-method-not-found)
(declare-function harness-chat--segment "harness-ui-chat" (text command help &optional face))
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))

(defgroup harness-ui-cache-warm nil
  "Keeping a session's prompt cache warm." :group 'harness-ui)

(defface harness-chat-warm-face '((t :inherit warning))
  "The flame and the countdown in a chat's header line.
They show while the session's prompt cache is being kept warm; under a
minute from the end of the warming period the countdown is dim."
  :group 'harness-ui-cache-warm)

(harness-ui-define-icon harness-icon-flame "flame" "🔥" "warm"
                        "Heat: a prompt cache that is being kept warm.")

(defconst harness-ui-cache-warm--report-interval 20
  "Seconds between two reports that the user is active in a chat buffer.")

(defconst harness-ui-cache-warm--tick-interval 15
  "Seconds between two redraws of the countdowns, while one is shown.")

(defconst harness-ui-cache-warm--max-seconds (* 24 3600)
  "The longest period `harness-cache-keep-warm' asks the harness for, in seconds.")

(defconst harness-ui-cache-warm--header-priority 15
  "Priority of the flame in a chat's header line.
Above the spend (10) and below the thinking level (20), so a narrow
window gives it up after the spend, which shows nothing that is going
on, and before the rest of the session's own segments, which matter
more (see `harness-ui-fit-header').  The companion pet's face goes first.")

(defconst harness-ui-cache-warm--presets '("15m" "30m" "1h" "2h" "off")
  "The periods `harness-cache-keep-warm' offers, in this order.")

(defconst harness-ui-cache-warm--default "30m"
  "The period `harness-cache-keep-warm' proposes.")

;;;; The states

(defvar harness-ui-cache-warm--states (make-hash-table :test 'equal)
  "Session id -> the warm state the harness last announced for it.
See `harness-ui-cache-warm-state'.")

(defvar harness-ui-cache-warm-functions nil
  "Functions called with (SESSION-ID STATE) after a warm state changed.
STATE is what `harness-ui-cache-warm-state' reads for the session now,
nil once it has none.  Both are nil after every state was fetched
again, or forgotten.")

(defvar harness-ui-cache-warm--unavailable nil
  "Non-nil when the harness answered that it has no cache-warming module.
Nothing is reported to it then, until the UI connects to a harness again.")

(defun harness-ui-cache-warm--number (value)
  "Return VALUE when it is a number, else nil."
  (and (numberp value) value))

(defun harness-ui-cache-warm--read (sid state)
  "Return STATE, session SID's warm state as the harness sent it, tidied; or nil.
The result is (:session-id SID :warming BOOL :supported BOOL :tool BOOL
:until TIME :manual-until TIME :active-at TIME :next TIME :expires TIME
:ttl SECONDS :refreshes N :max-refreshes N :refresh-cost USD
:resend-cost USD :unsupported TEXT :blocked TEXT): the booleans t or
nil, whatever came over JSON; the times, the lifetime and the prices a
number or nil; the counts natural numbers, `:max-refreshes' nil when the
harness names no limit; `:unsupported' why its provider cannot be asked
to keep the cache warm now, and `:blocked' the reason nothing is kept
warm, each a text, or nil.

`:until' is where the warming period ends -- the earlier of the end of
the period and of the refreshes that cost less than sending the
conversation again, and a day at most while a turn waits on a tool --
`:manual-until' where the period set by hand
does, `:next' when the next refresh is due and `:refreshes' how many
were made since the period began.  `:tool' says the cache is kept warm
while a turn waits on a tool call, whether or not the user is about.
`:refresh-cost' is what one refresh costs, `:resend-cost' what sending
the whole conversation uncached would, both in US dollars, and
`:max-refreshes' how many refreshes cost less than that.  nil when STATE
is none."
  (when (and (consp state) (keywordp (car state)))
    (list :session-id (if (stringp (plist-get state :session-id)) (plist-get state :session-id) sid)
          :warming (and (harness-json-true-p (plist-get state :warming)) t)
          :supported (if (plist-member state :supported)
                         (and (harness-json-true-p (plist-get state :supported)) t)
                       t)
          :tool (and (harness-json-true-p (plist-get state :tool)) t)
          :until (harness-ui-cache-warm--number (plist-get state :until))
          :manual-until (harness-ui-cache-warm--number (plist-get state :manual-until))
          :active-at (harness-ui-cache-warm--number (plist-get state :active-at))
          :next (harness-ui-cache-warm--number (plist-get state :next))
          :expires (harness-ui-cache-warm--number (plist-get state :expires))
          :ttl (harness-ui-cache-warm--number (plist-get state :ttl))
          :refreshes (let ((n (plist-get state :refreshes))) (if (natnump n) n 0))
          :max-refreshes (let ((n (plist-get state :max-refreshes))) (and (natnump n) n))
          :refresh-cost (harness-ui-cache-warm--number (plist-get state :refresh-cost))
          :resend-cost (harness-ui-cache-warm--number (plist-get state :resend-cost))
          :unsupported (let ((why (plist-get state :unsupported)))
                         (and (stringp why) (not (string-blank-p why)) (string-trim why)))
          :blocked (let ((why (plist-get state :blocked)))
                     (and (stringp why) (not (string-blank-p why)) (string-trim why))))))

(defun harness-ui-cache-warm-state (sid)
  "Return the warm state of session SID as the harness last announced it, or nil.
See `harness-ui-cache-warm--read' for what it holds.  The harness
announces a state when a warming period begins, moves or ends, and a
session that has none is not in the cache."
  (and (stringp sid) (gethash sid harness-ui-cache-warm--states)))

(defun harness-ui-cache-warm--end (state)
  "Return where the period STATE shows ends, a time, or nil.
That is the end of the warming period while the cache is being kept
warm.  While nothing is kept warm because the harness is blocked (it
costs about what sending the conversation again does, say), it is the
end of the period the user set, which the header goes on showing."
  (if (plist-get state :warming)
      (plist-get state :until)
    (and (plist-get state :blocked) (plist-get state :manual-until))))

(defun harness-ui-cache-warm--showing (sid &optional now)
  "Return session SID's warm state while its chat shows a flame at NOW.
That is while the state says the cache is being kept warm and the end
of the warming period, by the clock of this Emacs, is still to come;
and while the harness says it keeps nothing warm, for a reason
\(`:blocked'), though the user asked it to for a period that is still
to run.  Else nil.  NOW is the current time by default."
  (let* ((state (harness-ui-cache-warm-state sid))
         (end (and state (harness-ui-cache-warm--end state))))
    (and (numberp end)
         (> end (or now (float-time)))
         state)))

(defun harness-ui-cache-warm--redraw (sid)
  "Draw the header line of session SID's chat again; every one when SID is nil."
  (if (null sid)
      (force-mode-line-update t)
    (when-let* ((buffer (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid))))
      (with-current-buffer buffer (force-mode-line-update)))))

(defun harness-ui-cache-warm--changed (sid state)
  "Take in STATE, the warm state of session SID; nil says it has none now.
The header line of SID's chat is drawn again, the countdown's timer
started or stopped, and `harness-ui-cache-warm-functions' run.  Return
the state as the cache holds it."
  (when (stringp sid)
    (let ((read (harness-ui-cache-warm--read sid state)))
      (if read
          (puthash sid read harness-ui-cache-warm--states)
        (remhash sid harness-ui-cache-warm--states))
      (harness-ui-cache-warm--redraw sid)
      (harness-ui-cache-warm--sync-timer)
      (harness-ignore-errors-logged "harness-ui-cache-warm-functions"
        (run-hook-with-args 'harness-ui-cache-warm-functions sid read))
      read)))

(defun harness-ui-cache-warm--missing-p (err)
  "Non-nil when ERR says the harness has no such method.
That is a harness that runs without the cache-warming module."
  (or (eq (car-safe err) 'harness-no-such-method)
      (and (eq (car-safe err) 'acp-error)
           (eql (nth 1 err) (if (boundp 'harness-acp-error-method-not-found)
                                harness-acp-error-method-not-found
                              -32601)))))

(defun harness-ui-cache-warm-refresh (&optional callback)
  "Fetch the warm state of every session that has one, then call CALLBACK.
CALLBACK, when given, gets the states as they came.  The cache is
replaced whole, and `harness-ui-cache-warm-functions' runs with nil.  A
harness without the cache-warming module answers with an error, which
leaves the cache as it is and stops the reports of the user's activity
\(`harness-ui-cache-warm--unavailable'): there is nothing to say of it."
  (harness-ui-call "_harness/cache/warm-list" nil
                   (lambda (states)
                     (clrhash harness-ui-cache-warm--states)
                     (dolist (state (append states nil))
                       (when-let* ((sid (and (consp state) (plist-get state :session-id)))
                                   ((stringp sid))
                                   (read (harness-ui-cache-warm--read sid state)))
                         (puthash sid read harness-ui-cache-warm--states)))
                     (harness-ui-cache-warm--redraw nil)
                     (harness-ui-cache-warm--sync-timer)
                     (harness-ignore-errors-logged "harness-ui-cache-warm-functions"
                       (run-hook-with-args 'harness-ui-cache-warm-functions nil nil))
                     (when callback (funcall callback states)))
                   (lambda (err)
                     (when (harness-ui-cache-warm--missing-p err)
                       (setq harness-ui-cache-warm--unavailable t))
                     nil)))

;;;; What the header shows

(defun harness-ui-cache-warm-countdown (seconds)
  "Describe SECONDS left, coarsely: \"1h20m\", \"2h\", \"12m\", \"<1m\".
A minute or more reads in whole minutes, rounded up, and an hour or
more in hours and minutes, so what is shown changes once a minute."
  (if (< seconds 60)
      "<1m"
    (let* ((minutes (ceiling seconds 60))
           (hours (/ minutes 60))
           (rest (% minutes 60)))
      (cond ((zerop hours) (format "%dm" minutes))
            ((zerop rest) (format "%dh" hours))
            (t (format "%dh%02dm" hours rest))))))

(defun harness-ui-cache-warm--describe (state &optional now)
  "Describe STATE, a warm state shown at NOW, for a tooltip.
It says what is happening and until when, why the cache is kept warm
\(the period you set, your activity, or a tool call the turn waits on),
when the next refresh is due and how many were made, what a refresh
costs against sending the conversation again when the harness says, and
what a click does.  A state the header shows although nothing is kept
warm says why."
  (let* ((now (or now (float-time)))
         (warming (plist-get state :warming))
         (until (harness-ui-cache-warm--end state))
         (manual (plist-get state :manual-until))
         (next (plist-get state :next))
         (refreshes (or (plist-get state :refreshes) 0))
         (refresh-cost (plist-get state :refresh-cost))
         (resend-cost (plist-get state :resend-cost)))
    (concat
     (cond
      ((not warming)
       (format "The harness is not keeping this session's prompt cache warm: %s.\nThe period you set lasts until %s."
               (string-trim-right (or (plist-get state :blocked) "") "[.]+")
               (harness-ui-format-clock until now)))
      ((plist-get state :tool)
       (format (concat "This session is waiting on a tool call, and its prompt cache is kept warm meanwhile: "
                       "just before the provider would drop it, the harness reads it again, so the next step "
                       "of the turn does not send the whole conversation uncached.\n"
                       "Kept warm until %s at the latest.")
               (harness-ui-format-clock until now)))
      (t
       (concat "This session's prompt cache is being kept warm: just before the provider would drop it, "
               "the harness reads it again, so the next message does not send the whole conversation uncached.\n"
               (format "Warm until %s%s." (harness-ui-format-clock until now)
                       (if (and (numberp manual) (>= manual (- until 1.0)))
                           ", the period you set"
                         ", as you were active")))))
     (if (and warming (numberp next)) (format "  Next refresh at %s." (harness-ui-format-clock next now)) "")
     (if (and warming (> refreshes 0)) (format "  %d so far." refreshes) "")
     (if (and (numberp refresh-cost) (numberp resend-cost))
         (format "\nA refresh costs about %s; sending the whole conversation again uncached, about %s."
                 (harness-format-cost refresh-cost) (harness-format-cost resend-cost))
       "")
     "\nmouse-1: keep it warm for a period of your own, or stop")))

(defun harness-ui-cache-warm--help (window _object _pos)
  "Return the tooltip of the flame in WINDOW's header line.
A `help-echo' function, so the clock times are worked out on hover."
  (let* ((buffer (if (window-live-p window) (window-buffer window) (current-buffer)))
         (state (harness-ui-cache-warm--showing (buffer-local-value 'harness-ui-session-id buffer))))
    (if state
        (harness-ui-cache-warm--describe state)
      "The prompt cache is not being kept warm (mouse-1: keep it warm for a period of your own)")))

(defun harness-ui-cache-warm--segment (state &optional now)
  "Return the header line's flame and countdown for STATE, at NOW.
While nothing is kept warm because the harness is blocked, a period
the user set being on, the flame is dim and says \"off\" in place of a
countdown; hovering says why.  A segment that runs
`harness-cache-keep-warm' when clicked."
  (let* ((warming (plist-get state :warming))
         (left (- (harness-ui-cache-warm--end state) (or now (float-time)))))
    (harness-chat--segment (concat (harness-ui-icon 'harness-icon-flame) " "
                                   (if warming (harness-ui-cache-warm-countdown left) "off"))
                           #'harness-cache-keep-warm
                           #'harness-ui-cache-warm--help
                           (if (and warming (>= left 60)) 'harness-chat-warm-face 'harness-dim-face))))

(defun harness-ui-cache-warm--header ()
  "Return the flame and the countdown for a chat's header line, or nil.
On `harness-chat-header-end-functions': a segment while this chat's
session has its prompt cache kept warm and the warming period has not
ended -- whether the user is about or a turn waits on a tool call -- and
while a period the user set is blocked (`harness-ui-cache-warm--end')."
  (when-let* ((state (harness-ui-cache-warm--showing harness-ui-session-id)))
    (list (concat "  " (harness-ui-cache-warm--segment state))
          harness-ui-cache-warm--header-priority)))

;;;; The countdown's timer

(defvar harness-ui-cache-warm--timer nil
  "The timer that draws the countdowns again while one is shown, or nil.")

(defun harness-ui-cache-warm--any-showing-p (&optional now)
  "Non-nil when some session's chat shows a countdown at NOW."
  (let ((found nil))
    (maphash (lambda (sid _state)
               (when (harness-ui-cache-warm--showing sid now) (setq found t)))
             harness-ui-cache-warm--states)
    found))

(defun harness-ui-cache-warm--tick ()
  "Draw the countdowns again, and stop the timer once none is shown."
  (force-mode-line-update t)
  (harness-ui-cache-warm--sync-timer))

(defun harness-ui-cache-warm--sync-timer ()
  "Run the countdowns' timer while one is shown, and cancel it when none is.
A timer already running stays."
  (if (harness-ui-cache-warm--any-showing-p)
      (unless (and (timerp harness-ui-cache-warm--timer)
                   (memq harness-ui-cache-warm--timer timer-list))
        (setq harness-ui-cache-warm--timer
              (run-at-time harness-ui-cache-warm--tick-interval harness-ui-cache-warm--tick-interval
                           #'harness-ui-cache-warm--tick)))
    (when (timerp harness-ui-cache-warm--timer)
      (cancel-timer harness-ui-cache-warm--timer))
    (setq harness-ui-cache-warm--timer nil)))

;;;; Reporting that the user is active

(defvar-local harness-ui-cache-warm--reported nil
  "When this chat buffer last reported the user active, a float time, or nil.")

(defun harness-ui-cache-warm--report (sid)
  "Tell the harness that the user is active in session SID.
What it answers is the user's presence in the session; the warm state
that follows from it comes as `cache/warm-changed', and an answer that
is a warm state is taken in as one.  A harness without the
cache-warming module stops the reports, and no failure is shown: this is
a courtesy to a feature, not something the user asked for."
  (harness-ui-call "_harness/cache/active" (list :session-id sid)
                   (lambda (state)
                     (when (and (consp state) (plist-member state :warming))
                       (harness-ui-cache-warm--changed sid state)))
                   (lambda (err)
                     (when (harness-ui-cache-warm--missing-p err)
                       (setq harness-ui-cache-warm--unavailable t))
                     nil)))

(defun harness-ui-cache-warm--note-activity ()
  "Report that the user is active in this chat's session, now and then.
A local `post-command-hook' of the chat buffers: a command run while the
buffer is in the selected window -- typing in the compose box, scrolling,
a click on a button -- is the user being active in the session.  At most
one report goes out every `harness-ui-cache-warm--report-interval'
seconds, so a command costs one comparison."
  (when (and harness-ui-session-id
             (not harness-ui-cache-warm--unavailable)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (let ((now (float-time)))
      (when (or (null harness-ui-cache-warm--reported)
                (>= (- now harness-ui-cache-warm--reported) harness-ui-cache-warm--report-interval))
        (setq harness-ui-cache-warm--reported now)
        (harness-ignore-errors-logged "harness-ui-cache-warm"
          (harness-ui-cache-warm--report harness-ui-session-id))))))

(defun harness-ui-cache-warm--setup ()
  "Report the user's activity in this chat buffer."
  (add-hook 'post-command-hook #'harness-ui-cache-warm--note-activity nil t))

;;;; Setting a period by hand

(defun harness-ui-cache-warm--parse-token (rest)
  "Return (NUMBER UNIT REMAINDER) for the first duration in REST, or nil.
NUMBER is a number, UNIT the seconds a unit of its is worth, or nil
when it has no unit, and REMAINDER what is left of REST."
  (when (string-match (concat "\\`[ ,]*\\(?:and[ ]+\\)?\\([0-9]+\\(?:[.][0-9]+\\)?\\)[ ]*"
                              "\\(d\\(?:ays?\\)?\\|h\\(?:ours?\\|rs?\\)?\\|m\\(?:in\\(?:ute\\)?s?\\)?"
                              "\\|s\\(?:ec\\(?:ond\\)?s?\\)?\\)?")
                      rest)
    (let ((unit (match-string 2 rest)))
      (list (string-to-number (match-string 1 rest))
            (and unit (pcase (aref unit 0) (?d 86400) (?h 3600) (?m 60) (_ 1)))
            (substring rest (match-end 0))))))

(defun harness-ui-cache-warm-parse-duration (text)
  "Return the seconds the period TEXT says, 0 for \"off\".
Signal a `user-error' when TEXT says none.
TEXT is a period such as 30m, 1h, 1h30m, 1.5h or 90, which is minutes;
seconds (45s) and days (1d) are read too, and so is a number after hours
with no unit, 1h30, as minutes.  A comma between digits is a decimal
point (1,5h), one anywhere else a separator (1h, 30m).  off, stop, none,
clear, cancel and 0 say there is no period.  A period is at most 24
hours."
  (let ((rest (replace-regexp-in-string
               "\\([0-9]\\),\\([0-9]\\)" "\\1.\\2"
               (downcase (string-trim (or text ""))))))
    (cond
     ((string-empty-p rest)
      (user-error "Say how long: 30m, 1h, 1h30m, or off"))
     ((string-match-p "\\`\\(?:off\\|stop\\|none\\|no\\|clear\\|cancel\\)\\'" rest) 0)
     (t
      (let ((total 0.0) (previous nil) (any nil))
        (while (not (string-empty-p rest))
          (let ((token (harness-ui-cache-warm--parse-token rest)))
            (unless token
              (user-error "Cannot read “%s” as a period: try 30m, 1h30m or off" (string-trim text)))
            (let* ((number (nth 0 token))
                   (unit (or (nth 1 token)
                             ;; A bare number is minutes, and after hours too: 1h30.
                             (if (or (null previous) (eql previous 3600) (eql previous 86400)) 60
                               (user-error "Cannot read “%s” as a period: try 30m, 1h30m or off"
                                           (string-trim text))))))
              (setq total (+ total (* number unit))
                    previous unit
                    any t
                    rest (string-trim-left (nth 2 token))))))
        (unless any
          (user-error "Say how long: 30m, 1h, 1h30m, or off"))
        (min harness-ui-cache-warm--max-seconds (round total)))))))

(defun harness-ui-cache-warm--read-seconds (sid)
  "Ask how long to keep session SID's prompt cache warm; return the seconds.
The prompt names the period that is in effect, if one is.  Completion
offers `harness-ui-cache-warm--presets', and an empty answer takes
`harness-ui-cache-warm--default'."
  (let* ((state (harness-ui-cache-warm--showing sid))
         (what (if state
                   (format "Keep the prompt cache warm, now until %s, for"
                           (harness-ui-format-clock (harness-ui-cache-warm--end state)))
                 "Keep the prompt cache warm for"))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action harness-ui-cache-warm--presets string pred))))
         (answer (completing-read (format-prompt what harness-ui-cache-warm--default)
                                  table nil nil nil nil harness-ui-cache-warm--default)))
    (harness-ui-cache-warm-parse-duration answer)))

(defun harness-ui-cache-warm--refreshes (left state)
  "Return about how many refreshes keeping the cache warm for LEFT seconds makes.
STATE is the session's warm state.  The first refresh is due at its
`:next', and one falls every `:ttl' seconds less the lead the harness
keeps before the cache lapses (the gap between `:next' and `:expires'),
five minutes with a lead of ten seconds when it says nothing.  The limit
the harness names -- `:max-refreshes', how many cost less than sending
the conversation again -- is the most counted."
  (let* ((ttl (or (plist-get state :ttl) 300))
         (next (plist-get state :next))
         (expires (plist-get state :expires))
         (lead (if (and (numberp next) (numberp expires) (> expires next))
                   (- expires next)
                 (min 60 (max 10 (/ ttl 30.0)))))
         (interval (max 1 (- ttl lead)))
         (first (if (numberp next) (max 0 (- next (float-time))) interval))
         (count (if (< left first) 0 (1+ (floor (- left first) interval))))
         (limit (plist-get state :max-refreshes)))
    (if (natnump limit) (min count limit) count)))

(defun harness-ui-cache-warm--said (seconds state read-cost)
  "Return what the echo area says after asking to keep a cache warm for SECONDS.
STATE is the warm state the harness answered with, nil when it gave
none, and READ-COST what reading the cache once costs in US dollars
when the state has no `:refresh-cost' of its own, else nil.  A request
the harness cannot go through with says why, in the harness's words."
  (let* ((now (float-time))
         (state (or state (list :supported t)))
         (manual (plist-get state :manual-until))
         (until (or (plist-get state :until) manual))
         (blocked (plist-get state :blocked))
         (capped (if (= seconds harness-ui-cache-warm--max-seconds)
                     "; a period is kept 24 hours at most"
                   "")))
    (cond
     ((zerop seconds)
      (if (plist-get state :warming)
          (format "Stopped the period you set; the prompt cache is kept warm until %s all the same, as you were active"
                  (harness-ui-format-clock (plist-get state :until) now))
        "Stopped keeping the prompt cache warm"))
     ((and blocked (not (plist-get state :warming)))
      (format "Not keeping the prompt cache warm: %s" (string-trim-right blocked "[.]+")))
     ((not (plist-get state :supported))
      ;; Why, in the harness's words: a turn that runs reads the cache
      ;; itself, which is not a provider with no way to refresh it.
      (if-let* ((why (plist-get state :unsupported)))
          (format "Nothing to keep warm now: %s" (string-trim-right why "[.]+"))
        "Nothing to keep warm: this session's provider has no way to refresh its prompt cache"))
     ((plist-get state :warming)
      (let* ((end (or until (+ now seconds)))
             (refreshes (harness-ui-cache-warm--refreshes (max 0 (- end now)) state))
             (price (or (plist-get state :refresh-cost) read-cost))
             (resend (plist-get state :resend-cost)))
        (format "Keeping the prompt cache warm until %s (%s)%s%s"
                (harness-ui-format-clock end now)
                (string-join
                 (delq nil
                       (list (if (zerop refreshes)
                                 "the cache lapses before a refresh is due"
                               (format "about %d refresh%s" refreshes (if (= refreshes 1) "" "es")))
                             (and (numberp price) (> refreshes 0)
                                  (format "~%s at cache-read prices" (harness-format-cost (* refreshes price))))
                             (and (numberp resend)
                                  (format "against ~%s to send it all again uncached" (harness-format-cost resend)))))
                 ", ")
                ;; The harness stops short of the period when more refreshes cost more.
                (if (and (numberp manual) (numberp until) (< until (- manual 60)))
                    "; longer would cost more than sending the conversation again"
                  "")
                capped)))
     (t
      (format "Nothing is cached to keep warm: the next message sends the whole conversation again; the cache is kept warm after it, until %s%s"
              (harness-ui-format-clock (or manual until (+ now seconds)) now)
              capped)))))

;;;###autoload
(defun harness-cache-keep-warm (session-id &optional seconds)
  "Keep SESSION-ID's prompt cache warm for SECONDS from now, whatever you do.
Interactively it is this buffer's session, and you are asked how long:
30m, 1h, 1h30m, 90 (minutes) or off, which ends a period you set.  It is
for when the harness has not noticed you are around -- you know you
will be back in twenty minutes -- and adds to what it works out itself:
the cache is kept warm for as long as you have been active in the
session and for a while after, and for this period too, whichever ends
last, though never for longer than it costs less than sending the
conversation again.  The harness reads the cache just before it would
lapse, which costs a fraction of sending the conversation uncached;
the echo area says until when, about how many refreshes that is and,
when it can price them, what they cost.  A period is at most 24 hours.
Without SECONDS, called from Lisp, it asks too."
  (interactive (let ((sid (harness-ui-current-session-id)))
                 (list sid (harness-ui-cache-warm--read-seconds sid))))
  (let ((seconds (or seconds (harness-ui-cache-warm--read-seconds session-id))))
    (harness-ui-call
     "_harness/cache/keep-warm" (list :session-id session-id :seconds seconds)
     (lambda (state)
       (let ((read (harness-ui-cache-warm--changed session-id state)))
         (if (and (> seconds 0) read (plist-get read :warming)
                  (not (numberp (plist-get read :refresh-cost))))
             ;; The harness named no price for a refresh: ask what reading
             ;; the whole context from the cache costs, which is what it
             ;; says carrying on costs while the cache lasts.
             (harness-ui-call
              "_harness/compaction/estimate" (list :session-id session-id)
              (lambda (estimate)
                (message "%s" (harness-ui-cache-warm--said
                               seconds read
                               (and (consp estimate) (numberp (plist-get estimate :carry-on-cached))
                                    (plist-get estimate :carry-on-cached)))))
              (lambda (_err)
                (message "%s" (harness-ui-cache-warm--said seconds read nil))
                nil))
           (message "%s" (harness-ui-cache-warm--said seconds read nil)))))
     (lambda (err)
       (unless (harness-ui-connection-replaced-p err)
         (message "%s" (if (harness-ui-cache-warm--missing-p err)
                           "Cannot keep the cache warm: the harness has no cache-warming module (enable cache-warm)"
                         (format "Keeping the prompt cache warm failed: %s" (harness-error-message err)))))
       nil))))

(defun harness-ui-cache-warm--chat-command (args)
  "Run /warm ARGS in a chat's message box: keep its session's prompt cache warm.
ARGS is a period (`harness-ui-cache-warm-parse-duration') or off; empty,
it asks.  One that cannot be read keeps the text in the box."
  (harness-cache-keep-warm harness-ui-session-id
                           (and (not (string-empty-p args))
                                (harness-ui-cache-warm-parse-duration args))))

;;;; The menu

(defun harness-ui-cache-warm--suffix-command (key)
  "Return the command the harness menu has at KEY, or nil."
  (when-let* ((suffix (ignore-errors (transient-get-suffix 'harness-menu key))))
    (plist-get (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix))) :command)))

(defun harness-ui-cache-warm--menu-install ()
  "Put `harness-cache-keep-warm' in the harness menu, after Fork session."
  (condition-case err
      (pcase (harness-ui-cache-warm--suffix-command "K")
        ((pred null) (transient-append-suffix 'harness-menu "f" '("K" "Keep cache warm" harness-cache-keep-warm)))
        ('harness-cache-keep-warm nil)
        (other (harness-log 'warn "cache-warm: the menu key K is %s's: no entry for keeping a cache warm" other)))
    (error (harness-log 'warn "cache-warm: no menu entry: %s" (error-message-string err)))))

(defun harness-ui-cache-warm--menu-remove ()
  "Take `harness-cache-keep-warm' out of the harness menu."
  (when (eq (harness-ui-cache-warm--suffix-command "K") 'harness-cache-keep-warm)
    (ignore-errors (transient-remove-suffix 'harness-menu "K"))))

;;;; Following the harness

(defun harness-ui-cache-warm--on-event (event args)
  "Follow EVENT with ARGS, from `_harness/event'.
`cache/warm-changed' brings a session's warm state, nil once it has
none; a session deleted has none either; after `harness/reloaded' the
states are fetched again."
  (pcase event
    ("cache/warm-changed" (harness-ui-cache-warm--changed (car args) (cadr args)))
    ("session/deleted" (when (stringp (car args)) (harness-ui-cache-warm--changed (car args) nil)))
    ("harness/reloaded" (harness-ui-cache-warm-refresh))))

(defun harness-ui-cache-warm--on-connected ()
  "Forget the states of the harness the UI was connected to before.
The harness the UI is connected to now is asked for its own, and may
have a cache-warming module the other lacked."
  (setq harness-ui-cache-warm--unavailable nil)
  (clrhash harness-ui-cache-warm--states)
  (harness-ui-cache-warm--sync-timer)
  (harness-ui-cache-warm--redraw nil)
  (harness-ui-cache-warm-refresh))

;;;; Module

(defun harness-ui-cache-warm--init ()
  "Wire the flame, the activity reports, K and /warm into the UI.
The flame goes in every chat's header, the reports from every chat
buffer, those open already included.  When the UI is connected
already, the states are fetched now."
  (add-hook 'harness-ui-event-functions #'harness-ui-cache-warm--on-event)
  (add-hook 'harness-ui-connected-hook #'harness-ui-cache-warm--on-connected)
  (add-hook 'harness-chat-header-end-functions #'harness-ui-cache-warm--header)
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-cache-warm--setup)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-chat-mode)
          (harness-ui-cache-warm--setup)))))
  (setf (alist-get "warm" harness-chat-commands nil nil #'equal) #'harness-ui-cache-warm--chat-command)
  (define-key harness-ui-map (kbd "K") #'harness-cache-keep-warm)
  (harness-ui-cache-warm--menu-install)
  (when (harness-ui-connected-p)
    (harness-ui-cache-warm-refresh)))

(defun harness-ui-cache-warm--shutdown ()
  "Take the flame out of the chats, stop reporting, and unbind K and /warm."
  (remove-hook 'harness-ui-event-functions #'harness-ui-cache-warm--on-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-cache-warm--on-connected)
  (remove-hook 'harness-chat-header-end-functions #'harness-ui-cache-warm--header)
  (remove-hook 'harness-chat-mode-hook #'harness-ui-cache-warm--setup)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      ;; Only a buffer that has the hook of its own: removing from the
      ;; local value of another would give it one.
      (when (local-variable-p 'post-command-hook)
        (remove-hook 'post-command-hook #'harness-ui-cache-warm--note-activity t))))
  (when (eq (cdr (assoc "warm" harness-chat-commands)) #'harness-ui-cache-warm--chat-command)
    (setq harness-chat-commands (assoc-delete-all "warm" harness-chat-commands)))
  (when (eq (lookup-key harness-ui-map (kbd "K")) #'harness-cache-keep-warm)
    (define-key harness-ui-map (kbd "K") nil t))
  (harness-ui-cache-warm--menu-remove)
  (clrhash harness-ui-cache-warm--states)
  (harness-ui-cache-warm--sync-timer)
  (harness-ui-cache-warm--redraw nil)
  (setq harness-ui-cache-warm--unavailable nil))

(harness-define-module 'ui-cache-warm
  :doc "A session's prompt cache kept warm, in the UI: a flame and a countdown in the chat header, the user's activity reported, and /warm, K and the flame to set a period by hand."
  :requires '(ui ui-chat)
  :init #'harness-ui-cache-warm--init
  :shutdown #'harness-ui-cache-warm--shutdown)

(provide 'harness-ui-cache-warm)
;;; harness-ui-cache-warm.el ends here
