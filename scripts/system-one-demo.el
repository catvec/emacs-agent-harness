;;; -*- lexical-binding: t; -*-
;;; harness-provider-system-one-demo --- one System One contract, three models  -*- lexical-binding: t; -*-

;;; This file is part of the Emacs agent harness.

;;; Commentary:

;; A demo of the System One capability: two providers that answer it --
;; the System One API (TypeSafe's Jev) over a stub transport, and the
;; deterministic fixture -- put one request to the same contract, and a
;; third provider declares both System One and completions, which is the
;; point: the capability is one a model may declare, not a kind of
;; provider it must be.  Then the refusals: a question type the model does
;; not answer, an answer that is not what its question asked, a request
;; with no content, and the artifact a model ships.  Nothing touches the
;; network.  See docs/provider-system-one.md.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-provider-system-one)
(require 'harness-provider)

(defvar harness-provider-system-one-demo--fixture
  (expand-file-name "test/fixtures/system-one" harness-test-root)
  "The fixture directory the training side and the inference side share.")

(defconst harness-provider-system-one-demo--state
  "Yes, run it, and tell me when the migration finishes."
  "The content every model is asked about.")

(defconst harness-provider-system-one-demo--questions
  '(:same-thread (:type "noul"
                 :instructions "Is the message a continuation of the thread?")
    :next-step (:type "choice"
                :instructions "What should the harness do with this message?"
                :criteria (:continue "The thread carries on."
                           :new "The message starts something else."))
    :topic-cue (:type "score"
                :instructions "How strongly does the topic match?"
                :criteria ("no topic in common" "one topic in common" "the same topic")))
  "One question of each kind a System One model answers.")

(defvar harness-provider-system-one-demo--wire nil
  "The requests the stub System One transport got, newest first.")

(defconst harness-provider-system-one-demo--api-answer
  (list :model "jev-1.14.0"
        :answers (list :same-thread (list :type "noul" :noul 0.96)
                       :next-step (list :type "choice" :choice "continue"
                                        :confidence 0.91
                                        :probabilities (list :continue 0.91 :new 0.09))
                       :topic-cue (list :type "score" :score 1.7
                                        :confidence 0.6
                                        :legend (list :0 "no topic in common"
                                                      :1 "one topic in common"
                                                      :2 "the same topic")
                                        :probabilities (list :0 0.05 :1 0.2 :2 0.75)))
        :usage (list :input_tokens 349 :output_tokens 39))
  "What the System One API answers the demo's three questions.")

(defun harness-provider-system-one-demo--says (status body)
  "Return a transport that answers STATUS with BODY and records the request."
  (lambda (url &rest args)
    (push (cons url args) harness-provider-system-one-demo--wire)
    (run-at-time 0.01 nil
                 (lambda ()
                   (funcall (plist-get args :callback) status nil
                            (if (stringp body) body (harness-json-encode body))
                            nil)))
    (lambda () (push :cancelled harness-provider-system-one-demo--wire))))

