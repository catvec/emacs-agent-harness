;;; demo.el --- Show how a permission-judge reply is read  -*- lexical-binding: t; -*-

;;; Commentary:

;; Prints what the permission judge's strict reader makes of a reply, what
;; a reply with no verdict costs, and where a verdict schema goes on the
;; wire.  Four parts:
;;
;;   1. the field's reply, `{"allow":"Read-only inspection of a local git
;;      diff"}', and eight other replies, read strictly: which are a
;;      verdict, which are no verdict, and why;
;;   2. the retry: the observed reply then a corrected one, through the
;;      real `harness-perms--auto' stage with a scripted provider, so
;;      what it prints is the two calls, their messages and the decision
;;      the chain settled on;
;;   3. exhaustion: two malformed replies, which settle as a denial while
;;      the user is away and as one prompt while they are present, which
;;      the demo then answers (a denial) so the chain settles;
;;   4. the schema gate: which endpoints are sent the verdict's JSON
;;      schema and which are not -- a plain OpenAI-compatible one, and an
;;      OpenRouter pin that did or did not list `structured_outputs'.
;;
;; Run it with demo/perms-judge-verdicts/demo.sh.  It sends no model
;; request, sets no permission rule, installs no module and runs no tool:
;; the provider is a scripted stub, the tool is a page of text, and every
;; path it prints is a placeholder.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.."
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))

