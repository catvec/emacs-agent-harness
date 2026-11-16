;;; harness-system-one.el --- A local reflex that reads a tool call  -*- lexical-binding: t; -*-

;;; Commentary:

;; The permission chain asks a model what to do with a call it cannot
;; settle itself (see `harness-perms--auto'): a cheap model, one call at
;; a time, a few hundred milliseconds to a few seconds.  That is the
;; right reader for a hard call and far more than an ordinary one needs.
;;
;; This module is the reflex in front of it.  A small open-weight encoder
;; (`harness-system-one-model-directory'), fine-tuned on labelled workflows of tool
;; calls (scripts/system-one/), reads the last few calls of the turn with
;; the task they serve and answers one number: the probability that the
;; call being decided is safe work.  Above `harness-system-one-trust' it
;; allows the call; below one minus that it denies it; between the two it
;; says nothing and the chain goes on to the judge and the user, exactly
;; as it would have.
;;
;; The number is not a boolean because the two answers cost differently.
;; A wrong allow runs the call; a wrong deny stops work the user asked
;; for.  One threshold cannot be both, so the module has two, and a call
;; the model is sure of neither way costs only the judge call it would
;; have had anyway.
;;
;; The model is a subprocess, started on the first decision and kept
;; warm (`scripts/system-one/predict.py', a JSON-lines server): loading a
;; 22M-parameter encoder takes about a second, and a reflex that pays it
;; per call is not one.  A process that dies is restarted on the next
;; call, and a call that waits longer than
;; `harness-system-one-timeout' is left undecided.  With no model on the
;; machine the stage does nothing at all: the harness works as it did,
;; and `harness-system-one-status' says what is missing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defgroup harness-system-one nil
  "A local reflex that reads a tool call before the judge does."
  :group 'harness
  :prefix "harness-system-one-")

