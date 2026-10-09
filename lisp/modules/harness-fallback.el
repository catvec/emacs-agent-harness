;;; harness-fallback.el --- Carry on with another provider when one runs out  -*- lexical-binding: t; -*-

;;; Commentary:

;; A subscription's quota runs out (Claude Max's 5-hour and weekly
;; windows, Copilot's monthly allowance), and so does money (a prepaid
;; DeepSeek balance, OpenAI credit).  Without this module a session
;; whose provider ran out stops, and so does every task on that
;; provider.  With it, `harness-fallback-models' says where to go
;; instead, in order of preference, and the harness goes there on its
;; own: the turn that failed carries on with another provider's model
;; of similar ability, or with a model named outright.
;;
;; What ran out is kept as a mark: a whole provider, or one model when
;; only a window scoped to that model is used up.  A mark lasts until
;; the limit resets, when the provider said when, else for an hour,
;; after which the provider is tried again.  Marks come from failed
;; steps (`agent/step-error': the provider's `:error-kind', else the
;; error's text) and from the providers' quota reports (a plan window
;; used up, unless extra usage pays for calls).
;;
;; A session's own model always comes first.  When it is out, the
;; first entry of the list that is not wins, and the session remembers
;; its own model: once that works again, its next turn goes back to it.
;; The switch happens before a turn (`agent/before-turn', ahead of
;; compaction, which must judge the new model's window) and after a
;; failed step, which then runs again.  A session handed to a provider
;; that runs its own loop is caught up by the agent (see
;; `harness-agent--handoff').
;;
;; Nothing here blocks or calls a model: it decides from what the
;; providers already said.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-fallback-models nil
  "Providers and models to carry on with when one runs out, most preferred first.
When a session's provider runs out of quota (a plan's usage limit, such
as Claude Max's 5-hour or weekly window) or of money (a prepaid balance
or credit spent), the session moves to the first entry here that has
not run out, and the turn that failed carries on there.  Tasks keep
going the same way, until every entry has run out.

An entry is a provider id, such as \"deepseek\", standing for that
provider's model of similar ability to the session's (its cheap,
balanced or frontier model), or a model id, PROVIDER:MODEL, used as it
is: (\"claude\" \"deepseek:deepseek-flash\") uses Claude Code first and
DeepSeek-V4.1-Flash once Claude's quota is used up.

A session's own model still comes first: a session moved here goes
back to it once its provider works again (when its limit resets, or an
hour on when the provider did not say).  nil leaves sessions on their
provider, which then stop.  The usage dashboard (\\[harness-usage])
shows and edits this list beside the plans' quota."
  :type '(repeat (string :tag "Provider or model id" :names (provider model)))
  :group 'harness)

(defconst harness-fallback--retry-after 3600
  "Seconds a provider counts as out when it did not say when it comes back.
Money spent has no reset time, and a usage limit sometimes comes
without one; the provider is tried again after this, as a person
topping up an account or a plan resetting early would want.")

(defconst harness-fallback--store "fallback.json"
  "Store name of the marks and of the sessions the fallback moved.")

(defconst harness-fallback--billing-patterns
  '("insufficient[ _-]balance" "insufficient[ _-]credits?" "insufficient[ _-]funds"
    "insufficient_quota" "credit balance is too low" "out of credits?"
    "no \\(?:ai \\)?credits\\(?: left\\)?" "payment required"
    "\\(?:http\\|api error:?\\|status\\|code\\)[ :]*402\\b" "check your plan and billing"
    "billing_error" "account is on hold" "account_on_hold" "key limit exceeded"
    "spend\\(?:ing\\)? limit \\(?:reached\\|exceeded\\)")
  "Regexps, matched against an error's text in lower case, of running out of money.")

(defconst harness-fallback--quota-patterns
  '("usage limit" "hit your limit" "reached your limit"
    "\\(?:5-hour\\|five-hour\\|weekly\\|daily\\|monthly\\|session\\|opus\\|sonnet\\|fable\\) limit \\(?:reached\\|exceeded\\)"
    "quota exceeded" "exceeded your \\(?:current \\)?quota" "out of quota" "quota is exhausted"
    "out of extra usage" "premium request" "allowance" "tokens per day" "requests per day")
  "Regexps, matched against an error's text in lower case, of a used-up quota.
A short-term rate limit is not one: the provider works again in a moment.")

;;;; State

(defvar harness-fallback--marks (make-hash-table :test 'equal)
  "Key -> MARK: the providers and models that ran out.
A key is a provider id (\"deepseek\") for the whole provider, or a model
id for one model.  MARK is (:key :provider :model :kind quota|billing
:reason TEXT :since FLOAT :until FLOAT :guess BOOL :source error|quota);
`:guess' says `:until' is a retry time, not a reset the provider gave.")

(defvar harness-fallback--moved (make-hash-table :test 'equal)
  "Session id -> (:original MODEL :since FLOAT) for sessions moved off their model.")

(defvar harness-fallback--quotas (make-hash-table :test 'equal)
  "Provider id (a string) -> the last quota it reported.")

(defvar harness-fallback--notified (make-hash-table :test 'equal)
  "What was already notified: a mark's key and since, or the set of marks out.")

(defvar harness-fallback--timer nil
  "Timer that ends the next mark to expire.")

(defvar harness-fallback--switching nil
  "Non-nil while this module changes a session's model.")

;;;; Small helpers

(defun harness-fallback--sym (value)
  "Return VALUE as a symbol: strings are interned, nil stays nil."
  (cond ((null value) nil) ((stringp value) (intern value)) (t value)))

(defun harness-fallback--provider-of (id)
  "Return the provider id of ID, a model id or a provider id, as a string."
  (cond ((null id) nil)
        ((symbolp id) (symbol-name id))
        ((string-match "\\`\\([^:]+\\):" id) (match-string 1 id))
        (t id)))

(defun harness-fallback--model-p (id)
  "Non-nil when ID is a model id (PROVIDER:MODEL) rather than a provider id."
  (and (stringp id) (string-match-p ":" id)))

(defun harness-fallback--clock (time)
  "Describe TIME, a float time, the way a reset time reads: 19:00, or a date."
  (if (< (- time (float-time)) 72000)
      (format-time-string "%H:%M" time)
    (format-time-string "%a %b %-d, %H:%M" time)))

(defun harness-fallback--registered ()
  "Return the ids of the registered providers, as strings."
  (and (harness-method-exists-p 'provider/list)
       (mapcar (lambda (p) (format "%s" (plist-get p :id)))
               (ignore-errors (harness-call 'provider/list)))))

(defun harness-fallback--provider-label (pid)
  "Return the display name of provider PID."
  (or (and (harness-method-exists-p 'provider/list)
           (plist-get (cl-find pid (ignore-errors (harness-call 'provider/list))
                               :key (lambda (p) (format "%s" (plist-get p :id))) :test #'equal)
                      :label))
      (capitalize (or pid "?"))))

(defun harness-fallback--model-info (model)
  "Return the catalogue plist of MODEL, or nil."
  (and model (harness-method-exists-p 'provider/model)
       (ignore-errors (harness-call 'provider/model model))))

(defun harness-fallback--model-label (model)
  "Return MODEL as people read it: \"DeepSeek-V4-Pro (DeepSeek)\"."
  (let* ((info (harness-fallback--model-info model))
         (label (or (plist-get info :label) model))
         (provider (or (plist-get info :provider-label)
                       (harness-fallback--provider-label (harness-fallback--provider-of model)))))
    (if (or (null provider) (string-match-p (regexp-quote provider) label))
        label
      (format "%s (%s)" label provider))))

(defun harness-fallback--provider-models (pid)
  "Return the catalogue plists of provider PID's models, as far as it listed them."
  (and (harness-method-exists-p 'provider/cached-models)
       (ignore-errors (harness-call 'provider/cached-models pid))))

(defun harness-fallback--model-known-p (model)
  "Non-nil unless MODEL's provider listed its models without MODEL.
A provider that listed nothing yet is given the benefit of the doubt."
  (let ((models (harness-fallback--provider-models (harness-fallback--provider-of model))))
    (or (null models)
        (cl-find model models :key (lambda (m) (plist-get m :id)) :test #'equal))))

;;;; Telling a failure apart

(defun harness-fallback--matches-p (patterns text)
  "Non-nil when one of PATTERNS matches TEXT."
  (cl-some (lambda (re) (string-match-p re text)) patterns))

(defun harness-fallback-error-kind (failure)
  "Return `quota' or `billing' when FAILURE says its provider ran out, else nil.
FAILURE is the plist `agent/step-error' passes: the `done' event's keys.
A provider that knows says so in `:error-kind', which decides: `quota'
or `billing', or anything else, which is not running out (a rate
limit, a login).  Without it the error's text is read: a 402, an
insufficient balance or credit, a used-up quota or usage limit."
  (let ((kind (harness-fallback--sym (plist-get failure :error-kind))))
    (cond
     ((memq kind '(quota billing)) kind)
     (kind nil)
     (t (let ((text (downcase (format "%s" (or (plist-get failure :error) "")))))
          (cond ((harness-fallback--matches-p harness-fallback--billing-patterns text) 'billing)
                ((harness-fallback--matches-p harness-fallback--quota-patterns text) 'quota)))))))

;;;; Quota reports

(defun harness-fallback--extra-pays-p (quota)
  "Non-nil when QUOTA says the plan's extra usage pays for calls past its limits."
  (let* ((extra (plist-get quota :extra))
         (used (plist-get extra :used))
         (limit (plist-get extra :limit)))
    (or (harness-json-true-p (plist-get quota :using-extra))
        (and (harness-json-true-p (plist-get extra :enabled))
             (or (not (numberp limit)) (not (numberp used)) (< used limit))))))

(defun harness-fallback--full-windows (quota &optional now)
  "Return the windows of QUOTA used up and resetting after NOW."
  (let ((now (or now (float-time))))
    (cl-remove-if-not (lambda (w)
                        (and (numberp (plist-get w :used)) (>= (plist-get w :used) 1.0)
                             (numberp (plist-get w :resets)) (> (plist-get w :resets) now)))
                      (plist-get quota :windows))))

(defun harness-fallback--window-models (pid window)
  "Return the ids of provider PID's models the scoped WINDOW limits."
  (let ((name (downcase (format "%s" (plist-get window :model)))))
    (delq nil (mapcar (lambda (m)
                        (let ((id (plist-get m :id)))
                          (and (string-match-p (regexp-quote name)
                                               (downcase (format "%s %s" id (or (plist-get m :label) ""))))
                               id)))
                      (harness-fallback--provider-models pid)))))

(defun harness-fallback--quota-out (pid quota &optional now)
  "Return what provider PID's QUOTA says is out at NOW, as ((KEY . PROPS) ...).
A plan window used up (used >= 1, resetting later) puts the whole
provider out until the last of them resets; one scoped to a model puts
that model's ids out.  Nothing is out while extra usage pays for calls."
  (unless (harness-fallback--extra-pays-p quota)
    (let* ((full (harness-fallback--full-windows quota now))
           (plan (cl-remove-if (lambda (w) (plist-get w :model)) full))
           (scoped (cl-remove-if-not (lambda (w) (plist-get w :model)) full)))
      (if plan
          (list (cons pid (list :until (apply #'max (mapcar (lambda (w) (plist-get w :resets)) plan))
                                :reason (format "%s is used up"
                                                (or (plist-get (car plan) :label) (plist-get (car plan) :name))))))
        (cl-loop for w in scoped
                 append (mapcar (lambda (model)
                                  (cons model (list :until (plist-get w :resets)
                                                    :reason (format "%s is used up"
                                                                    (or (plist-get w :label) (plist-get w :name))))))
                                (harness-fallback--window-models pid w)))))))

(defun harness-fallback--quota-reset (model)
  "Return when the quota MODEL ran out of resets, or nil.
The time comes from its provider's last report."
  (let* ((pid (harness-fallback--provider-of model))
         (out (harness-fallback--quota-out pid (gethash pid harness-fallback--quotas))))
    (plist-get (cdr (or (assoc model out) (assoc pid out))) :until)))

(defun harness-fallback--quota-scope (model)
  "Return the key a quota failure of MODEL marks.
That is MODEL when its provider's last report has a used-up window
scoped to MODEL and no plan-wide one; otherwise the whole provider."
  (let* ((pid (harness-fallback--provider-of model))
         (out (harness-fallback--quota-out pid (gethash pid harness-fallback--quotas))))
    (if (and (assoc model out) (not (assoc pid out))) model pid)))

;;;; Marks

(defun harness-fallback--live-p (mark &optional now)
  "Non-nil while MARK has not expired at NOW."
  (> (or (plist-get mark :until) 0) (or now (float-time))))

(defun harness-fallback--prune (&optional now)
  "Drop the marks expired at NOW; return non-nil when any went."
  (let (gone)
    (maphash (lambda (k m) (unless (harness-fallback--live-p m now) (push k gone))) harness-fallback--marks)
    (dolist (k gone) (remhash k harness-fallback--marks))
    gone))

(defun harness-fallback--marks ()
  "Return the live marks, the earliest to end first."
  (harness-fallback--prune)
  (let (out)
    (maphash (lambda (_ m) (push m out)) harness-fallback--marks)
    (sort out (lambda (a b) (< (plist-get a :until) (plist-get b :until))))))

(defun harness-fallback-mark-of (model)
  "Return the live mark that puts MODEL out: its provider's, else its own, or nil."
  (let ((now (float-time)))
    (cl-find-if (lambda (m) (and m (harness-fallback--live-p m now)))
                (list (gethash (harness-fallback--provider-of model) harness-fallback--marks)
                      (gethash model harness-fallback--marks)))))

(defun harness-fallback-out-p (model)
  "Non-nil when MODEL, or its whole provider, has run out."
  (and (harness-fallback-mark-of model) t))

(defun harness-fallback--changed ()
  "Save the state, time the next expiry and announce the change."
  (harness-fallback--save)
  (harness-fallback--schedule)
  (harness-emit 'fallback/changed))

(cl-defun harness-fallback--put (key &key kind reason until guess source model)
  "Mark KEY out of KIND until UNTIL; return the mark.
A mark that is live already keeps its `:since' and is only extended.
REASON is the text saying why, and GUESS non-nil says UNTIL is a retry
time rather than a reset the provider gave.  SOURCE is what made the
mark, error or quota, and MODEL, when KEY is a provider, the model
whose failure put it out."
  (let* ((now (float-time))
         (old (gethash key harness-fallback--marks))
         (old (and old (harness-fallback--live-p old now) old))
         (mark (list :key key
                     :provider (harness-fallback--provider-of key)
                     :model (or (and (harness-fallback--model-p key) key) model)
                     :kind kind
                     :reason reason
                     :since (or (plist-get old :since) now)
                     :until (max until (if (and old (eq (plist-get old :kind) kind)) (plist-get old :until) 0))
                     :guess (and guess t)
                     :source source)))
    (puthash key mark harness-fallback--marks)
    mark))

(defun harness-fallback--record-failure (model kind failure)
  "Mark what MODEL's failure of KIND puts out; return the mark.
Money spent puts the whole provider out; a quota the provider's report
scopes to MODEL puts MODEL out.  The mark lasts until the reset
FAILURE or the report gives, else `harness-fallback--retry-after'."
  (let* ((now (float-time))
         (resets (let ((r (plist-get failure :resets))) (and (numberp r) (> r now) (float r))))
         (key (if (eq kind 'quota) (harness-fallback--quota-scope model) (harness-fallback--provider-of model)))
         (known (or resets (and (eq kind 'quota) (harness-fallback--quota-reset model))))
         (mark (harness-fallback--put key :kind kind
                                      :reason (harness-first-line (format "%s" (or (plist-get failure :error) "")) 200)
                                      :until (or known (+ now harness-fallback--retry-after))
                                      :guess (not known) :source 'error :model model)))
    (harness-log 'info "fallback: %s is out of %s until %s (%s)" key kind
                 (format-time-string "%F %T" (plist-get mark :until)) (plist-get mark :reason))
    (harness-fallback--changed)
    mark))

(defun harness-fallback--apply-quota (pid quota)
  "Bring provider PID's quota marks in line with its report QUOTA.
Marks taken from reports follow them; a mark a failure made stays,
unless extra usage now pays for calls.  A failure's whole-provider mark
narrows to the models a report scopes the used-up window to."
  (let* ((out (harness-fallback--quota-out pid quota))
         (pays (harness-fallback--extra-pays-p quota))
         (changed nil))
    (maphash
     (lambda (key mark)
       (when (and (equal (plist-get mark :provider) pid) (eq (plist-get mark :kind) 'quota)
                  (or (eq (plist-get mark :source) 'quota) pays)
                  (not (assoc key out)))
         (remhash key harness-fallback--marks)
         (setq changed t)))
     harness-fallback--marks)
    ;; A failure took the whole provider out, but the report says one window,
    ;; scoped to some models, is the only one used up.
    (let ((whole (gethash pid harness-fallback--marks)))
      (when (and whole (eq (plist-get whole :source) 'error) (eq (plist-get whole :kind) 'quota)
                 out (not (assoc pid out)))
        (remhash pid harness-fallback--marks)
        (setq changed t)))
    (dolist (cell out)
      (let ((old (gethash (car cell) harness-fallback--marks)))
        (unless (and old (harness-fallback--live-p old)
                     (equal (plist-get old :until) (plist-get (cdr cell) :until)))
          (harness-fallback--put (car cell) :kind 'quota :reason (plist-get (cdr cell) :reason)
                                 :until (plist-get (cdr cell) :until)
                                 :source (if (and old (eq (plist-get old :source) 'error)) 'error 'quota))
          (setq changed t))))
    (when changed (harness-fallback--changed))))

(defun harness-fallback--on-quota-updated (provider quota)
  "Note PROVIDER's QUOTA report and mark what it says is out."
  (let ((pid (harness-fallback--provider-of provider)))
    (puthash pid quota harness-fallback--quotas)
    (condition-case err
        (harness-fallback--apply-quota pid quota)
      (error (harness-log 'warn "fallback: reading the quota of %s: %S" pid err)))))

(defun harness-fallback--schedule ()
  "Time the end of the next mark to expire."
  (when (timerp harness-fallback--timer) (cancel-timer harness-fallback--timer))
  (setq harness-fallback--timer nil)
  (when-let* ((next (car (harness-fallback--marks))))
    (setq harness-fallback--timer
          (run-at-time (max 1 (- (plist-get next :until) (float-time) -1)) nil #'harness-fallback--expire))))

(defun harness-fallback--expire ()
  "End the marks whose time is up and announce it."
  (setq harness-fallback--timer nil)
  (when (harness-fallback--prune)
    (harness-fallback--save)
    (harness-emit 'fallback/changed))
  (harness-fallback--schedule))

;;;; Persistence

(defun harness-fallback--save ()
  "Write the live marks and the moved sessions to the store."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (harness-call 'store/save harness-fallback--store
                      (list :marks (harness-json-array
                                    (mapcar (lambda (m)
                                              (append (harness-plist-remove m :guess)
                                                      (list :guess (if (plist-get m :guess) t :false))))
                                            (harness-fallback--marks)))
                            :moved (harness-json-array
                                    (let (out)
                                      (maphash (lambda (sid r) (push (append (list :session sid) r) out))
                                               harness-fallback--moved)
                                      out))))
      (error (harness-log 'warn "fallback: saving failed: %S" err)))))

(defun harness-fallback--load ()
  "Read the marks and the moved sessions back from the store."
  (let ((data (and (harness-method-exists-p 'store/load)
                   (ignore-errors (harness-call 'store/load harness-fallback--store))))
        (now (float-time)))
    (when (listp data)
      (dolist (m (plist-get data :marks))
        (when (and (listp m) (stringp (plist-get m :key)) (numberp (plist-get m :until))
                   (> (plist-get m :until) now))
          (puthash (plist-get m :key)
                   (append (harness-plist-remove m :kind :source :guess)
                           (list :kind (harness-fallback--sym (plist-get m :kind))
                                 :source (harness-fallback--sym (plist-get m :source))
                                 :guess (harness-json-true-p (plist-get m :guess))))
                   harness-fallback--marks)))
      (dolist (r (plist-get data :moved))
        (let ((sid (plist-get r :session)))
          (when (and (stringp sid) (stringp (plist-get r :original))
                     (or (not (harness-method-exists-p 'session/exists-p))
                         (harness-call 'session/exists-p sid)))
            (puthash sid (harness-plist-remove r :session) harness-fallback--moved)))))))

;;;; Choosing a model

(defun harness-fallback--entry-model (entry own)
  "Return the model ENTRY of `harness-fallback-models' stands for, for OWN.
A model id is itself; a provider id is that provider's model in the
tier OWN is in at its own provider; nil when there is none."
  (cond
   ((not (and (stringp entry) (not (string-blank-p entry)))) nil)
   ((harness-fallback--model-p entry) (string-trim entry))
   ((harness-method-exists-p 'provider/tier-model)
    (ignore-errors
      (harness-call 'provider/tier-model (string-trim entry)
                    (if (harness-method-exists-p 'provider/model-tier)
                        (harness-call 'provider/model-tier own)
                      'balanced))))))

(defun harness-fallback-choose (session)
  "Return the model SESSION should run on now, as (:model ID :back BOOL :entry E).
Its own model -- the one it had before the fallback moved it, else its
model -- unless that is out: then the model of the first entry of
`harness-fallback-models' that is not out, whose provider is registered
and which its provider's catalogue does not deny.  `:back' is non-nil
when that is its own model again.  Nil when everything is out."
  (let* ((sid (plist-get session :id))
         (current (plist-get session :model))
         (own (or (plist-get (gethash sid harness-fallback--moved) :original) current)))
    (if (not (harness-fallback-out-p own))
        (list :model own :back (not (equal own current)))
      (let ((registered (harness-fallback--registered)))
        (cl-loop for entry in harness-fallback-models
                 for model = (harness-fallback--entry-model entry own)
                 when (and model
                           (member (harness-fallback--provider-of model) registered)
                           (not (harness-fallback-out-p model))
                           (harness-fallback--model-known-p model))
                 return (list :model model :entry entry))))))

;;;; Switching

(defun harness-fallback--out-text (mark)
  "Say what MARK puts out: \"Claude Code is out of quota until 19:00\"."
  (let* ((key (plist-get mark :key))
         (who (if (harness-fallback--model-p key)
                  (harness-fallback--model-label key)
                (harness-fallback--provider-label key))))
    (concat who
            (if (eq (plist-get mark :kind) 'billing) " is out of money" " is out of quota")
            (if (plist-get mark :guess) ""
              (format " until %s" (harness-fallback--clock (plist-get mark :until)))))))

(defun harness-fallback--switch (session target why &optional mark)
  "Move SESSION to model TARGET; WHY is `out' (MARK put it out) or `back'.
The change is the session's own setting, made silently, with a hint of
this module's saying why; `fallback/switched' announces it.  The
session's own model is remembered while it runs on another."
  (let* ((sid (plist-get session :id))
         (from (plist-get session :model))
         (record (gethash sid harness-fallback--moved))
         (original (or (plist-get record :original) from)))
    (unless (equal from target)
      (if (equal target original)
          (remhash sid harness-fallback--moved)
        (unless record (puthash sid (list :original from :since (float-time)) harness-fallback--moved)))
      (let ((harness-fallback--switching t))
        (harness-call 'session/update sid :model target :silent t))
      (harness-call 'session/hint sid
                    (if (eq why 'back)
                        (format "%s works again, so this session goes back to %s."
                                (harness-fallback--provider-label (harness-fallback--provider-of target))
                                (harness-fallback--model-label target))
                      (format "%s, so this session carries on with %s."
                              (if mark (harness-fallback--out-text mark)
                                (format "%s is out" (harness-fallback--model-label from)))
                              (harness-fallback--model-label target))))
      (harness-log 'info "fallback: %s %s → %s (%s)" sid from target why)
      (harness-emit 'fallback/switched sid from target why)
      (when (and mark (eq why 'out)) (harness-fallback--notify-switch session mark target))
      (harness-fallback--changed))))

(defun harness-fallback--notify (key title body urgency session)
  "Send the notification TITLE BODY at URGENCY about SESSION, once per KEY."
  (unless (gethash key harness-fallback--notified)
    (puthash key t harness-fallback--notified)
    (when (harness-method-exists-p 'notification/send)
      (harness-catch (harness-call-async 'notification/send
                                         (list :title title :body body :urgency urgency
                                               :source "fallback" :kind "fallback"
                                               :session (plist-get session :id)
                                               :project (plist-get session :project)))
                     (lambda (e) (harness-log 'warn "fallback: notifying failed: %s" (harness-error-message e)))))))

(defun harness-fallback--notify-switch (session mark target)
  "Tell the user once that MARK put a provider out and sessions go to TARGET.
The notification is about SESSION, the first of them to move."
  (harness-fallback--notify (format "%s/%s" (plist-get mark :key) (plist-get mark :since))
                            (harness-fallback--out-text mark)
                            (format "Sessions carry on with %s." (harness-fallback--model-label target))
                            'low session))

(defun harness-fallback--nothing-left (session mark)
  "Tell SESSION that nothing is left to carry on with, MARK being what failed.
With a fallback list the hint names everything that is out, and the
user is notified once per set of marks; without one, it says where the
list is set."
  (let ((sid (plist-get session :id)))
    (if (null harness-fallback-models)
        (harness-call 'session/hint sid
                      (format "%s.  To carry on with another provider when this happens, add one under Fallback in the usage dashboard (M-x harness-usage)."
                              (harness-fallback--out-text mark)))
      (let* ((marks (harness-fallback--marks))
             (text (mapconcat #'harness-fallback--out-text marks "; ")))
        (harness-call 'session/hint sid
                      (format "Nothing left to carry on with: %s.  This turn stops here; sessions go on once one of them works again (Fallback, in the usage dashboard)."
                              text))
        (harness-fallback--notify (concat "all/" (mapconcat (lambda (m) (format "%s@%s" (plist-get m :key)
                                                                                 (plist-get m :since)))
                                                           marks ","))
                                  "Every provider has run out"
                                  (concat text ".  Sessions and tasks stop until one works again.")
                                  'normal session)))))

;;;; Hooks

(defun harness-fallback--before-turn (value next session)
  "`agent/before-turn' handler: move SESSION to the model it should run on.
VALUE and NEXT are the filter's.  A model that is out gives way to the
first of `harness-fallback-models' that is not, and a session moved
earlier goes back to its own model once that works again."
  (when (plist-get value :proceed)
    (condition-case err
        (let ((choice (harness-fallback-choose session)))
          (when (and choice (not (equal (plist-get choice :model) (plist-get session :model))))
            (harness-fallback--switch session (plist-get choice :model)
                                      (if (plist-get choice :back) 'back 'out)
                                      (harness-fallback-mark-of (plist-get session :model)))))
      (error (harness-log 'warn "fallback: before the turn of %s: %S" (plist-get session :id) err))))
  (funcall next value)
  nil)

(defun harness-fallback--step-error (value next session failure)
  "`agent/step-error' handler: when FAILURE ran out of quota or money, move on.
VALUE and NEXT are the filter's, SESSION the session as it failed.  The
provider or model is marked; when another model can carry on, SESSION
moves there and the step is retried."
  (let ((decision value))
    (unless (plist-get value :retry)
      (condition-case err
          (when-let* ((kind (harness-fallback-error-kind failure)))
            (let* ((model (or (plist-get failure :model) (plist-get session :model)))
                   (mark (harness-fallback--record-failure model kind failure))
                   (choice (harness-fallback-choose session)))
              (if (and choice (not (equal (plist-get choice :model) (plist-get session :model))))
                  (progn
                    (harness-fallback--switch session (plist-get choice :model)
                                              (if (plist-get choice :back) 'back 'out) mark)
                    (setq decision (list :retry t :reason (harness-fallback--out-text mark))))
                (harness-fallback--nothing-left session mark))))
        (error (harness-log 'warn "fallback: after the failure of %s: %S" (plist-get session :id) err))))
    (funcall next decision))
  nil)

(defun harness-fallback--on-session-updated (id changes)
  "Forget session ID's own model when CHANGES set its model from elsewhere."
  (when (and (plist-member changes :model) (not harness-fallback--switching)
             (gethash id harness-fallback--moved))
    (remhash id harness-fallback--moved)
    (harness-fallback--changed)))

(defun harness-fallback--on-session-deleted (id &rest _)
  "Forget deleted session ID."
  (when (gethash id harness-fallback--moved)
    (remhash id harness-fallback--moved)
    (harness-fallback--changed)))

(defun harness-fallback--on-session-forked (parent child)
  "Let fork CHILD go back to PARENT's own model as PARENT would."
  (when-let* ((record (gethash parent harness-fallback--moved)))
    (when (and (harness-call 'session/exists-p child) (harness-call 'session/exists-p parent)
               (equal (plist-get (harness-call 'session/get child) :model)
                      (plist-get (harness-call 'session/get parent) :model)))
      (puthash child (copy-sequence record) harness-fallback--moved)
      (harness-fallback--changed))))

;;;; Methods

(defun harness-fallback--describe-mark (mark)
  "Return MARK for the wire."
  (list :key (plist-get mark :key) :provider (plist-get mark :provider) :model (plist-get mark :model)
        :kind (plist-get mark :kind) :reason (plist-get mark :reason)
        :since (plist-get mark :since) :until (plist-get mark :until)
        :guess (if (plist-get mark :guess) t :false) :source (plist-get mark :source)
        :label (if (harness-fallback--model-p (plist-get mark :key))
                   (harness-fallback--model-label (plist-get mark :key))
                 (harness-fallback--provider-label (plist-get mark :key)))))

(defun harness-fallback--describe-entry (entry registered)
  "Describe ENTRY of `harness-fallback-models'; REGISTERED lists the providers."
  (let* ((pid (harness-fallback--provider-of entry))
         (model (and (harness-fallback--model-p entry) entry))
         (info (and model (harness-fallback--model-info model)))
         (mark (if model (harness-fallback-mark-of model)
                 (let ((m (gethash pid harness-fallback--marks))) (and m (harness-fallback--live-p m) m)))))
    (append
     (list :entry entry :provider pid :model model
           :label (if model (or (plist-get info :label) model) (harness-fallback--provider-label pid))
           :provider-label (harness-fallback--provider-label pid)
           :registered (if (member pid registered) t :false)
           :known (if (or (null model) (harness-fallback--model-known-p model)) t :false)
           :mark (and mark (harness-fallback--describe-mark mark)))
     (unless model
       (list :tiers (delq nil (mapcar (lambda (tier)
                                        (when-let* ((m (and (member pid registered)
                                                            (harness-method-exists-p 'provider/tier-model)
                                                            (ignore-errors (harness-call 'provider/tier-model pid tier)))))
                                          (list :tier (symbol-name tier) :model m
                                                :label (plist-get (harness-fallback--model-info m) :label)
                                                :out (if (harness-fallback-out-p m) t :false))))
                                      '(cheap balanced frontier))))))))

(harness-defmethod fallback/status ()
  "Return the fallback list and what is out, for a dashboard.
\(:enabled BOOL :models (ENTRY ...) :marks (MARK ...) :moved ((:session
SID :original MODEL :model MODEL) ...)).  ENTRY is (:entry STRING
:provider ID :model MODEL-OR-NIL :label :provider-label :registered
BOOL :known BOOL :mark MARK-OR-NIL :tiers ((:tier :model :label :out)
...)), `:tiers' for a provider entry: the model each tier maps to.
MARK is (:key :provider :model :kind :reason :since :until :guess
:source :label), `:guess' non-nil when `:until' is a retry time rather
than a reset the provider gave."
  (let ((registered (harness-fallback--registered)))
    (list :enabled (if harness-fallback-models t :false)
          :models (mapcar (lambda (e) (harness-fallback--describe-entry e registered)) harness-fallback-models)
          :marks (mapcar #'harness-fallback--describe-mark (harness-fallback--marks))
          :moved (let (out)
                   (maphash (lambda (sid r)
                              (when (harness-call 'session/exists-p sid)
                                (push (list :session sid :original (plist-get r :original)
                                            :model (plist-get (harness-call 'session/get sid) :model))
                                      out)))
                            harness-fallback--moved)
                   out))))

(harness-defmethod fallback/clear (key)
  "Forget the mark KEY, so its provider or model is tried again.
KEY is a provider id, which also forgets its models' marks, or a model
id.  Return non-nil when a mark went."
  (let ((key (harness-fallback--provider-of-key key)) gone)
    (maphash (lambda (k m)
               (when (or (equal k key)
                         (and (not (harness-fallback--model-p key)) (equal (plist-get m :provider) key)))
                 (push k gone)))
             harness-fallback--marks)
    (dolist (k gone) (remhash k harness-fallback--marks))
    (when gone (harness-fallback--changed))
    (and gone t)))

(defun harness-fallback--provider-of-key (key)
  "Return KEY, a provider or model id given as a symbol or a string, as a string."
  (if (symbolp key) (symbol-name key) key))

(harness-defmethod fallback/mark (key &rest props)
  "Mark KEY, a provider or model id, as out; return the mark.
PROPS: `:kind' quota (default) or billing, `:until' a float time (by
default an hour on), `:reason' a text."
  (let* ((now (float-time))
         (until (plist-get props :until))
         (mark (harness-fallback--put (harness-fallback--provider-of-key key)
                                      :kind (or (harness-fallback--sym (plist-get props :kind)) 'quota)
                                      :reason (or (plist-get props :reason) "marked by hand")
                                      :until (if (numberp until) (float until) (+ now harness-fallback--retry-after))
                                      :guess (not (numberp until)) :source 'error)))
    (harness-fallback--changed)
    (harness-fallback--describe-mark mark)))

(harness-defmethod fallback/choose (session-id)
  "Return the model session SESSION-ID would run on now.
See `harness-fallback-choose'."
  (harness-fallback-choose (harness-call 'session/get session-id)))

;;;; Module

(defun harness-fallback--init ()
  "Load what ran out and hook into turns, failures and quota reports."
  (harness-fallback--load)
  (harness-on 'provider/quota-updated #'harness-fallback--on-quota-updated)
  (harness-on 'session/updated #'harness-fallback--on-session-updated)
  (harness-on 'session/deleted #'harness-fallback--on-session-deleted)
  (harness-on 'session/forked #'harness-fallback--on-session-forked)
  (harness-add-filter 'agent/before-turn #'harness-fallback--before-turn 10)
  (harness-add-filter 'agent/step-error #'harness-fallback--step-error 50)
  (harness-fallback--schedule))

(defun harness-fallback--shutdown ()
  "Save, and stop the expiry timer."
  (harness-fallback--save)
  (when (timerp harness-fallback--timer) (cancel-timer harness-fallback--timer))
  (setq harness-fallback--timer nil))

(harness-declare-event 'fallback/changed "() after what ran out, or the sessions moved off their model, changed.")
(harness-declare-event 'fallback/switched
                       "(SESSION-ID FROM TO WHY) after the fallback moved a session to model TO; WHY is `out' or `back'.")

(harness-define-module 'fallback
  :doc "Carry on with another provider when one runs out of quota or money."
  :requires '(store session provider)
  :init #'harness-fallback--init
  :shutdown #'harness-fallback--shutdown)

(provide 'harness-fallback)
;;; harness-fallback.el ends here