(require 'harness-util)
(require 'harness-provider)
(require 'harness-tools)
(require 'harness-perms)
;; The transport whose schema gate part 4 shows.
(require 'harness-provider-openrouter)

;; The permission chain is installed by the modules' own `:init', which
;; runs in dependency order: `perms' requires `config', which requires
;; `project'.  The module names are the short ones they register under.
;; `harness' is loaded for the settings a start would have made -- the
;; state directory, chiefly -- but never started: `harness-started' stays
;; nil, so no session, no module and no timer of a real Harness exists.
(require 'harness)
(dolist (module '(project config tools provider perms))
  (require (intern (format "harness-%s" module))))
(harness-modules-init '(project config tools provider perms))

(defconst demo-cwd "/home/user/project/"
  "The working directory the demo's call runs in, a placeholder.
The demo shows what a reply is made of, not where this checkout is.")

(defvar demo-session
  (list :id "demo" :cwd demo-cwd :permission-mode 'auto
        :non-interactive t :model "demo:judge")
  "The session the judge is asked for.  A record, so `session/get' answers it.")

(defconst demo-replies
  '(("the field's reply" "{\"allow\":\"Read-only inspection of a local git diff; no destructive or exfiltrating action.\"}")
    ("a valid allow" "{\"decision\":\"allow\",\"reason\":\"a local diff is ordinary work\"}")
    ("a valid deny" "{\"decision\":\"deny\",\"reason\":\"it force pushes to the shared remote\"}")
    ("a decision of ask" "{\"decision\":\"ask\",\"reason\":\"not mine to call\"}")
    ("markdown around the object" "Verdict:\n```json\n{\"decision\": \"Allow\", \"reason\": \"fine\"}\n```")
    ("a decision that is no word" "{\"decision\":\"maybe\",\"reason\":\"unsure\"}")
    ("the decision key twice" "{\"decision\":\"allow\",\"decision\":\"deny\"}")
    ("two objects that disagree" "{\"decision\":\"allow\"}\n{\"decision\":\"deny\"}")
    ("a verdict beside a vague one" "{\"decision\":\"allow\"}\n{\"decision\":\"maybe\"}")
    ("explanation, no JSON" "The call is safe; allow it."))
  "Labeled replies the reader is shown.")

(defun demo-read-replies ()
  "Part 1: read each reply and say what it is.
A reply that spans lines is shown with those lines joined, so the
reading sits beside the whole reply it makes."
  (princ "1. What the strict reader makes of a reply\n")
  (dolist (entry demo-replies)
    (let* ((label (car entry))
           (reply (cadr entry))
           (read (harness-perms--read-verdict reply))
           (behavior (plist-get read :behavior))
           (shown (replace-regexp-in-string "\n" " " reply)))
      (princ (format "\n  %-30s %s\n" (concat label ":") (harness-truncate-end shown 96)))
      (princ (format "  %-30s %s\n" ""
                     (if behavior
                         (format "VERDICT %s — %s" (upcase (symbol-name behavior))
                                 (plist-get read :reason))
                       (format "no verdict — %s" (or (plist-get read :problem) "it gave no answer"))))))))

(defun demo--request ()
  "Return the request the judge is asked about, and the session it is asked for.
A shell command is the kind of call auto mode leaves to the judge: a
read inside the allowed roots never reaches it, which is why the field's
call was a `git diff` run through bash."
  (harness-register-method 'session/get (lambda (_id) demo-session))
  (harness-register-method 'tools/get
                           (lambda (_name)
                             (list :name "bash" :kind 'exec
                                   :description "Runs a shell command.")))
  (list :session demo-session :tool "bash" :kind 'exec
        :input '(:command "git diff --stat") :call-id "call_demo"))

(defun demo--scripted-provider (replies)
  "Register provider `demo' whose judge answers REPLIES, one per call.
Return a function giving what each call was asked, newest first."
  (let ((asked nil) (left replies))
    (harness-define-provider 'demo
      :label "Demo judge"
      :complete (lambda (req)
                  (let ((on-event (plist-get req :on-event))
                        (reply (or (pop left) "{\"decision\":\"allow\",\"reason\":\"fallback\"}")))
                    (push (plist-get (car (plist-get (car (plist-get req :messages)) :content)) :text)
                          asked)
                    (harness-run-soon
                     (lambda ()
                       (funcall on-event (list :type 'text :delta reply))
                       (funcall on-event (list :type 'done :stop-reason 'end-turn)))))
                  (list :cancel #'ignore)))
    (lambda () asked)))

(defun demo--decide (request)
  "Run REQUEST through the permission chain and return the decision."
  (harness-await (harness-run-filter-async 'permission/decide (list :behavior 'ask) request)))

(defun demo--wait-for (pred timeout message)
  "Spin the event loop until PRED returns non-nil, at most TIMEOUT seconds.
Say MESSAGE when it does not."
  (let ((deadline (+ (float-time) timeout)) result)
    (while (and (not (setq result (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.005))
    (or result (error "Timed out waiting for %s" message))))

(defun demo--print-asked (asked)
  "Print what the judge was asked, newest first, from ASKED."
  (dolist (text (reverse (funcall asked)))
    (princ (format "\n  --- judge message (%d characters) ---\n%s\n"
                   (length text)
                   (harness-truncate-end text 1500)))))

(defun demo-retry ()
  "Part 2: the observed reply, corrected on the second call."
  (princ "\n\n2. The observed reply, and the one correction it gets\n")
  (let* ((asked (demo--scripted-provider
                 '("{\"allow\":\"Read-only inspection of a local git diff; no destructive or exfiltrating action.\"}"
                   "{\"decision\":\"allow\",\"reason\":\"a local diff is ordinary work\"}")))
         (harness-perms-auto-model "demo:judge")
         (request (demo--request))
         (decision (demo--decide request)))
    (demo--print-asked asked)
    (princ (format "\n  calls made: %d\n  decision: %S\n"
                   (length (funcall asked))
                   (list :behavior (plist-get decision :behavior)
                         :reason (plist-get decision :reason)
                         :no-verdict (plist-get decision :no-verdict))))))

(defun demo-exhaustion ()
  "Part 3: two malformed replies, in both fallbacks.
Away, the chain cannot ask anyone, so it denies.  With the user present,
it asks them -- once -- and the call waits for their answer, which is
what the next block lets it have (a denial) so the chain settles."
  (princ "\n\n3. Two malformed replies: no verdict, and the fallback\n")
  ;; The user is away: nothing may be asked, so the call is denied.
  (let* ((asked (demo--scripted-provider
                 '("{\"allow\":\"Read-only inspection of a local git diff\"}"
                   "{\"allow\":\"it is fine, really\"}")))
         (harness-perms-auto-model "demo:judge")
         (request (demo--request))
         (request (plist-put request :session
                             (plist-put (copy-sequence (plist-get request :session))
                                        :non-interactive t)))
         (decision (demo--decide request)))
    (princ (format "\n  the user is away: %d calls, then %s\n      %s\n"
                   (length (funcall asked))
                   (upcase (symbol-name (plist-get decision :behavior)))
                   (harness-truncate-end (or (plist-get decision :reason) "") 160))))
  ;; The user is present: the call becomes a prompt, and nothing runs
  ;; until they answer it.
  (let* ((asked (demo--scripted-provider
                 '("{\"allow\":\"Read-only inspection of a local git diff\"}"
                   "{\"allow\":\"it is fine, really\"}")))
         (harness-perms-auto-model "demo:judge")
         (prompts nil)
         (request (demo--request))
         (request (plist-put request :session
                             (plist-put (copy-sequence (plist-get request :session))
                                        :non-interactive nil))))
    (harness-register-method 'session/pending-add
                             (lambda (_sid pending)
                               (push pending prompts)
                               "p1"))
    (harness-register-method 'session/pending-resolve (lambda (&rest _) nil))
    (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask) request)))
      (demo--wait-for (lambda () prompts) 5 "the user's prompt")
      (let ((payload (plist-get (car prompts) :payload)))
        (princ (format "\n  the user is present: %d calls, then a prompt (not a run)\n"
                       (length (funcall asked))))
        (princ (format "      %s\n      %s\n"
                       (harness-truncate-end (or (plist-get payload :title) "") 150)
                       (or (plist-get payload :reason)
                           "the prompt carries no judge verdict: there was none"))))
      ;; The user denies it; that answer is what settles the chain.
      (let ((decision (harness-call 'permission/answer "demo" "p1" "deny-once")))
        (princ (format "      the user denied it, so the call is %s\n"
                       (upcase (symbol-name (plist-get decision :behavior)))))
        (harness-await p 5)))))

(defconst demo-policy
  '(:enabled t
    :model "deepseek/deepseek-v4.1-flash-1017"
    :freshness 300
    :owner-price (:prompt 0.30 :completion 1.20 :cache-read 0.006
                  :source "demo placeholder, not evidence" :read-at 0 :max-age 31536000)
    :privacy (:no-training t :retention "zero" :zdr-eligible t
              :safety-retention :excluded :regions ("US"))
    :retry (:max-attempts 2 :max-seconds 30 :max-output-tokens 4096))
  "A routing policy, dated and given one vetted endpoint by `demo--policy'.
Both are placeholders: the point is only that the policy is complete, so
the gate that decides whether the pinned endpoint takes a schema is open
to be shown.  None of it is evidence for a real policy.")

(defun demo--policy ()
  "Return `demo-policy', dated now so its owner price is not stale.
The policy is complete only so that the routing gate is open; the pin
the schema gate reads is the session's, not this policy's selection."
  (let ((now (float-time))
        (policy (copy-sequence demo-policy)))
    (plist-put
     policy :owner-price
     (plist-put (copy-sequence (plist-get policy :owner-price)) :read-at now))
    (plist-put
     policy :endpoints
     (list (list :key "demo-standard" :slug "demo/fp8" :tag "demo/fp8"
                 :provider "Demo" :quantization "fp8" :host "demo.example"
                 :evidence (list :no-training t :retention "zero" :zdr-eligible t
                                 :safety-retention :excluded :regions '("US")
                                 :host "demo.example" :checked-at now
                                 :source "demo placeholder, never evidence"
                                 :max-age 31536000))))))

(defun demo-schema-gate ()
  "Part 4: where the verdict schema goes on the wire."
  (princ "\n\n4. Where the verdict's schema goes\n")
  (let* ((schema harness-perms--judge-verdict-schema)
         (request (list :response-schema schema :response-schema-name "permission_verdict"))
         (plain (list :id 'plain :base-url "https://api.example/v1")))
    (princ (format "\n  a plain OpenAI-compatible endpoint:       %s\n"
                   (if (harness-openai--response-format plain request) "schema sent" "no schema")))
    ;; The pin records what the pinned endpoint's catalogue entry listed:
    ;; only such an endpoint is sent the schema.
    (let ((harness-openrouter-routing (demo--policy)))
      (princ (format "  routing enabled for this policy:          %s\n"
                     (if (harness-openrouter-routing-enabled-p harness-openrouter-routing) "yes" "no")))
      (dolist (entry '(("OpenRouter, the endpoint listed it" . t)
                       ("OpenRouter, the endpoint listed none" . nil)))
        (let ((session (list :id "demo"
                             :ext (list :openrouter-route
                                        (append (list :model "demo/model" :slug "demo/fp8")
                                                (and (cdr entry) (list :structured-outputs t)))))))
          (princ (format "  %-40s %s\n"
                         (concat (car entry) ":")
                         (if (harness-openai--response-format
                              (harness-openrouter--endpoint)
                              (plist-put (copy-sequence request) :session session))
                             "schema sent" "no schema"))))))
    (princ (format "  the reader does not depend on it:        %s\n"
                   (let ((read (harness-perms--read-verdict
                                "{\"decision\":\"deny\",\"reason\":\"no\"}")))
                     (format "%s, reason %S"
                             (upcase (symbol-name (plist-get read :behavior)))
                             (plist-get read :reason)))))))

(defun demo-run ()
  "Run every part of the demo.
The state directory is a placeholder too: nothing here reads or writes
a real Harness's state, and no path of yours is printed."
  (let ((harness-state-directory "/home/user/.harness/")
        (harness-directory "/home/user/harness/"))
    (demo-read-replies)
    (demo-retry)
    (demo-exhaustion)
    (demo-schema-gate)))
(provide 'demo)
;;; demo.el ends here
