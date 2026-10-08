;;; harness-ui-cache.el --- The expired prompt cache of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it: five minutes or an hour for Claude, hours for
;; DeepSeek (see `harness-cache-ttl').  A session left alone for longer
;; sends its whole context again uncached with its next message, which
;; costs more and answers slower.  The harness knows when each session's
;; requests last used the cache and how long its provider keeps it: the
;; session's `:cache', (:at TIME :ttl SECONDS :expires TIME).  Once that
;; moment is past, a panel above the compose box says so, with how much
;; context the next message sends uncached and what that costs at list
;; prices.  It informs; there is nothing to do about it but know, as
;; even a compaction would read the history uncached.
;;
;; The panel comes on its own: each chat buffer has one timer, for the
;; moment its session's cache lapses, which draws the tail again then
;; (`harness-compose-redraw').  Nothing polls.  A session update moves
;; the timer, as a new request keeps the cache longer, and hides the
;; panel as soon as a request is under way.  The panel names clock
;; times, never ages, so it stays true for as long as it shows without
;; being drawn again.  A session that never used a cache, a new one
;; included, has no `:cache' and never shows it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-chat--session)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-compose-redraw "harness-ui-compose" ())

(defgroup harness-ui-cache nil
  "Telling when a session's prompt cache has expired." :group 'harness-ui)

(defface harness-chat-cache-face
  '((((background light)) :background "#f8e6f4" :extend t)
    (((background dark)) :background "#3a2237" :extend t))
  "Background of the cache panel: the session's prompt cache has expired.
An orchid of its own, apart from the activity line's lavender, which
shows in the same place while the session runs."
  :group 'harness-ui-cache)

(harness-ui-define-icon harness-icon-clock "clock" "◷" "cache" "Time: a cache that lapsed.")

(defvar-local harness-ui-cache--shown nil
  "What this buffer's cache panel showed when last drawn, or nil for nothing.
See `harness-ui-cache--state'.")

(defvar-local harness-ui-cache--timer nil
  "Timer that draws this buffer's tail again when its session's cache lapses.")

(defvar-local harness-ui-cache--due nil
  "The moment `harness-ui-cache--timer' is set for, a float time.")

;;;; What the panel shows

(defun harness-ui-cache--session ()
  "Return the session of this chat buffer, as last heard."
  (or (bound-and-true-p harness-chat--session)
      (and harness-ui-session-id (harness-ui-session harness-ui-session-id))))

(defun harness-ui-cache--state (session &optional now)
  "Return what the cache panel shows of SESSION at NOW, or nil for nothing.
NOW is the current time by default.  The panel shows once the cache
SESSION's requests last used has lapsed (its `:cache' `:expires' is
past) while SESSION waits for the user: idle, closed, or blocked on
an answer.  A running session sends requests, which keep the cache.
States that read the same are `equal', so a session update that
changes nothing the panel says does not draw it again."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires))
         (status (format "%s" (plist-get session :status))))
    (when (and (numberp expires)
               (member status '("idle" "inactive" "blocked"))
               (>= (or now (float-time)) expires))
      (list :at (plist-get cache :at) :ttl (plist-get cache :ttl) :expires expires
            :context (plist-get (plist-get session :usage) :context)
            :model (plist-get session :model)
            :blocked (equal status "blocked")))))

(defun harness-ui-cache--duration (seconds)
  "Describe SECONDS, how long a cache lasts, in words: \"5 minutes\"."
  (pcase-let* ((s (max 1 (round seconds)))
               (`(,n . ,unit) (cond ((< s 120) (cons s "second"))
                                    ((< s 3600) (cons (round s 60) "minute"))
                                    ((< s 172800) (cons (round s 3600) "hour"))
                                    (t (cons (round s 86400) "day")))))
    (format "%d %s%s" n unit (if (= n 1) "" "s"))))

(defun harness-ui-cache--clock (time now)
  "Return TIME as a clock time, with its day unless that is NOW's."
  (if (equal (format-time-string "%F" time) (format-time-string "%F" now))
      (format-time-string "%H:%M" time)
    (format-time-string "%b %-d, %H:%M" time)))

(defun harness-ui-cache--price (tokens model key)
  "Return what TOKENS tokens cost at MODEL's KEY price, or nil.
The price, in US dollars per million tokens, is the catalogue's."
  (let ((price (plist-get (plist-get (gethash model harness-ui--models) :pricing) key)))
    (and (numberp tokens) (> tokens 0) (numberp price) (>= price 0)
         (/ (* tokens price) 1e6))))

(defun harness-ui-cache--cost (state)
  "Return what the context of STATE costs uncached and cached, or nil.
A cons (UNCACHED . CACHED) at the model's list prices: written to the
cache again (its cache-write price, else its input price) against read
back from it.  Nil when the catalogue does not price both."
  (let* ((tokens (plist-get state :context))
         (model (plist-get state :model))
         (uncached (or (harness-ui-cache--price tokens model :cache-write)
                       (harness-ui-cache--price tokens model :input)))
         (cached (harness-ui-cache--price tokens model :cache-read)))
    (and uncached cached (> uncached cached) (cons uncached cached))))

(defun harness-ui-cache--next (state)
  "Return what sends the context again for STATE, as a sentence's subject."
  (if (plist-get state :blocked) "The next request" "Your next message"))

(defun harness-ui-cache--help (state)
  "Return the tooltip of the cache panel for STATE."
  (format (concat "The provider keeps the start of a conversation cached for %s after a request uses it.\n"
                  "This session's requests last used the cache at %s, so it lapsed at %s.\n"
                  "%s sends the whole context, %s tokens, at the uncached rate, and caches it again.")
          (harness-ui-cache--duration (plist-get state :ttl))
          (format-time-string "%H:%M:%S" (plist-get state :at))
          (format-time-string "%H:%M:%S" (plist-get state :expires))
          (harness-ui-cache--next state)
          (harness-format-tokens (plist-get state :context))))

(defun harness-ui-cache--banner (state now)
  "Return the cache panel for STATE, drawn at NOW."
  (let* ((cost (harness-ui-cache--cost state))
         (tokens (plist-get state :context))
         (string
          (concat
           " " (propertize (concat (harness-ui-icon 'harness-icon-clock) " Prompt cache expired")
                           'face 'harness-label-face)
           "  "
           (propertize (format "at %s, %s after its last use"
                               (harness-ui-cache--clock (plist-get state :expires) now)
                               (harness-ui-cache--duration (plist-get state :ttl)))
                       'face 'harness-dim-face)
           "\n"
           (propertize (concat "   " (harness-ui-cache--next state)
                               (if (and (numberp tokens) (> tokens 0))
                                   (format " re-sends ~%s tokens uncached" (harness-format-tokens tokens))
                                 " re-sends the conversation uncached")
                               (if cost
                                   (format ": about %s instead of %s, at list prices."
                                           (harness-format-cost (car cost)) (harness-format-cost (cdr cost)))
                                 "."))
                       'wrap-prefix "   ")
           "\n")))
    (add-text-properties 0 (length string)
                         (list 'harness-ui-cache-panel t 'help-echo (harness-ui-cache--help state))
                         string)
    (harness-ui-add-face string 'harness-chat-cache-face)))

;;;; Showing it on time

(defun harness-ui-cache--cancel ()
  "Stop this buffer's cache timer, if any."
  (when (timerp harness-ui-cache--timer)
    (cancel-timer harness-ui-cache--timer))
  (setq harness-ui-cache--timer nil
        harness-ui-cache--due nil))

(defun harness-ui-cache--schedule (session)
  "Set this buffer's timer for the moment SESSION's cache lapses.
Nothing is set when it has lapsed already or SESSION has no cache; a
timer already set for that moment stays."
  (let* ((expires (plist-get (plist-get session :cache) :expires))
         (due (and (numberp expires) (> expires (float-time)) expires)))
    (unless (and due (equal due harness-ui-cache--due)
                 (memq harness-ui-cache--timer timer-list))
      (harness-ui-cache--cancel)
      (when due
        (setq harness-ui-cache--due due
              harness-ui-cache--timer (run-at-time (- due (float-time)) nil
                                                   #'harness-ui-cache--lapse (current-buffer)))))))

(defun harness-ui-cache--redraw ()
  "Draw the tail of this chat buffer again."
  (when (functionp harness-compose-redraw-function)
    (harness-compose-redraw)))

(defun harness-ui-cache--sync ()
  "Bring this chat buffer's cache timer and panel up to date with its session.
The tail is drawn again only when what the panel shows changed."
  (let ((session (harness-ui-cache--session)))
    (harness-ui-cache--schedule session)
    (unless (equal (harness-ui-cache--state session) harness-ui-cache--shown)
      (harness-ui-cache--redraw))))

(defun harness-ui-cache--lapse (buffer)
  "Show BUFFER's cache panel, its session's cache having lapsed by now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-cache--timer nil
            harness-ui-cache--due nil)
      (harness-ui-cache--sync))))

(defun harness-ui-cache--panel ()
  "Return the cache panel when this session's prompt cache has lapsed, else nil.
On `harness-chat-panel-functions'.  Drawing sets the timer for when
the cache lapses too, so a buffer that just opened shows it on time."
  (let* ((session (harness-ui-cache--session))
         (now (float-time))
         (state (harness-ui-cache--state session now)))
    (setq harness-ui-cache--shown state)
    (harness-ui-cache--schedule session)
    (and state (harness-ui-cache--banner state now))))

(defun harness-ui-cache--on-update (sid update)
  "Follow the record of session SID, which UPDATE may bring.
On `harness-ui-update-functions', after the chat has taken it in."
  (when (equal (plist-get update :sessionUpdate) "_harness/session")
    (when-let* ((buffer (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid))))
      (with-current-buffer buffer
        (when (memq #'harness-ui-cache--panel harness-chat-panel-functions)
          (harness-ui-cache--sync))))))

;;;; Setup

(defun harness-ui-cache--setup ()
  "Show the cache panel in this chat buffer."
  (add-hook 'harness-chat-panel-functions #'harness-ui-cache--panel t t)
  (add-hook 'kill-buffer-hook #'harness-ui-cache--cancel nil t))

(defun harness-ui-cache--init ()
  "Add the cache panel to every chat buffer, those open already included."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-cache--setup)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-chat-mode)
          (harness-ui-cache--setup)))))
  (add-hook 'harness-ui-update-functions #'harness-ui-cache--on-update t))

(harness-define-module 'ui-cache
  :doc "Warns above a session's compose box once its prompt cache has expired."
  :requires '(ui ui-chat)
  :init #'harness-ui-cache--init)

(provide 'harness-ui-cache)
;;; harness-ui-cache.el ends here
