;;; harness-provider-deepseek-test.el --- Tests for the DeepSeek provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; DeepSeek reuses the OpenAI-compatible streaming, so these tests cover
;; what this provider adds: key detection, registration, the peak and
;; off-peak schedule (including Chinese public holidays), the pricing
;; function `usage/price' calls, and the peak-pricing notice.

;;; Code:

(require 'iso8601)
(require 'harness-test-helpers)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-deepseek)
;; Defines the `usage/price' and `usage/pricing' methods.
(require 'harness-usage)

(defun harness-deepseek-test-time (iso)
  "Return the float time the ISO 8601 string ISO names."
  (float-time (encode-time (iso8601-parse iso))))

(defun harness-deepseek-test-near (a b)
  "Non-nil when floats A and B agree to a millionth."
  (< (abs (- a b)) 1e-6))

(defun harness-deepseek-test-flash-model ()
  "Return the catalogue entry for deepseek-flash."
  (cl-find "deepseek-flash" (harness-deepseek--models)
           :key (lambda (m) (plist-get m :name)) :test #'equal))

;;;; The key

(ert-deftest harness-deepseek-key-resolution ()
  (let ((harness-deepseek-api-key nil) (auth-sources nil))
    (with-environment-variables (("DEEPSEEK_API_KEY" "from-env"))
      (should (equal "from-env" (harness-deepseek-api-key))))
    (with-environment-variables (("DEEPSEEK_API_KEY" ""))
      (should-not (harness-deepseek-api-key)))
    (let ((harness-deepseek-api-key "literal"))
      (should (equal "literal" (harness-deepseek-api-key))))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (when (and (equal (plist-get args :host) "api.deepseek.com")
                            (equal (plist-get args :user) "apikey"))
                   (list (list :host "api.deepseek.com" :secret (lambda () "from-auth-source")))))))
      (with-environment-variables (("DEEPSEEK_API_KEY" nil))
        (should (equal "from-auth-source" (harness-deepseek-api-key)))))))

;;;; Registration

