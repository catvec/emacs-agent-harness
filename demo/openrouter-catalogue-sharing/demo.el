;;; demo.el --- One shared catalogue, refreshed about every 15 minutes  -*- lexical-binding: t; -*-

;;; Commentary:

;; The reported failure, and what the harness does now.
;;
;;   OpenRouter routing paused (catalogue-unavailable): the endpoint
;;   catalogue could not be read: HTTP 200: request timed out after 20s
;;
;; Three things were wrong, and this demo shows all three.
;;
;; 1. Every new session, every stale-pin revalidation and every
;;    permission judge forced a catalogue fetch, even when the process
;;    already held a reading of the same model.  A momentary failure of
;;    that fetch stopped a session that had nothing to learn: the reading
;;    was already there.  Now the reading is the model's, shared by every
;;    caller, and one inside `harness-openrouter-catalogue-ttl' (900 s)
;;    answers without a request at all.
;;
;; 2. A reading past that interval made the caller wait for a fetch.
;;    Now it is answered at once from the reading in hand -- the read
;;    starts behind the caller -- while the policy's `:freshness' still
;;    admits it.  A judge starts no read of its own at all.
;;
;; 3. A failed refresh rejected outright, so an outage stopped sessions
;;    even while a reading inside the operator's freshness bound was in
;;    hand.  Now a failed refresh is answered from that reading, marked
;;    stale and said so; a reading outside the bound still stops the
;;    session, and nothing is invented when there is no reading at all.
;;    Bounded background re-reads work on getting a fresh one.
;;
;; Offline: the catalogue transport is a stub, no policy is installed in
;; the harness and no network is touched.
;;
;;   demo/openrouter-catalogue-sharing/demo.sh
;;
;; The same output is in demo/openrouter-catalogue-sharing/expected.txt.

;;; Code:

(require 'harness-util)
(require 'harness-core)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)

(defconst demo-model "deepseek/deepseek-v4.1-flash-1017")

(defconst demo-catalogue
  (list :data
        (list :id demo-model
              :endpoints
              (vector (list :name (format "DeepInfra | %s" demo-model)
                            :model_id demo-model :provider_name "DeepInfra"
                            :tag "deepinfra/fp8" :quantization "fp8"
                            :context_length 1048576
                            :supported_parameters '("tools" "response_format"
                                                    "structured_outputs")
                            :pricing '(:prompt "0.000000098"
                                       :completion "0.000000294"
                                       :input_cache_read "0.00000000294"
                                       :discount 0.51))))))

(defun demo-policy (&rest overrides)
  "Return a complete routing policy, with OVERRIDES applied."
  (let ((policy (list :enabled t :model demo-model :providers '("DeepInfra")
                      :max-price '(:prompt 0.15 :completion 0.60 :cache-read 0.003)
                      :freshness 3600)))
    (while overrides
      (setq policy (plist-put policy (car overrides) (cadr overrides))
            overrides (cddr overrides)))
    policy))

;;;; A stub transport that counts the reads and sends it is asked for

(defvar demo-reads 0 "Catalogue reads the stub has served in this case.")
(defvar demo-sent 0 "Completions that reached the stub transport.")
(defvar demo-pinned nil "The endpoint the last completion was restricted to.")
(defvar demo-answer nil "What the stub answers a catalogue read with.")
(defvar demo-held nil "Catalogue reads the stub is holding, oldest first.")
(defvar demo-hold nil "When non-nil, catalogue reads are held, not answered.")
(defvar demo-hints nil "Hints the last dispatch left on its session.")
(defvar demo-quiet nil "When non-nil, a dispatch prints its outcome and no hints.")

