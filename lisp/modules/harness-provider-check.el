;;; harness-provider-check.el --- Live provider and model checks  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A provider is imported from a plugin author, a model is chosen in the
;; catalogue, and neither is trusted to work until it has answered a real
;; request.  `harness-provider-check' (its UI, harness-ui-provider-check.el)
;; runs these checks from inside the harness, on the session's model or on
;; any model the catalogue lists.  They are opt-in: the ordinary suites use
;; fake providers and never call one of these.
;;
;; The checks are split in two, because the two failures need different
;; fixes.  The provider contract asks whether the generic provider API is
;; honoured: the catalogue has the model, events start and end exactly once,
;; usage is a number, an unsupported reasoning effort is rejected rather
;; than silently mislabelled, images and tools survive transport, and a
;; cancelled request really stops.  The model behavior suite asks whether
;; the model is good enough for the harness: does it follow an instruction,
;; choose a tool with structured arguments, and use the result it got.
;; A model that refuses to call a tool is no evidence that tool transport
;; is broken, so the contract check skips while the behavior check fails.
;;
;; Checks are incremental in both senses.  Each one reports PASS, FAIL or
;; SKIP as soon as it settles, with guidance about the feature that may need
;; to be removed or fixed, and the remaining checks keep running.  Nothing
;; stops at the first failure, and a SKIP means unverified, not supported.
;; A check that cannot run because the account is out of quota or money, is
;; rate-limited, refused its credential or cannot reach the provider is a
;; SKIP too: an exhausted plan is not a broken provider, and the report says
;; which of those it was without echoing the provider's error text.
;;
;; The job runs in the harness process, so it must not block the event loop:
;; every check returns a promise, and completions are driven by the
;; provider's own events.  The UI half follows the job's events over ACP
;; (`provider-check/started', `provider-check/result' and
;; `provider-check/finished').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

(defgroup harness-provider-check nil
  "Live checks of a provider's contract and a model's harness skills."
  :prefix "harness-provider-check-"
  :group 'harness)

(defcustom harness-provider-check-timeout 90
  "Seconds to wait for one live request or one provider answer.
A check that waits longer is a failure of its own, and the checks after
it still run."
  :type 'number
  :group 'harness-provider-check)

(define-error 'harness-provider-check-failure "Provider check failed")

(define-error 'harness-provider-check-unavailable "Provider check could not run")

(defconst harness-provider-check--environment-kinds
  '(quota billing rate-limit auth transport)
  "Done-event error kinds that say a check could not run.
A plan's usage limit, an empty balance, a short rate limit, a refused
credential and an unreachable route are conditions of the account or
the network.  None is evidence about the provider contract or the
model, so a check that hits one is SKIPped rather than failed.  A
`request' kind is different: it says the body was wrong, which is the
provider's own contract to keep.")

(defconst harness-provider-check--image
  "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC"
  "64x64 solid red PNG used to check whether a vision model accepts images.
The bytes are a complete PNG: some APIs reject a truncated image as an
unsupported format rather than a bad request.")

(cl-defstruct (harness-provider-check-job (:copier nil))
  id model suite embedding-model
  provider-id provider
  plan pending
  metadata base tool-attempt
  results completed total
  cancelled finished
  handle abort
  promise
  started-at)

(defconst harness-provider-check-suites '(provider model all)
  "Suites `harness-provider-check-start' runs.")

(defun harness-provider-check--require (condition message)
  "Signal `harness-provider-check-failure' with MESSAGE unless CONDITION."
  (unless condition
    (signal 'harness-provider-check-failure (list message))))

;;;; Requests and event validation

(defun harness-provider-check--request (model session-id user &optional system)
  "Build a minimal REQUEST for MODEL, SESSION-ID, USER and SYSTEM."
  (list :model model
        :session (list :id session-id :cwd default-directory)
        :ephemeral t
        :system (or system "You are a helpful assistant.")
        :max-tokens 512
        :messages (list (list :role 'user
                              :content (list (list :type "text" :text user))))))

(defun harness-provider-check--image-request (model id prompt)
  "Return a request for MODEL and ID with PROMPT and a small red image."
  (let* ((request (harness-provider-check--request model id prompt))
         (message (car (plist-get request :messages))))
    (setf message
          (plist-put message :content
                     (append (plist-get message :content)
                             (list (list :type "image" :mime "image/png"
                                         :data harness-provider-check--image)))))
    (plist-put request :messages (list message))))

(defun harness-provider-check--kind (value)
  "Return VALUE, an error kind, as a non-keyword symbol, or nil."
  (and value (intern (string-remove-prefix ":" (format "%s" value)))))

(defun harness-provider-check--unavailable-detail (kind)
  "Return a safe explanation for a check that ended with error KIND.
The text is built from the kind alone, never from the provider's error
message, which a third-party plugin may have filled with a key.  It
says that the account or network is the reason, so a reader does not
mistake the SKIP for a verdict on the provider."
  (pcase kind
    ('quota (concat "The account's plan usage limit is reached, so this check "
                    "could not run; try again after the limit resets."))
    ('billing (concat "The account cannot be billed for this provider, so this "
                      "check could not run; check the account's balance or plan."))
    ('rate-limit (concat "The provider rate-limited this check, so it could not "
                         "run; try again shortly."))
    ('auth (concat "The provider refused the account's credential, so this check "
                   "could not run; sign in again and rerun."))
    ('transport (concat "The provider could not be reached, so this check could "
                        "not run; try again later."))
    (_ "This check could not run against this account.")))