(ert-deftest harness-deepseek-registers-when-key-present ()
  (let ((harness-deepseek-api-key "sk-test-deepseek") (auth-sources nil))
    (unwind-protect
        (progn
          (should (eq 'deepseek (harness-deepseek-refresh)))
          (should (harness-provider-get 'deepseek))
          (let* ((models (harness-test-await
                          (funcall (harness-provider-models-fn (harness-provider-get 'deepseek)))))
                 (flash (car models)) (pro (car (last models))))
            (should (equal '("deepseek-flash" "deepseek-v4-flash"
                             "deepseek-v4-flash-vision-exp" "deepseek-v4-pro")
                           (mapcar (lambda (m) (plist-get m :name)) models)))
            (should (equal "DeepSeek-V4.1-Flash" (plist-get flash :label)))
            (should (= 1048576 (plist-get flash :context-window)))
            (should (= 393216 (plist-get flash :max-output)))
            (should (equal '("text" "image") (plist-get flash :input-modalities)))
            (should (equal '("text") (plist-get pro :input-modalities)))
            (should (eq 'harness-deepseek-rates-at (plist-get flash :pricing-fn)))
            (should (harness-deepseek-test-near 0.15 (plist-get (plist-get flash :pricing) :input)))
            (should (harness-deepseek-test-near 0.30 (plist-get (plist-get flash :peak-pricing) :input)))
            (should (harness-deepseek-test-near 0.0 (plist-get (plist-get flash :pricing) :cache-write)))
            (should (equal "deepseek:deepseek-flash"
                           (plist-get (harness-call 'provider/model "deepseek:deepseek-flash") :id)))
            (should (eq 'harness-deepseek-rates-at
                        (plist-get (harness-call 'provider/model "deepseek:deepseek-flash") :pricing-fn)))
            ;; The provider names its tiers, so the judge does not sort prices.
            (should (equal "deepseek:deepseek-flash"
                           (harness-call 'provider/tier-model "deepseek:deepseek-v4-pro" 'cheap)))
            (should (equal "deepseek:deepseek-v4-pro"
                           (harness-call 'provider/tier-model "deepseek:deepseek-flash" 'frontier)))))
      (harness-provider-unregister 'deepseek)
      (setq harness-deepseek--registered nil))))

(ert-deftest harness-deepseek-not-registered-without-key ()
  (let ((harness-deepseek-api-key nil) (harness-deepseek-always-register nil) (auth-sources nil))
    (with-environment-variables (("DEEPSEEK_API_KEY" nil))
      (harness-provider-unregister 'deepseek)
      (setq harness-deepseek--registered nil)
      (should-not (harness-deepseek-refresh))
      (should-not (harness-provider-get 'deepseek)))
    ;; always-register keeps it without a key.
    (let ((harness-deepseek-always-register t))
      (with-environment-variables (("DEEPSEEK_API_KEY" nil))
        (unwind-protect
            (progn
              (should (eq 'deepseek (harness-deepseek-refresh)))
              (should (harness-provider-get 'deepseek)))
          (harness-provider-unregister 'deepseek)
          (setq harness-deepseek--registered nil))))))

(ert-deftest harness-deepseek-removal-does-not-drop-a-user-endpoint ()
  (let ((harness-deepseek-api-key nil) (auth-sources nil) (saved harness-openai-endpoints))
    (unwind-protect
        (progn
          (harness-openai-add-endpoint :id 'deepseek :label "Mine"
                                       :base-url "https://api.deepseek.com" :api-key "sk-mine")
          (setq harness-deepseek--registered nil)
          (with-environment-variables (("DEEPSEEK_API_KEY" nil))
            (harness-deepseek-refresh))
          ;; The user's endpoint is left registered.
          (should (harness-provider-get 'deepseek))
          (should (equal "Mine" (harness-provider-label (harness-provider-get 'deepseek)))))
      (setq harness-openai-endpoints saved)
      (harness-openai--register-all))))

;;;; Peak schedule

(ert-deftest harness-deepseek-peak-windows ()
  ;; Monday 12 October 2026 is a working day; 5 October is still a holiday.
  (should (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T02:00:00Z")))
  (should (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T03:59:00Z")))
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T04:00:00Z")))
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T05:00:00Z")))
  (should (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T06:00:00Z")))
  (should (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T09:59:00Z")))
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T10:00:00Z")))
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-12T18:00:00Z")))
  ;; All weekend is off-peak.
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-10T02:00:00Z")))
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-11T07:00:00Z")))
  ;; Chinese public holidays are off-peak all day.
  (should-not (harness-deepseek-peak-p (harness-deepseek-test-time "2026-10-05T02:00:00Z")))
  (should (harness-deepseek-off-peak-date-p (harness-deepseek-test-time "2026-02-17T03:00:00Z")))
  (should-not (harness-deepseek-off-peak-date-p (harness-deepseek-test-time "2026-02-12T03:00:00Z")))
  ;; The windows are half-open at their end.
  (should (equal '(1 . 4) (harness-deepseek-peak-window (harness-deepseek-test-time "2026-10-12T02:00:00Z"))))
  (should (equal '(6 . 10) (harness-deepseek-peak-window (harness-deepseek-test-time "2026-10-12T07:00:00Z"))))
  (should-not (harness-deepseek-peak-window (harness-deepseek-test-time "2026-10-12T05:00:00Z"))))

;;;; Pricing

(ert-deftest harness-deepseek-pricing-follows-the-clock ()
  (let ((model (harness-deepseek-test-flash-model))
        (peak (harness-deepseek-test-time "2026-10-12T02:00:00Z"))
        (off (harness-deepseek-test-time "2026-10-12T05:00:00Z")))
    (let ((off-rates (harness-deepseek-rates-at model nil off))
          (peak-rates (harness-deepseek-rates-at model nil peak)))
      (should (harness-deepseek-test-near 0.15 (plist-get off-rates :input)))
      (should (harness-deepseek-test-near 0.60 (plist-get off-rates :output)))
      (should (harness-deepseek-test-near 0.003 (plist-get off-rates :cache-read)))
      (should (harness-deepseek-test-near 0.30 (plist-get peak-rates :input)))
      (should (harness-deepseek-test-near 1.20 (plist-get peak-rates :output)))
      (should (harness-deepseek-test-near 0.006 (plist-get peak-rates :cache-read)))
      ;; Peak is exactly double the off-peak rate.
      (should (harness-deepseek-test-near (* 2 (plist-get off-rates :output))
                                          (plist-get peak-rates :output))))
    ;; `usage/price' resolves the model's `:pricing-fn' at the given time.
    (should (equal (harness-deepseek-rates-at model nil off)
                   (harness-usage--pricing-at model nil off)))
    (should (equal (harness-deepseek-rates-at model nil peak)
                   (harness-usage--pricing-at model nil peak)))))

(ert-deftest harness-deepseek-usage-price-follows-the-clock ()
  (let ((harness-deepseek-api-key "sk-test-deepseek") (auth-sources nil))
    (unwind-protect
        (progn
          (harness-deepseek-refresh)
          (let ((usage '(:input 1000000 :output 0 :cache-read 0 :cache-write 0))
                (peak (harness-deepseek-test-time "2026-10-12T02:00:00Z"))
                (off (harness-deepseek-test-time "2026-10-12T05:00:00Z")))
            (should (harness-deepseek-test-near
                     0.30 (harness-call 'usage/price "deepseek:deepseek-flash" usage peak)))
            (should (harness-deepseek-test-near
                     0.15 (harness-call 'usage/price "deepseek:deepseek-flash" usage off)))
            ;; Cached input is billed at the cache-hit rate, not the miss rate.
            (should (harness-deepseek-test-near
                     0.003 (harness-call 'usage/price "deepseek:deepseek-flash"
                                         '(:input 0 :output 0 :cache-read 1000000) off)))))
      (harness-provider-unregister 'deepseek)
      (setq harness-deepseek--registered nil))))

;;;; The peak-pricing notice

(ert-deftest harness-deepseek-peak-notice ()
  (should (equal "DeepSeek peak pricing in effect until 04:00 UTC: rates are double the off-peak price."
                 (harness-deepseek-peak-notice (harness-deepseek-test-time "2026-10-12T02:00:00Z"))))
  (should-not (harness-deepseek-peak-notice (harness-deepseek-test-time "2026-10-12T05:00:00Z"))))

(ert-deftest harness-deepseek-warns-once-per-peak-window ()
  (clrhash harness-deepseek--warned)
  (let ((warnings nil)
        (peak (harness-deepseek-test-time "2026-10-12T02:00:00Z"))
        (later (harness-deepseek-test-time "2026-10-12T03:00:00Z"))
        (off (harness-deepseek-test-time "2026-10-12T05:00:00Z")))
    (harness-on 'provider/pricing-warning (lambda (pid tier window) (push (list pid tier window) warnings)))
    (harness-deepseek--on-request-started 'deepseek (list :session (list :id "s1")) peak)
    (harness-deepseek--on-request-started 'deepseek (list :session (list :id "s1")) later)
    (should (equal '((deepseek peak (1 . 4))) warnings))
    ;; A second session warns of its own.
    (harness-deepseek--on-request-started 'deepseek (list :session (list :id "s2")) peak)
    (should (= 2 (length warnings)))
    ;; Off-peak is silent, and another provider never warns.
    (harness-deepseek--on-request-started 'deepseek (list :session (list :id "s1")) off)
    (harness-deepseek--on-request-started 'openai (list :session (list :id "s1")) peak)
    (should (= 2 (length warnings)))))

;;;; Integration

(ert-deftest harness-deepseek-integration-text ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (getenv "DEEPSEEK_API_KEY"))
  (let ((harness-deepseek-api-key nil) (auth-sources nil))
    (unwind-protect
        (progn
          (harness-deepseek-refresh)
          (let ((events nil))
            (harness-call 'provider/complete
                          (list :model "deepseek:deepseek-flash"
                                :system "You answer with a single word."
                                :max-tokens 400
                                :messages '((:role user :content ((:type "text" :text "Say the word pong."))))
                                :on-event (lambda (e) (push e events))))
            (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                               90 "deepseek done")
            (setq events (reverse events))
            (should (eq 'start (plist-get (car events) :type)))
            ;; Thinking is on by default, so a tiny answer may still hit the cap.
            (should (memq (plist-get (car (last events)) :stop-reason) '(end-turn max-tokens)))
            (let ((usage (cl-find 'usage events :key (lambda (e) (plist-get e :type)))))
              (should usage)
              ;; DeepSeek reports prompt_tokens as hit + miss; the usage event
              ;; splits them, and context counts both.
              (should (> (plist-get usage :input) 0))
              (should (> (plist-get usage :output) 0))
              (should (= (plist-get usage :context)
                         (+ (plist-get usage :input) (plist-get usage :cache-read)))))))
      (harness-provider-unregister 'deepseek)
      (setq harness-deepseek--registered nil))))

(defun harness-deepseek-test--deltas (events type)
  "Concatenate the TYPE deltas (`text' or `thinking') in EVENTS."
  (mapconcat (lambda (e) (if (eq (plist-get e :type) type) (plist-get e :delta) "")) events ""))

(ert-deftest harness-deepseek-integration-tool-round-trip ()
  ;; DeepSeek's thinking mode wants the reasoning of the tool-calling turn
  ;; back on the next request; without it, the API answers 400.
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (getenv "DEEPSEEK_API_KEY"))
  (let ((harness-deepseek-api-key nil) (auth-sources nil))
    (unwind-protect
        (progn
          (harness-deepseek-refresh)
          (let* ((tools '((:name "echo" :description "Echo VALUE back through the tool runtime."
                           :schema (:type "object" :properties (:value (:type "string" :description "Text to echo"))
                                    :required ("value")))))
                 (user (list :role 'user
                             :content (list (list :type "text" :text "Call the echo tool with the value \"marble\". Then report the tool's exact output back to me."))))
                 (run (lambda (messages)
                        (let ((events nil))
                          (harness-call 'provider/complete
                                        (list :model "deepseek:deepseek-flash" :tools tools :max-tokens 2000
                                              :messages messages
                                              :on-event (lambda (e) (push e events))))
                          (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                                             120 "deepseek done")
                          (reverse events))))
                 (first (funcall run (list user)))
                 (call (cl-find 'tool-call first :key (lambda (e) (plist-get e :type)))))
            (should call)
            (should (equal "marble" (plist-get (plist-get call :input) :value)))
            (should (equal '(:type done :stop-reason tool-use) (car (last first))))
            ;; Replay the assistant turn the way `session/messages' does:
            ;; thinking, text and the call in one message.  If the thinking
            ;; did not stream back as `reasoning_content', this 400s.
            (let* ((assistant (list :role 'assistant
                                    :content (append
                                              (let ((thought (harness-deepseek-test--deltas first 'thinking)))
                                                (unless (string-empty-p thought)
                                                  (list (list :type "thinking" :text thought))))
                                              (let ((text (harness-deepseek-test--deltas first 'text)))
                                                (unless (string-empty-p text)
                                                  (list (list :type "text" :text text))))
                                              (list (list :type "tool_use" :id (plist-get call :id)
                                                          :name "echo" :input (plist-get call :input))))))
                   (result (list :role 'tool
                                 :content (list (list :type "tool_result" :tool_use_id (plist-get call :id)
                                                      :content "ZEBRA-4242"))))
                   (second (funcall run (list user assistant result))))
              (should (equal '(:type done :stop-reason end-turn) (car (last second))))
              (should (string-match-p "ZEBRA-4242"
                                      (harness-deepseek-test--deltas second 'text))))))
      (harness-provider-unregister 'deepseek)
      (setq harness-deepseek--registered nil))))

(provide 'harness-provider-deepseek-test)
;;; harness-provider-deepseek-test.el ends here