(defun demo-http (url &rest args)
  "Answer URL for the stub transport, and count what it is asked for."
  (let ((handle (make-harness-http-handle :url url :started (float-time))))
    (cond
     ((string-match-p "/endpoints\\'" url)
      (cl-incf demo-reads)
      (if demo-hold
          (setq demo-held (append demo-held (list args)))
        (let ((answer demo-answer))
          (harness-run-soon
           (lambda ()
             (cond
              ((eq answer 'timeout)
               (funcall (plist-get args :callback) nil nil ""
                        (list 'http-error 200
                              (list 'timeout "request timed out after 20s"))))
              ((eq answer 'fail)
               (funcall (plist-get args :callback) nil nil ""
                        (list 'http-error 503 "upstream unavailable")))
              (t (funcall (plist-get args :callback) 200 nil
                          (harness-json-encode demo-catalogue) nil))))))))
     ;; The model record: a new session's pin reads it for the canonical
     ;; slug OpenRouter reports beside the id it was asked for.
     ((string-match-p "/model/" url)
      (harness-run-soon
       (lambda ()
         (funcall (plist-get args :callback) 200 nil
                  (harness-json-encode
                   (list :data (list :id demo-model
                                     :canonical_slug
                                     "deepseek/deepseek-v4.1-flash-20261017")))
                  nil))))
     ;; A completion is recorded, not answered: what a send is here is that
     ;; it reached the transport, restricted to the pin.
     ((string-match-p "/chat/completions\\'" url)
      (cl-incf demo-sent)
      (setq demo-pinned (car (append (plist-get (plist-get (plist-get args :json)
                                                           :provider)
                                                :only)
                                     nil)))
      nil)
     (t nil))
    handle))

(defun demo-answer-held ()
  "Answer the oldest held catalogue read with the fixture."
  (let ((args (car demo-held)))
    (setq demo-held (cdr demo-held))
    (funcall (plist-get args :callback) 200 nil
             (harness-json-encode demo-catalogue) nil)))

(defun demo-fail-held ()
  "Fail the oldest held catalogue read, as a 503."
  (let ((args (car demo-held)))
    (setq demo-held (cdr demo-held))
    (funcall (plist-get args :callback) nil nil ""
             (list 'http-error 503 "upstream unavailable"))))

(defun demo-outcome (done)
  "Return the words for how one dispatch ended, DONE its `done' event."
  (cond
   ((and done (eq (plist-get done :stop-reason) 'end-turn))
    (format "SEND, restricted to %s" (or demo-pinned "no endpoint")))
   (done (format "STOP (%s): %s" (plist-get done :error-kind)
                 (plist-get done :error)))
   ((plusp demo-sent)
    (format "SEND, restricted to %s (the stub transport does not answer)"
            (or demo-pinned "no endpoint")))
   (t "nothing was sent")))

(defun demo-status-line ()
  "Return the catalogue's state, as `harness-openrouter-catalogue-status' has it."
  (let ((status (harness-openrouter-catalogue-status demo-model)))
    (format "%s, %s, %s" (plist-get status :state)
            (if (numberp (plist-get status :age))
                (format "%d s old" (round (plist-get status :age)))
              "no reading")
            (if (eq 'usable (plist-get status :reading))
                "usable" (format "%s to decide from" (plist-get status :reading))))))

(defmacro demo-with-world (&rest body)
  "Run BODY with the module's tables empty and the stub transport in place."
  (declare (indent 0))
  `(let* ((harness-openrouter-routing (demo-policy))
          (harness-openrouter--catalogue (make-hash-table :test 'equal))
          (harness-openrouter--fetching (make-hash-table :test 'equal))
          (harness-openrouter--catalogue-failures (make-hash-table :test 'equal))
          (harness-openrouter--invalidations (make-hash-table :test 'equal))
          (harness-openrouter--canonical (make-hash-table :test 'equal))
          (harness-openai--models-cache (make-hash-table :test 'eq)))
     (setq demo-reads 0 demo-sent 0 demo-pinned nil demo-held nil demo-hold nil)
     (cl-letf (((symbol-function 'harness-http-request) #'demo-http))
       ,@body)))

(defun demo-seed (age)
  "Store a reading of the demo catalogue AGE seconds old."
  (puthash demo-model
           (list :at (- (float-time) age)
                 :endpoints (harness-openrouter-parse-endpoints
                             (harness-json-parse (harness-json-encode demo-catalogue))))
           harness-openrouter--catalogue))

(defun demo-dispatch (id &optional ephemeral)
  "Send one request as session ID, and return its `done' event.
EPHEMERAL marks it as the harness's own small call -- a permission judge."
  (let* ((session (list :id id :name id :kind 'main :status 'idle
                        :model (format "openrouter:%s" demo-model)))
         (events nil)
         (real (symbol-function 'harness-call)))
    (setq demo-hints nil)
    (cl-letf (((symbol-function 'harness-method-exists-p)
               ;; The demo does not load the session module, whose methods
               ;; these are; the stubs below answer them.
               (lambda (method) (memq method '(session/get session/exists-p
                                               session/set-ext session/hint))))
              ((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (pcase method
                   ('session/get session)
                   ('session/exists-p t)
                   ('session/set-ext args)
                   ('session/hint (push (nth 1 args) demo-hints) args)
                   (_ (apply real method args))))))
      (harness-openrouter--complete
       (list :model (format "openrouter:%s" demo-model)
             :session session
             :ephemeral ephemeral
             :messages '((:role user :content ((:type "text" :text "hi"))))
             :on-event (lambda (e) (push e events))))
      ;; The dispatch is asynchronous, as a real one is: wait for it to say
      ;; how it ended rather than reading events it has not sent.
      (let ((deadline (+ (float-time) 5)))
        (while (and (not (cl-find-if (lambda (e) (eq (plist-get e :type) 'done))
                                     events))
                    (< (float-time) deadline))
          (accept-process-output nil 0.02)
          (sit-for 0.01)))
      (let ((done (car (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'done))
                                         events))))
        (princ (format "  outcome: %s\n" (demo-outcome done)))
        (unless demo-quiet
          (dolist (hint (nreverse demo-hints))
            (princ (format "  hint: %s\n" hint))))
        done))))

(defun demo-wait-fetching ()
  "Wait until no shared read is in flight."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (zerop (hash-table-count harness-openrouter--fetching)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.01))))

(defun demo-case (label fn)
  "Print LABEL and run FN inside a fresh world."
  (princ (format "\n=== %s\n" label))
  (funcall fn))

(defun demo-run ()
  "Print what the reported failure was, and what the harness does now."
  (princ "\nOne shared catalogue, refreshed about every 15 minutes\n")
  (princ (format "The shared interval is %d s.\n" harness-openrouter-catalogue-ttl))
  ;; 1. Inside the interval: no request at all, however many callers.
  (demo-case "1. Five sessions and three judges inside the interval: no read"
             (lambda ()
               (demo-with-world
                (setq demo-answer 'ok)
                (demo-seed 10)
                ;; Eight callers, and the pin hint of each would only repeat
                ;; itself: what this case is about is the reads they spend.
                (let ((demo-quiet t))
                  (dotimes (n 5) (demo-dispatch (format "s-%d" n))))
                (let ((after-sessions demo-reads))
                  (dotimes (n 3) (demo-dispatch (format "j-%d" n) t))
                  (princ (format "  catalogue reads: %d after 5 sessions, %d after 3 judges\n"
                                 after-sessions demo-reads)))
                (princ (format "  catalogue status: %s\n" (demo-status-line))))))
  ;; 2. Past the interval, inside the bound: served, and revalidated behind.
  (demo-case "2. Past the interval, inside the bound: served while it is read"
             (lambda ()
               (demo-with-world
                (setq demo-answer 'ok)
                (demo-seed 1000)
                (setq demo-hold t)
                (demo-dispatch "s-new")
                (princ (format "  shared reads started behind the dispatch: %d\n"
                               (length demo-held)))
                (princ (format "  catalogue status: %s\n" (demo-status-line)))
                (demo-answer-held)
                (demo-wait-fetching)
                (princ (format "  after the read settles: %s\n"
                               (demo-status-line))))))
  ;; 3. A judge past the interval starts no read of its own.
  (demo-case "3. A judge past the interval: answered, and it starts no read"
             (lambda ()
               (demo-with-world
                (setq demo-answer 'ok)
                (demo-seed 1000)
                (demo-dispatch "s-judge" t)
                (princ (format "  catalogue reads: %d\n" demo-reads))
                (princ (format "  catalogue status: %s\n" (demo-status-line))))))
  ;; 4. A failed refresh inside the bound: still sends, and says so.
  (demo-case "4. A failed refresh inside the bound: still sends, and says so"
             (lambda ()
               (demo-with-world
                (demo-seed 1000)
                (setq demo-answer 'fail)
                (demo-dispatch "s-first")
                (demo-wait-fetching)
                (princ (format "  catalogue status: %s\n" (demo-status-line)))
                (demo-dispatch "s-second"))))
  ;; 5. A reading outside the bound: stops, as before.
  (demo-case "5. A failed refresh outside the bound: stops, as before"
             (lambda ()
               (demo-with-world
                (setq harness-openrouter-routing (demo-policy :freshness 300))
                (demo-seed 3600)
                (setq demo-answer 'timeout)
                (demo-dispatch "s-old")
                (demo-wait-fetching)
                (princ (format "  catalogue status: %s\n" (demo-status-line))))))
  ;; 6. No reading at all: nothing is invented.
  (demo-case "6. No reading at all: stops, and nothing is invented"
             (lambda ()
               (demo-with-world
                (setq demo-answer 'timeout)
                (demo-dispatch "s-cold")
                (demo-wait-fetching)
                (princ (format "  catalogue status: %s\n" (demo-status-line))))))
  ;; 7. Explicit invalidation: the one path that forces a read.
  (demo-case "7. Explicit invalidation: the one path that forces a read"
             (lambda ()
               (demo-with-world
                (setq demo-answer 'ok)
                (demo-seed 10)
                (let ((before demo-reads))
                  (harness-openrouter-catalogue-invalidate demo-model)
                  (demo-wait-fetching)
                  (princ (format "  reads the invalidation spent: %d\n"
                                 (- demo-reads before)))
                  (princ (format "  catalogue status: %s\n"
                                 (demo-status-line)))))))
  (princ "\nA reading is never used outside the policy's freshness bound, a\n")
  (princ "reading is never invented, and the price rule still decides from\n")
  (princ "whatever reading is used.  A reused reading is not evidence that a\n")
  (princ "price is current now: the bound is the guarantee.\n\n")
  (princ "Background re-reads after a failure: a burst, then a heartbeat.\n")
  (let ((attempts 0))
    (while (< attempts harness-openrouter-catalogue-retry-attempts)
      (princ (format "  burst %d: in %d s\n"
                     (1+ attempts)
                     (round (harness-openrouter--catalogue-delay attempts))))
      (setq attempts (1+ attempts)))
    (princ (format "  after the burst: one probe every %d s until a read settles\n\n"
                   harness-openrouter-catalogue-retry-max-delay))))

(provide 'demo)
;;; demo.el ends here
