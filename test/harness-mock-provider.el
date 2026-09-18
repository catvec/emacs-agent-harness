;;; harness-mock-provider.el --- A scripted provider for tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A provider that plays a script instead of talking to a network, so the run
;; loop, permissions and the UI can be tested deterministically.  Each script
;; element is one response:
;;
;;   (:text "hello")                 stream text, then finish
;;   (:deltas ((thinking "a") (text "b")))  stream each pair in order, then finish
;;   (:tool-call ("bash" ARGS))      emit one tool call, then finish
;;   (:error "boom")                 fail the request
;;   (:nothing)                      finish with no content
;;
;; Playback is scheduled with `run-at-time 0' rather than called inline, so
;; the tests exercise the same asynchronous path as a real provider.
;;
;; This file deliberately does not match `harness-*-test.el', so the test
;; runner does not treat it as a suite; suites `require' it.

;;; Code:

(require 'cl-lib)
(require 'harness-provider)

(cl-defstruct (harness-test-provider (:include harness-provider)
                                     (:constructor harness-test-provider--make))
  "A provider that plays a fixed script of responses."
  (script nil)
  (requests nil)
  (cancelled nil))

(defun harness-test-provider-create (spec)
  "Build a scripted provider from SPEC.
SPEC needs `:name' and `:script'; `:capabilities' overrides the defaults."
  (harness-test-provider--make
   :name (harness-plist-or-alist-get :name spec)
   :kind 'harness-test
   :label "mock"
   :caps (harness-plist-or-alist-get :capabilities spec)
   :script (copy-sequence (harness-plist-or-alist-get :script spec))
   :requests nil))

(harness-register-provider-kind 'harness-test #'harness-test-provider-create)

(cl-defmethod harness-provider-capabilities ((provider harness-test-provider))
  "The mock streams text, tools and usage.
SPEC's `:capabilities' overrides these, so a test can model a provider
without native tool calling."
  (append (harness-provider-caps provider)
          '(:streaming t :tools t :reasoning t :usage-in-stream t
            :system-role system)))

(cl-defmethod harness-provider-cancel ((provider harness-test-provider) _handle)
  "Record that the request was cancelled."
  (setf (harness-test-provider-cancelled provider) t))

(cl-defmethod harness-provider-models ((_provider harness-test-provider) callback)
  "The mock serves no discoverable models."
  (funcall callback nil))

(cl-defmethod harness-provider-chat ((provider harness-test-provider)
                                     request callbacks)
  "Play the next scripted response for REQUEST."
  (push request (harness-test-provider-requests provider))
  (let ((step (pop (harness-test-provider-script provider))))
    (run-at-time 0 nil (lambda () (harness-test-provider--play step callbacks)))
    (list 'harness-test-handle)))

(defun harness-test-provider--emit (callbacks key &rest args)
  "Call CALLBACKS's KEY with ARGS, if it has one.
Callers are not required to supply every callback, and neither is a real
provider, so the mock must not assume they are all present."
  (when-let* ((function (plist-get callbacks key)))
    (apply function args)))

(defun harness-test-provider--play (step callbacks)
  "Deliver STEP through CALLBACKS."
  (pcase (car-safe step)
    (:text
     (harness-test-provider--emit callbacks :on-delta 'text (nth 1 step))
     (let ((usage (or (nth 2 step) '(:in 10 :out 5))))
       (harness-test-provider--emit callbacks :on-usage usage)
       (harness-test-provider--emit callbacks :on-done "stop" usage)))
    (:thinking
     (harness-test-provider--emit callbacks :on-delta 'thinking (nth 1 step))
     (harness-test-provider--emit callbacks :on-delta 'text (or (nth 2 step) ""))
     (harness-test-provider--emit callbacks :on-done "stop" nil))
    (:deltas
     ;; Each element is (KIND TEXT); this is how a test streams several
     ;; reasoning chunks before the answer.
     (dolist (delta (cdr step))
       (harness-test-provider--emit callbacks :on-delta (car delta) (cadr delta)))
     (harness-test-provider--emit callbacks :on-usage '(:in 10 :out 5))
     (harness-test-provider--emit callbacks :on-done "stop" '(:in 10 :out 5)))
    (:tool-call
     (let ((index 0))
       (dolist (call (cdr step))
         (let* ((name (car call))
                (args (cadr call))
                (tool-call (harness-tool-call-create
                            :id (format "mock-%d" index)
                            :name name
                            :args-string (harness-json-write args))))
           (harness-tool-call-parse-args tool-call)
           (harness-test-provider--emit callbacks :on-tool-call index tool-call)
           (setq index (1+ index)))))
     (harness-test-provider--emit callbacks :on-usage '(:in 20 :out 10))
     (harness-test-provider--emit callbacks :on-done "tool_calls" '(:in 20 :out 10)))
    (:error
     (harness-test-provider--emit callbacks :on-error 'harness-test (nth 1 step)))
    (:nothing
     (harness-test-provider--emit callbacks :on-done "stop" nil))
    (_
     (harness-test-provider--emit callbacks :on-error 'harness-test "empty script"))))

(provide 'harness-mock-provider)
;;; harness-mock-provider.el ends here
