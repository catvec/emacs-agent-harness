;;; harness-thread-model.el --- A local reflex that reads a workspace message -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The workspace router (`harness-workspace--route') places a message by
;; its words: each thread is a small document, and a message is ranked
;; against them.  That rule is local, instant and free, and it is right
;; about most messages -- which is why it is still the first thing the
;; router does.  It is wrong in one way that matters: a message that
;; shares a word with the thread it arrived in continues it, even when
;; the person changed subject, and a message that shares none of its
;; words with the thread it belongs to starts a new one.
;;
;; This module is a reflex in front of that rule.  A small open-weight
;; encoder (`harness-thread-model-directory'), fine-tuned on labelled
;; workspace messages (scripts/thread-model/), reads the incoming
;; message with the current thread and the knowledge blocks that were
;; available at decision time, and answers one number: the probability
;; that the message continues the current thread.  The router asks it
;; when `harness-workspace-thread-model' is on, and reads the number
;; with its own policy (`harness-thread-model-trust'): at or above it
;; the message continues, at or below one minus it the message does not,
;; and between them the model says nothing and the router keeps its own
;; rule.
;;
;; The number is one question, not two.  "Does not continue this thread"
;; is not "belongs to that other thread": which other thread, or none,
;; is a decision about the threads themselves, and it stays with the
;; router.  A model asked to name another thread would be answering a
;; question its input does not contain.
;;
;; The number is not a boolean because the two mistakes cost differently.
;; A wrong switch moves a message the person did not move, or starts a
;; thread for a subject that had one; a missed switch leaves a new
;; subject in the old thread, where the person can still move it.  One
;; threshold cannot be both, so the module has two, and a message the
;; model is sure of neither way costs only the word rule it would have
;; had anyway.
;;
;; The model is a subprocess, started on the first decision and kept
;; warm (`scripts/thread-model/predict.py', a JSON-lines server): loading
;; a 22M-parameter encoder takes about two and a half seconds, and a
;; routing decision happens while the person is typing.  A process that
;; dies is started again on the next call, and a call that waits longer
;; than `harness-thread-model-timeout' is left to the router's own rule.
;; With no model on the machine the module does nothing at all: the
;; workspace works as it did, and `harness-thread-model-status' says what
;; is missing.
;;
;; What the module does not do: it never overrides an explicit signal.
;; A thread the person named, a `/new', a client that bound the thread, a
;; message that says continue and a message the person moved by hand all
;; decide before the model is asked, and the model's answer is only
;; weighed where the router's own ranking is.  The manual reassignment
;; (`workspace/reassign') is the person's answer about a message already
;; sent, and nothing here touches it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defgroup harness-thread-model nil
  "A local reflex that reads a workspace message before the router places it."
  :group 'harness
  :prefix "harness-thread-model-")

(defcustom harness-thread-model-enabled t
  "Whether the reflex answers for a message the workspace router places.
A nil value asks no model and starts nothing; the tool and
`harness-thread-model-status' still work."
  :type 'boolean
  :group 'harness-thread-model)

(defcustom harness-thread-model-model-directory
  (expand-file-name "thread-model" (or (bound-and-true-p harness-state-directory)
                                       "~/.local/share/harness/"))
  "Directory of the fine-tuned model, as `train.py' wrote it.
It holds the encoder's weights, its tokenizer and `training.json'.
`harness-thread-model-status' says whether one is there, and
`scripts/thread-model/train.py' makes one."
  :type 'directory
  :group 'harness-thread-model)

(defcustom harness-thread-model-python "python3"
  "Interpreter that runs the predictor.
It needs torch and transformers, as `scripts/thread-model/requirements.txt'
lists them."
  :type 'string
  :group 'harness-thread-model)

(defcustom harness-thread-model-script
  (expand-file-name "scripts/thread-model/predict.py"
                    (or (bound-and-true-p harness-source-directory)
                        default-directory))
  "Path of the predictor the module runs."
  :type 'file
  :group 'harness-thread-model)

(defcustom harness-thread-model-trust 0.9
  "How sure the model must be before the router takes its reading.
At or above it the message continues the thread, at or below one minus
it the message does not, and between them the reflex says nothing and
the router's own rule decides.  `scripts/thread-model/evaluate.py'
reports what each value would have decided, and how often wrongly."
  :type 'number
  :group 'harness-thread-model)

(defcustom harness-thread-model-context 6
  "Messages of the current thread the model reads.
The thread's most recent messages come first in the text, then the
message being placed.  `scripts/thread-model/evaluate.py' reports what
the model does with fewer."
  :type 'integer
  :group 'harness-thread-model)

(defcustom harness-thread-model-knowledge 3
  "Knowledge blocks of the workspace the model reads, the nearest first.
They are what `knowledge/recall' returned for the message at decision
time; a workspace with no graph, or a search that failed, gives none and
the model reads the message without them."
  :type 'integer
  :group 'harness-thread-model)

(defcustom harness-thread-model-timeout 2.0
  "Seconds the reflex may take before the message goes to the word rule.
A model that has to load its weights takes longer than this the first
time; that message is placed by the words, and the next one is answered."
  :type 'number
  :group 'harness-thread-model)

(defcustom harness-thread-model-start-timeout 60.0
  "Seconds the predictor may take to load its model.
It answers the first request only once the weights are in memory, so
this is the load time, not the decision's."
  :type 'number
  :group 'harness-thread-model)

(defcustom harness-thread-model-thresholds t
  "Whether the reflex may move a message out of the current thread.
Nil keeps the reflex's `continue' reading only: it can confirm that a
message continues, and never starts a thread or moves a message to
another one.  That is the conservative setting for a workspace whose
threads a person keeps by hand."
  :type 'boolean
  :group 'harness-thread-model)

;;;; The predictor

(cl-defstruct (harness-thread-model--server (:copier nil))
  process
  buffer
  (pending (make-hash-table :test 'eql))  ; request id -> its wait
  (next-id 0)
  (partial ""))  ; a line of output not yet ended

(cl-defstruct (harness-thread-model--wait (:copier nil))
  promise
  timer)

(defvar harness-thread-model--server nil
  "The running predictor, or nil.")

(defun harness-thread-model-available-p ()
  "Non-nil when a trained model and the predictor are both on this machine."
  (and (file-exists-p (expand-file-name "config.json" harness-thread-model-model-directory))
       (file-exists-p harness-thread-model-script)))

(defun harness-thread-model--fail (wait value)
  "Settle WAIT's promise with VALUE, once."
  (when wait
    (when (harness-thread-model--wait-timer wait)
      (cancel-timer (harness-thread-model--wait-timer wait))
      (setf (harness-thread-model--wait-timer wait) nil))
    (harness-resolve (harness-thread-model--wait-promise wait) value)))

(defun harness-thread-model--answer (server line)
  "Answer the request LINE holds, in SERVER's protocol."
  (let* ((reply (condition-case nil (harness-json-parse line) (error nil)))
         (id (and (listp reply) (plist-get reply :id)))
         (wait (and id (gethash id (harness-thread-model--server-pending server)))))
    (when wait
      (remhash id (harness-thread-model--server-pending server))
      (harness-thread-model--fail
       wait
       (if (and (listp reply) (plist-get reply :error))
           (list :status 'error :message (format "%s" (plist-get reply :error)))
         (list :status 'ok :prob (plist-get reply :prob)))))))

(defun harness-thread-model--filter (server _process text)
  "Read the newline-delimited replies TEXT brings SERVER."
  (let ((pending (concat (harness-thread-model--server-partial server) text)))
    ;; A predictor that answers in something other than lines is not one
    ;; this protocol can read; drop it rather than grow a buffer.
    (if (> (length pending) 65536)
        (harness-thread-model-stop)
      (while (string-match "\n" pending)
        (let ((line (substring pending 0 (match-beginning 0))))
          (setq pending (substring pending (match-end 0)))
          (unless (string-blank-p line)
            (harness-thread-model--answer server line))))
      (setf (harness-thread-model--server-partial server) pending))))

(defun harness-thread-model-stop ()
  "Stop the predictor, if one is running."
  (when harness-thread-model--server
    (let ((server harness-thread-model--server))
      (setq harness-thread-model--server nil)
      (maphash (lambda (_id wait) (harness-thread-model--fail wait '(:status stopped)))
               (harness-thread-model--server-pending server))
      (clrhash (harness-thread-model--server-pending server))
      (when (process-live-p (harness-thread-model--server-process server))
        (delete-process (harness-thread-model--server-process server))))))

(defun harness-thread-model--sentinel (server _process event)
  "Notice SERVER's predictor dying, and settle what waited on it."
  (unless (string-prefix-p "open" event)
    (when (eq server harness-thread-model--server)
      (setq harness-thread-model--server nil))
    (maphash (lambda (_id wait)
               (harness-thread-model--fail wait (list :status 'error :message event)))
             (harness-thread-model--server-pending server))
    (clrhash (harness-thread-model--server-pending server))))

(defun harness-thread-model--start ()
  "Start the predictor and return its SERVER, or nil when it cannot start."
  (let ((buffer (generate-new-buffer " *harness-thread-model*" t)))
    (condition-case err
        (let ((process (make-process
                        :name "harness-thread-model"
                        :command (list harness-thread-model-python
                                       harness-thread-model-script
                                       "--model" harness-thread-model-model-directory)
                        :coding 'utf-8-unix :connection-type 'pipe :noquery t
                        :buffer buffer
                        :stderr buffer
                        :filter (lambda (proc text)
                                  (harness-thread-model--filter
                                   (process-get proc 'server) proc text))
                        :sentinel (lambda (proc event)
                                    (harness-thread-model--sentinel
                                     (process-get proc 'server) proc event)))))
          (setq harness-thread-model--server
                (make-harness-thread-model--server :process process :buffer buffer))
          (process-put process 'server harness-thread-model--server)
          harness-thread-model--server)
      (error
       (kill-buffer buffer)
       (harness-log 'warn "thread-model: cannot start the predictor: %s"
                    (harness-error-message err))
       nil))))

(defun harness-thread-model--live-server ()
  "Return the running predictor, or nil."
  (and harness-thread-model--server
       (process-live-p (harness-thread-model--server-process harness-thread-model--server))
       harness-thread-model--server))

(defun harness-thread-model--server-for-request ()
  "Return a live predictor, starting one when there is none."
  (or (harness-thread-model--live-server)
      (harness-thread-model--start)))

(defun harness-thread-model-classify (text &optional timeout)
  "Return a promise of the model's reading of TEXT.
The value is (:status ok :prob P), P the probability that the message
continues the current thread, or (:status error, stopped, timeout
:message WHY).  TIMEOUT defaults to `harness-thread-model-start-timeout'
while the predictor is loading its weights, and to
`harness-thread-model-timeout' after that."
  (let* ((promise (harness-make-promise))
         (server (harness-thread-model--server-for-request)))
    (if (not server)
        (progn (harness-resolve promise '(:status error :message "no predictor"))
               promise)
      (let* ((id (cl-incf (harness-thread-model--server-next-id server)))
             (wait (make-harness-thread-model--wait :promise promise))
             (seconds (or timeout
                          (if (= 1 (harness-thread-model--server-next-id server))
                              harness-thread-model-start-timeout
                            harness-thread-model-timeout))))
        (puthash id wait (harness-thread-model--server-pending server))
        (setf (harness-thread-model--wait-timer wait)
              (run-at-time seconds nil
                           (lambda ()
                             (when (gethash id (harness-thread-model--server-pending server))
                               (remhash id (harness-thread-model--server-pending server))
                               (harness-log 'warn "thread-model: the predictor took longer than %ss" seconds)
                               (harness-thread-model--fail wait '(:status timeout))))))
        (condition-case err
            (process-send-string
             (harness-thread-model--server-process server)
             (concat (harness-json-encode (list :id id :text text)) "\n"))
          (error
           (remhash id (harness-thread-model--server-pending server))
           (harness-thread-model--fail wait (list :status 'error
                                                  :message (harness-error-message err)))))
        promise))))

;;;; What the model reads

(defconst harness-thread-model-message-chars 1200
  "Characters of the message being placed the model reads.
It matches `schema.MESSAGE_CHARS', which rendered the training data: a
model asked in another shape reads another distribution.")

(defconst harness-thread-model-context-chars 700
  "Characters of one earlier message the model reads.
It matches `schema.CONTEXT_CHARS'.")

(defconst harness-thread-model-knowledge-chars 300
  "Characters of one knowledge block the model reads.
It matches `schema.KNOWLEDGE_CHARS'.")

(defconst harness-thread-model-title-chars 200
  "Characters of the thread's title the model reads.")

(defun harness-thread-model--line (text limit)
  "Return TEXT as one line of at most LIMIT characters, as the schema does."
  (let ((text (if (stringp text) text (format "%s" (or text "")))))
    (setq text (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))
    (if (> (length text) limit)
        (concat (string-trim (substring text 0 (1- limit))) "…")
      text)))

(defun harness-thread-model--role (message)
  "Return MESSAGE's role as the schema names it: `user' or `assistant'."
  (let ((role (plist-get message :role)))
    (cond ((memq role '(user assistant)) (symbol-name role))
          ((member role '("user" "assistant")) role)
          (t "user"))))

(defun harness-thread-model-render (&rest args)
  "Return the text the model reads, from ARGS as a plist.
ARGS names `:task' (the workspace's name), `:title' (the thread's),
`:context' (messages oldest first, each `(:role R :text T)'),
`:knowledge' (block texts, nearest first), `:sender' and `:message'
(the text being placed).

The shape is `schema.render_case' exactly: the same lines, in the same
order, with the same limits.  A training run and a live decision read
one shape, which is the only reason a model trained here is worth
running there."
  (let* ((context (cl-remove-if-not
                   (lambda (message)
                     (member (harness-thread-model--role message) '("user" "assistant")))
                   (or (plist-get args :context) nil)))
         (context (if (> harness-thread-model-context 0)
                      (last context (min (length context) harness-thread-model-context))
                    nil))
         (knowledge (cl-remove-if
                     (lambda (block) (string-blank-p (or block "")))
                     (cl-subseq (or (plist-get args :knowledge) nil) 0
                                (min (length (or (plist-get args :knowledge) nil))
                                     (max 0 harness-thread-model-knowledge)))))
         (title (harness-thread-model--line (or (plist-get args :title) "")
                                            harness-thread-model-title-chars))
         (task (harness-thread-model--line (or (plist-get args :task) "") 200))
         (sender (harness-thread-model--line (or (plist-get args :sender) "") 60))
         (lines nil))
    (when (not (string-blank-p task))
      (push (format "Task: %s" task) lines))
    (push (if (string-blank-p title)
              "Current thread: (untitled)"
            (format "Current thread: %s" title))
          lines)
    (when context
      (push "Thread so far:" lines)
      (dolist (message context)
        (push (format "- %s: %s" (harness-thread-model--role message)
                      (harness-thread-model--line (plist-get message :text)
                                                  harness-thread-model-context-chars))
              lines)))
    (when knowledge
      (push "Knowledge:" lines)
      (dolist (block knowledge)
        (push (format "- %s" (harness-thread-model--line block
                                                         harness-thread-model-knowledge-chars))
              lines)))
    (when (not (string-blank-p sender))
      (push (format "Sender: %s" sender) lines))
    (push "Message to place:" lines)
    (push (format "- %s" (harness-thread-model--line
                          (or (plist-get args :message) "")
                          harness-thread-model-message-chars))
          lines)
    (mapconcat #'identity (nreverse lines) "\n")))

;;;; The decision

(defun harness-thread-model-verdict (prob)
  "Return the reflex's reading of PROB, the probability of continuing.
It is `continue', `switch', or nil for a message the model is sure of
neither way.  The two thresholds are `harness-thread-model-trust' and
one minus it, because a wrong switch and a missed switch cost
differently.

With `harness-thread-model-thresholds' nil the reflex may only confirm:
a sure `continue' is still read, and a sure `switch' is not, so a
workspace whose threads a person keeps by hand never has a message moved
out of the thread it was written in."
  (cond ((not (numberp prob)) nil)
        ((>= prob harness-thread-model-trust) 'continue)
        ((and harness-thread-model-thresholds
              (<= prob (+ (- 1 harness-thread-model-trust) 1e-9)))
         'switch)
        (t nil)))

(defun harness-thread-model--decide (text)
  "Return a promise of the reflex's verdict on TEXT, or nil.
The value is (:verdict VERDICT :prob P) or (:status STATUS :message WHY),
or nil when the reflex will not answer at all."
  (when (and harness-thread-model-enabled
             (harness-thread-model-available-p))
    (harness-then (harness-thread-model-classify
                   text
                   (unless (harness-thread-model--live-server)
                     harness-thread-model-start-timeout))
                  (lambda (answer)
                    (if (not (eq (plist-get answer :status) 'ok))
                        answer
                      (list :verdict (harness-thread-model-verdict
                                      (plist-get answer :prob))
                            :prob (plist-get answer :prob)))))))

(defun harness-thread-model-reading (text)
  "Return a promise of the reflex's reading of TEXT, or a resolved nil.
This is the whole surface the workspace router uses: a promise of
`(:verdict VERDICT :prob P)' or `(:status ...)'.  A caller that cannot
wait (`harness-thread-model-reading-sync') uses the blocking form."
  (or (harness-thread-model--decide text)
      (harness-resolved nil)))

(defun harness-thread-model-reading-sync (text &optional timeout)
  "Return the reflex's reading of TEXT, waiting at most TIMEOUT seconds.
It is (:verdict VERDICT :prob P), (:status ...), or nil when the reflex
is off, there is no model, or the wait ran out.  This blocks, so it is
for a caller that has already decided it can wait -- a tool, a test, or
a script -- and never the router, which asks and carries on."
  (let* ((promise (harness-thread-model--decide text))
         (deadline (+ (float-time) (or timeout 30.0)))
         (answer nil))
    (if (not promise)
        nil
      (harness-then promise (lambda (value) (setq answer (or value :none))))
      (while (and (null answer) (< (float-time) deadline))
        (accept-process-output nil 0.01))
      (if (eq answer :none) nil answer))))

;;;; The tool

(defun harness-thread-model--read-tool (input _ctx)
  "Handler of `thread_model_read': read a message as the reflex does."
  (let ((text (or (plist-get input :text)
                  (harness-thread-model-render
                   :task (plist-get input :task)
                   :title (plist-get input :thread)
                   :context (plist-get input :context)
                   :knowledge (plist-get input :knowledge)
                   :sender (plist-get input :sender)
                   :message (or (plist-get input :message) "")))))
    (if (not (harness-thread-model-available-p))
        (harness-tool-error (harness-thread-model-status))
      (let ((answer (harness-thread-model-reading-sync text
                                                       harness-thread-model-start-timeout)))
        (cond
         ((null answer)
          (harness-tool-error "thread-model: no reading"))
         ((not (eq (plist-get answer :status) 'ok))
          (harness-tool-error (format "thread-model: %s"
                                      (or (plist-get answer :message)
                                          (plist-get answer :status)))))
         (t
          (harness-tool-ok
           (format "%s\nprobability continue %.4f\nverdict %s"
                   text (plist-get answer :prob)
                   (or (plist-get answer :verdict) "undecided")))))))))

(harness-define-tool "thread_model_read"
  :label "Read a message"
  :description "Read a workspace message with the local thread-continuation model, without sending it: the probability that the message continues the current thread, and the reading the router makes of it."
  :kind 'meta
  :schema '(:type "object"
            :properties (:message (:type "string" :description "The message being placed.")
                         :thread (:type "string" :description "The current thread's title.")
                         :task (:type "string" :description "The workspace's name, when it has one.")
                         :context (:type "array" :description "Earlier messages of the thread, oldest first, each {role, text}.")
                         :knowledge (:type "array" :description "Knowledge blocks available at decision time, nearest first.")
                         :sender (:type "string" :description "Who sent the message.")
                         :text (:type "string" :description "The whole text to read, instead of the parts."))
            :required ("message"))
  :handler #'harness-thread-model--read-tool)

(defun harness-thread-model-status ()
  "Return one line on what the reflex can do here."
  (cond ((not harness-thread-model-enabled) "thread-model: off")
        ((not (file-exists-p (expand-file-name "config.json" harness-thread-model-model-directory)))
         "thread-model: no model")
        ((not (file-exists-p harness-thread-model-script))
         "thread-model: no predictor")
        (t (format "thread-model: ready · trust %.2f · context %d"
                   harness-thread-model-trust harness-thread-model-context))))

;;;; Module

(defun harness-thread-model--init ()
  "Nothing to hook: the module is asked for a reading, it never asks.
The predictor starts on the first decision the workspace router asks
for, and `harness-thread-model--shutdown' stops it."
  (ignore))

(defun harness-thread-model--shutdown ()
  "Take the module off the bus, and stop the predictor."
  (harness-thread-model-stop))

;; A reload does not initialise a running module again: nothing here
;; needs hooking, so there is nothing to add.

(harness-define-module 'thread-model
  :doc "A local reflex that reads a workspace message: a small fine-tuned encoder answers the probability that the message continues the current thread, and the workspace router weighs it where its own word rule ranks."
  :requires '(session tools)
  :init #'harness-thread-model--init
  :shutdown #'harness-thread-model--shutdown)

(provide 'harness-thread-model)
;;; harness-thread-model.el ends here
