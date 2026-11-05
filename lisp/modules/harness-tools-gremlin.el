;;; harness-tools-gremlin.el --- Tools that misbehave on purpose  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; These tools are the tool half of the gremlin chaos suite.  They are
;; the kind of work an agent gets from a bad day, a bug, or a model
;; taking the path of least resistance:
;;
;;   gremlin_slow       answers eventually, reporting progress meanwhile
;;   gremlin_hang       never answers, so the tool timeout has to
;;   gremlin_big        returns more output than a turn can carry
;;   gremlin_hog        spins the CPU and allocates memory, within a budget
;;   gremlin_probe      tries to read paths a session was not given
;;   gremlin_leak       returns secret-shaped text, as a `cat' of the wrong file would
;;   gremlin_noisy      floods progress and notes
;;   gremlin_error      signals, rejects, or returns a result of the wrong shape
;;   gremlin_ping       a quick well-behaved call, for tool-storm scenarios
;;   gremlin_stay       starts a process and returns, leaving it behind
;;
;; Each is registered as a gremlin of origin `unreliable', `bug' or
;; `optimizer'.  The tools do not bypass the harness: `gremlin_probe'
;; declares every path it touches, so the permission chain refuses the
;; call before the handler runs when the path is outside the session.
;; That is the property under test.  The tool is trusted code, as every
;; tool is; what a plugin or a tool's own author does is bounded by the
;; plugin trust model, not by the permission chain.  The gremlins model
;; the calls a model can make, which are bounded.
;;
;; All of them are disarmed unless `harness-gremlin-enabled' is non-nil,
;; and all spend from `harness-gremlin-budget'.  The CPU, memory and
;; process tools clamp their inputs even before the budget does, so a
;; typo in a test cannot turn into a machine-sized accident.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-gremlin)

