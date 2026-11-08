;;; harness-provider-check-test.el --- Offline tests of the live check jobs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The live provider and model checks make real API requests, so the
;; ordinary suite drives them with a fake provider and never touches the
;; network.  What is tested here is the runner: that results arrive one
;; at a time, that a failed check does not stop the checks after it, that
;; a model refusing a tool is not reported as broken transport, that a
;; hosted loop's tool call is answered so its turn can end, that a
;; hanging provider times out, and that a third-party provider's error
;; text (which may hold a key) is not copied into a result.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-check-test--calls nil)
(defvar harness-provider-check-test--no-thinking-error nil)
(defvar harness-provider-check-test--no-tools nil)
(defvar harness-provider-check-test--hosted-tool nil)
(defvar harness-provider-check-test--hosted-answers nil)
(defvar harness-provider-check-test--tool-use-without-call nil)
(defvar harness-provider-check-test--drop-label nil)
(defvar harness-provider-check-test--error-kind nil)
(defvar harness-provider-check-test--error-text nil)
(defvar harness-provider-check-test--events nil)
(defvar harness-provider-check-test--cache-read nil
  "The `:cache-read' the fake provider's usage events report, when a number.")

(defvar harness-provider-check-test--cache-simulate nil
  "Non-nil makes the fake provider simulate a prefix cache.
A request whose system prompt and first message were already seen reads
1000 cached tokens; a new prefix reads none.  The key deliberately
ignores a message appended after the first, as a prefix cache does.")

(defvar harness-provider-check-test--cache-prefixes nil
  "Prefixes the fake provider has seen in a simulated cache.")

(defun harness-provider-check-test--cache-key (request)
  "Return the prefix key of REQUEST, or nil."
  (let ((messages (plist-get request :messages)))
    (and messages
         (list (plist-get request :system)
               (plist-get (car messages) :content)))))

(defun harness-provider-check-test--cache-read-for (request)
  "Return the cache-read count the fake provider reports for REQUEST."
  (cond
   ((numberp harness-provider-check-test--cache-read)
    harness-provider-check-test--cache-read)
   (harness-provider-check-test--cache-simulate
    (let* ((key (harness-provider-check-test--cache-key request))
           (seen (and key (gethash key harness-provider-check-test--cache-prefixes))))
      (when (and key (not seen))
        (puthash key t harness-provider-check-test--cache-prefixes))
      (if seen 1000 0)))
   (t nil)))

(defun harness-provider-check-test--usage (&optional cache-read)
  "Return the usage event of the fake provider with CACHE-READ.
A nil CACHE-READ says nothing of cache tokens, as a provider with no
telemetry does."
  (append '(:type usage :input 42 :output 5)
          (and (numberp cache-read) (list :cache-read cache-read))))

(defun harness-provider-check-test--usage-for (request)
  "Return the usage event of REQUEST from the fake provider."
  (harness-provider-check-test--usage (harness-provider-check-test--cache-read-for request)))

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
             (funcall emit (harness-provider-check-test--usage-for request))
             (setq done t)
             (funcall emit '(:type done :stop-reason end-turn))))
          ((and (plist-get request :tools)
                harness-provider-check-test--hosted-tool
                (not harness-provider-check-test--no-tools))
           ;; As a hosted loop does: hand the turn the call and wait for the
           ;; result in :respond before the turn can end.
           (let* ((tool (car (plist-get request :tools)))
                  (name (plist-get tool :name))
                  (label (and (string-match "marker-[0-9a-f]+"
                                            (or (plist-get tool :description) ""))
                              (match-string 0 (plist-get tool :description))))
                  (input (if (equal name "resubmit")
                             (list :note (or label "marker-unknown"))
                           (list :value "ping"))))
             (funcall emit
                      (list :type 'tool-call :id "call-hosted" :name name :input input
                            :respond
                            (lambda (result)
                              (push result harness-provider-check-test--hosted-answers)
                              (funcall emit (list :type 'text
                                                  :delta (or (plist-get result :content) "")))
                              (funcall emit '(:type usage :input 42 :output 5))
                              (setq done t)
                              (funcall emit '(:type done :stop-reason end-turn)))))))
          ((and (plist-get request :tools)
                harness-provider-check-test--tool-use-without-call)
           (funcall emit (harness-provider-check-test--usage-for request))
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
             (funcall emit (harness-provider-check-test--usage-for request))
             (setq done t)
             (funcall emit '(:type done :stop-reason tool-use))))
          ((and (plist-get request :tools)
                (not harness-provider-check-test--no-tools))
           (funcall emit '(:type tool-call :id "call-1"
                           :name "check_echo" :input (:value "ping")))
           (funcall emit (harness-provider-check-test--usage-for request))
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
             (funcall emit (harness-provider-check-test--usage-for request))
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
           (harness-provider-check-test--hosted-tool nil)
           (harness-provider-check-test--hosted-answers nil)
           (harness-provider-check-test--tool-use-without-call nil)
           (harness-provider-check-test--drop-label nil)
           (harness-provider-check-test--error-kind nil)
           (harness-provider-check-test--error-text nil)
           (harness-provider-check-test--events nil)
           (harness-provider-check-test--cache-read nil)
           (harness-provider-check-test--cache-simulate nil)
           (harness-provider-check-test--cache-prefixes (make-hash-table :test #'equal))
           (harness-provider-check-cache-persistence-wait 0)
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
      (should (= 16 (cl-count 'provider results
                              :key (lambda (r) (plist-get r :suite)))))
      (should (= 4 (cl-count 'model results
                             :key (lambda (r) (plist-get r :suite)))))
      (should (= 12 (cl-count 'pass results
                              :key (lambda (r) (plist-get r :status)))))
      (should (= 8 (cl-count 'skip results
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

(ert-deftest harness-provider-check-answers-a-hosted-tool-call ()
  "A hosted loop's tool call is answered, so its turn ends by itself.
Claude Code is a hosted loop: it hands the turn a `tool-call' with a
`:respond' and writes nothing more until the result is sent.  A check
that never answers would wait for its timeout and look hung, and the
model behavior checks that ask for a tool call could never pass."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--hosted-tool t
          harness-provider-check-timeout 1)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'all)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results
                                    "Tool-call transport and tool-result continuation")
                                  :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Instruction following") :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Choose and form a harness tool call")
                                  :status)))
      (should (eq 'pass (plist-get (harness-provider-check-test-by-name
                                    results "Use the returned tool result") :status)))
      ;; The echo tool's answer is the receipt the model is asked to report,
      ;; so the tool-result check can see the model used what it was given.
      (should (cl-some (lambda (answer)
                         (let ((content (plist-get answer :content)))
                           (and (stringp content)
                                (string-prefix-p "receipt-" content))))
                       harness-provider-check-test--hosted-answers))
      ;; The instructions check's resubmit call is answered too: its turn
      ;; must end, not wait for a result that never comes.
      (should (cl-some (lambda (answer)
                         (equal "Resubmitted." (plist-get answer :content)))
                       harness-provider-check-test--hosted-answers)))))

(ert-deftest harness-provider-check-results-arrive-one-at-a-time ()
  "A job announces its plan, then each result before the next check."
  (harness-provider-check-test-with
    (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
           (started (car (harness-provider-check-test-events 'started))))
      (should (equal (nth 0 started) (harness-provider-check-job-id job)))
      (should (= 16 (nth 3 started)))
      (should (null (harness-provider-check-test-events 'result)))
      (harness-await (harness-provider-check-job-promise job) 10)
      (let ((results (harness-provider-check-test-events 'result)))
        (should (= 16 (length results)))
        (should (equal (mapcar (lambda (event) (nth 2 event)) results)
                       (number-sequence 1 16)))
        (should (= 16 (nth 3 (car (last results)))))
        (let ((finished (car (harness-provider-check-test-events 'finished))))
          (should (= 16 (length (nth 2 finished))))
          (should (= 16 (plist-get (nth 3 finished) :completed))))))))

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

(ert-deftest harness-provider-check-prompt-caching-is-conservative ()
  "The cache check reports observations, not a guarantee.
With a simulated prefix cache, repeated probes and keep-warm requests
read it while isolated controls stay cold.  A complete run of repeated
misses with clean controls is a FAIL for that run, while the capability
record still calls one run unverified, not unsupported; no telemetry is
unknown rather than zero, and stays a SKIP."
  (harness-provider-check-test-with
    (let ((harness-provider-check-test--cache-simulate t))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (cache (harness-provider-check-test-by-name
                     results "Exact-prefix cache reuse and keep-warm"))
             (evidence (plist-get cache :evidence)))
        (should (eq 'pass (plist-get cache :status)))
        (should (= 2 (plist-get evidence :repeat-hits)))
        (should (= 2 (plist-get (plist-get evidence :keep-warm) :refresh-hits)))
        (should (plist-get evidence :controls-clean))
        (should (plist-get evidence :distinct-sessions))
        (should (string-match-p "TTL unverified" (plist-get cache :detail)))))
    ;; Repeated misses with cold controls are a failure of this run, but the
    ;; record still calls one run unverified, not unsupported.
    (let ((harness-provider-check-test--cache-read 0))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (cache (harness-provider-check-test-by-name
                     results "Exact-prefix cache reuse and keep-warm")))
        (should (eq 'fail (plist-get cache :status)))
        (should (string-match-p "unverified, not unsupported" (plist-get cache :detail)))))
    ;; No telemetry is unknown, not zero: the check could not measure.
    (let ((harness-provider-check-test--cache-read nil))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (cache (harness-provider-check-test-by-name
                     results "Exact-prefix cache reuse and keep-warm")))
        (should (eq 'skip (plist-get cache :status)))
        (should (string-match-p "unknown, not zero" (plist-get cache :detail)))))))

(ert-deftest harness-provider-check-prompt-cache-verdict-classifies-runs ()
  "A cache check that measured misses fails; one that could not measure skips.
The status says whether the check ran, not whether the provider's cache
is unsupported: a complete run of misses is FAIL with the record still
unverified, and the detail says so."
  (let ((verdict (lambda (&rest evidence)
                   (harness-provider-check--prompt-cache-verdict evidence))))
    ;; A run that could not measure the claim is a skip.
    (let ((result (funcall verdict :environment '(quota))))
      (should (eq 'skip (car result)))
      (should (string-match-p "unavailable: quota" (cdr result))))
    (let ((result (funcall verdict :errors 1 :telemetry 'present)))
      (should (eq 'skip (car result)))
      (should (string-match-p "incomplete probes" (cdr result))))
    (let ((result (funcall verdict :telemetry 'missing :repeat-samples 2
                           :repeats '(nil nil))))
      (should (eq 'skip (car result)))
      (should (string-match-p "unknown, not zero" (cdr result))))
    (let ((result (funcall verdict :telemetry 'present :repeat-samples 1
                           :repeats '(0))))
      (should (eq 'skip (car result)))
      (should (string-match-p "1/2 repeat samples" (cdr result))))
    (let ((result (funcall verdict :telemetry 'present :repeat-samples 2
                           :repeats '(0 0) :controls-clean nil)))
      (should (eq 'skip (car result)))
      (should (string-match-p "control prefix warm" (cdr result))))
    ;; A complete measurement is a pass or a fail, never a skip.
    (let ((result (funcall verdict :telemetry 'present :repeat-samples 2
                           :repeats '(1000 1000) :repeat-hits 2
                           :controls-clean t)))
      (should (eq 'pass (car result)))
      (should (string-match-p "reuse observed" (cdr result))))
    (let ((result (funcall verdict :telemetry 'present :repeat-samples 2
                           :repeats '(0 0) :repeat-hits 0 :controls-clean t
                           :errors 0)))
      (should (eq 'fail (car result)))
      (should (string-match-p "repeated misses in one run" (cdr result)))
      (should (string-match-p "unverified, not unsupported" (cdr result))))
    (let ((result (funcall verdict :telemetry 'present :repeat-samples 2
                           :repeats '(1000 0) :repeat-hits 1 :controls-clean t
                           :errors 0)))
      (should (eq 'fail (car result)))
      (should (string-match-p "some repeats cached" (cdr result))))))

(ert-deftest harness-provider-check-independent-cache-verdict-classifies-runs ()
  "A complete independent-prefix miss run fails; an unmeasurable one skips.
Throttling, identity mixing, failed requests, warm controls and missing
telemetry leave the claim unmeasured; primed prefixes that missed, a
serial-only hit or partial reuse are failures of the run."
  (let* ((verdict (lambda (&rest evidence)
                    (harness-provider-check--independent-cache-verdict evidence)))
         (base '(:telemetry present :prefix-count 4 :cached-count 4
                 :baseline-hits 4 :round-1-hits 4 :round-2-hits 4
                 :control-hits 0 :peak-concurrency 4 :distinct-sessions t
                 :actual 18 :errors 0 :throttled 0 :identity-mismatches 0)))
    (let ((result (apply verdict (plist-put (copy-sequence base)
                                            :environment '(transport)))))
      (should (eq 'skip (car result)))
      (should (string-match-p "unavailable: transport" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base) :throttled 2))))
      (should (eq 'skip (car result)))
      (should (string-match-p "throttled" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base)
                                            :identity-mismatches 1))))
      (should (eq 'skip (car result)))
      (should (string-match-p "identity mismatched" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base) :errors 1))))
      (should (eq 'skip (car result)))
      (should (string-match-p "requests failed" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base)
                                            :distinct-sessions nil))))
      (should (eq 'skip (car result)))
      (should (string-match-p "session ids repeated" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base) :prefix-count 1))))
      (should (eq 'skip (car result)))
      (should (string-match-p "fewer than 2" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base)
                                            :telemetry 'missing))))
      (should (eq 'skip (car result)))
      (should (string-match-p "unknown, not zero" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base) :control-hits 1))))
      (should (eq 'skip (car result)))
      (should (string-match-p "isolation ambiguous" (cdr result))))
    (let ((result (apply verdict (plist-put (copy-sequence base)
                                            :peak-concurrency 1))))
      (should (eq 'skip (car result)))
      (should (string-match-p "did not overlap" (cdr result))))
    ;; A complete measurement is a pass or a fail, never a skip.
    (let ((result (apply verdict base)))
      (should (eq 'pass (car result)))
      (should (string-match-p "reuse observed" (cdr result))))
    (let ((result (apply verdict (plist-put (plist-put (copy-sequence base)
                                                       :round-1-hits 0)
                                            :round-2-hits 0))))
      (should (eq 'fail (car result)))
      (should (string-match-p "serial baseline reuse" (cdr result))))
    (let ((result (apply verdict (plist-put (plist-put (copy-sequence base)
                                                       :cached-count 2)
                                            :round-2-hits 2))))
      (should (eq 'fail (car result)))
      (should (string-match-p "partial reuse: 2/4" (cdr result)))
      (should (string-match-p "unverified, not unsupported" (cdr result))))
    (let* ((evidence (copy-sequence base))
           (evidence (plist-put evidence :cached-count 0))
           (evidence (plist-put evidence :baseline-hits 0))
           (evidence (plist-put evidence :round-1-hits 0))
           (evidence (plist-put evidence :round-2-hits 0))
           (result (apply verdict evidence)))
      (should (eq 'fail (car result)))
      (should (string-match-p "primed prefixes missed" (cdr result)))
      (should (string-match-p "unverified, not unsupported" (cdr result))))))

(ert-deftest harness-provider-check-cache-detail-reports-tokens-and-cost ()
  "The detail names prompt, cached and output tokens and how the cost was had."
  (let ((detail (harness-provider-check--cache-detail
                 '(:telemetry present :repeats (1000 1000) :repeat-hits 2
                   :repeat-samples 2 :controls-clean t
                   :context 5000 :cache-read 2000 :output 40
                   :persistence (:wait 2)
                   :keep-warm (:refresh (1000 1000) :refresh-hits 2
                                        :refresh-samples 2 :resume 1000)
                   :cost (:observed nil :estimated 0.002 :source catalogue)))))
    (should (string-match-p "prompt 5000 · cached 2000 · output 40" detail))
    (should (string-match-p "cost \$0\\.0020 estimated (catalogue)" detail)))
  (let ((detail (harness-provider-check--independent-detail
                 '(:prefix-count 4 :cached-count 4 :baseline-hits 4
                   :round-1-hits 4 :round-2-hits 4
                   :control-samples 2 :control-hits 0
                   :sessions ("a" "b" "c" "d") :requested-sessions 4
                   :distinct-sessions t :peak-concurrency 4 :throttled 0
                   :errors 0 :median-seconds 1.2
                   :context 9000 :cache-read 7000 :output 120
                   :cost (:observed 0.5 :estimated nil :source provider)))))
    (should (string-match-p "independent prefixes 4/4 cached" detail))
    (should (string-match-p "baseline 4/4" detail))
    (should (string-match-p "round 1 4/4 · round 2 4/4" detail))
    (should (string-match-p "controls 0/2 cached" detail))
    (should (string-match-p "sessions 4/4 (all distinct)" detail))
    (should (string-match-p "prompt 9000 · cached 7000 · output 120" detail))
    (should (string-match-p "cost \$0\\.5000 observed (provider)" detail))))

(ert-deftest harness-provider-check-tier-models-resolve ()
  "Every tier the provider declares must name a model of its catalogue.
A tier that matches none is a failure naming it, so a plan whose judges
fall back to the session's model says so; a catalogue of one model has
nothing to choose between and is skipped."
  (harness-provider-check-test-with
    (harness-define-provider 'checkfake
      :models (lambda () (harness-resolved '((:name "small") (:name "big"))))
      :complete #'harness-provider-check-test--complete
      :tiers '(:simple "small" :medium "big" :hard nil :frontier nil))
    (let* ((results (harness-provider-check-test-run "checkfake:big" 'provider))
           (tiers (harness-provider-check-test-by-name results "Tier model resolution")))
      (should (eq 'pass (plist-get tiers :status)))
      (should (string-match-p "simple: small" (plist-get tiers :detail)))
      (should (string-match-p "medium: big" (plist-get tiers :detail))))
    ;; A tier that matches no model leaves the harness on the session's.
    (harness-define-provider 'checkfake
      :models (lambda () (harness-resolved '((:name "small") (:name "big"))))
      :complete #'harness-provider-check-test--complete
      :tiers '(:simple "nano" :hard "big" :frontier nil))
    (let* ((results (harness-provider-check-test-run "checkfake:big" 'provider))
           (tiers (harness-provider-check-test-by-name results "Tier model resolution")))
      (should (eq 'fail (plist-get tiers :status)))
      (should (string-match-p "simple (none)" (plist-get tiers :detail)))
      (should (string-match-p "session's model" (plist-get tiers :advice))))
    ;; `frontier' is the user's to choose: the harness never asks for it,
    ;; so one the catalogue does not list is no fallback and no failure.
    (harness-define-provider 'checkfake
      :models (lambda () (harness-resolved '((:name "small") (:name "big"))))
      :complete #'harness-provider-check-test--complete
      :tiers '(:simple "small" :frontier "astra"))
    (let* ((results (harness-provider-check-test-run "checkfake:big" 'provider))
           (tiers (harness-provider-check-test-by-name results "Tier model resolution")))
      (should (eq 'pass (plist-get tiers :status)))
      (should (string-match-p "simple: small" (plist-get tiers :detail)))
      (should (string-match-p "frontier: none" (plist-get tiers :detail))))
    ;; One model: a tier has nothing to choose between.
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--complete
      :tiers '(:simple "model"))
    (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
           (tiers (harness-provider-check-test-by-name results "Tier model resolution")))
      (should (eq 'skip (plist-get tiers :status))))))

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
      (should (= 16 (length results))))))

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
  "Cancelling every request in flight ends the job with the results it has."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 5)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--hang)
    (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
           (id (harness-provider-check-job-id job))
           (deadline (+ (float-time) 5)))
      ;; Wait for a live request, which the cache check makes first.
      (while (and (zerop (harness-provider-check-job-request-count job))
                  (< (float-time) deadline))
        (accept-process-output nil 0.02)
        (sit-for 0.01))
      (should (> (harness-provider-check-job-request-count job) 0))
      (should (harness-provider-check-cancel id))
      (harness-await (harness-provider-check-job-promise job) 5)
      (let ((finished (car (harness-provider-check-test-events 'finished))))
        (should (harness-json-true-p (plist-get (nth 3 finished) :cancelled)))
        ;; The checks that settled before the cancel keep their results;
        ;; none that was in flight does, and the cache experiment, which
        ;; waits to run alone, never started.
        (should (< (length (nth 2 finished)) 16))
        (should (cl-every (lambda (result) (null (plist-get result :sessions)))
                          (nth 2 finished)))
        (should-not (cl-find "cache" (nth 2 finished)
                             :key (lambda (result) (plist-get result :id))
                             :test #'equal)))
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
      (should (= 16 (plist-get answer :total)))
      (should (= 16 (length (plist-get answer :checks))))
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

(ert-deftest harness-provider-check-transcript-round-trip-checks-its-own-nodes ()
  "The transcript round trip renders the harness's own transcript twice.
It writes a thinking node with its signature and a tool call with its
result, renders the request, reloads the transcript from the store and
renders again: both requests must carry the same thinking signature,
tool call and tool result."
  (harness-provider-check-test-with-session
    (harness-test-load-module 'agent)
    (let* ((original (symbol-function 'harness-agent-step-request))
           (requests nil)
           (results
            (cl-letf (((symbol-function 'harness-agent-step-request)
                       (lambda (sid state on-event)
                         (let ((request (funcall original sid state on-event)))
                           (push request requests)
                           request))))
              (harness-provider-check-test-run "checkfake:model" 'provider)))
           (round-trip (harness-provider-check-test-by-name
                        results "Transcript round trip"))
           (own (cl-remove-if-not
                 (lambda (request)
                   (cl-some (lambda (message)
                              (cl-some (lambda (block)
                                         (equal (plist-get block :text)
                                                "Round trip: read a.txt."))
                                       (plist-get message :content)))
                            (plist-get request :messages)))
                 requests)))
      (should (eq 'pass (plist-get round-trip :status)))
      (should (string-match-p "before and after a restart"
                              (plist-get round-trip :detail)))
      (should (= 2 (length own)))
      (should (equal (plist-get (nth 0 own) :messages)
                     (plist-get (nth 1 own) :messages)))
      (let ((blocks (apply #'append
                           (mapcar (lambda (message) (plist-get message :content))
                                   (plist-get (nth 0 own) :messages)))))
        (should (cl-some (lambda (block)
                           (and (equal (plist-get block :type) "thinking")
                                (equal (plist-get block :signature)
                                       "signature-round-trip")))
                         blocks))
        (should (cl-some (lambda (block)
                           (and (equal (plist-get block :type) "tool_use")
                                (equal (plist-get block :id) "call-round-trip")))
                         blocks))
        (should (cl-some (lambda (block)
                           (and (equal (plist-get block :type) "tool_result")
                                (equal (plist-get block :tool_use_id)
                                       "call-round-trip")))
                         blocks))))))

(ert-deftest harness-provider-check-transcript-round-trip-error-is-a-failure ()
  "An exception while rendering the harness's own transcript is a FAIL.
A SKIP would report the check's own error as an unverified result, which
is exactly the misreporting this check exists to prevent."
  (harness-provider-check-test-with-session
    (harness-test-load-module 'agent)
    (cl-letf (((symbol-function 'harness-agent-step-request)
               (lambda (&rest _) (error "rendering broke"))))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (round-trip (harness-provider-check-test-by-name
                          results "Transcript round trip")))
        (should (eq 'fail (plist-get round-trip :status)))
        (should (string-match-p "Harness render error"
                                (plist-get round-trip :detail)))
        (should (string-match-p "rendering broke"
                                (plist-get round-trip :detail)))))))

(ert-deftest harness-provider-check-transcript-round-trip-notices-a-dropped-render ()
  "A renderer that drops the thinking and tool blocks is a FAIL.
Rendering nothing twice is still the same request, so the check also
asserts that the blocks it built reached the request."
  (harness-provider-check-test-with-session
    (harness-test-load-module 'agent)
    (cl-letf (((symbol-function 'harness-agent-step-request)
               (lambda (&rest _) '(:system "system" :messages nil :tools nil))))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (round-trip (harness-provider-check-test-by-name
                          results "Transcript round trip")))
        (should (eq 'fail (plist-get round-trip :status)))
        (should (string-match-p "render missing" (plist-get round-trip :detail)))
        (should (string-match-p "thinking signature" (plist-get round-trip :detail)))
        (should (string-match-p "tool call" (plist-get round-trip :detail)))
        (should (string-match-p "tool result" (plist-get round-trip :detail)))))))


;;;; Bounded concurrency, dependencies and cancellation

(defun harness-provider-check-test--entry (id fn &rest keys)
  "Return a plan entry for check ID running FN with KEYS."
  (append (list :suite 'provider :id id :name id :requests 1 :fn fn) keys))

(ert-deftest harness-provider-check-independent-checks-run-together ()
  "Independent checks overlap, and their results still come back in plan order."
  (harness-provider-check-test-with
    (let ((order nil) (active 0) (peak 0) (finished 0))
      (cl-letf (((symbol-function 'harness-provider-check--plan)
                 (lambda (&rest _)
                   (list
                    (harness-provider-check-test--entry
                     "first" (lambda (job run)
                               (push 'first-start order)
                               (harness-then
                                (harness-provider-check--complete
                                 run (harness-provider-check--request
                                      (harness-provider-check-job-model job)
                                      "concurrency-first" "Reply ok."))
                                (lambda (_) '(pass . "first")))))
                    (harness-provider-check-test--entry
                     "second" (lambda (job run)
                                (push 'second-start order)
                                (harness-then
                                 (harness-provider-check--complete
                                  run (harness-provider-check--request
                                       (harness-provider-check-job-model job)
                                       "concurrency-second" "Reply ok."))
                                 (lambda (_) '(pass . "second")))))
                    (harness-provider-check-test--entry
                     "third" (lambda (job run)
                               (push 'third-start order)
                               (harness-then
                                (harness-provider-check--complete
                                 run (harness-provider-check--request
                                      (harness-provider-check-job-model job)
                                      "concurrency-third" "Reply ok."))
                                (lambda (_) '(pass . "third")))))))))
        (harness-define-provider 'checkfake
          :models #'harness-provider-check-test--models
          :complete (lambda (request)
                      (cl-incf active)
                      (setq peak (max peak active))
                      (let ((emit (plist-get request :on-event)))
                        (funcall emit '(:type start))
                        (run-at-time 0.05 nil
                                     (lambda ()
                                       (cl-decf active)
                                       (cl-incf finished)
                                       (funcall emit '(:type usage :input 1 :output 1))
                                       (funcall emit '(:type done :stop-reason end-turn))))
                        (list :cancel #'ignore))))
        (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
          (should (= 3 (length results)))
          (should (= 3 peak))
          (should (= 3 finished))
          (should (equal (mapcar (lambda (result) (plist-get result :id)) results)
                         '("first" "second" "third"))))))))

(ert-deftest harness-provider-check-dependencies-wait-for-their-result ()
  "A check listed first but marked `:after' runs only once its dependency settled."
  (harness-provider-check-test-with
    (let (order)
      (cl-letf (((symbol-function 'harness-provider-check--plan)
                 (lambda (&rest _)
                   (list
                    (harness-provider-check-test--entry
                     "second" (lambda (_job _run)
                                (push 'second order)
                                (cons 'pass "second"))
                     :after '("first"))
                    (harness-provider-check-test--entry
                     "first" (lambda (_job _run)
                               (push 'first order)
                               (cons 'pass "first")))))))
        (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
          (should (equal (nreverse order) '(first second)))
          (should (equal (mapcar (lambda (result) (plist-get result :id)) results)
                         '("second" "first"))))))))

(ert-deftest harness-provider-check-cache-probes-wait-for-the-catalogue ()
  "The cache probes carry the model's advertised identity, so the catalogue comes first."
  (let ((plan (harness-provider-check--plan 'provider)))
    (dolist (id '("cache" "cache-parallel"))
      (let ((entry (cl-find id plan :key (lambda (one) (plist-get one :id))
                            :test #'equal)))
        (should entry)
        (should (member "catalogue" (plist-get entry :after)))))))

(ert-deftest harness-provider-check-cost-is-observed-or-estimated ()
  "A reported cost wins; without one the catalogue prices estimate it."
  (harness-provider-check-test-with
    (let ((job (make-harness-provider-check-job
                :metadata (harness-call 'provider/model "checkfake:model"))))
      ;; The fake model has no prices: the cost is unknown, not zero.
      (should-not (harness-provider-check--usage-cost
                   job '(:input 1000000 :output 1000000)))
      ;; A cost the provider reports is used as observed.
      (should (equal (harness-provider-check--usage-cost
                      job '(:input 1000000 :output 1000000 :cost 0.5))
                     '(0.5 . provider))))
    (harness-define-provider 'checkfake
      :models (lambda ()
                (harness-resolved
                 '((:name "model" :context-window 100000
                    :pricing (:input 1.0 :output 2.0 :cache-read 0.1)))))
      :complete #'harness-provider-check-test--complete)
    (let ((job (make-harness-provider-check-job
                :metadata (harness-call 'provider/model "checkfake:model"))))
      (should (equal (harness-provider-check--usage-cost
                      job '(:input 1000000 :output 1000000 :cache-read 1000000))
                     '(3.1 . catalogue))))))

(ert-deftest harness-provider-check-cache-experiments-run-alone ()
  "A solo cache experiment starts nothing else while it measures concurrency."
  (harness-provider-check-test-with
    (let (order)
      (cl-letf (((symbol-function 'harness-provider-check--plan)
                 (lambda (&rest _)
                   (list
                    (harness-provider-check-test--entry
                     "solo" (lambda (_job _run)
                              (harness-then
                               (harness-provider-check--delay 0.2)
                               (lambda (_)
                                 (push 'solo order)
                                 (cons 'pass "solo"))))
                     :solo t)
                    (harness-provider-check-test--entry
                     "ordinary" (lambda (_job _run)
                                  (push 'ordinary order)
                                  (cons 'pass "ordinary")))))))
        (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
          (should (equal (nreverse order) '(solo ordinary)))
          (should (equal (mapcar (lambda (result) (plist-get result :id)) results)
                         '("solo" "ordinary"))))))))

(ert-deftest harness-provider-check-cancels-every-request-in-flight ()
  "Cancelling a job cancels every live request, not one shared handle."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 5)
    (let (cancelled)
      (cl-letf (((symbol-function 'harness-provider-check--plan)
                 (lambda (&rest _)
                   (list
                    (harness-provider-check-test--entry
                     "one" (lambda (job run)
                             (harness-provider-check--complete
                              run (harness-provider-check--request
                                   (harness-provider-check-job-model job)
                                   "cancel-one" "Reply ok."))))
                    (harness-provider-check-test--entry
                     "two" (lambda (job run)
                             (harness-provider-check--complete
                              run (harness-provider-check--request
                                   (harness-provider-check-job-model job)
                                   "cancel-two" "Reply ok."))))))))
        (harness-define-provider 'checkfake
          :models #'harness-provider-check-test--models
          :complete (lambda (request)
                      (let ((emit (plist-get request :on-event)))
                        (funcall emit '(:type start))
                        (list :cancel (lambda ()
                                        (push (plist-get (plist-get request :session) :id)
                                              cancelled)
                                        (funcall emit '(:type done :stop-reason cancelled)))))))
        (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
               (deadline (+ (float-time) 5)))
          (while (and (< (harness-provider-check-job-request-count job) 2)
                      (< (float-time) deadline))
            (accept-process-output nil 0.02)
            (sit-for 0.01))
          (should (= 2 (harness-provider-check-job-request-count job)))
          (should (harness-provider-check-cancel (harness-provider-check-job-id job)))
          (harness-await (harness-provider-check-job-promise job) 5)
          (should (= 2 (length cancelled)))
          (should (= 2 (length (delete-dups (copy-sequence cancelled)))))
          (let ((finished (car (harness-provider-check-test-events 'finished))))
            (should (harness-json-true-p (plist-get (nth 3 finished) :cancelled)))))))))

(ert-deftest harness-provider-check-request-budget-bounds-a-job ()
  "A job past its request bound starts no request and reports SKIP, not FAIL."
  (harness-provider-check-test-with
    (let ((harness-provider-check-max-requests 1))
      (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
        (should (= 1 (length harness-provider-check-test--calls)))
        (should-not (cl-find 'fail results :key (lambda (result)
                                                   (plist-get result :status))))
        (should (string-match-p
                 "Request budget"
                 (mapconcat (lambda (result) (or (plist-get result :detail) ""))
                            results " ")))))))

(ert-deftest harness-provider-check-total-timeout-stops-a-job ()
  "A job has a whole-run bound too, and reports what it completed."
  (harness-provider-check-test-with
    (setq harness-provider-check-timeout 30
          harness-provider-check-total-timeout 1)
    (harness-define-provider 'checkfake
      :models #'harness-provider-check-test--models
      :complete #'harness-provider-check-test--hang)
    (let* ((job (harness-provider-check-start "checkfake:model" 'provider))
           (results (harness-await (harness-provider-check-job-promise job) 6))
           (finished (car (harness-provider-check-test-events 'finished))))
      (should (listp results))
      (should (harness-json-true-p (plist-get (nth 3 finished) :timed-out)))
      (should (harness-json-true-p (plist-get (nth 3 finished) :cancelled))))))

;;;; Cache evidence and independent-prefix identity

(defun harness-provider-check-test--independent-cross (&optional cached baseline)
  "Return independent-prefix evidence of four prefixes.
CACHED of them hit in both concurrent rounds and BASELINE of them hit in
the serial baseline.  The controls are cold and every other guard is
clean, so a test can change one field and watch the classification."
  (let* ((cached (or cached 4))
         (baseline (or baseline 4))
         (prefixes (cl-loop for i below 4
                            collect (list :index i
                                          :prefix (format "prefix-%d" i)
                                          :session-id (format "session-%d" i)
                                          :baseline-hit (< i baseline)
                                          :round-1-hit (< i cached)
                                          :round-2-hit (< i cached)
                                          :cached (< i cached)))))
    (list :telemetry 'present
          :prefixes prefixes
          :controls (cl-loop for i below 2
                             collect (list :index i
                                           :prefix (format "control-%d" i)
                                           :session-id (format "control-session-%d" i)
                                           :cache-read 0))
          :control-samples 2
          :control-hits 0
          :controls-clean t
          :requested-sessions 4
          :prefix-count 4
          :cached-count cached
          :baseline-hits baseline
          :round-1-hits cached
          :round-2-hits cached
          :peak-concurrency 4
          :distinct-sessions t
          :identity-mismatches 0
          :throttled 0
          :errors 0
          :environment nil)))

(defun harness-provider-check-test--finding (findings key capability)
  "Return the finding of CAPABILITY at KEY in FINDINGS."
  (cl-find capability (plist-get findings key)
           :key (lambda (finding) (plist-get finding :capability))))

(ert-deftest harness-provider-check-cache-findings-are-conservative ()
  "One hit is an observation; repeated misses need two runs to say unsupported."
  (let* ((cache '(:telemetry present :repeat-samples 2 :repeat-hits 2
                  :controls-clean t :repeat-seconds (0.1 0.2)
                  :keep-warm (:refresh-samples 2 :refresh-hits 2 :resume 1000)
                  :persistence (:wait 2 :sample 1000)
                  :control (:resume 1000)))
         (findings (harness-provider-check--cache-findings cache nil nil)))
    (should (harness-provider-check-test--finding
             findings :observed 'prompt-cache-exact-prefix))
    (should (harness-provider-check-test--finding
             findings :observed 'prompt-cache-keep-warm-reuse))
    (should (harness-provider-check-test--finding
             findings :unverified 'prompt-cache-ttl)))
  ;; One run of repeated misses with cold controls is unverified.
  (let* ((cache '(:telemetry present :repeat-samples 2 :repeat-hits 0
                  :controls-clean t :environment nil
                  :keep-warm (:refresh-samples 2 :refresh-hits 0 :resume 0)
                  :persistence (:wait 2 :sample 0)
                  :control (:resume 0)))
         (findings (harness-provider-check--cache-findings cache nil nil)))
    (should (harness-provider-check-test--finding
             findings :unverified 'prompt-cache-exact-prefix))
    (should-not (plist-get findings :unsupported))
    ;; The same miss in a second independent run makes it unsupported.
    (let ((again (harness-provider-check--cache-findings
                  cache nil (list :cache-miss-runs 1))))
      (should (harness-provider-check-test--finding
               again :unsupported 'prompt-cache-exact-prefix))))
  ;; Missing telemetry is unknown, not zero.
  (let ((findings (harness-provider-check--cache-findings
                   '(:telemetry missing :repeat-samples 2 :repeat-hits 0) nil nil)))
    (should (harness-provider-check-test--finding
             findings :unverified 'prompt-cache-exact-prefix))))

(ert-deftest harness-provider-check-independent-findings-are-conservative ()
  "Independent-prefix reuse is observed only when every own prefix hits.
A partial batch, a warm control, a throttle, missing telemetry, identity
mixing or a single run is unverified; repeated misses need two runs."
  (let* ((findings (harness-provider-check--cache-findings
                    nil (harness-provider-check-test--independent-cross) nil)))
    (should (harness-provider-check-test--finding
             findings :observed 'independent-prefix-cache-reuse))
    (should (equal "fresh never-primed prefixes cold"
                   (plist-get (harness-provider-check-test--finding
                               findings :observed 'independent-prefix-cache-reuse)
                              :controls))))
  ;; Some prefixes hit, some did not: partial reuse is not an observation.
  (let* ((findings (harness-provider-check--cache-findings
                    nil (harness-provider-check-test--independent-cross 2) nil)))
    (should (harness-provider-check-test--finding
             findings :unverified 'independent-prefix-cache-reuse))
    (should (string-match-p
             "partial"
             (plist-get (harness-provider-check-test--finding
                         findings :unverified 'independent-prefix-cache-reuse)
                        :reason)))
    (should-not (plist-get findings :unsupported)))
  ;; One run of misses is unverified; the same miss in a second run is not.
  (let* ((cross (harness-provider-check-test--independent-cross 0 0))
         (first (harness-provider-check--cache-findings nil cross nil)))
    (should (harness-provider-check-test--finding
             first :unverified 'independent-prefix-cache-reuse))
    (should-not (plist-get first :unsupported))
    (let ((again (harness-provider-check--cache-findings
                  nil cross (list :cross-miss-runs 1))))
      (should (harness-provider-check-test--finding
               again :unsupported 'independent-prefix-cache-reuse))))
  ;; A throttle is no capability verdict, and neither is missing telemetry.
  (dolist (change '((:throttled 2) (:telemetry missing) (:identity-mismatches 1)
                    (:control-hits 1) (:peak-concurrency 1) (:discard t)))
    (let* ((cross (harness-provider-check-test--independent-cross))
           (cross (if (equal change '(:discard t))
                      (plist-put (copy-sequence cross) :distinct-sessions nil)
                    (let ((copy (copy-sequence cross)))
                      (while change
                        (setq copy (plist-put copy (car change) (cadr change)))
                        (setq change (cddr change)))
                      copy)))
           (findings (harness-provider-check--cache-findings nil cross nil)))
      (should (harness-provider-check-test--finding
               findings :unverified 'independent-prefix-cache-reuse))
      (should-not (harness-provider-check-test--finding
                   findings :observed 'independent-prefix-cache-reuse))
      (should-not (plist-get findings :unsupported))))
  ;; The serial baseline can hit while the concurrent rounds miss: that is
  ;; a concurrency effect, which is unverified, not a hit.
  (let* ((findings (harness-provider-check--cache-findings
                    nil (harness-provider-check-test--independent-cross 0 4) nil)))
    (should (harness-provider-check-test--finding
             findings :unverified 'independent-prefix-cache-reuse))
    (should (string-match-p
             "concurrent"
             (plist-get (harness-provider-check-test--finding
                         findings :unverified 'independent-prefix-cache-reuse)
                        :reason)))))

(ert-deftest harness-provider-check-independent-prefixes-are-distinct-and-stable ()
  "Every independent session has its own early prefix and one session id.
This is the regression that a single shared prefix would fail: each
prefix is the very first thing in its system prompt, differs from every
other prefix, and keeps one session id through prime, baseline and both
concurrent rounds."
  (let* ((job (make-harness-provider-check-job :model "checkfake:model"))
         (specs (harness-provider-check--independent-session-specs job 4))
         (primed (cl-remove-if (lambda (spec) (plist-get spec :control)) specs))
         (controls (cl-remove-if-not (lambda (spec) (plist-get spec :control)) specs))
         (prefixes (delete-dups (mapcar (lambda (spec) (plist-get spec :prefix)) primed)))
         (systems (delete-dups
                   (mapcar (lambda (spec) (plist-get (plist-get spec :request) :system))
                           primed))))
    (should (= 18 (length specs)))
    (should (= 4 (length prefixes)))
    (should (= 4 (length systems)))
    (should (= 2 (length controls)))
    ;; The serial primes and baselines come first, one prefix at a time;
    ;; only then do the concurrent rounds and the controls run.
    (should (equal (mapcar (lambda (spec) (plist-get spec :phase))
                           (cl-subseq specs 0 8))
                   '(prime baseline prime baseline prime baseline prime baseline)))
    (should (eq 'round-1 (plist-get (nth 8 specs) :phase)))
    (should (eq 'round-2 (plist-get (nth 12 specs) :phase)))
    (should (eq 'control (plist-get (nth 16 specs) :phase)))
    ;; One system prompt per prefix, and each begins with that prefix.
    (dotimes (i 4)
      (let* ((group (cl-remove-if-not
                     (lambda (spec)
                       (and (not (plist-get spec :control))
                            (eql (plist-get spec :index) i)))
                     specs))
             (group-systems (mapcar (lambda (spec)
                                      (plist-get (plist-get spec :request) :system))
                                    group))
             (sessions (delete-dups
                        (mapcar (lambda (spec) (plist-get spec :session-id)) group)))
             (firsts (delete-dups
                      (mapcar (lambda (spec)
                                (plist-get (car (plist-get (plist-get spec :request)
                                                           :messages))
                                           :content))
                              group))))
        (should (= 4 (length group)))
        (should (= 1 (length (delete-dups group-systems))))
        (should (string-prefix-p (plist-get (car group) :prefix)
                                 (car group-systems)))
        (should (= 1 (length sessions)))
        (should (= 1 (length firsts)))))
    ;; The four prefixes are distinct, each starts its own system prompt (the
    ;; assertion above), and no control shares one.
    (should-not (cl-some (lambda (control)
                           (member (plist-get control :prefix) prefixes))
                         controls))
    ;; Round 2 asks for the same prefixes in the reverse order.
    (let ((round-1 (cl-remove-if-not (lambda (spec)
                                       (eq (plist-get spec :phase) 'round-1))
                                     specs))
          (round-2 (cl-remove-if-not (lambda (spec)
                                       (eq (plist-get spec :phase) 'round-2))
                                     specs)))
      (should (equal (mapcar (lambda (spec) (plist-get spec :index)) round-1)
                     (reverse (mapcar (lambda (spec) (plist-get spec :index))
                                      round-2))))
      (should (equal (sort (mapcar (lambda (spec) (plist-get spec :prefix))
                                   round-1)
                           #'string<)
                     (sort (mapcar (lambda (spec) (plist-get spec :prefix))
                                   round-2)
                           #'string<))))))

(ert-deftest harness-provider-check-independent-prefixes-are-primed-and-concurrent ()
  "Each session primes its own prefix, then reuses that same prefix.
The fake provider's prefix cache hits only a system prompt and first
message it has seen, so a shared prefix, a swapped session or an
unprimed round would show up as a miss or as identity mixing."
  (harness-provider-check-test-with
    (let ((harness-provider-check-test--cache-simulate t))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (cross (harness-provider-check-test-by-name
                     results "Independent-prefix cache reuse"))
             (evidence (plist-get cross :evidence)))
        (should (eq 'pass (plist-get cross :status)))
        (should (= 4 (plist-get evidence :prefix-count)))
        (should (= 4 (plist-get evidence :cached-count)))
        (should (= 4 (plist-get evidence :baseline-hits)))
        (should (= 4 (plist-get evidence :round-1-hits)))
        (should (= 4 (plist-get evidence :round-2-hits)))
        (should (= 2 (plist-get evidence :control-samples)))
        (should (zerop (plist-get evidence :control-hits)))
        (should (plist-get evidence :distinct-sessions))
        (should (zerop (plist-get evidence :identity-mismatches)))
        (should (= 4 (plist-get evidence :peak-concurrency)))
        (should (string-match-p "independent-prefix reuse observed"
                                (plist-get cross :detail)))
        (let* ((requests
                (cl-remove-if-not
                 (lambda (request)
                   (string-prefix-p
                    "provider-check-independent-"
                    (or (plist-get (plist-get request :session) :id) "")))
                 harness-provider-check-test--calls))
               (primed (cl-remove-if
                        (lambda (request)
                          (string-match-p
                           "-control-[0-9]+\\'"
                           (plist-get (plist-get request :session) :id)))
                        requests)))
          (should (= 18 (length requests)))
          (should (= 16 (length primed)))
          ;; Each prefix's four requests share one system and one session.
          (dolist (prefix (plist-get evidence :prefixes))
            (let* ((session-id (plist-get prefix :session-id))
                   (own (cl-remove-if-not
                         (lambda (request)
                           (equal (plist-get (plist-get request :session) :id)
                                  session-id))
                         requests)))
              (should (= 4 (length own)))
              (should (= 1 (length (delete-dups
                                    (mapcar (lambda (request)
                                              (plist-get request :system))
                                            own)))))
              (should (string-prefix-p
                       (plist-get prefix :prefix)
                       (plist-get (car own) :system)))))
          ;; Four different primed prefixes, not one shared prefix.
          (should (= 4 (length (delete-dups
                                (mapcar (lambda (request)
                                          (plist-get request :system))
                                        primed)))))
          ;; The controls were never primed: their systems are new.
          (should (= 2 (length (delete-dups
                                (mapcar (lambda (request)
                                          (plist-get request :system))
                                        (cl-set-difference requests primed)))))))))))

(ert-deftest harness-provider-check-independent-prefixes-missing-is-a-failure ()
  "A complete independent-prefix run with no reuse fails, not skips.
Every primed prefix and the fresh controls report zero cached tokens:
the check ran, measured every prefix, and the reuse it tests did not
happen.  The capability record still calls one run unverified."
  (harness-provider-check-test-with
    (let ((harness-provider-check-test--cache-read 0))
      (let* ((results (harness-provider-check-test-run "checkfake:model" 'provider))
             (cross (harness-provider-check-test-by-name
                     results "Independent-prefix cache reuse"))
             (evidence (plist-get cross :evidence)))
        (should (eq 'fail (plist-get cross :status)))
        (should (= 4 (plist-get evidence :prefix-count)))
        (should (zerop (plist-get evidence :cached-count)))
        (should (zerop (plist-get evidence :baseline-hits)))
        (should (zerop (plist-get evidence :round-1-hits)))
        (should (zerop (plist-get evidence :round-2-hits)))
        (should (zerop (plist-get evidence :control-hits)))
        (should (string-match-p "primed prefixes missed" (plist-get cross :detail)))
        (should (string-match-p "unverified, not unsupported"
                                (plist-get cross :detail)))))))

(ert-deftest harness-provider-check-independent-prefixes-reject-shared-and-mixed ()
  "One shared prefix, or one session used for two prefixes, is not evidence.
The old shared-only experiment would pass one prefix to every session;
the editor's usual desktop has different early content in every session,
so the classification must not call that independent-prefix reuse."
  (let* ((job (make-harness-provider-check-job :model "checkfake:model"))
         (specs (harness-provider-check--independent-session-specs job 4))
         (primed (cl-remove-if (lambda (spec) (plist-get spec :control)) specs))
         (first (car primed))
         ;; The old shape: every primed request carries one prefix and one
         ;; session id.
         (shared (mapcar (lambda (spec)
                           (let ((copy (copy-sequence spec)))
                             (setf (plist-get copy :prefix) (plist-get first :prefix)
                                   (plist-get copy :session-id)
                                   (plist-get first :session-id))
                             copy))
                         specs))
         (results-of
          (lambda (specs)
            (mapcar (lambda (spec)
                      (list :phase (plist-get spec :phase)
                            :prefix (plist-get spec :prefix)
                            :index (plist-get spec :index)
                            :control (plist-get spec :control)
                            :session-id (plist-get spec :session-id)
                            :cache-read 1000 :input 100 :output 5
                            :seconds 1.0 :started-at 0.0
                            :telemetry 'present))
                    specs))))
    ;; Shared prefix and session: the evidence says the sessions repeat.
    (let* ((evidence (harness-provider-check--independent-evidence
                      job shared (funcall results-of shared)))
           (findings (harness-provider-check--cache-findings nil evidence nil)))
      (should-not (plist-get evidence :distinct-sessions))
      (should (harness-provider-check-test--finding
               findings :unverified 'independent-prefix-cache-reuse))
      (should-not (harness-provider-check-test--finding
                   findings :observed 'independent-prefix-cache-reuse)))
    ;; One session's result carrying another prefix's session is mixing.
    (let* ((results (funcall results-of specs))
           (other (plist-get (cadr primed) :session-id))
           (moved (mapcar (lambda (result)
                            (if (eq (plist-get result :phase) 'round-1)
                                (plist-put result :session-id other)
                              result))
                          results))
           (evidence (harness-provider-check--independent-evidence
                      job specs moved))
           (findings (harness-provider-check--cache-findings nil evidence nil)))
      (should (> (plist-get evidence :identity-mismatches) 0))
      (should (harness-provider-check-test--finding
               findings :unverified 'independent-prefix-cache-reuse))
      (should-not (harness-provider-check-test--finding
                   findings :observed 'independent-prefix-cache-reuse)))))

(ert-deftest harness-provider-check-cache-stress-is-bounded-and-opt-in ()
  "The ordinary run uses 4 sessions; the stress option asks for 12, bounded.
The stress runs the cache checks only, so the bounded plan stays under
the request bound without raising it."
  (harness-provider-check-test-with
    (let ((harness-provider-check-test--cache-simulate t))
      (let* ((job (harness-provider-check-start
                   "checkfake:model" 'provider nil nil '(:cache-stress t)))
             (results (harness-await (harness-provider-check-job-promise job) 30))
             (cross (harness-provider-check-test-by-name
                     results "Independent-prefix cache reuse")))
        (should (= 4 (length results)))
        (should (= 12 (plist-get (plist-get cross :evidence) :requested-sessions)))
        (should (= 12 (plist-get (plist-get cross :evidence) :prefix-count)))
        (should (= 12 (plist-get (plist-get cross :evidence) :cached-count)))
        (should (= 12 (plist-get (plist-get cross :evidence) :peak-concurrency)))
        (should (= 3 (harness-provider-check-job-concurrency job)))
        (should (= 12 (harness-provider-check-job-request-concurrency job)))
        (should (= 59 (harness-provider-check-job-request-count job)))
        (should (<= (harness-provider-check-job-request-count job)
                    harness-provider-check-max-requests))))))

(ert-deftest harness-provider-check-cache-evidence-is-kept-and-scoped ()
  "Evidence is persisted, read back, and stale when the provider configuration changes."
  (harness-test-with-temp-state
    (harness-provider-check-test-with
      (let ((harness-provider-check-test--cache-simulate t))
        (harness-provider-check-test-run "checkfake:model" 'provider)
        (let* ((answer (harness-call 'provider/cache-evidence "checkfake:model"))
               (record (plist-get answer :record))
               (findings (plist-get record :findings)))
          (should answer)
          (should-not (plist-get answer :stale))
          (should (harness-provider-check-test--finding
                   findings :observed 'prompt-cache-exact-prefix))
          (should (harness-provider-check-test--finding
                   findings :observed 'independent-prefix-cache-reuse))
          (should (harness-provider-check-test--finding
                   findings :unverified 'prompt-cache-ttl))
          (should (equal (plist-get record :model) "checkfake:model"))
          (should (= 2 (plist-get record :schema))))
        ;; A changed capability scope invalidates the old record.
        (harness-define-provider 'checkfake
          :models #'harness-provider-check-test--models
          :complete #'harness-provider-check-test--complete
          :capabilities '(:cache-ttl 999))
        (should (plist-get (harness-call 'provider/cache-evidence "checkfake:model")
                           :stale))))))

(ert-deftest harness-provider-check-estimate-bounds-before-a-paid-run ()
  "The estimate gives request and output bounds, and says when cost is unknown."
  (harness-provider-check-test-with
    (let ((estimate (harness-call 'provider/check-estimate "checkfake:model" "provider")))
      (should (= 16 (plist-get estimate :checks)))
      (should (= 35 (plist-get estimate :requests)))
      (should (= harness-provider-check-max-output-tokens
                 (plist-get estimate :max-output)))
      (should-not (plist-get estimate :cost))
      (should (string-match-p "unknown" (plist-get estimate :basis))))
    (let ((stress (harness-call 'provider/check-estimate
                               "checkfake:model" "provider" '(:cache-stress t))))
      (should (= 4 (plist-get stress :checks)))
      (should (= 59 (plist-get stress :requests))))
    (harness-define-provider 'checkfake
      :models (lambda ()
                (harness-resolved
                 '((:name "model" :context-window 100000
                    :pricing (:input 1.0 :output 2.0 :cache-read 0.1)))))
      :complete #'harness-provider-check-test--complete)
    (let ((estimate (harness-call 'provider/check-estimate "checkfake:model" "provider")))
      (should (numberp (plist-get estimate :cost)))
      (should (> (plist-get estimate :cost) 0)))))

(ert-deftest harness-provider-check-rate-limit-does-not-become-a-verdict ()
  "A throttled cache probe is unverified, and no fail is reported."
  (harness-provider-check-test-with
    (setq harness-provider-check-test--error-kind 'rate-limit)
    (let ((results (harness-provider-check-test-run "checkfake:model" 'provider)))
      (should-not (cl-find 'fail results :key (lambda (result)
                                                 (plist-get result :status))))
      (dolist (name '("Exact-prefix cache reuse and keep-warm"
                      "Independent-prefix cache reuse"))
        (let ((result (harness-provider-check-test-by-name results name)))
          (should (eq 'skip (plist-get result :status)))
          (should (string-match-p "unavailable" (plist-get result :detail))))))))

(provide 'harness-provider-check-test)
;;; harness-provider-check-test.el ends here
