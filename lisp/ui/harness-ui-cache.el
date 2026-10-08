;;; harness-ui-cache.el --- The expired prompt cache of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it: five minutes or an hour for Claude, hours for
;; DeepSeek (see `harness-cache-ttl').  A session left alone for longer
;; sends its whole context again uncached with its next message, which
;; costs more and answers slower.  The harness knows when each session's
;; requests last used the cache, the model they went to and how long its
;; provider keeps it: the session's `:cache', (:at TIME :ttl SECONDS
;; :expires TIME :model MODEL).  Once that moment is past, a panel above
;; the compose box says so, with how much context the next message sends
;; uncached and what that costs at list prices.
;;
;; It offers to compact the conversation first, so the next message sends
;; only what stands in for it (harness-ui-compact.el): a button for each
;; kind with what it costs (`compaction/estimate', asked once per thing
;; the panel says and drawn when it comes), the brief summary first.
;; That one is the cheap way out of a long conversation gone cold: a
;; cheap model reads only its first and last messages, for cents,
;; where a summary on the session's model reads all of it uncached, as
;; carrying on would.  A transcript file asks no model at all.  The
;; buttons' keys work while point is on their line.  A session blocked
;; on an answer is in the middle of a turn, which no compaction
;; interrupts: its panel only informs.
;;
;; A cache serves one model, so a session switched to another model
;; finds nothing cached for it: the panel says so at once, with what the
;; new model's first request costs, and goes when that request caches the
;; conversation again (or the session switches back while the old cache
;; lasts).  A switch that starts a conversation of its own on the new
;; provider -- a hosted loop, handed over a summary or a transcript or
;; nothing -- sends none of the old one, and a compaction replaces it
;; with its summary: the session reports no cache then, and no panel
;; shows.  While the switch banner asks how to hand over
;; (harness-ui-switch.el), the panel stays away: what the next request
;; sends depends on the answer, and the banner says what the cache
;; means for each.
;;
;; The panel comes on its own: each chat buffer has one timer, for the
;; moment its session's cache lapses, which draws the tail again then
;; (`harness-compose-redraw'), the switch banner included.  Nothing
;; polls.  A session update moves the timer, as a new request keeps the
;; cache longer, and hides the panel as soon as a request is under way.
;; The panel names clock times, never ages, so it stays true for as long
;; as it shows without being drawn again.  A session that never used a
;; cache, a new one included, has no `:cache' and never shows it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compact)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-chat--session)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(defvar harness-ui-switch--prompt)
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-compose-redraw "harness-ui-compose" ())
(declare-function harness-chat--button "harness-ui-chat" (label action &rest props))
(declare-function harness-chat--kbd "harness-ui-chat" (key))

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

(defvar-local harness-ui-cache--estimate nil
  "What compacting this buffer's session costs, as its cache panel last asked.
A cons (STATE . ESTIMATE): STATE what the panel showed when it asked
\(`harness-ui-cache--state'), ESTIMATE the `compaction/estimate'
answer, `pending' while it is asked, or `failed'.")

(defvar-local harness-ui-cache--compacting nil
  "The kind of compaction the cache panel started in this buffer, while it runs.")

;;;; What the panel shows

(defun harness-ui-cache--session ()
  "Return the session of this chat buffer, as last heard."
  (or (bound-and-true-p harness-chat--session)
      (and harness-ui-session-id (harness-ui-session harness-ui-session-id))))

(defun harness-ui-cache--other-model (session)
  "Return the model of SESSION's cache when it is not SESSION's model, else nil.
A cache serves the model that wrote it, so SESSION, switched since,
has nothing cached for its own."
  (let ((cached (plist-get (plist-get session :cache) :model)))
    (and cached (not (equal cached (plist-get session :model))) cached)))

(defun harness-ui-cache--state (session &optional now)
  "Return what the cache panel shows of SESSION at NOW, or nil for nothing.
NOW is the current time by default.  The panel shows once the cache
SESSION's requests last used has lapsed (its `:cache' `:expires' is
past), and at once when that cache is of a model SESSION no longer uses
\(`:from'), while SESSION waits for the user: idle, closed, or blocked
on an answer.  A running session sends requests, which keep the cache.
States that read the same are `equal', so a session update that
changes nothing the panel says does not draw it again."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires))
         (from (harness-ui-cache--other-model session))
         (status (format "%s" (plist-get session :status))))
    (when (and (numberp expires)
               (member status '("idle" "inactive" "blocked"))
               (or from (>= (or now (float-time)) expires)))
      (list :at (plist-get cache :at) :ttl (plist-get cache :ttl) :expires expires
            :context (plist-get (plist-get session :usage) :context)
            :model (plist-get session :model)
            :from from
            :blocked (equal status "blocked")))))

(defun harness-ui-cache--current (session &optional now)
  "Return what this buffer's cache panel shows of SESSION at NOW, or nil.
That is `harness-ui-cache--state', save while the switch banner asks
how to hand over: what the next request sends depends on the answer,
and the banner says what the cache means for each."
  (unless (bound-and-true-p harness-ui-switch--prompt)
    (harness-ui-cache--state session now)))

(defun harness-ui-cache--duration (seconds)
  "Describe SECONDS, how long a cache lasts, in words: \"5 minutes\"."
  (pcase-let* ((s (max 1 (round seconds)))
               (`(,n . ,unit) (cond ((< s 120) (cons s "second"))
                                    ((< s 3600) (cons (round s 60) "minute"))
                                    ((< s 172800) (cons (round s 3600) "hour"))
                                    (t (cons (round s 86400) "day")))))
    (format "%d %s%s" n unit (if (= n 1) "" "s"))))

(defun harness-ui-cache--price (tokens model key)
  "Return what TOKENS tokens cost at MODEL's KEY price, or nil.
The price, in US dollars per million tokens, is the catalogue's."
  (let ((price (plist-get (plist-get (gethash model harness-ui--models) :pricing) key)))
    (and (numberp tokens) (> tokens 0) (numberp price) (>= price 0)
         (/ (* tokens price) 1e6))))

(defun harness-ui-cache--cost (state)
  "Return what the context of STATE costs uncached and cached, or nil.
A cons (UNCACHED . CACHED) at the model's list prices: written to the
cache again against read back from it.  Writing costs the higher of the
cache-write and the input price: a provider that does not charge for
writes (DeepSeek, whose catalogue says 0) still charges the input.  Nil
when the catalogue does not price both."
  (let* ((tokens (plist-get state :context))
         (model (plist-get state :model))
         (written (harness-ui-cache--price tokens model :cache-write))
         (input (harness-ui-cache--price tokens model :input))
         (uncached (if (and written input) (max written input) (or written input)))
         (cached (harness-ui-cache--price tokens model :cache-read)))
    (and uncached cached (> uncached cached) (cons uncached cached))))

(defun harness-ui-cache--next (state)
  "Return what sends the context again for STATE, as a sentence's subject."
  (if (plist-get state :blocked) "The next request" "Your next message"))

(defun harness-ui-cache--help (state)
  "Return the tooltip of the cache panel for STATE."
  (concat
   (if-let* ((from (plist-get state :from)))
       (format (concat "A provider caches a conversation for one model only.\n"
                       "This session's requests last used the cache of %s, at %s; %s has none of it.\n")
               (harness-ui-model-label from)
               (format-time-string "%H:%M:%S" (plist-get state :at))
               (harness-ui-model-label (plist-get state :model)))
     (format (concat "The provider keeps the start of a conversation cached for %s after a request uses it.\n"
                     "This session's requests last used the cache at %s, so it lapsed at %s.\n")
             (harness-ui-cache--duration (plist-get state :ttl))
             (format-time-string "%H:%M:%S" (plist-get state :at))
             (format-time-string "%H:%M:%S" (plist-get state :expires))))
   (format "%s sends the whole context, %s tokens, at the uncached rate, and caches it again."
           (harness-ui-cache--next state)
           (harness-format-tokens (plist-get state :context)))))

(defun harness-ui-cache--heading (state now)
  "Return the first line of the cache panel for STATE, drawn at NOW.
It says why nothing is cached: the cache lapsed, and when, or it is
the cache of the model the session used before."
  (let ((from (plist-get state :from)))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-clock)
                             (if from " Prompt cache cold" " Prompt cache expired"))
                     'face 'harness-label-face)
     "  "
     (propertize (if from
                     (format "cached for %s, not %s"
                             (harness-ui-model-label from)
                             (harness-ui-model-label (plist-get state :model)))
                   (format "at %s, %s after its last use"
                           (harness-ui-format-clock (plist-get state :expires) now)
                           (harness-ui-cache--duration (plist-get state :ttl))))
                 'face 'harness-dim-face)
     "\n")))

(defun harness-ui-cache--banner (state now &optional offer)
  "Return the cache panel for STATE, drawn at NOW.
OFFER, when given, is the line offering to compact the conversation
first (`harness-ui-cache--offer'), which goes last."
  (let* ((cost (harness-ui-cache--cost state))
         (tokens (plist-get state :context))
         (string
          (concat
           (harness-ui-cache--heading state now)
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
    (add-text-properties 0 (length string) (list 'help-echo (harness-ui-cache--help state)) string)
    (when offer (setq string (concat string offer)))
    (add-text-properties 0 (length string) (list 'harness-ui-cache-panel t) string)
    (harness-ui-add-face string 'harness-chat-cache-face)))

;;;; Compacting first

(defun harness-ui-cache--estimated (buffer state estimate)
  "Keep ESTIMATE, what compacting costs, for the panel of BUFFER showing STATE.
The tail is drawn again when the panel still shows STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal (car harness-ui-cache--estimate) state)
        (setq harness-ui-cache--estimate (cons state estimate))
        (when (equal state harness-ui-cache--shown)
          (harness-ui-cache--redraw))))))

(defun harness-ui-cache--estimate (state)
  "Return what compacting costs while the panel shows STATE, or nil.
The `compaction/estimate' answer, asked once per STATE; nil while it is
asked, and its answer draws the tail again, or when asking failed."
  (let ((known (and (equal (car harness-ui-cache--estimate) state)
                    (cdr harness-ui-cache--estimate))))
    (cond ((consp known) known)
          (known nil)
          (harness-ui-session-id
           (let ((buffer (current-buffer)))
             (setq harness-ui-cache--estimate (cons state 'pending))
             (harness-ui-call "_harness/compaction/estimate" (list :session-id harness-ui-session-id)
                              (lambda (estimate) (harness-ui-cache--estimated buffer state estimate))
                              (lambda (_err) (harness-ui-cache--estimated buffer state 'failed) nil))
             nil)))))

(defun harness-ui-cache--compact (buffer kind)
  "Compact the session of BUFFER as KIND, from its cache panel.
The panel says so while it runs, and goes once the conversation is
compacted, as nothing of it is cached any more."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless harness-ui-cache--compacting
        (setq harness-ui-cache--compacting kind)
        (harness-ui-cache--redraw)
        (harness-ui-compact-run harness-ui-session-id kind
                                (lambda (_node)
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (setq harness-ui-cache--compacting nil)
                                      (harness-ui-cache--redraw)))))))))

(defun harness-ui-cache--command (buffer kind)
  "Return the command compacting the session of BUFFER as KIND."
  (lambda () (interactive) (harness-ui-cache--compact buffer kind)))

(defun harness-ui-cache--offer-help (estimate kind)
  "Return the tooltip of the button compacting as KIND, as ESTIMATE says.
ESTIMATE is nil while it is asked."
  (let ((entry (assq kind harness-ui-compact-kinds))
        (cost (harness-ui-compact-cost-text estimate kind)))
    (concat (harness-ui-compact-label kind) (if cost (format " (%s)" cost) "") ": "
            (if estimate
                (harness-ui-compact-describe estimate kind)
              (concat (nth 3 entry) "."))
            (format "\nPress %c on this line, or click, to compact the conversation this way."
                    (nth 1 entry)))))

(defun harness-ui-cache--offer (state)
  "Return the line of the cache panel for STATE that offers to compact, or nil.
A button for each kind of compaction (`harness-ui-compact-kinds') says
what it costs as the harness estimates it; while it is asked, or
without a price, the buttons only name the kinds.  While a compaction
the panel started runs, the line says so instead.  A session blocked on
an answer is running a turn, which no compaction interrupts: nil."
  (cond
   ((plist-get state :blocked) nil)
   (harness-ui-cache--compacting
    (propertize (format "   Compacting the conversation into a %s…\n"
                        (nth 2 (assq harness-ui-cache--compacting harness-ui-compact-kinds)))
                'face 'harness-dim-face))
   (t
    (let* ((buffer (current-buffer))
           (estimate (harness-ui-cache--estimate state))
           (map (make-sparse-keymap))
           (line
            (concat
             (propertize "   Compact it first" 'face 'harness-label-face)
             (mapconcat
              (lambda (entry)
                (pcase-let* ((`(,kind ,key . ,_) entry)
                             (cost (harness-ui-compact-cost-text estimate kind)))
                  (define-key map (char-to-string key) (harness-ui-cache--command buffer kind))
                  (concat "  " (harness-chat--kbd (format " %c " key)) " "
                          (harness-chat--button (harness-ui-compact-label kind)
                                                (harness-ui-cache--command buffer kind)
                                                :help (harness-ui-cache--offer-help estimate kind))
                          (if cost (propertize (format " (%s)" cost) 'face 'harness-dim-face) ""))))
              harness-ui-compact-kinds "")
             "\n")))
      (add-text-properties 0 (length line) (list 'wrap-prefix "   ") line)
      (harness-ui-with-keymap line map)))))

;;;; Showing it on time

(defun harness-ui-cache--cancel ()
  "Stop this buffer's cache timer, if any."
  (when (timerp harness-ui-cache--timer)
    (cancel-timer harness-ui-cache--timer))
  (setq harness-ui-cache--timer nil
        harness-ui-cache--due nil))

(defun harness-ui-cache--schedule (session)
  "Set this buffer's timer for the moment SESSION's cache lapses.
Nothing is set when it has lapsed already, SESSION has no cache, or
it is another model's, which is cold already; a timer already set for
that moment stays."
  (let* ((expires (plist-get (plist-get session :cache) :expires))
         (due (and (numberp expires) (> expires (float-time))
                   (not (harness-ui-cache--other-model session))
                   expires)))
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
    (unless (equal (harness-ui-cache--current session) harness-ui-cache--shown)
      (harness-ui-cache--redraw))))

(defun harness-ui-cache--lapse (buffer)
  "Draw BUFFER's tail again, its session's cache having lapsed by now.
The cache panel shows from now on, or, while the switch banner asks
instead, the banner says the cache expired; drawing sets the next
timer, if any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-cache--timer nil
            harness-ui-cache--due nil)
      (harness-ui-cache--redraw))))

(defun harness-ui-cache--panel ()
  "Return the cache panel when this session's prompt cache is cold, else nil.
On `harness-chat-panel-functions'.  Drawing sets the timer for when
the cache lapses too, so a buffer that just opened shows it on time."
  (let* ((session (harness-ui-cache--session))
         (now (float-time))
         (state (harness-ui-cache--current session now)))
    (setq harness-ui-cache--shown state)
    (harness-ui-cache--schedule session)
    (and state (harness-ui-cache--banner state now (harness-ui-cache--offer state)))))

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
  :doc "Warns above a session's compose box once its prompt cache has expired, offering to compact."
  :requires '(ui ui-chat)
  :init #'harness-ui-cache--init)

(provide 'harness-ui-cache)
;;; harness-ui-cache.el ends here