(dolist (entry '((tool-slow . unreliable)
                 (tool-hang . bug)
                 (tool-big . bug)
                 (tool-hog . bug)
                 (tool-probe . optimizer)
                 (tool-leak . optimizer)
                 (tool-noisy . bug)
                 (tool-error . bug)
                 (tool-stay . unreliable)))
  (harness-gremlin-define
   (car entry) :kind 'tool :origin (cdr entry)
   :doc (pcase (car entry)
          ('tool-slow "A tool answer that takes longer than the caller wants to wait.")
          ('tool-hang "A handler promise that never settles, which the tool timeout must end.")
          ('tool-big "A result larger than the context-bomb guard can carry.")
          ('tool-hog "A handler that uses CPU and memory until its budget stops it.")
          ('tool-probe "A call that asks to read files outside the session, for the jail to refuse.")
          ('tool-leak "A tool that returns credentials, for the secrets filter to mask.")
          ('tool-noisy "A call that floods progress and note events.")
          ('tool-error "A handler that signals, rejects, or returns the wrong shape.")
          ('tool-stay "A call that leaves a process behind, for the run cleanup to kill."))))

(defun harness-gremlin-tools--disarmed ()
  "Return an error result when gremlins are disarmed, else nil."
  (unless (harness-gremlin-armed-p)
    (harness-tool-error
     "Gremlin tools are disarmed. Bind `harness-gremlin-enabled' to t, or use `harness-gremlin-with-run'.")))

(defun harness-gremlin-tools--number (value default minimum maximum)
  "Return VALUE as a number within MINIMUM and MAXIMUM, or DEFAULT.
A string that is a number is accepted, as a model may send one; a
value that is not a number at all is DEFAULT.  The clamp is the
tool's own safety rail, before the run's budget."
  (let* ((number (cond ((numberp value) (float value))
                       ((and (stringp value)
                             (string-match-p "\\`[ \t]*[-+]?[0-9.]+\\(?:e[-+]?[0-9]+\\)?[ \t]*\\'" value))
                        (string-to-number value))
                       (t (float default))))
         (number (if (or (not (numberp number)) (/= number number)) (float default) number)))
    (max minimum (min maximum number))))

(defun harness-gremlin-tools--spend-call (name)
  "Spend one call for tool NAME; return non-nil when it may run."
  (or (harness-gremlin-spend :calls 1)
      (progn (harness-gremlin-incident name "call-budget-spent") nil)))

;;;; Waiting and hanging

(harness-define-tool "gremlin_slow"
  :label "Gremlin: slow tool"
  :description "Wait before answering, reporting progress as it waits. For chaos tests."
  :kind 'meta
  :schema '(:type "object"
            :properties (:seconds (:type "number" :description "How long to take; capped by the run.")
                         :chunks (:type "integer" :description "How many progress reports.")))
  :handler
  (lambda (input ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_slow"))
            (harness-tool-error "Gremlin slow tool: budget spent")
          (let* ((wanted (harness-gremlin-tools--number (plist-get input :seconds) 1.0 0 30))
                 (seconds (min wanted (harness-gremlin-time-left)))
                 (chunks (round (harness-gremlin-tools--number (plist-get input :chunks) 3 1 20)))
                 (promise (harness-make-promise)))
            (when (< seconds wanted)
              (harness-gremlin-incident 'tool-slow "wait-clamped"
                                        :wanted wanted :allowed seconds))
            (if (<= seconds 0)
                (harness-tool-error "Gremlin slow tool: the run has no time left")
              (dotimes (i chunks)
                (let ((at (* seconds (/ (float (1+ i)) (1+ chunks)))))
                  (harness-gremlin-run-at
                   at
                   (lambda ()
                     (let ((report (plist-get ctx :report)))
                       (when report
                         (funcall report (format "gremlin slow: %d of %d" (1+ i) chunks))))))))
              (harness-gremlin-run-at
               seconds
               (lambda ()
                 (harness-resolve
                  promise
                  (harness-tool-ok
                   (format "Waited %.3fs in %d report%s." seconds chunks
                           (if (= chunks 1) "" "s"))))))
              promise))))))

(harness-define-tool "gremlin_hang"
  :label "Gremlin: hanging tool"
  :description "Return a promise that never settles. For chaos tests of the tool timeout."
  :kind 'meta
  :timeout 0.5
  :handler
  (lambda (_input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (progn
          (harness-gremlin-tools--spend-call "gremlin_hang")
          (harness-gremlin-incident 'tool-hang "promise-never-settles")
          (harness-make-promise)))))

;;;; Output and resources

(harness-define-tool "gremlin_big"
  :label "Gremlin: huge output"
  :description "Return more text than a turn can carry. For chaos tests of the size guard."
  :kind 'meta
  :schema '(:type "object"
            :properties (:bytes (:type "integer" :description "How many bytes; capped by the run.")))
  :handler
  (lambda (input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_big"))
            (harness-tool-error "Gremlin big tool: budget spent")
          (let* ((wanted (round (harness-gremlin-tools--number (plist-get input :bytes) 100000 0 4194304)))
                 (text (harness-gremlin-bytes wanted ?g)))
            (harness-gremlin-incident 'tool-big "returned"
                                      :wanted wanted :returned (length text))
            (harness-tool-ok text))))))

(harness-define-tool "gremlin_hog"
  :label "Gremlin: resource hog"
  :description "Spin the CPU and allocate memory, but only up to the run's budget."
  :kind 'meta
  :schema '(:type "object"
            :properties (:milliseconds (:type "integer")
                         :megabytes (:type "integer")))
  :timeout 10
  :handler
  (lambda (input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_hog"))
            (harness-tool-error "Gremlin hog tool: budget spent")
          (let* ((wanted-ms (harness-gremlin-tools--number (plist-get input :milliseconds) 10 0 5000))
                 (wanted-mb (harness-gremlin-tools--number (plist-get input :megabytes) 1 0 64))
                 (left-ms (* 1000 (harness-gremlin-time-left)))
                 (ms (min wanted-ms left-ms))
                 (block (harness-gremlin-allocate wanted-mb))
                 (seconds (harness-gremlin-spin ms)))
            (when (< ms wanted-ms)
              (harness-gremlin-incident 'tool-hog "spin-clamped"
                                        :wanted wanted-ms :allowed ms))
            (harness-gremlin-incident 'tool-hog "finished"
                                      :milliseconds ms :megabytes wanted-mb
                                      :allocated-bytes (length block))
            (harness-tool-ok
             (format "Spun %.3fs and allocated %d bytes of %d MB requested."
                     seconds (length block) (round wanted-mb))))))))

;;;; Paths and secrets

(defun harness-gremlin-tools--probe-targets (input)
  "Return INPUT's `:targets' as a list of strings, or signal.
A target that is not a string makes the paths function fail, which
the harness turns into a refused call rather than an unchecked one."
  (let ((targets (plist-get input :targets)))
    (unless (and (listp targets) (<= (length targets) 64))
      (error "gremlin_probe needs at most 64 targets"))
    (mapcar (lambda (target)
              (unless (stringp target)
                (error "gremlin_probe targets must be strings, not %S" target))
              target)
            targets)))

(harness-define-tool "gremlin_probe"
  :label "Gremlin: path probe"
  :description "Try to read paths, without printing their contents. For chaos tests of the jail."
  :kind 'read
  :coalescable t
  :schema '(:type "object"
            :properties (:targets (:type "array" :items (:type "string")
                                   :description "Paths to try; the jail decides whether the call runs.")))
  :paths (lambda (input) (harness-gremlin-tools--probe-targets input))
  :handler
  (lambda (input ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_probe"))
            (harness-tool-error "Gremlin probe tool: budget spent")
          (let ((targets (harness-gremlin-tools--probe-targets input))
                (lines nil))
            (dolist (target targets)
              (let* ((path (harness-tools-resolve-path target ctx))
                     (outcome (harness-gremlin-attempt
                               'tool-probe "read" path
                               (lambda ()
                                 (with-temp-buffer
                                   (insert-file-contents-literally path nil 0 4096)
                                   (buffer-size))))))
                (push (format "%s: %s"
                              path
                              (if (car outcome)
                                  (format "readable (%d bytes)" (cdr outcome))
                                "not readable"))
                      lines)))
            (harness-tool-ok
             (format "Probed %d path%s; contents were not printed.\n%s"
                     (length targets) (if (= (length targets) 1) "" "s")
                     (mapconcat #'identity (nreverse lines) "\n"))))))))

(harness-define-tool "gremlin_leak"
  :label "Gremlin: credential leak"
  :description "Return secret-shaped text, as a careless command would. For chaos tests of masking."
  :kind 'meta
  :schema '(:type "object"
            :properties (:include-environment
                         (:type "boolean"
                          :description "Also return secret-looking environment values.")))
  :handler
  (lambda (input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_leak"))
            (harness-tool-error "Gremlin leak tool: budget spent")
          (let ((parts
                 (list
                  "OPENAI_API_KEY=sk-proj-gremlin000000000000000000000000000000"
                  "password = \"gremlin-password-1234567890\""
                  (concat "-----BEGIN OPENSSH PRIVATE KEY-----\n"
                          "Z3JlbWxpbiBwcml2YXRlIGtleSBtYXRlcmlhbA==\n"
                          "-----END OPENSSH PRIVATE KEY-----"))))
            (when (and (harness-json-true-p (plist-get input :include-environment))
                       (harness-gremlin-spend :calls 1))
              (let ((count 0))
                (dolist (entry process-environment)
                  (when (and (< count 5)
                             (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" entry)
                             (string-match-p
                              "\\(?:TOKEN\\|SECRET\\|API[_-]?KEY\\|PASSWORD\\)"
                              (match-string 1 entry))
                             (> (length (match-string 2 entry)) 12))
                    (push (format "%s=%s" (match-string 1 entry) (match-string 2 entry)) parts)
                    (cl-incf count)))))
            (harness-gremlin-incident 'tool-leak "returned" :parts (length parts))
            (harness-tool-ok (string-join (nreverse parts) "\n")))))))

;;;; Noise, errors and leftovers

(harness-define-tool "gremlin_noisy"
  :label "Gremlin: noisy tool"
  :description "Emit many progress and note events. For chaos tests of event floods."
  :kind 'meta
  :schema '(:type "object"
            :properties (:count (:type "integer")
                         :text (:type "string")))
  :handler
  (lambda (input ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_noisy"))
            (harness-tool-error "Gremlin noisy tool: budget spent")
          (let* ((wanted (round (harness-gremlin-tools--number (plist-get input :count) 20 0 1000)))
                 (text (or (plist-get input :text) "noise"))
                 (text (if (> (length text) 2048) (substring text 0 2048) text))
                 (sent 0))
            (dotimes (i wanted)
              (when (harness-gremlin-spend :calls 1)
                (when-let* ((report (plist-get ctx :report)))
                  (funcall report (format "[%d] %s" i text)))
                (when-let* ((note (plist-get ctx :note)))
                  (funcall note (format "note %d\n%s" i text)))
                (cl-incf sent)))
            (harness-gremlin-incident 'tool-noisy "sent" :wanted wanted :sent sent)
            (harness-tool-ok (format "Announced %d of %d reports and notes." sent wanted)))))))

(harness-define-tool "gremlin_error"
  :label "Gremlin: failing tool"
  :description "Signal, reject, or return a result of the wrong shape. For chaos tests."
  :kind 'meta
  :schema '(:type "object"
            :properties (:mode (:type "string")
                         :message (:type "string")))
  :handler
  (lambda (input ctx)
    (or (harness-gremlin-tools--disarmed)
        (progn
          (harness-gremlin-tools--spend-call "gremlin_error")
          (let ((mode (or (plist-get input :mode) "signal"))
                (message (or (plist-get input :message) "the gremlin tool failed")))
            (harness-gremlin-incident 'tool-error "called" :mode mode)
            (pcase mode
              ("signal" (error "Gremlin tool: %s" message))
              ("reject" (harness-rejected (list 'gremlin message)))
              ("bad-result" [1 2 3 :not "a result"])
              ("no-content" (list :unexpected message))
              ("nil" nil)
              ("number" 42)
              ("report-then-signal"
               (when-let* ((report (plist-get ctx :report)))
                 (funcall report "about to fail"))
               (error "Gremlin tool: %s" message))
              (_ (harness-tool-error (format "Gremlin tool: unknown error mode %s" mode)))))))))

(harness-define-tool "gremlin_ping"
  :label "Gremlin: ping"
  :description "Return a tiny answer. The well-behaved call a tool storm repeats."
  :kind 'meta
  :schema '(:type "object"
            :properties (:n (:type "integer") :note (:type "string")))
  :handler
  (lambda (input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (progn
          (harness-gremlin-tools--spend-call "gremlin_ping")
          (harness-tool-ok (format "pong %s" (or (plist-get input :n) "?")))))))

(harness-define-tool "gremlin_stay"
  :label "Gremlin: lingering process"
  :description "Start a process and return, leaving it for the run cleanup. For chaos tests."
  :kind 'exec
  :schema '(:type "object"
            :properties (:seconds (:type "number" :description "How long the process sleeps.")))
  :handler
  (lambda (input _ctx)
    (or (harness-gremlin-tools--disarmed)
        (if (not (harness-gremlin-tools--spend-call "gremlin_stay"))
            (harness-tool-error "Gremlin stay tool: budget spent")
          (let* ((seconds (harness-gremlin-tools--number (plist-get input :seconds) 30 1 120))
                 (program (or (executable-find "sleep") "sleep")))
            (condition-case err
                (let ((process (harness-gremlin-start-process
                                "gremlin-sleeper" (generate-new-buffer " *gremlin-sleeper*")
                                (list program (format "%.0f" seconds)))))
                  (harness-gremlin-incident 'tool-stay "started" :seconds seconds)
                  (harness-tool-ok
                   (format "Started process %d for %.0fs; the run cleanup kills it."
                           (process-id process) seconds)))
              (error
               (harness-tool-error
                (format "Gremlin stay tool could not start a process: %s"
                        (error-message-string err))))))))))

(harness-define-module 'tools-gremlin
  :doc "Slow, hanging, noisy, lying and boundary-testing chaos tools."
  :requires '(tools gremlin))

(provide 'harness-tools-gremlin)
;;; harness-tools-gremlin.el ends here
