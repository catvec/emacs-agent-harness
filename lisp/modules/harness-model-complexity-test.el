;;; harness-model-complexity-test.el --- Tests for the model complexity guide  -*- lexical-binding: t; -*-

;;; Commentary:

;; The guide contains explicit estimates, not price-derived capability
;; claims.  Unknown models stay unknown; user rules and alias resolution
;; do not change the catalogue, names, model choices or policy filters.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)
(require 'harness-model-complexity)

(defmacro harness-model-complexity-test-with (&rest body)
  "Run BODY with an isolated catalogue and the guide registered on a fresh bus."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'provider)
     (harness-test-load-module 'model-complexity)
     (let ((harness-providers (make-hash-table :test 'eq))
           (harness-provider--models nil)
           (harness-provider--models-promise nil)
           (harness-provider--models-by-provider (make-hash-table :test 'eq))
           (harness-provider--catalogue (make-hash-table :test 'eq))
           (harness-provider--model-index (make-hash-table :test 'equal))
           (harness-provider--fetching (make-hash-table :test 'eq))
           (harness-provider--lookups (make-hash-table :test 'equal))
           (harness-provider--estimate-index nil)
           (harness-provider--warned (make-hash-table :test 'equal))
           (harness-provider--lifecycle (make-hash-table :test 'eq))
           (harness-allowed-models nil)
           (harness-model-complexity-rules nil))
       ,@body)))

(defun harness-model-complexity-test--model (id &rest properties)
  "Return a minimal model for qualified ID with extra PROPERTIES."
  (append (list :id id :name (cdr (harness-provider-parse-model id)) :label id) properties))

(defun harness-model-complexity-test--rank (id &rest properties)
  "Return the guide's annotated copy of model ID with PROPERTIES."
  (car (harness-model-complexity-rank-models
        (list (apply #'harness-model-complexity-test--model id properties)))))

(ert-deftest harness-model-complexity-default-chatgpt-guide-is-explicit ()
  "Only named versions of Luna, Sol and Astra get the initial estimates."
  (let ((harness-model-complexity-rules nil))
    (dolist (entry '(("chatgpt:gpt-5.6-luna" "routine" "Routine tasks" 2)
                     ("chatgpt:gpt-6-sol" "complex" "Complex tasks" 3)
                     ("chatgpt:gpt-6.1-sol" "complex" "Complex tasks" 3)
                     ("chatgpt:gpt-6-astra" "very-complex" "Very complex tasks" 4)
                     ("openai:gpt-6-sol" "complex" "Complex tasks" 3)))
      (let ((row (harness-model-complexity-test--rank (car entry))))
        (should (equal (nth 1 entry) (plist-get row :complexity-level)))
        (should (equal (nth 2 entry) (plist-get row :complexity-label)))
        (should (= (nth 3 entry) (plist-get row :complexity-rank)))
        (should (equal "Default guide (estimate)" (plist-get row :complexity-basis)))
        (should (> (length (plist-get row :complexity-description)) 15))))))

(ert-deftest harness-model-complexity-anthropic-families-across-providers ()
  "Family aliases, old naming and Bedrock regional ids use the same guide."
  (let ((harness-model-complexity-rules nil))
    (dolist (entry '(("claude:haiku" . "simple")
                     ("claude:claude-haiku-4-5-20251001" . "simple")
                     ("copilot:claude-haiku-4.5" . "simple")
                     ("claude:sonnet" . "routine")
                     ("claude:claude-sonnet-5" . "routine")
                     ("copilot:claude-3-5-sonnet-20241022" . "routine")
                     ("bedrock:us.anthropic.claude-3-5-sonnet-20241022-v2:0" . "routine")
                     ("claude:claude-opus-5-5" . "complex")
                     ("bedrock:anthropic.claude-opus-5-5-v1:0" . "complex")
                     ("bedrock:global.anthropic.claude-fable-5-1" . "very-complex")
                     ("claude:fable" . "very-complex")))
      (should (equal (cdr entry)
                     (plist-get (harness-model-complexity-test--rank (car entry)) :complexity-level))))))

(ert-deftest harness-model-complexity-unknown-is-not-inferred ()
  "New names stay Unrated despite prices, context windows and thinking levels."
  (let ((harness-model-complexity-rules nil))
    (dolist (id '("chatgpt:gpt-7-sol" "chatgpt:gpt-6.2-sol" "chatgpt:gpt-5.7-luna"
                   "chatgpt:gpt-6-astra-pro" "chatgpt:gpt-6" "chatgpt:gpt-6-nova"
                   "claude:claude-sonnetish-5" "local:largest-model" "test:unknown"))
      (let ((row (harness-model-complexity-test--rank
                  id :pricing '(:input 1000 :output 5000) :context-window 10000000
                  :thinking-levels '("low" "high" "max"))))
        (should-not (plist-get row :complexity-level))
        (should-not (plist-get row :complexity-rank))
        (should (equal "Unrated" (plist-get row :complexity-label)))
        (should (equal "No matching rule" (plist-get row :complexity-basis)))))))

(ert-deftest harness-model-complexity-first-user-rule-wins ()
  "Rules precede defaults, follow their order, and do not erase other defaults."
  (let ((harness-model-complexity-rules
         '(("\\`chatgpt:gpt-6-sol\\'" . simple)
           ("\\`chatgpt:" . very-complex))))
    (let ((sol (harness-model-complexity-test--rank "chatgpt:gpt-6-sol"))
          (luna (harness-model-complexity-test--rank "chatgpt:gpt-5.6-luna"))
          (sonnet (harness-model-complexity-test--rank "claude:claude-sonnet-5")))
      (should (equal "simple" (plist-get sol :complexity-level)))
      (should (equal "User rule (estimate)" (plist-get sol :complexity-basis)))
      (should (equal "very-complex" (plist-get luna :complexity-level)))
      (should (equal "routine" (plist-get sonnet :complexity-level)))
      (should (equal "Default guide (estimate)" (plist-get sonnet :complexity-basis))))))

(ert-deftest harness-model-complexity-nil-rule-explicitly-unrates ()
  "Matching nil suppresses a default estimate and later user matches."
  (let* ((harness-model-complexity-rules
          '(("\\`chatgpt:gpt-6-sol\\'" . nil) ("\\`chatgpt:" . simple)))
         (row (harness-model-complexity-test--rank "chatgpt:gpt-6-sol")))
    (should-not (plist-get row :complexity-level))
    (should-not (plist-get row :complexity-rank))
    (should (equal "Unrated" (plist-get row :complexity-label)))
    (should (equal "User rule (estimate)" (plist-get row :complexity-basis)))))

(ert-deftest harness-model-complexity-can-rate-a-new-model ()
  "The user's estimate can describe a model absent from the default guide."
  (let* ((harness-model-complexity-rules '(("\\`local:custom\\'" . complex)))
         (row (harness-model-complexity-test--rank "local:custom")))
    (should (equal "complex" (plist-get row :complexity-level)))
    (should (equal "User rule (estimate)" (plist-get row :complexity-basis)))))

(ert-deftest harness-model-complexity-alias-follows-resolved-id ()
  "Aliases retain their names but get estimates for the model actually run."
  (let ((harness-model-complexity-rules nil))
    (dolist (target '("claude-opus-5-5" "claude:claude-opus-5-5"))
      (let ((row (harness-model-complexity-test--rank
                  "claude:default" :resolves-to target)))
        (should (equal "complex" (plist-get row :complexity-level)))
        (should (equal "claude:default" (plist-get row :id)))
        (should (equal "default" (plist-get row :name)))
        (should (equal "claude:default" (plist-get row :label)))))
    ;; An alias's name must not overrule what it resolves to.
    (should (equal "complex"
                   (plist-get (harness-model-complexity-test--rank
                               "claude:sonnet" :resolves-to "claude-opus-5-5") :complexity-level)))
    (should-not (plist-get (harness-model-complexity-test--rank
                           "claude:sonnet" :resolves-to "unknown-model") :complexity-rank))))

(ert-deftest harness-model-complexity-user-rule-can-match-alias-or-target ()
  "The first user rule across either id wins, including an explicit nil."
  (let ((harness-model-complexity-rules
         '(("\\`claude:default\\'" . nil) ("opus" . simple))))
    (should (equal "Unrated"
                   (plist-get (harness-model-complexity-test--rank
                               "claude:default" :resolves-to "claude-opus-5-5") :complexity-label))))
  (let ((harness-model-complexity-rules '(("\\`claude:claude-opus-5-5\\'" . simple))))
    (should (equal "simple"
                   (plist-get (harness-model-complexity-test--rank
                               "claude:default" :resolves-to "claude-opus-5-5") :complexity-level)))))

(ert-deftest harness-model-complexity-stable-level-order ()
  "Ascending task levels come before Unrated; ties use id, never price."
  (let* ((harness-model-complexity-rules nil)
         (ids '("local:z-unknown" "claude:claude-fable-5-1" "openai:gpt-6-sol"
                "claude:claude-opus-5-5" "claude:claude-sonnet-5" "chatgpt:gpt-5.6-luna"
                "claude:haiku" "local:a-unknown"))
         (models (mapcar #'harness-model-complexity-test--model ids))
         (rows (harness-model-complexity-rank-models models))
         (expected '("claude:haiku" "chatgpt:gpt-5.6-luna" "claude:claude-sonnet-5"
                     "claude:claude-opus-5-5" "openai:gpt-6-sol" "claude:claude-fable-5-1"
                     "local:a-unknown" "local:z-unknown")))
    (should (equal expected (mapcar (lambda (m) (plist-get m :id)) rows)))
    (should (equal rows (harness-model-complexity-rank-models (reverse models))))
    (should (equal '(1 2 2 3 3 4 nil nil)
                   (mapcar (lambda (m) (plist-get m :complexity-rank)) rows)))))

(ert-deftest harness-model-complexity-does-not-mutate-models ()
  "Copies preserve all catalogue fields and replace stale derived annotations."
  (let* ((harness-model-complexity-rules nil)
         (models (list (harness-model-complexity-test--model
                        "claude:haiku" :pricing '(:input 1 :output 5)
                        :capabilities '(:vision t) :complexity-label "stale")))
         (before (copy-tree models))
         (rows (harness-model-complexity-rank-models models)))
    (should (equal models before))
    (should-not (eq (car models) (car rows)))
    (should (equal "Simple tasks" (plist-get (car rows) :complexity-label)))
    (dolist (key '(:id :name :label :pricing :capabilities))
      (should (equal (plist-get (car models) key) (plist-get (car rows) key))))
    (setf (plist-get (plist-get (car rows) :pricing) :input) 99)
    (should (equal models before))))

(ert-deftest harness-model-complexity-malformed-regexp-does-not-break-guide ()
  "An invalid rule matches nothing, leaving subsequent rules usable."
  (let ((harness-model-complexity-rules '(("[" . complex) ("\\`test:" . simple))))
    (should (equal "simple" (plist-get (harness-model-complexity-test--rank "test:one")
                                       :complexity-level)))))

(ert-deftest harness-model-complexity-list-respects-policy-and-refresh ()
  "The method lists only allowed models and forwards refresh without completions."
  (harness-model-complexity-test-with
    (let ((listings nil)
          (completions 0)
          (harness-allowed-models '("test:claude-haiku*")))
      (harness-define-provider
       'test :label "Test"
       :models (lambda (&optional refresh)
                 (push refresh listings)
                 '((:name "claude-fable-5-1" :context-window 1000)
                   (:name "claude-haiku-4-5" :context-window 1000)))
       :complete (lambda (&rest _) (cl-incf completions) (error "No paid requests")))
      (let ((rows (harness-test-await (harness-call 'model-complexity/list))))
        (should (equal '("test:claude-haiku-4-5")
                       (mapcar (lambda (m) (plist-get m :id)) rows)))
        (should (equal '(nil) listings))
        (should (equal "Simple tasks" (plist-get (car rows) :complexity-label))))
      (harness-test-await (harness-call 'model-complexity/list))
      (should (equal '(nil) listings))
      (harness-test-await (harness-call 'model-complexity/list t))
      (should (equal '(t nil) listings))
      (should (= 0 completions))
      (should-not (plist-member (car harness-provider--models) :complexity-level)))))

(ert-deftest harness-model-complexity-list-waits-for-catalogue ()
  "An asynchronous model listing is awaited rather than treated as empty."
  (harness-model-complexity-test-with
    (let ((listing (harness-make-promise)))
      (harness-define-provider 'test :models (lambda () listing))
      (let ((answer (harness-call 'model-complexity/list)))
        (should (harness-promise-p answer))
        (should-not (harness-promise-settled-p answer))
        (harness-resolve listing '((:name "claude-haiku-4-5" :context-window 1000)))
        (should (equal "Simple tasks"
                       (plist-get (car (harness-test-await answer)) :complexity-label)))))))

(ert-deftest harness-model-complexity-list-empty-catalogue ()
  "An empty allowed catalogue resolves to an empty guide."
  (harness-model-complexity-test-with
    (should-not (harness-test-await (harness-call 'model-complexity/list)))))

(provide 'harness-model-complexity-test)
;;; harness-model-complexity-test.el ends here
