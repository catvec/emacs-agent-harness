;;; harness-provider-check-test.el --- Offline tests of the live check jobs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The live provider and model checks make real API requests, so the
;; ordinary suite drives them with a fake provider and never touches the
;; network.  What is tested here is the runner: that results arrive one
;; at a time, that a failed check does not stop the checks after it, that
;; a model refusing a tool is not reported as broken transport, that a
;; hanging provider times out, and that a third-party provider's error
;; text (which may hold a key) is not copied into a result.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-check-test--calls nil)
(defvar harness-provider-check-test--no-thinking-error nil)
(defvar harness-provider-check-test--no-tools nil)
(defvar harness-provider-check-test--tool-use-without-call nil)
(defvar harness-provider-check-test--drop-label nil)
(defvar harness-provider-check-test--error-kind nil)
(defvar harness-provider-check-test--error-text nil)
(defvar harness-provider-check-test--events nil)

(defun harness-provider-check-test--complete (request)
  "Fake completion of REQUEST, including tool continuation and cancellation."
  (push request harness-provider-check-test--calls)
  (let ((emit (plist-get request :on-event))
        (done nil))
    (funcall emit '(:type start))
    (harness-run-soon
     (lambda ()
       (unless done
         (cond
          (harness-provider-check-test--error-kind
           (setq done t)
           (funcall emit (list :type 'done :stop-reason 'error
                               :error (or harness-provider-check-test--error-text
                                          "the provider failed")
                               :error-kind harness-provider-check-test--error-kind)))
          ((and (plist-get request :no-thinking)
                harness-provider-check-test--no-thinking-error)
           (setq done t)
           (funcall emit '(:type done :stop-reason error :error "unsupported_value")))
          ((cl-find-if (lambda (message)
                         (eq (plist-get message :role) 'tool))
                       (plist-get request :messages))
           (let* ((tool (car (plist-get (car (last (plist-get request :messages))) :content)))
                  (receipt (plist-get tool :content)))
             (funcall emit (list :type 'text :delta receipt))
             (funcall emit '(:type usage :input 42 :output 5))
             (setq done t)
             (funcall emit '(:type done :stop-reason end-turn))))
          ((and (plist-get request :tools)
                harness-provider-check-test--tool-use-without-call)
           (setq done t)
           (funcall emit '(:type done :stop-reason tool-use)))
          ((and (plist-get request :tools)
                (not harness-provider-check-test--no-tools)
                (cl-find "resubmit" (plist-get request :tools)
                         :key (lambda (tool) (plist-get tool :name))
                         :test #'equal))
           (let* ((tool (cl-find "resubmit" (plist-get request :tools)
                                 :key (lambda (tool) (plist-get tool :name))
                                 :test #'equal))
                  (label (and (string-match "marker-[0-9a-f]+"
                                            (or (plist-get tool :description) ""))
                              (match-string 0 (plist-get tool :description))))
                  (note (if harness-provider-check-test--drop-label
                            (string-remove-prefix "marker-" label)
                          label)))
             (funcall emit (list :type 'tool-call :id "call-resubmit"
                                 :name "resubmit" :input (list :note note)))
             (setq done t)
             (funcall emit '(:type done :stop-reason tool-use))))
          ((and (plist-get request :tools)
                (not harness-provider-check-test--no-tools))
           (funcall emit '(:type tool-call :id "call-1"
                           :name "check_echo" :input (:value "ping")))
           (setq done t)
           (funcall emit '(:type done :stop-reason tool-use)))
          (t
           (let* ((prompt (plist-get (car (plist-get request :messages)) :content))
                  (vision (cl-some
                           (lambda (block)
                             (and (equal (plist-get block :type) "text")
                                  (string-match-p "solid color"
                                                  (plist-get block :text))))
                           prompt)))
             (funcall emit (list :type 'text :delta (or (and vision "red") "hello")))
             (unless (plist-get request :ephemeral)
               (funcall emit '(:type provider-state :state (:id "fake-state"))))
             (funcall emit '(:type usage :input 42 :output 5))
             (setq done t)
             (funcall emit '(:type done :stop-reason end-turn))))))))
    (list :cancel
          (lambda ()
            (unless done
              (setq done t)
              (funcall emit '(:type done :stop-reason cancelled)))))))

(defun harness-provider-check-test--stall (request)
  "A completion that starts and never ends, whatever is asked of it."
  (let ((emit (plist-get request :on-event)))
    (funcall emit '(:type start))
    (list :cancel #'ignore)))

(defun harness-provider-check-test--hang (request)
  "A completion that starts and ends only when it is cancelled."
  (let ((emit (plist-get request :on-event))
        (done nil))
    (funcall emit '(:type start))
    (list :cancel
          (lambda ()
            (unless done
              (setq done t)
              (funcall emit '(:type done :stop-reason cancelled)))))))

(defun harness-provider-check-test--models ()
  "Return the model listing of the fake provider."
  (harness-resolved
   '((:name "model" :context-window 100000
      :thinking-levels ("low" "max")
      :input-modalities ("text" "image")))))

(defmacro harness-provider-check-test-with (&rest body)
  "Run BODY with an offline, fake provider and a fresh bus."
  (declare (indent 0))
  `(harness-provider-check-test--with nil ,@body))

(defmacro harness-provider-check-test-with-session (&rest body)
  "Run BODY as `harness-provider-check-test-with' does, with the session module.
The checks then record their model calls as internal sessions, which
the test can read back."
  (declare (indent 0))
  `(harness-provider-check-test--with '(store project config session) ,@body))

(defmacro harness-provider-check-test--with (modules &rest body)
  "Run BODY with an offline, fake provider, a fresh bus and MODULES loaded."
  (declare (indent 1))
  `(progn
     (harness-test-reset-bus)
     (harness-test-load-module 'provider)
     (harness-test-load-module 'provider-check)
     (dolist (module ,modules)
       (harness-test-load-module module))
     (harness-define-provider 'checkfake
       :models #'harness-provider-check-test--models
       :complete #'harness-provider-check-test--complete)
     (let ((harness-provider-check-test--calls nil)
           (harness-provider-check-test--no-thinking-error nil)
           (harness-provider-check-test--no-tools nil)
           (harness-provider-check-test--tool-use-without-call nil)
           (harness-provider-check-test--drop-label nil)
           (harness-provider-check-test--error-kind nil)
           (harness-provider-check-test--error-text nil)
           (harness-provider-check-test--events nil)
           (harness-provider-check-timeout 1))
       (harness-on 'provider-check/started
                   (lambda (&rest args)
                     (push (cons 'started args) harness-provider-check-test--events)))
       (harness-on 'provider-check/result
                   (lambda (&rest args)
                     (push (cons 'result args) harness-provider-check-test--events)))
       (harness-on 'provider-check/finished
                   (lambda (&rest args)
                     (push (cons 'finished args) harness-provider-check-test--events)))
       (unwind-protect (progn ,@body)
         (harness-provider-unregister 'checkfake)))))

(defun harness-provider-check-test-run (model &optional suite embedding-model)
  "Run a check job on MODEL and return its results, waiting for them."
  (let ((job (harness-provider-check-start model suite embedding-model)))
    (harness-await (harness-provider-check-job-promise job) 10)))

(defun harness-provider-check-test-by-name (results name)
  "Find the check called NAME in RESULTS."
  (cl-find name results :key (lambda (result) (plist-get result :name)) :test #'equal))

(defun harness-provider-check-test-events (type)
  "Return the recorded events of TYPE, oldest first."
  (mapcar #'cdr (nreverse (cl-remove-if-not (lambda (event) (eq (car event) type))
                                            harness-provider-check-test--events))))

(defun harness-provider-check-test--u32 (data pos)
  "Return the big-endian 32-bit number at POS in unibyte string DATA."
  (logior (ash (aref data pos) 24)
          (ash (aref data (+ pos 1)) 16)
          (ash (aref data (+ pos 2)) 8)
          (aref data (+ pos 3))))

(defun harness-provider-check-test--png-chunks (data)
  "Return the (TYPE . PAYLOAD) chunks of PNG DATA, checking their lengths."
  (should (equal (substring data 0 8) "\211PNG\r\n\032\n"))
  (let ((pos 8)
        (limit (length data))
        chunks)
    (while (< pos limit)
      (should (<= (+ pos 12) limit))
      (let* ((size (harness-provider-check-test--u32 data pos))
             (type (substring data (+ pos 4) (+ pos 8)))
             (end (+ pos 12 size)))
        (should (<= end limit))
        (should (string-match-p "\\`[A-Za-z]\\{4\\}\\'" type))
        (push (cons type (substring data (+ pos 8) (+ pos 8 size))) chunks)
        (setq pos end)))
    (should (= pos limit))
    (nreverse chunks)))

(ert-deftest harness-provider-check-both-suites-pass-offline ()
  (harness-provider-check-test-with
    (let ((results (harness-provider-check-test-run "checkfake:model" 'all)))
      (should (= 11 (cl-count 'provider results
                              :key (lambda (r) (plist-get r :suite)))))
      (should (= 4 (cl-count 'model results
                             :key (lambda (r) (plist-get r :suite)))))
      (should (= 12 (cl-count 'pass results
                              :key (lambda (r) (plist-get r :status)))))
      (should (= 3 (cl-count 'skip results
                             :key (lambda (r) (plist-get r :status)))))
      (should (cl-some
               (lambda (request)
                 (cl-some (lambda (message)
                            (cl-some (lambda (block)
                                       (equal (plist-get block :type) "image"))
                                     (plist-get message :content)))
                          (plist-get request :messages)))
               harness-provider-check-test--calls))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Quota reporting (optional)") :status)))
      (should (cl-some (lambda (request) (plist-get request :no-thinking))
                       harness-provider-check-test--calls))
      (should (cl-some (lambda (request)
                         (equal (plist-get request :thinking) "max"))
                       harness-provider-check-test--calls)))))

(ert-deftest harness-provider-check-results-arrive-one-at-a-time ()
  "A job announces its plan, then each result before the next check."
  (harness-provider-check-test-with
    (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
           (started (car (harness-provider-check-test-events 'started))))
      (should (equal (nth 0 started) (harness-provider-check-job-id job)))
      (should (= 11 (nth 3 started)))
      (should (null (harness-provider-check-test-events 'result)))
      (harness-await (harness-provider-check-job-promise job) 10)
      (let ((results (harness-provider-check-test-events 'result)))
        (should (= 11 (length results)))
        (should (equal (mapcar (lambda (event) (nth 2 event)) results)
                       (number-sequence 1 11)))
        (should (= 11 (nth 3 (car (last results)))))
        (let ((finished (car (harness-provider-check-test-events 'finished))))
          (should (= 11 (length (nth 2 finished))))
          (should (= 11 (plist-get (nth 3 finished) :completed))))))))

(ert-deftest harness-provider-check-continues-after-effort-rejection ()
  (harness-provider-check-test-with
    (setq harness-provider-check-test--no-thinking-error t)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
      (should (eq 'fail (plist-get (harness-provider-check-test-by-name
                                    results "No-thinking request") :status)))
      (should (string-match-p
               "reasoning-effort"
               (plist-get (harness-provider-check-test-by-name
                           results "No-thinking request") :advice)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Declared thinking level") :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Tool-call transport and tool-result continuation")
                                   :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Cancellation and cleanup") :status))))))

(ert-deftest harness-provider-check-model-refusal-does-not-convict-transport ()
  (harness-provider-check-test-with
    (setq harness-provider-check-test--no-tools t)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'all)))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Tool-call transport and tool-result continuation")
                                   :status)))
      (should (eq 'fail (plist-get (harness-provider-check-test-by-name
                                    results "Choose and form a harness tool call") :status)))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Use the returned tool result") :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Cancellation and cleanup") :status))))))

(ert-deftest harness-provider-check-tool-use-without-a-call-is-a-transport-failure ()
  "A tool-use stop with no tool-call event is the provider's fault, not the model's."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--tool-use-without-call t)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'all)))
      (let ((transport (harness-provider-check-test-by-name
                        results "Tool-call transport and tool-result continuation")))
        (should (eq 'fail (plist-get transport :status)))
        (should (string-match-p "no tool-call event" (plist-get transport :detail))))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Choose and form a harness tool call")
                                   :status)))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Use the returned tool result")
                                   :status))))))

(ert-deftest harness-provider-check-optional-hooks-are-tested-when-configured ()
  (harness-provider-check-test-with
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--complete
      :capabilities '(:fork t :vision t)
      :fork (lambda (_model state)
              (harness-resolved (list :fork-of (plist-get state :id))))
      :quota (lambda ()
               (harness-resolved
                '(:billing subscription :windows ((:name "5h" :used 0.2)))))
      :embed (lambda (_name texts _opts)
               (harness-resolved
                (list :vectors (mapcar (lambda (text) (list (float (length text)) 1.0))
                                       texts)))))
    (let ((results (harness-provider-check-test-run
                    "checkfake:model" 'provider "checkfake:embed")))
      (dolist (name '("Advertised image input" "Quota reporting (optional)"
                      "Provider-state and fork (optional)" "Embeddings (optional)"))
        (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                      results name) :status)))))))

(ert-deftest harness-provider-check-bad-quota-does-not-block-cancellation ()
  (harness-provider-check-test-with
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--complete
      :quota (lambda ()
               (harness-resolved
                '(:billing subscription :windows ((:name "5h" :used 50))))))
    (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
      (should (eq 'fail (plist-get (harness-provider-check-test-by-name
                                    results "Quota reporting (optional)") :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Cancellation and cleanup") :status))))))

(ert-deftest harness-provider-check-event-validation-catches-malformed-events ()
  (should-error (harness-provider-check--events
                 '((:type start) (:type usage :input nil :output 3)
                   (:type done :stop-reason end-turn))))
  (should-error (harness-provider-check--events
                 '((:type start) (:type done :stop-reason end-turn)
                   (:type done :stop-reason end-turn))))
  (should-error (harness-provider-check--events
                 '((:type start) (:type tool-call :id "x" :name "echo" :input nil
                                  :respond "not callable")
                   (:type done :stop-reason tool-use)))))

(ert-deftest harness-provider-check-environment-errors-are-unavailable ()
  "An account or network failure says the check could not run, not that the API broke.
A `request' error is different: the provider rejected the body, which
is its contract to keep."
  (dolist (kind '(quota billing rate-limit auth transport :quota))
    (should-error
     (harness-provider-check--events
      (list '(:type start)
            (list :type 'done :stop-reason 'error :error-kind kind)))
     :type 'harness-provider-check-unavailable))
  (should (harness-provider-check--events
           '((:type start)
             (:type done :stop-reason error :error-kind request))))
  (should (harness-provider-check--events
           '((:type start)
             (:type done :stop-reason error)))))

(ert-deftest harness-provider-check-image-is-a-complete-valid-png ()
  "The baked-in test image is whole: a truncated PNG is an unsupported image.
DeepSeek rejected the former constant, whose IDAT declared more bytes
than the file held, with an HTTP 400 unsupported-image error."
  (harness-provider-check-test-with
    (let* ((data (base64-decode-string harness-provider-check--image))
           (chunks (harness-provider-check-test--png-chunks data))
           (ihdr (cdr (assoc "IHDR" chunks)))
           (idat (apply #'concat
                        (mapcar #'cdr (cl-remove-if-not
                                       (lambda (chunk) (equal (car chunk) "IDAT"))
                                       chunks)))))
      (should (= 13 (length ihdr)))
      (should (= 64 (harness-provider-check-test--u32 data 16)))
      (should (= 64 (harness-provider-check-test--u32 data 20)))
      (should (= 8 (aref ihdr 8)))       ; bit depth
      (should (= 2 (aref ihdr 9)))       ; RGB, no alpha
      (should (equal "IEND" (car (car (last chunks)))))
      (should idat)
      ;; The zlib stream inflates to one filter byte and three bytes per
      ;; pixel on every row, so the image data itself is intact too.
      (when (fboundp 'zlib-decompress-region)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert idat)
          (zlib-decompress-region (point-min) (point-max))
          (should (= (* 64 (1+ (* 64 3))) (buffer-size))))))))

(ert-deftest harness-provider-check-instruction-uses-a-resubmit-tool-with-a-label ()
  "The instruction check models a real resubmit call with an exact label."
  (harness-provider-check-test-with
    (harness-provider-check-test-run "checkfake:model" 'model)
    (let* ((request
            (cl-find-if (lambda (request)
                          (cl-find "resubmit" (plist-get request :tools)
                                   :key (lambda (tool) (plist-get tool :name))
                                   :test #'equal))
                        harness-provider-check-test--calls))
           (tool (and request
                      (cl-find "resubmit" (plist-get request :tools)
                               :key (lambda (tool) (plist-get tool :name))
                               :test #'equal)))
           (description (plist-get tool :description)))
      (should request)
      (should (string-match-p "marker-[0-9a-f]+" description))
      (should (string-match-p "including the marker- prefix" description))
      (should (string-match-p "prefix included"
                              (plist-get
                               (plist-get (plist-get (plist-get tool :schema)
                                                     :properties)
                                          :note)
                               :description))))))

(ert-deftest harness-provider-check-instruction-requires-the-resubmit-label ()
  "A reply that keeps only the hex value is not following the tool instruction."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--drop-label t)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'model)))
      (let ((instructions (harness-provider-check-test-by-name
                           results "Instruction following")))
        (should (eq 'fail (plist-get instructions :status)))
        (should (string-match-p "label" (plist-get instructions :detail)))))))

(ert-deftest harness-provider-check-never-prints-provider-error-details ()
  (harness-provider-check-test-with
    (cl-letf (((symbol-function 'harness-provider-check-test--complete)
               (lambda (_request) (error "secret-password"))))
      (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
        (let ((basic (harness-provider-check-test-by-name
                      results "Text completion and event lifecycle")))
          (should (eq 'fail (plist-get basic :status)))
          (should-not (string-match-p "secret-password" (plist-get basic :detail))))))))

(ert-deftest harness-provider-check-an-exhausted-account-is-a-skip-not-a-failure ()
  "A plan's usage limit is not evidence that the provider or model is broken.
Every request that could not run because the account is out of quota is
a SKIP with a safe explanation, and no raw provider text reaches the
report."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--error-kind 'quota
          harness-provider-check-test--error-text "secret-quota-credential")
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'all))
           (status-of (lambda (name)
                        (plist-get (harness-provider-check-test-by-name
                                    results name)
                                   :status))))
      (should (eq 'pass (funcall status-of "Registry and model catalogue")))
      (should (eq 'pass (funcall status-of "Cancellation and cleanup")))
      (dolist (name '("Text completion and event lifecycle"
                      "Usage accounting"
                      "No-thinking request"
                      "Declared thinking level"
                      "Advertised image input"
                      "Tool-call transport and tool-result continuation"
                      "Instruction following"
                      "Image recognition (optional)"
                      "Choose and form a harness tool call"
                      "Use the returned tool result"))
        (should (eq 'skip (funcall status-of name))))
      (should-not (cl-find 'fail results
                           :key (lambda (result) (plist-get result :status))))
      (should (string-match-p
               "usage limit"
               (plist-get (harness-provider-check-test-by-name
                           results "Text completion and event lifecycle")
                          :detail)))
      (should-not (string-match-p
                   "secret-quota-credential"
                   (mapconcat (lambda (result) (or (plist-get result :detail) ""))
                              results "\n"))))))

(ert-deftest harness-provider-check-a-wrong-request-is-still-a-failure ()
  "An error the provider calls `request' is its own contract to keep.
Only account and network conditions turn a check into a SKIP."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--error-kind 'request
          harness-provider-check-test--error-text "unsupported body field")
    (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
      (let ((basic (harness-provider-check-test-by-name
                    results "Text completion and event lifecycle")))
        (should (eq 'fail (plist-get basic :status)))
        (should-not (string-match-p "unsupported body field"
                                    (plist-get basic :detail)))))))

(ert-deftest harness-provider-check-hanging-provider-times-out-and-carries-on ()
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 0.2)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--stall)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
      (let ((basic (harness-provider-check-test-by-name
                    results "Text completion and event lifecycle")))
        (should (eq 'fail (plist-get basic :status)))
        (should (string-match-p "Timed out" (plist-get basic :detail))))
      (should (eq 'skip (plist-get (harness-provider-check-test-by-name
                                    results "Usage accounting") :status)))
      (should (= 11 (length results))))))

(ert-deftest harness-provider-check-cancellation-needs-a-cancel-function ()
  "A completion handle without :cancel fails the cancellation check."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 0.2)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete (lambda (request)
                  (funcall (plist-get request :on-event) '(:type start))
                  '(:other t)))
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
           (cancellation (harness-provider-check-test-by-name
                          results "Cancellation and cleanup")))
      (should (eq 'fail (plist-get cancellation :status)))
      (should (string-match-p ":cancel" (plist-get cancellation :detail))))))

(ert-deftest harness-provider-check-cancel-stops-the-job ()
  "Cancelling a request in flight ends the job with the results it has."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 5)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--hang)
    (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
           (id (harness-provider-check-job-id job))
           (deadline (+ (float-time) 5)))
      ;; The catalogue check settles first; the completion then hangs.
      (while (and (null (harness-provider-check-test-events 'result))
                  (< (float-time) deadline))
        (accept-process-output nil 0.02)
        (sit-for 0.01))
      (should (harness-provider-check-test-events 'result))
      (should (harness-provider-check-cancel id))
      (harness-await (harness-provider-check-job-promise job) 5)
      (let ((finished (car (harness-provider-check-test-events 'finished))))
        (should (harness-json-true-p (plist-get (nth 3 finished) :cancelled)))
        (should (= 1 (length (nth 2 finished)))))
      (should-not (gethash id harness-provider-check--jobs)))))

(ert-deftest harness-provider-check-methods-start-and-cancel-a-job ()
  "The ACP surface starts a named job and can cancel it."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 5)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--hang)
    (let* ((answer (harness-call 'provider/check-start "checkfake:model"
                                 "provider" nil "test-job"))
           (id (plist-get answer :job))
           (job (gethash id harness-provider-check--jobs)))
      (should (equal id "test-job"))
      (should (= 11 (plist-get answer :total)))
      (should (= 11 (length (plist-get answer :checks))))
      (should job)
      (should (harness-call 'provider/check-cancel id))
      (harness-await (harness-provider-check-job-promise job) 5)
      (should-not (harness-call 'provider/check-cancel id)))))

(ert-deftest harness-provider-check-records-each-checks-calls-as-sessions ()
  "A check's model requests are recorded as internal sessions it names.
The page can then open what the check asked, what the model answered and
how the call ended, which the result itself never spells out."
  (harness-provider-check-test-with-session
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'all))
           (completion (harness-provider-check-test-by-name
                        results "Text completion and event lifecycle"))
           (usage (harness-provider-check-test-by-name results "Usage accounting"))
           (transport (harness-provider-check-test-by-name
                       results "Tool-call transport and tool-result continuation"))
           (tool-call (harness-provider-check-test-by-name
                       results "Choose and form a harness tool call"))
           (tool-result (harness-provider-check-test-by-name
                         results "Use the returned tool result")))
      (dolist (result (list completion usage transport tool-call tool-result))
        (should result)
        (should (plist-get result :sessions)))
      ;; Usage reads the completion's own call: the same session.
      (should (equal (plist-get usage :sessions) (plist-get completion :sessions)))
      (should (= 1 (length (plist-get completion :sessions))))
      ;; The tool turn calls the model twice, and both checks that reuse it
      ;; name both calls.
      (should (= 2 (length (plist-get transport :sessions))))
      (should (equal (plist-get tool-call :sessions) (plist-get transport :sessions)))
      (should (equal (plist-get tool-result :sessions) (plist-get transport :sessions)))
      (let* ((session-id (car (plist-get completion :sessions)))
             (session (harness-session--get session-id))
             (nodes (harness-call 'session/nodes session-id)))
        (should session)
        (should (eq (harness-session-kind session) 'internal))
        (should (equal (harness-session-name session)
                       "Provider check: Text completion and event lifecycle"))
        (should (cl-some (lambda (node)
                           (and (eq (plist-get node :kind) 'user)
                                (string-match-p "short greeting"
                                                (plist-get node :content))))
                         nodes))
        (should (cl-some (lambda (node)
                           (and (eq (plist-get node :kind) 'assistant)
                                (equal (plist-get node :content) "hello")))
                         nodes)))))
  ;; A check whose requests nothing recorded names no session, rather than
  ;; a link to nowhere.
  (harness-provider-check-test-with-session
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
           (catalogue (harness-provider-check-test-by-name
                       results "Registry and model catalogue")))
      (should (eq 'pass (plist-get catalogue :status)))
      (should-not (plist-get catalogue :sessions)))))

(ert-deftest harness-provider-check-model-suite-shares-the-tool-turn-sessions ()
  "The tool checks of the model suite name the calls the turn made.
A model-only run makes the turn in `tool-call`; `tool-result` reads it."
  (harness-provider-check-test-with-session
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'model))
           (tool-call (harness-provider-check-test-by-name
                       results "Choose and form a harness tool call"))
           (tool-result (harness-provider-check-test-by-name
                         results "Use the returned tool result")))
      (should (eq 'pass (plist-get tool-call :status)))
      (should (= 2 (length (plist-get tool-call :sessions))))
      (should (equal (plist-get tool-result :sessions)
                     (plist-get tool-call :sessions))))))

(ert-deftest harness-provider-check-session-holds-the-provider-error ()
  "A provider's error text never reaches the result detail, but the session
the check links to says how the call ended."
  (harness-provider-check-test-with-session
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete (lambda (request)
                  (let ((emit (plist-get request :on-event)))
                    (funcall emit '(:type start))
                    (funcall emit '(:type done :stop-reason error
                                    :error "secret-password"))
                    (list :cancel #'ignore))))
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
           (completion (harness-provider-check-test-by-name
                        results "Text completion and event lifecycle"))
           (session-id (car (plist-get completion :sessions))))
      (should (eq 'fail (plist-get completion :status)))
      (should-not (string-match-p "secret-password" (plist-get completion :detail)))
      (should session-id)
      (should (cl-some (lambda (node)
                         (and (eq (plist-get node :kind) 'hint)
                              (string-match-p "secret-password"
                                              (plist-get node :content))))
                       (harness-call 'session/nodes session-id))))))

(provide 'harness-provider-check-test)
;;; harness-provider-check-test.el ends here