(defun harness-provider-system-one-demo--settle (handle)
  "Wait for HANDLE and return (STATE . VALUE)."
  (let ((promise (plist-get handle :promise))
        (deadline (+ (float-time) 10)))
    (while (and (not (harness-promise-settled-p promise)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (cons (harness-promise-state promise) (harness-promise-value promise))))

(defun harness-provider-system-one-demo--result (handle)
  "Return what HANDLE resolved with, or print why it did not."
  (let ((settled (harness-provider-system-one-demo--settle handle)))
    (if (eq (car settled) 'resolved)
        (cdr settled)
      (princ (format "  no decision: %s\n" (harness-error-message (cdr settled))))
      nil)))

(defun harness-provider-system-one-demo--show-answers (result)
  "Print the answer RESULT carries, one line a question."
  (dolist (cell (harness-provider-system-one--pairs (plist-get result :answers)))
    (let* ((name (harness-provider-system-one--key-name (car cell)))
           (answer (cdr cell))
           (type (harness-provider-system-one--type-name (plist-get answer :type)))
           (value (harness-provider-system-one-answer-value answer))
           (prob (harness-provider-system-one-answer-probability answer))
           (confidence (harness-provider-system-one-answer-confidence answer)))
      (princ (format "  %-14s %-8s %-10s p=%s%s\n"
                     name type
                     (if (numberp value) (format "%.2f" value) value)
                     (if (numberp prob) (format "%.2f" prob) "-")
                     (if (numberp confidence) (format "  confidence=%.2f" confidence) ""))))))

(defun harness-provider-system-one-demo--register ()
  "Register the three providers the demo puts one request to."
  (harness-provider-system-one-register-fixture
   'local harness-provider-system-one-demo--fixture)
  ;; A model that does both: it declares System One and completions, on
  ;; the one provider, because the capability is one a model may have.
  (harness-define-provider
   'both
   :label "Both (a model that does both)"
   :doc "Answers System One questions and completions, on one model."
   :models (lambda ()
             (harness-resolved
              (list (list :name "dual" :label "Dual" :context-window 1
                          :capabilities (harness-plist-merge
                                         (harness-provider-system-one-demo--questions-capabilities)
                                         '(:abstain t :confidence t))))))
   :complete (lambda (request)
               (let ((on-event (plist-get request :on-event)))
                 (run-at-time 0 nil (lambda ()
                                      (funcall on-event (list :type 'text :delta "ok"))
                                      (funcall on-event (list :type 'done :stop-reason 'end-turn))))
                 (list :cancel (lambda ()))))
   :system-one (lambda (_name _request)
                 (harness-resolved
                  (list :answers (list :same-thread (list :type "noul" :noul 0.99)
                                       :next-step (list :type "choice" :choice "continue"
                                                        :probabilities (list :continue 0.98 :new 0.02)
                                                        :confidence 0.98)
                                       :topic-cue (list :type "score" :score 1.9
                                                        :confidence 0.86
                                                        :legend (list :0 "no topic in common"
                                                                      :1 "one topic in common"
                                                                      :2 "the same topic")
                                                        :probabilities (list :0 0.01 :1 0.08 :2 0.91)))))))
  (harness-provider-system-one-register-jev
   'jev :model "jev-latest" :api-key "demo-key" :base-url "https://api.example.test"
   :questions harness-provider-system-one-demo--questions
   :transport (harness-provider-system-one-demo--says 200
                                                       harness-provider-system-one-demo--api-answer)))

(defun harness-provider-system-one-demo--questions-capabilities ()
  "Return the capabilities a model answering the demo's questions declares."
  '(:noul t :choice t :score t))

(defun harness-provider-system-one-demo--request (&rest args)
  "Return a request with ARGS, as every provider is asked."
  (harness-plist-merge
   (list :state harness-provider-system-one-demo--state
         :questions harness-provider-system-one-demo--questions)
   args))

(defun harness-provider-system-one-demo ()
  "Show the System One capability: one contract, three models."
  (harness-test-reset-bus)
  (dolist (module '(provider provider-system-one))
    (harness-test-load-module module))
  (setq harness-provider-system-one-demo--wire nil)
  (harness-provider-system-one-demo--register)

  (princ "\nSystem One models registered:\n")
  (dolist (id '(both jev local))
    (let* ((model-id (format "%s:%s" id (if (eq id 'both) "dual" (if (eq id 'jev) "jev-latest" "fixture"))))
           (caps (harness-call 'provider/model model-id)))
      (princ (format "  %-6s %-26s %s\n"
                     id
                     (plist-get (harness-call 'provider/model model-id) :label)
                     (string-join
                      (cl-loop for (key . _) in harness-provider-system-one-capability-keys
                               when (harness-provider-system-one-can-p model-id key)
                               collect (harness-provider-system-one--key-name key))
                      " ")))))

  (princ "\nOne request, three models -- a noul, a choice and a score:\n")
  (dolist (id '(local both jev))
    (let* ((model-id (format "%s:%s" id (if (eq id 'both) "dual" (if (eq id 'jev) "jev-latest" "fixture"))))
           (handle (harness-provider-system-one-decide
                    (harness-provider-system-one-demo--request :model model-id)))
           (result (harness-provider-system-one-demo--result handle)))
      (princ (format "  %s\n" model-id))
      (when result
        (harness-provider-system-one-demo--show-answers result))))

  (princ "\nWhat the System One API was sent, and what it answered:\n")
  (let* ((wire (car (last harness-provider-system-one-demo--wire)))
         (url (car wire))
         (args (cdr wire))
         (body (plist-get args :json))
         (result (harness-provider-system-one-demo--result
                  (harness-provider-system-one-decide
                   (harness-provider-system-one-demo--request :model "jev:jev-latest")))))
    (princ (format "  %s\n" url))
    (princ (format "  %s\n" (cdr (assoc "Authorization" (plist-get args :headers)))))
    (princ (format "  model: %s\n" (harness-provider-system-one--field body "model")))
    (princ (format "  questions: %s\n"
                   (string-join
                    (mapcar (lambda (cell)
                              (format "%s (%s)"
                                      (harness-provider-system-one--key-name (car cell))
                                      (harness-provider-system-one--field (cdr cell) "type")))
                            (harness-provider-system-one--pairs
                             (harness-provider-system-one--field body "questions")))
                    " ")))
    (when result
      (princ (format "  answered by %s, asked for %s, %s input tokens\n"
                     (plist-get result :model)
                     (plist-get result :requested-model)
                     (plist-get (plist-get result :usage) (intern "input_tokens"))))))

  (princ "\nA question type a model does not answer:\n")
  (let ((handle (harness-provider-system-one-decide
                 (harness-provider-system-one-demo--request
                  :model "local:fixture"
                  :questions '(:where (:type "box" :instructions "Where is it?"))))))
    (princ (format "  local, a box question      %s\n"
                   (harness-error-message (cdr (harness-provider-system-one-demo--settle handle))))))

  (princ "\nAn answer that is not what its question asked for:\n")
  (princ (format "  a choice nobody offered   %s\n"
                 (string-join
                  (harness-provider-system-one-answer-problems
                   '(:type "choice" :instructions "Which?"
                     :criteria (:continue "The thread carries on." :new "Something else."))
                   '(:type "choice" :choice "maybe"
                     :probabilities (:continue 0.5 :new 0.5)))
                  "; ")))

  (princ "\nWhat the contract refuses before a provider is asked:\n")
  (dolist (pair '((:questions '(:q (:instructions "Which?")) "a question with no type")
                 (:state nil "no content to judge")
                 (:schema-version 2 "a schema version this module does not speak")))
    (let ((request (harness-plist-merge
                    (harness-provider-system-one-demo--request :model "local:fixture")
                    (list (car pair) (cadr pair)))))
      (princ (format "  %-26s %s\n"
                     (caddr pair)
                     (string-join (harness-provider-system-one-validate request) "; ")))))

  (princ "\nThe artifact a model ships, and a request that disagrees with it:\n")
  (let ((artifact (plist-get (harness-call 'provider/model "local:fixture") :artifact)))
    (princ (format "  artifact %s %s, model %s %s\n"
                   (plist-get (plist-get artifact :artifact) :id)
                   (plist-get (plist-get artifact :artifact) :version)
                   (plist-get (plist-get artifact :model) :id)
                   (plist-get (plist-get artifact :model) :version)))
    (princ (format "  the request it was made for  %s\n"
                   (let ((problems (harness-provider-system-one-artifact-agrees-p
                                    artifact (harness-provider-system-one-demo--request))))
                     (if problems (string-join problems "; ") "accepted"))))
    (princ (format "  a question it does not ask  %s\n"
                   (string-join
                    (harness-provider-system-one-artifact-agrees-p
                     artifact
                     (harness-provider-system-one-demo--request
                      :questions '(:same-thread (:type "noul" :instructions "Same?"))))
                    "; "))))

  (princ "\nA decision cancelled while it was still running:\n")
  (let ((handle (harness-provider-system-one-decide
                 (harness-provider-system-one-demo--request :model "jev:jev-latest"))))
    (princ (format "  cancelled                  %s\n"
                   (harness-provider-system-one-cancel handle)))
    (princ (format "  what the caller got        %s\n"
                   (harness-error-message
                    (cdr (harness-provider-system-one-demo--settle handle))))))

  (princ "\nNothing was sent anywhere: the API is a stub.\n"))

(harness-provider-system-one-demo)