(defun harness-provider-check--events (events &optional allow-cancel)
  "Validate the transport shape of EVENTS, allowing cancellation if ALLOW-CANCEL.
Do not assert the model's words or its choice to use tools here.  A
turn that ended because the account is out of quota or money, was
rate-limited, refused the credential or could not reach the provider
signals `harness-provider-check-unavailable', which the runner reports
as SKIP: nothing about the provider was observed."
  (harness-provider-check--require (eq (plist-get (car events) :type) 'start)
                                   "No start event")
  (harness-provider-check--require (eq (plist-get (car (last events)) :type) 'done)
                                   "Done was not the last event")
  (harness-provider-check--require
   (= 1 (cl-count 'done events :key (lambda (e) (plist-get e :type))))
   "Expected exactly one done event")
  (dolist (event events)
    (harness-provider-check--require
     (and (listp event) (symbolp (plist-get event :type)))
     "An event is not a plist with a symbol :type")
    (pcase (plist-get event :type)
      ((or 'text 'thinking)
       (harness-provider-check--require (stringp (plist-get event :delta))
                                        "A text/thinking delta is not a string"))
      ('tool-call
       (harness-provider-check--require
        (and (stringp (plist-get event :id))
             (not (string-empty-p (plist-get event :id)))
             (stringp (plist-get event :name))
             (listp (plist-get event :input))
             (or (not (plist-get event :respond))
                 (functionp (plist-get event :respond))))
        "A tool-call needs a name, id, plist input and optional respond function"))
      ('usage
       (dolist (key '(:input :output))
         (harness-provider-check--require
          (and (numberp (plist-get event key)) (>= (plist-get event key) 0))
          (format "Usage %s is not a nonnegative number" key))))
      ('done
       (harness-provider-check--require
        (memq (plist-get event :stop-reason)
              (if allow-cancel
                  '(cancelled end-turn error tool-use max-tokens)
                '(end-turn error tool-use max-tokens)))
        "Missing or unknown stop reason"))))
  ;; A turn that ran out of account or network is not a provider verdict.
  (let* ((done (car (last events)))
         (kind (and (eq (plist-get done :stop-reason) 'error)
                    (harness-provider-check--kind
                     (plist-get done :error-kind)))))
    (when (memq kind harness-provider-check--environment-kinds)
      (signal 'harness-provider-check-unavailable
              (list (harness-provider-check--unavailable-detail kind)))))
  t)

(defun harness-provider-check--finish-events (events &optional allow-tool-use allow-cancel)
  "Check EVENTS for a successful turn, optionally ALLOW-TOOL-USE or ALLOW-CANCEL."
  (harness-provider-check--events events allow-cancel)
  (let ((reason (plist-get (car (last events)) :stop-reason)))
    (harness-provider-check--require
     (or (eq reason 'end-turn)
         (and allow-tool-use (eq reason 'tool-use))
         (and allow-cancel (eq reason 'cancelled)))
     ;; Never echo error text: a third-party provider could put credentials in it.
     (format "Turn ended with %s (error text suppressed)" reason))))

(defun harness-provider-check--expect-text (events)
  "Check that EVENTS ended with an answer rather than a tool call or an error.
The failure message names the stop reason but never the provider's error
text, which a third-party plugin may have filled with a key."
  (harness-provider-check--events events)
  (let ((reason (plist-get (car (last events)) :stop-reason)))
    (harness-provider-check--require
     (eq reason 'end-turn)
     (format "Model ended with %s instead of answering" reason))))

(defun harness-provider-check--text (events)
  "Join the text deltas in EVENTS."
  (mapconcat (lambda (event)
               (if (eq (plist-get event :type) 'text)
                   (plist-get event :delta)
                 ""))
             events ""))

;;;; Running one completion without blocking

(defun harness-provider-check--close (model session-id)
  "Free what MODEL's provider keeps for SESSION-ID, ignoring a failure."
  (ignore-errors (harness-call 'provider/close model session-id)))

(defun harness-provider-check--complete (job request &optional keep-open cancel-now)
  "Complete REQUEST for JOB; return a promise of (:events EVENTS :state STATE).
Close the request's session afterwards unless KEEP-OPEN.  With CANCEL-NOW,
cancel the handle as soon as it exists, so the cancellation path is
exercised.  Every wait is bounded by `harness-provider-check-timeout'."
  (let* ((model (plist-get request :model))
         (session-id (plist-get (plist-get request :session) :id))
         (events nil)
         (state nil)
         (done nil)
         (handle nil)
         (timer nil)
         (promise (harness-make-promise)))
    (cl-labels
        ((settle (error)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer) (setq timer nil))
             (when (eq (harness-provider-check-job-handle job) handle)
               (setf (harness-provider-check-job-handle job) nil
                     (harness-provider-check-job-abort job) nil))
             (unless keep-open
               (harness-provider-check--close model session-id))
             (if error
                 (harness-reject promise error)
               (harness-resolve promise (list :events (nreverse events)
                                              :state state)))))
         (timed-out ()
           (unless done
             (let ((cancel (plist-get handle :cancel)))
               ;; Settle first: a provider whose cancel answers at once must
               ;; not turn a timeout into a successful cancellation.
               (settle (list 'harness-provider-check-failure
                             (format "Timed out after %s seconds"
                                     harness-provider-check-timeout)))
               (when (functionp cancel) (ignore-errors (funcall cancel)))))))
      (setq timer (run-at-time harness-provider-check-timeout nil #'timed-out))
      (condition-case err
          (setq handle
                (harness-call
                 'provider/complete
                 (plist-put
                  (copy-sequence request)
                  :on-event
                  (lambda (event)
                    (push event events)
                    (when (eq (plist-get event :type) 'provider-state)
                      (setq state (plist-get event :state)))
                    (when (eq (plist-get event :type) 'done)
                      (settle nil))))))
        (error (settle err)))
      (when (and handle (not done))
        (setf (harness-provider-check-job-handle job) handle
              (harness-provider-check-job-abort job)
              (lambda ()
                (let ((cancel (plist-get handle :cancel)))
                  (when (functionp cancel) (ignore-errors (funcall cancel))))
                (settle (list 'harness-provider-check-failure
                              "Cancelled by the user"))))
        (when cancel-now
          (let ((cancel (plist-get handle :cancel)))
            (if (functionp cancel)
                (ignore-errors (funcall cancel))
              (settle (list 'harness-provider-check-failure
                            "Completion handle has no :cancel function")))))))
    promise))

(defun harness-provider-check--finally (promise fn)
  "Call FN after PROMISE settles, either way, and pass its outcome on."
  (harness-then promise
                (lambda (value) (funcall fn) value)
                (lambda (error) (funcall fn) (harness-rejected error))))

;;;; The checks
;;
;; Each check is a function of JOB returning a cons (STATUS . DETAIL), or a
;; promise of one.  STATUS is `pass', `fail' or `skip'.  A check that cannot
;; run because an optional feature is not advertised returns `skip': it was
;; not verified, so it says nothing for or against the provider.

(defun harness-provider-check--check-catalogue (job)
  "Check that the model of JOB is listed with usable metadata."
  (let* ((model (harness-provider-check-job-model job))
         (parsed (harness-provider-parse-model model))
         (pid (car parsed))
         (name (cdr parsed))
         (provider (and pid (harness-provider-get pid))))
    (harness-provider-check--require provider "Provider is not registered")
    (harness-provider-check--require (functionp (harness-provider-models-fn provider))
                                     "Provider does not list models")
    (setf (harness-provider-check-job-provider-id job) pid
          (harness-provider-check-job-provider job) provider)
    (harness-then
     (or (harness-as-promise (harness-provider-relist pid))
         (harness-resolved nil))
     (lambda (_)
       (let* ((listed (harness-call 'provider/cached-models pid))
              (metadata (harness-call 'provider/model model)))
         (harness-provider-check--require
          (cl-find name listed :key (lambda (m) (plist-get m :name)) :test #'equal)
          "Selected model absent from the refreshed provider catalogue")
         (harness-provider-check--require
          (and (equal (plist-get metadata :id) model)
               (eq (plist-get metadata :provider) pid)
               (numberp (plist-get metadata :context-window))
               (> (plist-get metadata :context-window) 0))
          "Model id, provider or context window is invalid")
         (setf (harness-provider-check-job-metadata job) metadata)
         (cons 'pass
               (if (plist-get metadata :context-window-estimated)
                   "Listed; context window is estimated (check its value)."
                 "Listed with model id and context window."))))
     (lambda (_error)
       (harness-rejected
        (list 'harness-provider-check-failure
              "Refreshing the provider catalogue failed"))))))

(defun harness-provider-check--check-completion (job)
  "Check a plain text completion of JOB and its start/text/done lifecycle."
  (harness-then
   (harness-provider-check--complete
    job
    (harness-provider-check--request (harness-provider-check-job-model job)
                                     "provider-check-basic"
                                     "Reply with a short greeting."))
   (lambda (reply)
     (let ((events (plist-get reply :events)))
       (harness-provider-check--finish-events events)
       (harness-provider-check--require
        (not (string-empty-p
              (string-trim (harness-provider-check--text events))))
        "No text deltas")
       (setf (harness-provider-check-job-base job) reply)
       '(pass . "Start, text and one successful done; no model wording asserted.")))))

(defun harness-provider-check--check-usage (job)
  "Check that the basic completion of JOB reported nonnegative usage."
  (let ((base (harness-provider-check-job-base job)))
    (if (not base)
        '(skip . "Text completion did not return events.")
      (let* ((events (plist-get base :events))
             (usage (cl-remove-if-not
                     (lambda (event) (eq (plist-get event :type) 'usage))
                     events)))
        (harness-provider-check--require usage "No usage event")
        (harness-provider-check--events events)
        '(pass . "Nonnegative input and output usage reported.")))))

(defun harness-provider-check--check-no-thinking (job)
  "Check that a request without thinking is accepted for JOB."
  (let ((request (harness-provider-check--request
                  (harness-provider-check-job-model job)
                  "provider-check-no-thinking"
                  "Reply with a short greeting.")))
    (setf request (plist-put request :no-thinking t))
    (harness-then
     (harness-provider-check--complete job request)
     (lambda (reply)
       (harness-provider-check--finish-events (plist-get reply :events))
       '(pass . "No-thinking request accepted; API did not reject its effort.")))))

(defun harness-provider-check--check-thinking (job)
  "Check the deepest thinking level the model of JOB advertises."
  (let* ((metadata (harness-provider-check-job-metadata job))
         (levels (plist-get metadata :thinking-levels))
         (level (car (last levels))))
    (if (not (and (stringp level)
                  (member level '("low" "medium" "high" "xhigh" "max"))))
        '(skip . "Model advertises no known thinking level (or catalogue failed).")
      (let ((request (harness-provider-check--request
                      (harness-provider-check-job-model job)
                      "provider-check-thinking"
                      "Reply with a short greeting.")))
        (setf request (plist-put request :thinking level))
        (harness-then
         (harness-provider-check--complete job request)
         (lambda (reply)
           (harness-provider-check--finish-events (plist-get reply :events))
           (cons 'pass
                 (format "Requested advertised level %s without API rejection." level))))))))

(defun harness-provider-check--vision-p (metadata provider)
  "Return non-nil when METADATA or PROVIDER advertises image input."
  (or (plist-get (or (plist-get metadata :capabilities)
                     (and provider (harness-provider-capabilities provider)))
                 :vision)
      (member "image" (plist-get metadata :input-modalities))))

(defun harness-provider-check--check-image-input (job)
  "Check that the provider of JOB accepts an advertised image block."
  (let ((metadata (harness-provider-check-job-metadata job)))
    (if (not (harness-provider-check--vision-p
              metadata (harness-provider-check-job-provider job)))
        '(skip . "This model does not advertise image input.")
      (harness-then
       (harness-provider-check--complete
        job
        (harness-provider-check--image-request
         (harness-provider-check-job-model job)
         "provider-check-image"
         "Here is an image. Reply briefly."))
       (lambda (reply)
         (harness-provider-check--finish-events (plist-get reply :events) t)
         '(pass . "Image block accepted; visual recognition not asserted."))))))

(defun harness-provider-check--tool-turn (job)
  "Try an echo-tool round trip on the model of JOB.
Return a promise of (:first EVENTS :second EVENTS :call TOOL-CALL :marker
RECEIPT).  A hosted loop receives the result through :respond; a native
loop gets assistant/tool messages in a second completion.  Not calling
the tool is reported separately as model behavior, not a provider bug."
  (let* ((model (harness-provider-check-job-model job))
         (id (format "provider-check-tool-%x" (random most-positive-fixnum)))
         (marker (format "receipt-%x" (random most-positive-fixnum)))
         (user "Call check_echo with value 'ping'. Then tell me the tool's receipt.")
         (request (harness-provider-check--request model id user))
         (tool '(:name "check_echo"
                  :description "Return a receipt for value."
                  :schema (:type "object"
                           :properties (:value (:type "string"))
                           :required ("value")))))
    (setf request (plist-put request :tools (list tool)))
    (harness-then
     (harness-provider-check--complete job request)
     (lambda (first)
       (let* ((first-events (plist-get first :events))
              (call (cl-find 'tool-call first-events
                             :key (lambda (event) (plist-get event :type))))
              (second nil))
         (when (and call
                    (not (plist-get call :respond))
                    (eq (plist-get (car (last first-events)) :stop-reason) 'tool-use))
           (let* ((text (harness-provider-check--text first-events))
                  (assistant
                   (list :role 'assistant
                         :content
                         (append
                          (unless (string-empty-p text)
                            (list (list :type "text" :text text)))
                          (list (list :type "tool_use"
                                      :id (plist-get call :id)
                                      :name (plist-get call :name)
                                      :input (plist-get call :input))))))
                  (tool-result
                   (list :role 'tool
                         :content (list (list :type "tool_result"
                                              :tool_use_id (plist-get call :id)
                                              :content marker))))
                  (follow (plist-put (copy-sequence request)
                                     :messages
                                     (append (plist-get request :messages)
                                             (list assistant tool-result)))))
             (setf follow (plist-put follow :provider-state
                                     (plist-get first :state)))
             (setq second
                   (harness-provider-check--complete job follow))))
         (if second
             (harness-then second
                           (lambda (reply)
                             (list :first first-events
                                   :second (plist-get reply :events)
                                   :call call :marker marker)))
           (harness-resolved
            (list :first first-events :second nil
                  :call call :marker marker))))))))

(defun harness-provider-check--check-tool-transport (job)
  "Check the tool-call event of JOB and its result continuation."
  (harness-then
   (harness-provider-check--tool-turn job)
   (lambda (attempt)
     (setf (harness-provider-check-job-tool-attempt job) attempt)
     (let ((events (plist-get attempt :first))
           (call (plist-get attempt :call))
           (second (plist-get attempt :second)))
       (harness-provider-check--finish-events events t)
       (if (not call)
           (if (eq (plist-get (car (last events)) :stop-reason) 'tool-use)
               '(fail . "Turn ended for tool use but delivered no tool-call event")
             '(skip . "Model chose not to call a tool; transport unexercised (see behavior suite)."))
         (harness-provider-check--require
          (equal (plist-get call :name) "check_echo")
          "Tool name changed in transport")
         (when second (harness-provider-check--finish-events second))
         (harness-provider-check--require
          (or second
              (and (plist-get call :respond)
                   (eq (plist-get (car (last events)) :stop-reason) 'end-turn)))
          "Tool result did not reach a completed continuation")
         '(pass . "Tool id/input and hosted or native result continuation completed."))))))

(defun harness-provider-check--check-quota (job)
  "Check the generic shape of the optional quota hook of JOB."
  (let* ((pid (harness-provider-check-job-provider-id job))
         (provider (harness-provider-check-job-provider job))
         (capabilities (and provider (harness-provider-capabilities provider))))
    (if (not (and provider (harness-provider-quota-fn provider)))
        (progn
          (harness-provider-check--require
           (not (plist-get capabilities :quota))
           "Advertises :quota but has no quota hook")
          '(skip . "Provider has no quota hook."))
      (harness-then
       (harness-as-promise (harness-call 'provider/quota pid))
       (lambda (quota)
         (if (null quota)
             '(skip . "No quota reported for this account; cannot validate windows.")
           (harness-provider-check--require
            (and (listp quota)
                 (memq (plist-get quota :billing) '(api subscription nil)))
            "Quota billing is invalid")
           (dolist (window (plist-get quota :windows))
             (harness-provider-check--require
              (and (stringp (plist-get window :name))
                   (numberp (plist-get window :used))
                   (<= 0 (plist-get window :used) 1))
              "Quota window needs a name and used fraction in [0,1]"))
           '(pass . "Billing and reported quota windows have the generic shape.")))))))

(defun harness-provider-check--check-fork (job)
  "Check the optional provider-state and fork support of JOB."
  (let* ((metadata (harness-provider-check-job-metadata job))
         (provider (harness-provider-check-job-provider job))
         (capabilities (or (plist-get metadata :capabilities)
                           (and provider (harness-provider-capabilities provider)))))
    (if (not (plist-get capabilities :fork))
        '(skip . "Provider does not advertise fork support.")
      (let* ((model (harness-provider-check-job-model job))
             (session-id "provider-check-fork")
             (request (harness-provider-check--request
                       model session-id "Reply with a short greeting.")))
        (setf request (plist-put request :ephemeral nil))
        (harness-then
         (harness-provider-check--finally
          (harness-provider-check--complete job request t)
          (lambda () (harness-provider-check--close model session-id)))
         (lambda (reply)
           (let ((state (plist-get reply :state)))
             (harness-provider-check--finish-events (plist-get reply :events))
             (harness-provider-check--require (listp state) "No provider-state event")
             (harness-then
              (harness-as-promise (harness-call 'provider/fork model state))
              (lambda (forked)
                (harness-provider-check--require
                 (plist-get forked :provider)
                 "Fork returned no provider-owned state")
                '(pass . "Emitted state and returned a provider-tagged fork."))))))))))

(defun harness-provider-check--check-embeddings (job)
  "Check the optional embedding hook of JOB when an embedding model is given."
  (let* ((model (harness-provider-check-job-model job))
         (pid (car (harness-provider-parse-model model)))
         (embedding-model (harness-provider-check-job-embedding-model job)))
    (cond
     ((not (and pid (harness-call 'provider/embeds-p model)))
      '(skip . "Provider has no embedding hook."))
     ((null embedding-model)
      '(skip . "Give an embedding model to check this hook."))
     (t
      (harness-provider-check--require
       (eq (car (harness-provider-parse-model embedding-model)) pid)
       "Embedding model belongs to another provider")
      (harness-then
       (harness-as-promise
        (harness-call 'provider/embed embedding-model '("alpha" "beta")))
       (lambda (answer)
         (let* ((vectors (plist-get answer :vectors)))
           (harness-provider-check--require
            (and (= (length vectors) 2)
                 (cl-every (lambda (vector)
                             (and (listp vector) vector
                                  (cl-every #'numberp vector)))
                           vectors)
                 (= (length (car vectors)) (length (cadr vectors))))
            "Embeddings need two same-size numeric vectors in input order")
           '(pass . "Two ordered inputs returned same-size numeric vectors."))))))))

(defun harness-provider-check--check-cancellation (job)
  "Check that cancelling a live request of JOB ends it once as cancelled."
  (harness-then
   (harness-provider-check--complete
    job
    (harness-provider-check--request (harness-provider-check-job-model job)
                                     "provider-check-cancel"
                                     "Reply with a short greeting.")
    nil t)
   (lambda (reply)
     (let ((events (plist-get reply :events)))
       (harness-provider-check--events events t)
       (harness-provider-check--require
        (eq (plist-get (car (last events)) :stop-reason) 'cancelled)
        "Cancelling did not end with cancelled")
       '(pass . "Cancel produced exactly one cancelled done event.")))))

;;;; Model behavior

(defun harness-provider-check--resubmit-label ()
  "Return a fresh exact label for the resubmit-tool instruction check.
The label keeps its \"marker-\" prefix: the tool description asks for
the exact string, prefix included, so dropping the prefix is a real
failure to follow the tool's instruction."
  (format "marker-%06x%06x" (random #x1000000) (random #x1000000)))

(defun harness-provider-check--resubmit-tool (label)
  "Return a resubmit tool whose description demands LABEL exactly."
  (list :name "resubmit"
        :description (format (concat "Resubmit finished work after review. "
                                     "Put the exact string %s in the note, "
                                     "including the marker- prefix.")
                             label)
        :schema (list :type "object"
                      :properties (list :note
                                        (list :type "string"
                                              :description
                                              (format (concat "The exact string %s, "
                                                              "prefix included.")
                                                      label)))
                      :required (list "note"))))

(defun harness-provider-check--check-instructions (job)
  "Check that the model of JOB follows a resubmit tool's label instruction.
Tool descriptions carry the formats that resubmit, hand-in and other
harness tools rely on.  This check puts a fresh label in the resubmit
tool's description, and requires the model to carry it, prefix included,
into the structured note argument rather than dropping it as a label."
  (let* ((label (harness-provider-check--resubmit-label))
         (request (harness-provider-check--request
                   (harness-provider-check-job-model job)
                   "provider-check-instructions"
                   "Resubmit the task now."
                   "You are a coding agent resubmitting finished work.")))
    (setf request (plist-put request :tools
                             (list (harness-provider-check--resubmit-tool
                                    label))))
    (harness-then
     (harness-provider-check--complete job request)
     (lambda (reply)
       (let* ((events (plist-get reply :events))
              (call (cl-find 'tool-call events
                             :key (lambda (event) (plist-get event :type))))
              (note (and call (plist-get (plist-get call :input) :note))))
         (harness-provider-check--finish-events events t)
         (harness-provider-check--require
          (and call (equal (plist-get call :name) "resubmit"))
          "Model did not call the resubmit tool")
         (harness-provider-check--require
          (and (stringp note)
               (string-match-p (regexp-quote label) note))
          "Model dropped the label from the resubmit note")
         '(pass . "Followed the resubmit tool's label in its argument."))))))

(defun harness-provider-check--check-vision (job)
  "Check that the model of JOB names the color of a red image."
  (let* ((model (harness-provider-check-job-model job))
         (info (harness-call 'provider/model model)))
    (if (not (harness-provider-check--vision-p info
                                               (harness-provider-check-job-provider job)))
        '(skip . "Model does not advertise image input.")
      (harness-then
       (harness-provider-check--complete
        job
        (harness-provider-check--image-request
         model "provider-check-vision" "What is the solid color of this image?"))
       (lambda (reply)
         (let ((events (plist-get reply :events)))
           (harness-provider-check--expect-text events)
           (harness-provider-check--require
            (string-match-p "\\bred\\b" (downcase (harness-provider-check--text events)))
            "Model did not identify the red image")
           '(pass . "Identified the solid red image without a tool.")))))))

(defun harness-provider-check--check-tool-call (job)
  "Check that the model of JOB chooses the offered tool with structured arguments."
  (harness-then
   (if (harness-provider-check-job-tool-attempt job)
       (harness-resolved (harness-provider-check-job-tool-attempt job))
     (harness-then
      (harness-provider-check--tool-turn job)
      (lambda (attempt)
        (setf (harness-provider-check-job-tool-attempt job) attempt)
        attempt)))
   (lambda (attempt)
     (let ((call (plist-get attempt :call))
           (events (plist-get attempt :first)))
       ;; An account or network failure is not the model's choice.
       (harness-provider-check--events events t)
       (if (not call)
           (if (eq (plist-get (car (last events)) :stop-reason) 'tool-use)
               '(skip . "Turn ended for tool use without a tool-call event; model choice unobserved.")
             (harness-provider-check--require nil "Model did not call the offered tool"))
         (progn
           (harness-provider-check--require
            (and (equal (plist-get call :name) "check_echo")
                 (equal (plist-get (plist-get call :input) :value) "ping"))
            "Model chose the wrong tool or arguments")
           '(pass . "Called check_echo with the requested structured argument.")))))))

(defun harness-provider-check--check-tool-result (job)
  "Check that the model of JOB used the receipt only the tool returned."
  (let ((attempt (harness-provider-check-job-tool-attempt job)))
    (if (not (and attempt (plist-get attempt :call)))
        '(skip . "No tool call to return a result to.")
      (let* ((second (plist-get attempt :second))
             (events (or second (plist-get attempt :first)))
             (marker (plist-get attempt :marker)))
        ;; A continuation that ran out of quota never reached the model.
        (when second (harness-provider-check--events second))
        (harness-provider-check--require
         (string-match-p (regexp-quote marker)
                         (harness-provider-check--text events))
         "Model omitted the receipt only the tool returned")
        '(pass . "Final answer included the tool-only receipt.")))))

;;;; The plan

(defun harness-provider-check--plan (suite)
  "Return the checks of SUITE, provider or model, in running order."
  (append
   (when (memq suite '(provider all))
     (list
      (list :suite 'provider :id "catalogue"
            :name "Registry and model catalogue"
            :advice "Fix :models / model metadata; do not rely on the model picker until it lists this model."
            :fn #'harness-provider-check--check-catalogue)
      (list :suite 'provider :id "completion"
            :name "Text completion and event lifecycle"
            :advice "Do not use this provider for sessions until completion and event framing work."
            :fn #'harness-provider-check--check-completion)
      (list :suite 'provider :id "usage"
            :name "Usage accounting"
            :advice "Do not advertise accurate token/cost tracking until :usage is populated."
            :fn #'harness-provider-check--check-usage)
      (list :suite 'provider :id "no-thinking"
            :name "No-thinking request"
            :advice "Fix reasoning-effort mapping (e.g. unsupported 'none'); do not claim :thinking support until fixed."
            :fn #'harness-provider-check--check-no-thinking)
      (list :suite 'provider :id "thinking"
            :name "Declared thinking level"
            :advice "Remove unsupported :thinking-levels / :thinking capability, or map efforts per model."
            :fn #'harness-provider-check--check-thinking)
      (list :suite 'provider :id "image-input"
            :name "Advertised image input"
            :advice "Remove :vision / image input modality for this model until image requests work."
            :fn #'harness-provider-check--check-image-input)
      (list :suite 'provider :id "tool-transport"
            :name "Tool-call transport and tool-result continuation"
            :advice "If calls are malformed or results cannot round-trip, fix tool transport before using this model as an agent."
            :fn #'harness-provider-check--check-tool-transport)
      (list :suite 'provider :id "quota"
            :name "Quota reporting (optional)"
            :advice "Do not advertise :quota until provider/quota returns valid windows and billing."
            :fn #'harness-provider-check--check-quota)
      (list :suite 'provider :id "fork"
            :name "Provider-state and fork (optional)"
            :advice "Do not advertise :fork / :resume until the provider emits usable state and forks it."
            :fn #'harness-provider-check--check-fork)
      (list :suite 'provider :id "embeddings"
            :name "Embeddings (optional)"
            :advice "Do not advertise :embed until vectors match inputs and have numeric components."
            :fn #'harness-provider-check--check-embeddings)
      (list :suite 'provider :id "cancellation"
            :name "Cancellation and cleanup"
            :advice "Fix :cancel to end a live request once and release its resources."
            :fn #'harness-provider-check--check-cancellation)))
   (when (memq suite '(model all))
     (list
      (list :suite 'model :id "instructions"
            :name "Instruction following"
            :advice (concat "A model that drops exact text from a tool description "
                            "fills resubmit or hand-in arguments wrongly; do not use it "
                            "for tools whose instructions carry exact formats.")
            :fn #'harness-provider-check--check-instructions)
      (list :suite 'model :id "vision"
            :name "Image recognition (optional)"
            :advice "Remove :vision / image input modality for this model if it cannot see images."
            :fn #'harness-provider-check--check-vision)
      (list :suite 'model :id "tool-call"
            :name "Choose and form a harness tool call"
            :advice "Use a stronger tool-using model; do not assign this one autonomous harness tasks."
            :fn #'harness-provider-check--check-tool-call)
      (list :suite 'model :id "tool-result"
            :name "Use the returned tool result"
            :advice "Do not rely on this model for tool-grounded answers; try a different model."
            :fn #'harness-provider-check--check-tool-result)))))

(defun harness-provider-check--plan-summary (plan)
  "Return PLAN without the functions, for a UI or an event."
  (mapcar (lambda (entry)
            (list :id (plist-get entry :id)
                  :suite (plist-get entry :suite)
                  :name (plist-get entry :name)))
          plan))

;;;; Running the plan

(defvar harness-provider-check--jobs (make-hash-table :test #'equal)
  "Running checks, id -> `harness-provider-check-job'.")

(defun harness-provider-check--timeout (promise seconds what)
  "Return a promise like PROMISE, rejecting after SECONDS waiting for WHAT."
  (let ((result (harness-make-promise))
        (timer nil)
        (settled nil))
    (setq timer
          (run-at-time seconds nil
                       (lambda ()
                         (unless settled
                           (setq settled t)
                           (harness-reject
                            result
                            (list 'harness-provider-check-failure
                                  (format "Timed out after %s seconds waiting for %s"
                                          seconds what)))))))
    (harness-then
     promise
     (lambda (value)
       (unless settled
         (setq settled t)
         (cancel-timer timer)
         (harness-resolve result value)))
     (lambda (error)
       (unless settled
         (setq settled t)
         (cancel-timer timer)
         (harness-reject result error))))
    result))

(defun harness-provider-check--result (entry value)
  "Return the result plist of check ENTRY from VALUE, its (STATUS . DETAIL)."
  (let* ((status (car-safe value))
         (detail (cdr-safe value)))
    (unless (memq status '(pass fail skip))
      (setq status 'fail
            detail "Check returned no status"))
    (list :id (plist-get entry :id)
          :suite (plist-get entry :suite)
          :name (plist-get entry :name)
          :status status
          :detail (or detail "")
          :advice (and (eq status 'fail) (plist-get entry :advice)))))

(defun harness-provider-check--failure-result (entry error)
  "Return the result of check ENTRY that signalled ERROR.
A check that could not run because the account is out of quota or
money, was rate-limited, refused the credential or could not reach the
provider is a SKIP, with the safe explanation attached to the
condition.  Any other failure is a FAIL.  Do not print a provider's
error text in either case: a third-party plugin may have put its key in
it."
  (cond
   ((and (consp error) (eq (car error) 'harness-provider-check-unavailable))
    (list :id (plist-get entry :id)
          :suite (plist-get entry :suite)
          :name (plist-get entry :name)
          :status 'skip
          :detail (or (cadr error) "This check could not run against this account.")
          :advice nil))
   (t
    (let ((detail
           (cond
            ((and (consp error) (eq (car error) 'harness-provider-check-failure))
             (cadr error))
            ((and (consp error) (eq (car error) 'error) (stringp (cadr error)))
             (format "Provider raised error (details suppressed)"))
            (t
             (format "Provider raised %s (details suppressed)"
                     (if (consp error) (car error) error))))))
      (list :id (plist-get entry :id)
            :suite (plist-get entry :suite)
            :name (plist-get entry :name)
            :status 'fail
            :detail detail
            :advice (plist-get entry :advice))))))

(defun harness-provider-check--stage (job entry)
  "Run ENTRY as one check of JOB; return a promise of its result.
A failure of this check, and a timeout, become a FAIL result rather
than an error that would hide the checks after it."
  (let* ((name (plist-get entry :name))
         (promise (condition-case error
                      (harness-as-promise (funcall (plist-get entry :fn) job))
                    (error (harness-rejected error)))))
    (harness-then
     (harness-provider-check--timeout
      promise (+ harness-provider-check-timeout 5) name)
     (lambda (value) (harness-provider-check--result entry value))
     (lambda (error) (harness-provider-check--failure-result entry error)))))

(defun harness-provider-check--advance (job)
  "Run the next check of JOB, emit its result, and carry on."
  (cond
   ((harness-provider-check-job-finished job) nil)
   ((harness-provider-check-job-cancelled job)
    (harness-provider-check--finish job))
   ((null (harness-provider-check-job-pending job))
    (harness-provider-check--finish job))
   (t
    (let ((entry (pop (harness-provider-check-job-pending job))))
      (harness-then
       (harness-provider-check--stage job entry)
       (lambda (result)
         (unless (harness-provider-check-job-cancelled job)
           (push result (harness-provider-check-job-results job))
           (cl-incf (harness-provider-check-job-completed job))
           (harness-emit 'provider-check/result
                         (harness-provider-check-job-id job)
                         result
                         (harness-provider-check-job-completed job)
                         (harness-provider-check-job-total job)))
         (harness-provider-check--advance job)
         nil)
       (lambda (error)
         (harness-log 'error "provider-check: %s stopped: %S"
                      (harness-provider-check-job-id job) error)
         (harness-provider-check--finish job)))))))

(defun harness-provider-check--summary (job results)
  "Return the summary plist of JOB with RESULTS."
  (list :pass (cl-count 'pass results :key (lambda (r) (plist-get r :status)))
        :fail (cl-count 'fail results :key (lambda (r) (plist-get r :status)))
        :skip (cl-count 'skip results :key (lambda (r) (plist-get r :status)))
        :completed (harness-provider-check-job-completed job)
        :total (harness-provider-check-job-total job)
        :cancelled (and (harness-provider-check-job-cancelled job) t)
        :seconds (max 0 (- (float-time)
                           (harness-provider-check-job-started-at job)))))

(defun harness-provider-check--finish (job)
  "Finish JOB, announce its results and resolve its promise."
  (unless (harness-provider-check-job-finished job)
    (setf (harness-provider-check-job-finished job) t
          (harness-provider-check-job-handle job) nil
          (harness-provider-check-job-abort job) nil)
    (remhash (harness-provider-check-job-id job) harness-provider-check--jobs)
    (let* ((results (nreverse (harness-provider-check-job-results job)))
           (summary (harness-provider-check--summary job results)))
      (harness-emit 'provider-check/finished
                    (harness-provider-check-job-id job)
                    (harness-provider-check-job-model job)
                    results summary)
      (harness-resolve (harness-provider-check-job-promise job) results))))

(defun harness-provider-check-cancel (id)
  "Cancel the check job ID, if it runs; return non-nil when it was found.
The request in flight is cancelled, the remaining checks are not run,
and the job finishes with the results it has.  A job between two checks
has no handle to cancel, so it finishes at once instead."
  (let ((job (gethash id harness-provider-check--jobs)))
    (when job
      (setf (harness-provider-check-job-cancelled job) t)
      (let ((abort (harness-provider-check-job-abort job)))
        (if (functionp abort)
            (funcall abort)
          (harness-provider-check--finish job)))
      t)))

(defun harness-provider-check-start (model &optional suite embedding-model job-id)
  "Start live checks of MODEL; return the `harness-provider-check-job'.
SUITE is `provider', `model' or `all' (the default).  EMBEDDING-MODEL
checks the optional embed hook.  JOB-ID lets a caller name the job, so
that events arriving before this returns still name the right one.  The
job's promise resolves with its results, in running order.  This makes
real API requests: only `harness-provider-check' and its UI call it."
  (let* ((suite (cond ((null suite) 'all)
                      ((stringp suite) (intern suite))
                      (t suite)))
         (job-id (or (and (stringp job-id) (not (string-empty-p job-id)) job-id)
                     (format "provider-check-%s" (harness-uuid)))))
    (unless (memq suite harness-provider-check-suites)
      (error "Unknown provider-check suite: %s" suite))
    (let* ((plan (harness-provider-check--plan suite))
           (job (make-harness-provider-check-job
                 :id job-id
                 :model model
                 :suite suite
                 :embedding-model embedding-model
                 :plan plan
                 :pending (copy-sequence plan)
                 :completed 0
                 :total (length plan)
                 :promise (harness-make-promise)
                 :started-at (float-time))))
      (puthash job-id job harness-provider-check--jobs)
      (harness-emit 'provider-check/started job-id model suite
                    (harness-provider-check-job-total job)
                    (harness-provider-check--plan-summary plan))
      (harness-run-soon #'harness-provider-check--advance job)
      job)))

(harness-defmethod provider/check-start (model &optional suite embedding-model job)
  "Start live provider and model checks of MODEL; return the job.
SUITE is \"provider\", \"model\" or \"all\".  EMBEDDING-MODEL checks the
optional embed hook.  JOB is an id the caller chooses, so events that
arrive before this answer still name the right job.

The checks run in the background.  Each result is announced as
`provider-check/result'; `provider-check/finished' carries them all.
They make real, paid model requests: this is the method behind
`harness-provider-check', not a routine call."
  (let* ((suite (cond ((null suite) 'all)
                      ((stringp suite) (intern suite))
                      (t suite)))
         (job-id (or (and (stringp job) (not (string-empty-p job)) job)
                     (format "provider-check-%s" (harness-uuid))))
         (started (harness-provider-check-start model suite embedding-model job-id)))
    (list :job job-id
          :model model
          :suite suite
          :total (harness-provider-check-job-total started)
          :checks (harness-provider-check--plan-summary
                   (harness-provider-check-job-plan started)))))

(harness-defmethod provider/check-cancel (job)
  "Cancel the live provider check JOB; non-nil when it was running."
  (and (stringp job) (harness-provider-check-cancel job) t))

;;;; Following a job

(harness-declare-event 'provider-check/started
                       "(JOB MODEL SUITE TOTAL CHECKS) before the first check of JOB runs.")
(harness-declare-event 'provider-check/result
                       "(JOB RESULT COMPLETED TOTAL) after each check of JOB settles.")
(harness-declare-event 'provider-check/finished
                       "(JOB MODEL RESULTS SUMMARY) when JOB ends, cancelled or done.")

(defvar harness-acp-extra-events nil)
(add-to-list 'harness-acp-extra-events 'provider-check/started)
(add-to-list 'harness-acp-extra-events 'provider-check/result)
(add-to-list 'harness-acp-extra-events 'provider-check/finished)

(defun harness-provider-check--init ()
  "Cancel checks that the code a reload replaces would leave half-run."
  (dolist (id (hash-table-keys harness-provider-check--jobs))
    (harness-provider-check-cancel id)))

(harness-define-module 'provider-check
  :doc "Live checks of a provider's contract and a model's harness skills, run from the harness."
  :requires '(provider)
  :init #'harness-provider-check--init)

(provide 'harness-provider-check)
;;; harness-provider-check.el ends here
