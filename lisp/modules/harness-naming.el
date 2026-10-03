;;; harness-naming.el --- Name sessions with the model  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that was not given a name gets one from the model after
;; its first turn.  The cheap way to do that is to reuse the prefix the
;; provider has just cached: when the provider can fork its state
;; (`:fork' capability) the naming request goes out on a fork of the
;; session's state, so a hosted loop only sends the naming question and
;; an API provider hits the cache for the transcript.  Otherwise the
;; transcript is sent again as plain messages.
;;
;; The result is sanitised (first line, no quotes or markdown, at most
;; `harness-naming--max-length' characters) and stored with
;; `session/update', which adds the "renamed to" hint.
;;
;; The request's system prompt goes through the sync filter
;; `naming/system-prompt' (value the prompt, args the session), as a
;; turn's goes through `agent/system-prompt', so other modules can say
;; how their sessions are titled: task mode asks for ticket titles.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-naming-auto t
  "When non-nil, name a nameless session after its first turn."
  :type 'boolean :group 'harness)

(defconst harness-naming--max-length 60
  "Longest name the model may give a session.")

(defconst harness-naming--base-system-prompt
  "You write short titles for conversations between a software engineer and a coding agent.  A good title says what the conversation is about in 3 to 6 words, like a commit subject or a ticket title."
  "System prompt for the naming request.
Modules add to it per session through the `naming/system-prompt' filter.")

(defconst harness-naming--request-text
  "Give the conversation above a title of 3 to 6 words.  Reply with the title only: no quotes, no trailing period, no markdown, no explanation."
  "User message that asks the model for a title.")

(defconst harness-naming--skip-kinds '(btw subagent)
  "Session kinds that are never named automatically.")

(defvar harness-naming--running (make-hash-table :test 'equal)
  "Session id -> promise of the naming request in flight.")

;;;; Sanitising

(defun harness-naming-sanitise (text)
  "Turn model output TEXT into a session name, or nil when nothing is left.
Keeps the first non-blank line, strips markdown markers, quotes and a
trailing period, collapses whitespace and truncates to
`harness-naming--max-length' characters."
  (let ((line (harness-first-line (or text ""))))
    (setq line (replace-regexp-in-string "\\`\\(?:title\\|name\\)[ \t]*:[ \t]*" "" line nil nil nil))
    (setq line (replace-regexp-in-string "[*_`#>]+" "" line))
    (setq line (string-trim line "[][ \t\"'“”‘’(){}<>.,:;!?-]+" "[][ \t\"'“”‘’(){}<>.,:;!?-]+"))
    (setq line (replace-regexp-in-string "[ \t]+" " " line))
    (unless (string-empty-p line)
      (harness-truncate-end line harness-naming--max-length))))

;;;; Naming

(defun harness-naming--system-prompt (session)
  "Return the naming system prompt for SESSION after `naming/system-prompt'."
  (harness-run-filter 'naming/system-prompt harness-naming--base-system-prompt session))

(defun harness-naming--messages (session-id)
  "Return the naming messages for SESSION-ID: the transcript plus the question."
  (let* ((messages (harness-call 'session/messages session-id))
         (ask (list :type "text" :text harness-naming--request-text))
         (last (car (last messages))))
    (if (and last (eq (plist-get last :role) 'user))
        (append (butlast messages)
                (list (list :role 'user :content (append (plist-get last :content) (list ask)))))
      (append messages (list (list :role 'user :content (list ask)))))))

(defun harness-naming--forked-state (session)
  "Return a promise of a forked provider state for SESSION, or of nil."
  (let ((model (plist-get session :model)))
    (if (and (plist-get (harness-call 'provider/capabilities model) :fork)
             (harness-method-exists-p 'provider/fork))
        (harness-catch (harness-call-async 'provider/fork model (plist-get session :provider-state))
                       (lambda (e)
                         (harness-log 'warn "naming: provider fork failed, sending the transcript: %s"
                                      (harness-error-message e))
                         nil))
      (harness-resolved nil))))

(defun harness-naming--request (session state promise)
  "Send the naming request for SESSION with provider STATE, settling PROMISE."
  (let ((sid (plist-get session :id)) (text ""))
    (harness-call
     'provider/complete
     (list :model (plist-get session :model) :session session
           :system (harness-naming--system-prompt session)
           :messages (harness-naming--messages sid)
           :tools nil :provider-state state :max-tokens 40
           :on-event
           (lambda (ev)
             (pcase (plist-get ev :type)
               ('text (setq text (concat text (plist-get ev :delta))))
               ('done
                (let* ((reason (plist-get ev :stop-reason))
                       (name (harness-naming-sanitise text))
                       (problem (cond ((memq reason '(error cancelled))
                                       (or (plist-get ev :error) (format "%s" reason)))
                                      ((null name) "the model returned no usable title"))))
                  (if problem
                      (harness-naming--fail sid promise problem)
                    (condition-case err
                        (progn
                          (harness-call 'session/update sid :name name)
                          (harness-emit 'naming/done sid name)
                          (harness-resolve promise name))
                      (error (harness-naming--fail sid promise err))))))
               (_ nil)))))))

(defun harness-naming--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it."
  (let ((msg (harness-error-message err)))
    (harness-log 'warn "naming %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Naming failed: %s" msg)))
    (harness-emit 'naming/failed session-id msg)
    (harness-reject promise err)))

(harness-defmethod naming/name (session-id)
  "Ask the model for a title for SESSION-ID; return a promise of the name.
The name is stored with `session/update'.  A second call while one is
running returns the running promise."
  (or (gethash session-id harness-naming--running)
      (let ((session (harness-call 'session/get session-id))
            (promise (harness-make-promise)))
        (puthash session-id promise harness-naming--running)
        (harness-finally promise (lambda () (remhash session-id harness-naming--running)))
        (harness-call 'session/hint session-id "Naming session…")
        (harness-then (harness-naming--forked-state session)
                      (lambda (state)
                        (condition-case err
                            (harness-naming--request session state promise)
                          (error (harness-naming--fail session-id promise err))))
                      (lambda (err) (harness-naming--fail session-id promise err)))
        promise)))

;;;; Automatic naming

(defun harness-naming--first-turn-p (session-id)
  "Non-nil when SESSION-ID has at least one user and one assistant node."
  (let ((kinds (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes session-id))))
    (and (memq 'user kinds) (memq 'assistant kinds))))

(defun harness-naming--on-turn-ended (session-id reason)
  "Name SESSION-ID after its first turn when it has no name.
REASON is the turn's stop reason; only `end-turn' counts."
  (when (and harness-naming-auto
             (eq reason 'end-turn)
             (harness-call 'session/exists-p session-id))
    (let ((session (harness-call 'session/get session-id)))
      (when (and (harness-string-blank-p (plist-get session :name))
                 (not (memq (plist-get session :kind) harness-naming--skip-kinds))
                 (harness-naming--first-turn-p session-id))
        (harness-call 'naming/name session-id)))))

(defun harness-naming--init ()
  "Subscribe automatic naming to the end of turns."
  (harness-on 'agent/turn-ended #'harness-naming--on-turn-ended))

(harness-naming--init)

(harness-declare-event 'naming/done "(SESSION-ID NAME) after a session is named by the model.")
(harness-declare-event 'naming/failed "(SESSION-ID MESSAGE) when naming fails.")

(harness-define-module 'naming
  :doc "Name nameless sessions with the model after their first turn."
  :requires '(session provider agent)
  :init #'harness-naming--init)

(provide 'harness-naming)
;;; harness-naming.el ends here