(defcustom harness-system-one-enabled t
  "Whether the reflex decides calls the permission chain left undecided.
A nil value leaves every call to the judge and the user, and starts
nothing; the tool and `harness-system-one-status' still work."
  :type 'boolean
  :group 'harness-system-one)

(defcustom harness-system-one-model-directory
  (expand-file-name "system-one" (or (bound-and-true-p harness-state-directory)
                                      "~/.local/share/harness/"))
  "Directory of the fine-tuned model, as `train.py' wrote it.
It holds the encoder's weights, its tokenizer and `training.json'.
`harness-system-one-status' says whether one is there, and
`scripts/system-one/train.py' makes one."
  :type 'directory
  :group 'harness-system-one)

(defcustom harness-system-one-python "python3"
  "Interpreter that runs the predictor.
It needs torch and transformers, as `scripts/system-one/requirements.txt'
lists them."
  :type 'string
  :group 'harness-system-one)

(defcustom harness-system-one-script
  (expand-file-name "scripts/system-one/predict.py"
                    (or (bound-and-true-p harness-source-directory)
                        default-directory))
  "Path of the predictor the module runs."
  :type 'file
  :group 'harness-system-one)

(defcustom harness-system-one-trust 0.95
  "How sure the model must be before the reflex decides a call.
Above it the call is allowed, below one minus it the call is denied, and
between them the reflex says nothing.  `scripts/system-one/evaluate.py'
reports what each value would have decided, and how often wrongly."
  :type 'number
  :group 'harness-system-one)

(defcustom harness-system-one-window 1
  "How many calls of the turn the model reads, the one decided last.
The turn's own calls come first and the call being decided after them;
the task line says what the turn is for.  `evaluate.py' picks the size
from the held-out data."
  :type 'integer
  :group 'harness-system-one)

(defcustom harness-system-one-timeout 2.0
  "Seconds the reflex may take before the call goes on undecided.
A model that has to load its weights takes longer than this the first
time; that call goes to the judge, and the next one is answered."
  :type 'number
  :group 'harness-system-one)

(defcustom harness-system-one-start-timeout 60.0
  "Seconds the predictor may take to load its model.
It answers the first request only once the weights are in memory, so
this is the load time, not the decision's."
  :type 'number
  :group 'harness-system-one)

;;;; The predictor

(cl-defstruct (harness-system-one--server (:copier nil))
  process
  buffer
  (pending (make-hash-table :test 'eql))  ; request id -> its wait
  (next-id 0)
  (partial ""))  ; a line of output not yet ended

(cl-defstruct (harness-system-one--wait (:copier nil))
  promise
  timer)

(defvar harness-system-one--server nil
  "The running predictor, or nil.")

(defun harness-system-one-available-p ()
  "Non-nil when a trained model and the predictor are both on this machine."
  (and (file-exists-p (expand-file-name "config.json" harness-system-one-model-directory))
       (file-exists-p harness-system-one-script)))

(defun harness-system-one--fail (wait why)
  "Settle WAIT's promise with WHY, once."
  (when wait
    (when (harness-system-one--wait-timer wait)
      (cancel-timer (harness-system-one--wait-timer wait))
      (setf (harness-system-one--wait-timer wait) nil))
    (harness-resolve (harness-system-one--wait-promise wait) why)))

(defun harness-system-one--answer (server line)
  "Answer the request LINE holds, in SERVER's protocol."
  (let* ((reply (condition-case nil (harness-json-parse line) (error nil)))
         (id (and (listp reply) (plist-get reply :id)))
         (wait (and id (gethash id (harness-system-one--server-pending server)))))
    (when wait
      (remhash id (harness-system-one--server-pending server))
      (harness-system-one--fail
       wait
       (if (and (listp reply) (plist-get reply :error))
           (list :status 'error :message (format "%s" (plist-get reply :error)))
         (list :status 'ok :prob (plist-get reply :prob)))))))

(defun harness-system-one--filter (server _process text)
  "Read the newline-delimited replies TEXT brings SERVER."
  (let ((pending (concat (harness-system-one--server-partial server) text)))
    ;; A predictor that answers in something other than lines is not one
    ;; this protocol can read; drop it rather than grow a buffer.
    (if (> (length pending) 65536)
        (harness-system-one-stop)
      (while (string-match "\n" pending)
        (let ((line (substring pending 0 (match-beginning 0))))
          (setq pending (substring pending (match-end 0)))
          (unless (harness-string-blank-p line)
            (harness-system-one--answer server line))))
      (setf (harness-system-one--server-partial server) pending))))

(defun harness-system-one-stop ()
  "Stop the predictor, if one is running."
  (when harness-system-one--server
    (let ((server harness-system-one--server))
      (setq harness-system-one--server nil)
      (maphash (lambda (_id wait) (harness-system-one--fail wait '(:status stopped)))
               (harness-system-one--server-pending server))
      (clrhash (harness-system-one--server-pending server))
      (when (process-live-p (harness-system-one--server-process server))
        (delete-process (harness-system-one--server-process server))))))

(defun harness-system-one--sentinel (server _process event)
  "Notice SERVER's predictor dying, and settle what waited on it."
  (unless (string-prefix-p "open" event)
    (when (eq server harness-system-one--server)
      (setq harness-system-one--server nil))
    (maphash (lambda (_id wait)
               (harness-system-one--fail wait (list :status 'error :message event)))
             (harness-system-one--server-pending server))
    (clrhash (harness-system-one--server-pending server))))

(defun harness-system-one--start ()
  "Start the predictor and return its SERVER, or nil when it cannot start."
  (let ((buffer (generate-new-buffer " *harness-system-one*" t)))
    (condition-case err
        (let ((process (make-process
                        :name "harness-system-one"
                        :command (list harness-system-one-python
                                       harness-system-one-script
                                       "--model" harness-system-one-model-directory)
                        :coding 'utf-8-unix :connection-type 'pipe :noquery t
                        :buffer buffer
                        :stderr buffer
                        :filter (lambda (proc text)
                                  (harness-system-one--filter
                                   (process-get proc 'server) proc text))
                        :sentinel (lambda (proc event)
                                    (harness-system-one--sentinel
                                     (process-get proc 'server) proc event)))))
          (setq harness-system-one--server
                (make-harness-system-one--server :process process :buffer buffer))
          (process-put process 'server harness-system-one--server)
          harness-system-one--server)
      (error
       (kill-buffer buffer)
       (harness-log 'warn "system-one: cannot start the predictor: %s"
                    (harness-error-message err))
       nil))))

(defun harness-system-one--live-server ()
  "Return the running predictor, or nil."
  (and harness-system-one--server
       (process-live-p (harness-system-one--server-process harness-system-one--server))
       harness-system-one--server))

(defun harness-system-one--server-for-request ()
  "Return a live predictor, starting one when there is none."
  (or (harness-system-one--live-server)
      (harness-system-one--start)))

(defun harness-system-one-classify (text &optional timeout)
  "Return a promise of the model's reading of TEXT.
The value is (:status ok :prob P), P the probability that the call is
safe work, or (:status error, stopped, timeout :message WHY).  TIMEOUT
defaults to `harness-system-one-start-timeout' while the predictor is
loading its weights, and to `harness-system-one-timeout' after that."
  (let* ((promise (harness-make-promise))
         (server (harness-system-one--server-for-request)))
    (if (not server)
        (progn (harness-resolve promise '(:status error :message "no predictor"))
               promise)
      (let* ((id (cl-incf (harness-system-one--server-next-id server)))
             (wait (make-harness-system-one--wait :promise promise))
             (seconds (or timeout
                          (if (zerop (harness-system-one--server-next-id server))
                              harness-system-one-start-timeout
                            harness-system-one-timeout))))
        (puthash id wait (harness-system-one--server-pending server))
        (setf (harness-system-one--wait-timer wait)
              (run-at-time seconds nil
                           (lambda ()
                             (when (gethash id (harness-system-one--server-pending server))
                               (remhash id (harness-system-one--server-pending server))
                               (harness-log 'warn "system-one: the predictor took longer than %ss" seconds)
                               (harness-system-one--fail wait '(:status timeout))))))
        (condition-case err
            (process-send-string
             (harness-system-one--server-process server)
             (concat (harness-json-encode (list :id id :text text)) "\n"))
          (error
           (remhash id (harness-system-one--server-pending server))
           (harness-system-one--fail wait (list :status 'error
                                                :message (harness-error-message err)))))
        promise))))

;;;; What the model reads

(defconst harness-system-one-arg-limit 300
  "Characters of one argument the model reads; the rest is cut.
It matches `scripts/system-one/schema.py', which rendered the training
data: a model asked in another shape reads another distribution.")

(defun harness-system-one--arg-text (value)
  "Return VALUE as the one line the training data rendered."
  (let ((text (if (stringp value)
                  value
                (if (fboundp 'json-serialize)
                    (condition-case nil
                        (decode-coding-string
                         (json-serialize (or value :null)) 'utf-8)
                      (error (format "%s" value)))
                  (format "%s" value)))))
    (setq text (string-trim (replace-regexp-in-string "[ 	
]+" " " text)))
    (if (> (length text) harness-system-one-arg-limit)
        (concat (substring text 0 harness-system-one-arg-limit) "...")
      text)))

(defun harness-system-one--keyword-pairs-p (input)
  "Non-nil when INPUT is a plist: a list whose keys are all keywords."
  (and (consp input)
       (cl-loop for (key _value) on input by #'cddr
                always (keywordp key))))

(defun harness-system-one--render-call (call)
  "Return CALL, a (TOOL . INPUT) pair, as the training data wrote it.
A call renders as `tool(key=value key=value)', the arguments in the
order the input holds them, which is what `schema.render_call' does.

An INPUT the model cannot read as a plist -- an alist, a nested list, a
string -- is rendered whole rather than dropped: a call printed as
`bash()' when it does carry a command would be read as a call with
nothing to run, which is the one misreading that makes harm look
safe."
  (let* ((tool (car call))
         (input (cdr call))
         (parts (and (harness-system-one--keyword-pairs-p input)
                     (cl-loop for (key value) on input by #'cddr
                              collect (format "%s=%s" (substring (symbol-name key) 1)
                                              (harness-system-one--arg-text value))))))
    (cond (parts (format "%s(%s)" tool (string-join parts " ")))
          ((null input) (format "%s()" tool))
          (t (format "%s(input=%s)" tool (harness-system-one--arg-text input))))))

(defun harness-system-one--render (task context call)
  "Return the decision text for CALL, given the earlier calls and TASK.
It is the shape `schema.render_decision' wrote the training data in: the
task, the calls already made, then the call being decided, set apart
because it is the one the answer is about."
  (concat (format "Task: %s
" (string-trim (replace-regexp-in-string
                                             "[ 	
]+" " " (or task ""))))
          (when context
            (concat "Earlier calls in this turn:
"
                    (mapconcat (lambda (c) (concat "- " (harness-system-one--render-call c)))
                               context "
")
                    "
"))
          "Call to decide:
"
          (format "- %s" (harness-system-one--render-call call))))

;;;; The decision

(defun harness-system-one--recent-calls (session-id)
  "Return the last few calls of SESSION-ID's turn, oldest first.
They are the tool calls of the session's current turn, which is what the
model was trained to read before the call it decides.  A session with no
history, or a session the harness does not know, gives nil: the call is
then read with the task alone, which is what a first call is."
  (when (and session-id (harness-method-exists-p 'session/nodes))
    (condition-case nil
        (let* ((nodes (harness-call 'session/nodes session-id '(:kinds (tool-call))))
               (calls (cl-loop for node in (append nodes nil)
                               for tool = (plist-get node :tool)
                               when (and (stringp tool) (not (harness-string-blank-p tool)))
                               collect (cons tool (plist-get node :input)))))
          (last calls (max 0 (1- harness-system-one-window))))
      (error nil))))

(defun harness-system-one--task (request)
  "Return what the turn of REQUEST is for, in one line.
A session's name is the task its user gave it, which is the same thing a
workflow's task line holds in the training data."
  (let* ((session (plist-get request :session))
         (name (plist-get session :name)))
    (if (and (stringp name) (not (harness-string-blank-p name)))
        name
      (or (plist-get session :cwd) default-directory))))

(defun harness-system-one-text (request)
  "Return the text the model reads to decide REQUEST.
The request is the call being decided, with the calls of the turn before
it: `harness-system-one--render' writes it in the training data's shape."
  (harness-system-one--render
   (harness-system-one--task request)
   (harness-system-one--recent-calls (plist-get (plist-get request :session) :id))
   (cons (plist-get request :tool) (plist-get request :input))))

(defun harness-system-one-verdict (prob)
  "Return the reflex's reading of PROB, the probability a call is safe.
It is (:behavior allow), (:behavior deny), or nil for a call the model is
sure of neither way.  The two thresholds are `harness-system-one-trust'
and one minus it, because a wrong allow and a wrong deny cost
differently: one runs a call that should not have run, the other stops
work the user asked for."
  (cond ((not (numberp prob)) nil)
        ((>= prob harness-system-one-trust) '(:behavior allow))
        ((<= prob (+ (- 1 harness-system-one-trust) 1e-9)) '(:behavior deny))
        (t nil)))

(defun harness-system-one--decision (answer)
  "Return the chain's decision from ANSWER, the model's reading.
It is nil when the model gave no probability or was sure of neither
way, and otherwise an allow or a deny with the model's confidence in it
and the reading in its reason."
  (when (eq (plist-get answer :status) 'ok)
    (let* ((prob (plist-get answer :prob))
           (verdict (harness-system-one-verdict prob))
           (allow (eq (plist-get verdict :behavior) 'allow))
           (confidence (if allow prob (- 1 prob))))
      (when verdict
        (append verdict
                (list :final t :by 'system-one :confidence confidence
                      :reason (format "%s by the local classifier (%.3f)"
                                      (if allow "allowed" "denied") confidence)))))))

(defun harness-system-one--decide (request)
  "Return a promise of the reflex's decision on REQUEST, or nil.
The value is a decision plist for the permission chain, or nil when the
reflex will not decide the call."
  (when (and harness-system-one-enabled
             (harness-system-one-available-p))
    ;; A predictor that is starting loads its weights before it answers,
    ;; so the first call of a process gets the load time, not the
    ;; decision's: it is the load that is slow, not the model.
    (harness-then (harness-system-one-classify
                   (harness-system-one-text request)
                   (unless (harness-system-one--live-server)
                     harness-system-one-start-timeout))
                  #'harness-system-one--decision)))

;;;; The permission stage

(defun harness-system-one--gate (decision next request)
  "A `permission/decide' stage: decide REQUEST when the reflex is sure.
It runs at 25, after the mode stage (20) has allowed what the mode
allows and before the judge (30) is asked, so the reflex sees exactly
the calls that would otherwise cost a model call.  A call it is not sure
of, a predictor that is slow or dead, and a call made with the reflex
off all go on with DECISION, which is what the chain would have decided
without this module."
  (if (not (eq (plist-get decision :behavior) 'ask))
      (funcall next decision)
    ;; What the request waits is the load time of a predictor that is not
    ;; running yet, and the decision's own after that.  It is read before
    ;; `harness-system-one--decide', which starts the predictor: asked
    ;; afterwards, every first call would look like a warm one.
    (let* ((starting (not (harness-system-one--live-server)))
           (patience (if starting
                         harness-system-one-start-timeout
                       harness-system-one-timeout))
           (promise (harness-system-one--decide request)))
      (if (not promise)
          (funcall next decision)
        ;; The chain runs once, whichever of the two answers first: the
        ;; model, or the timer that gives up on it.  SETTLED is a cons so
        ;; that both closures see the same cell: a `let' binding's init
        ;; form cannot see the binding beside it.
        ;; The guard is a second past whatever the request itself
        ;; waits.  It is only for a promise that somehow never settles;
        ;; the request's own timer settles it first.
        (let ((settled (list nil)))
          (cl-flet ((finish (d)
                      (unless (car settled)
                        (setcar settled t)
                        (funcall next (or d decision)))))
            (harness-then promise #'finish)
            (run-at-time (+ patience 1.0) nil
                         (lambda ()
                           (when (not (car settled))
                             (harness-log 'warn "system-one: no reading of %s in time"
                                          (plist-get request :tool))
                             (finish nil)))))
          nil)))))

;;;; The tool


(defun harness-system-one--classify-tool (input _ctx)
  "Handler of `system_one_classify': read a call as the reflex does."
  (let ((text (or (plist-get input :text)
                  (harness-system-one--render
                   "" nil
                   (cons (or (plist-get input :tool) "") (plist-get input :input))))))
    (if (not (harness-system-one-available-p))
        (harness-tool-error (harness-system-one-status))
      (harness-then
       (harness-system-one-classify text harness-system-one-start-timeout)
       (lambda (answer)
         (if (not (eq (plist-get answer :status) 'ok))
             (harness-tool-error (format "the classifier gave no reading: %s"
                                         (or (plist-get answer :message)
                                             (plist-get answer :status))))
           (let* ((prob (plist-get answer :prob))
                  (verdict (harness-system-one-verdict prob)))
             (harness-tool-ok
              (format "%s\nprobability safe %.4f\nverdict %s"
                      text prob
                      (if verdict (plist-get verdict :behavior) "undecided"))))))))))

(harness-define-tool "system_one_classify"
  :label "Classify a call"
  :description "Read a tool call with the local system-one classifier, without running it: the probability that the call is safe work, and the decision the reflex makes of it."
  :kind 'meta
  :schema '(:type "object"
            :properties (:tool (:type "string" :description "The tool's name, such as bash.")
                         :input (:type "object" :description "The call's input, as the tool takes it.")
                         :text (:type "string" :description "The whole text to read, instead of a tool and input."))
            :required ("tool"))
  :handler #'harness-system-one--classify-tool)

(defun harness-system-one-status ()
  "Return one line on what the reflex can do here."
  (cond ((not harness-system-one-enabled) "system-one: off")
        ((not (file-exists-p (expand-file-name "config.json" harness-system-one-model-directory)))
         "system-one: no model")
        ((not (file-exists-p harness-system-one-script))
         "system-one: no predictor")
        (t (format "system-one: ready · trust %.2f · window %d"
                   harness-system-one-trust harness-system-one-window))))

;;;; Module

(defun harness-system-one--init ()
  "Hook the module into the bus (idempotent)."
  (harness-add-filter 'permission/decide #'harness-system-one--gate 25))

(defun harness-system-one--shutdown ()
  "Take the module off the bus, and stop the predictor."
  (harness-remove-filter 'permission/decide #'harness-system-one--gate)
  (harness-system-one-stop))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'system-one)
  (harness-system-one--init))

(harness-define-module 'system-one
  :doc "A local reflex that reads a tool call: a small fine-tuned encoder answers whether the call is safe work, above a trust threshold it allows or denies it, and between them it leaves the call to the judge and the user."
  :requires '(session tools perms)
  :init #'harness-system-one--init
  :shutdown #'harness-system-one--shutdown)

(provide 'harness-system-one)
;;; harness-system-one.el ends here
