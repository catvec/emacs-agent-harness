;;; harness-provider-diagnostics-test.el --- Tests of content-free provider diagnostics  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests are offline.  They construct wire bodies and fake
;; provider streams, then read the diagnostic lines through
;; `harness-log-hook'.  The point is not that the lines are pretty: it
;; is that the same prefix keeps the same checkpoints, an append or a
;; changed segment is named, nothing raw or secret reaches the log, a
;; missing provider field stays unknown, and the provider's own usage
;; accounting is not changed or double counted by the diagnostics.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider-openai)
(require 'harness-provider-responses)
(require 'harness-provider-diagnostics)

(defvar harness-provider-diagnostics-test--logs nil
  "Captured (LEVEL MESSAGE) entries, newest first.")

(defvar harness-provider-diagnostics-test--requests nil
  "Requests the fake HTTP layer saw, newest first.")

(defmacro harness-provider-diagnostics-test--with-state (&rest body)
  "Run BODY with a fresh diagnostic key and a captured log."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-provider-diagnostics-enabled t)
           (harness-provider-diagnostics-key-file nil)
           (harness-provider-diagnostics--key 'unset)
           (harness-provider-diagnostics--last (make-hash-table :test 'equal))
           (harness-provider-diagnostics--last-order nil)
           (harness-provider-diagnostics--sequence 0)
           ;; Process-wide counters: without these, one case's requests are
           ;; still counted in the next one's concurrency reading.
           (harness-provider-diagnostics--requests 0)
           (harness-provider-diagnostics--in-flight (make-hash-table :test 'equal))
           (harness-provider-diagnostics--warned nil)
           (harness-provider-diagnostics--random-bytes-function
            #'harness-provider-diagnostics--random-bytes)
           (harness-log-level 'info)
           (harness-log-filter-function nil)
           (harness-provider-diagnostics-test--logs nil)
           (harness-provider-diagnostics-test--requests nil))
       (let ((harness-log-hook
              (list (lambda (level msg)
                      (push (list level msg) harness-provider-diagnostics-test--logs)))))
         ,@body))))

(defun harness-provider-diagnostics-test--messages ()
  "Return the diagnostic log messages, oldest first."
  (mapcar #'cadr (reverse harness-provider-diagnostics-test--logs)))

(defun harness-provider-diagnostics-test--lines (needle)
  "Return the diagnostic messages that contain NEEDLE."
  (cl-remove-if-not (lambda (msg) (string-match-p needle msg))
                    (harness-provider-diagnostics-test--messages)))

(defun harness-provider-diagnostics-test--request-line ()
  "Return the last request line."
  (car (last (harness-provider-diagnostics-test--lines "provider-diagnostics: request"))))

(defun harness-provider-diagnostics-test--response-line ()
  "Return the last response line."
  (car (last (harness-provider-diagnostics-test--lines "provider-diagnostics: response"))))

(defun harness-provider-diagnostics-test--field (line name)
  "Return the value of field NAME in LINE, or nil."
  (when (and line (string-match (concat "\\(?:^\\| \\)" (regexp-quote name) "=\\([^ ]+\\)") line))
    (match-string 1 line)))

(defun harness-provider-diagnostics-test--body (&rest overrides)
  "Return a representative wire body, with OVERRIDES applied."
  (let ((body (list :model "deepseek/test"
                    :messages (list (list :role "system" :content "You are a test.")
                                    (list :role "user" :content "Hello."))
                    :stream t
                    :stream_options '(:include_usage t)
                    :tools (list (list :type "function"
                                       :function (list :name "read_file"
                                                       :description "Read a file."
                                                       :parameters '(:type "object")))))))
    (while overrides
      (setq body (plist-put body (pop overrides) (pop overrides))))
    body))

(defun harness-provider-diagnostics-test--request (body &optional session)
  "Diagnose BODY for SESSION and return the attempt."
  (harness-provider-diagnostics-request
   body (list :session (list :id (or session "session-1")))
   :configured "testrouter:deepseek/test" :route 'openrouter :host "openrouter.example"))

(defun harness-provider-diagnostics-test--settled (body &optional session)
  "Diagnose BODY for SESSION and finish the attempt, as a served request.
A request that is the basis of a later comparison has been answered by the
time the later one is sent, so it is not in flight; leaving it open would
make every comparison look concurrent."
  (let ((attempt (harness-provider-diagnostics-test--request body session)))
    (harness-provider-diagnostics-response attempt :status 200 :outcome 'ok)
    attempt))

(defun harness-provider-diagnostics-test--key-bytes ()
  "Return the raw key bytes of the test key file, for a leak check."
  (harness-provider-diagnostics--decode-key
   (harness-read-file (harness-provider-diagnostics-key-file))))

;;;; Key lifecycle

(ert-deftest harness-provider-diagnostics-key-is-private-and-stable ()
  (harness-provider-diagnostics-test--with-state
    (let ((key (harness-provider-diagnostics-key)))
      (should (stringp key))
      (should (= (length key) 32))
      (should (string= (file-name-nondirectory
                        (harness-provider-diagnostics-key-file))
                       "provider-diagnostics.key"))
      (should (= (file-modes (harness-provider-diagnostics-key-file)) #o600))
      ;; A restart forgets the memory, not the key.
      (harness-provider-diagnostics-reset)
      (should (string= key (harness-provider-diagnostics-key)))
      ;; The key itself is never in a line.
      (let ((line (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body))))
        (should line)
        (dolist (msg (harness-provider-diagnostics-test--messages))
          (should-not (string-search key msg)))))))

(ert-deftest harness-provider-diagnostics-key-rotation-changes-the-key-id ()
  (harness-provider-diagnostics-test--with-state
    (let* ((first (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body)))
           (before (harness-provider-diagnostics-attempt-key-id first)))
      (should (harness-provider-diagnostics-rotate-key))
      (should-not (file-exists-p (harness-provider-diagnostics-key-file)))
      (let* ((second (harness-provider-diagnostics-test--request
                      (harness-provider-diagnostics-test--body)))
             (after (harness-provider-diagnostics-attempt-key-id second)))
        (should (stringp after))
        (should-not (string= before after))))))

(ert-deftest harness-provider-diagnostics-without-randomness-is-off ()
  (harness-provider-diagnostics-test--with-state
    (let ((harness-provider-diagnostics--random-bytes-function (lambda (_n) nil)))
      (should-not (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body)))
      (should-not (harness-provider-diagnostics-test--request-line))
      (should (harness-provider-diagnostics-test--lines "no secure random bytes"))
      (should-not (file-exists-p (harness-provider-diagnostics-key-file))))))

(ert-deftest harness-provider-diagnostics-disabled-module-is-silent ()
  "Naming the module disabled silences it even though the provider requires it."
  (harness-provider-diagnostics-test--with-state
    (let ((harness-disabled-modules '(provider-diagnostics)))
      (should-not (harness-provider-diagnostics-enabled-p))
      (should-not (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body)))
      (should-not (harness-provider-diagnostics-test--request-line))
      ;; The provider call still works with no diagnostic line.
      (let ((result (harness-provider-diagnostics-test--run
                     (list :status 200 :headers nil
                           :chunks (list (harness-provider-diagnostics-test--sse
                                          (list :choices (list (list :index 0
                                                                     :delta (list :content "ok")
                                                                     :finish_reason "stop")))))))))
        (should (= 1 (cl-count 'done (car result) :key (lambda (e) (plist-get e :type)))))
        (should-not (harness-provider-diagnostics-test--lines "provider-diagnostics"))))))

(ert-deftest harness-provider-diagnostics-invalid-key-disables-hashing ()
  (harness-provider-diagnostics-test--with-state
    (make-directory (file-name-directory (harness-provider-diagnostics-key-file)) t)
    (with-temp-file (harness-provider-diagnostics-key-file)
      (insert "hpd1:not-a-32-byte-key\n"))
    (should-not (harness-provider-diagnostics-test--request
                 (harness-provider-diagnostics-test--body)))
    (should (harness-provider-diagnostics-test--lines "not a valid diagnostic key"))
    (should-not (harness-provider-diagnostics-test--lines
                 "provider-diagnostics: request"))))

;;;; Prefix comparability

(ert-deftest harness-provider-diagnostics-appended-prefix-is-preserved ()
  (harness-provider-diagnostics-test--with-state
    (let* ((first (harness-provider-diagnostics-test--settled
                   (harness-provider-diagnostics-test--body)))
           (second-body (harness-provider-diagnostics-test--body
                         :messages (append (plist-get (harness-provider-diagnostics-test--body) :messages)
                                           (list (list :role "assistant" :content "Hi.")
                                                 (list :role "user" :content "More.")))))
           (second (harness-provider-diagnostics-test--request second-body)))
      (should first)
      (should second)
      (should (equal "appended"
                     (harness-provider-diagnostics-attempt-prefix second)))
      (should (> (harness-provider-diagnostics-attempt-chunks second)
                 (harness-provider-diagnostics-attempt-chunks first)))
      (should (equal "warm" (harness-provider-diagnostics-attempt-expected-cold second)))
      (should (= (harness-provider-diagnostics-attempt-final-index second)
                 (harness-provider-diagnostics-attempt-final-index
                  (gethash "session-1" harness-provider-diagnostics--last))))
      (let ((line (harness-provider-diagnostics-test--request-line)))
        (should (equal "appended" (harness-provider-diagnostics-test--field line "prefix")))
        (should (equal "warm" (harness-provider-diagnostics-test--field line "expected-cold")))
        (should (equal (harness-provider-diagnostics-attempt-id first)
                       (harness-provider-diagnostics-test--field line "prev")))))))

(ert-deftest harness-provider-diagnostics-identical-retry-is-identical ()
  (harness-provider-diagnostics-test--with-state
    (let ((first (harness-provider-diagnostics-test--settled
                  (harness-provider-diagnostics-test--body)))
          (second (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body))))
      (should first)
      (should second)
      (should (equal "identical" (harness-provider-diagnostics-attempt-prefix second)))
      ;; Deterministic within the scope: every checkpoint and the final
      ;; digest are the same for the same serialized bytes.
      (should (equal (harness-provider-diagnostics-attempt-final first)
                     (harness-provider-diagnostics-attempt-final second)))
      (should (equal (harness-provider-diagnostics-attempt-checkpoints first)
                     (harness-provider-diagnostics-attempt-checkpoints second))))))

(ert-deftest harness-provider-diagnostics-lengths-are-utf-8-bytes ()
  (harness-provider-diagnostics-test--with-state
    (let* ((body (harness-provider-diagnostics-test--body
                  :messages (list (list :role "user" :content "é𝄞"))))
           (attempt (harness-provider-diagnostics-test--request
                     body "unicode-session"))
           (chunks (harness-provider-diagnostics--chunks body))
           (encoded (cl-loop for chunk in chunks
                             sum (length (plist-get chunk :bytes))))
           ;; model, settings, tools, then the one message.
           (message (car (last chunks))))
      (should (= encoded (harness-provider-diagnostics-attempt-bytes attempt)))
      (should (equal "message/0" (plist-get message :tag)))
      ;; The bytes are multi-byte UTF-8, so a character count would be
      ;; smaller, and the two characters are one chunk, not two.
      (should (< (length "é𝄞")
                 (length (decode-coding-string
                          (plist-get message :bytes) 'utf-8))))
      (should (string-match-p "é𝄞" (decode-coding-string
                                     (plist-get message :bytes) 'utf-8))))))

(ert-deftest harness-provider-diagnostics-changed-system-diverges-at-system ()
  (harness-provider-diagnostics-test--with-state
    (harness-provider-diagnostics-test--settled
     (harness-provider-diagnostics-test--body))
    (let* ((changed (harness-provider-diagnostics-test--body
                     :messages (list (list :role "system" :content "Different system.")
                                     (list :role "user" :content "Hello."))))
           (second (harness-provider-diagnostics-test--request changed)))
      (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix second)))
      (should (equal "system-change" (harness-provider-diagnostics-attempt-expected-cold second)))
      ;; expected-cold names the category, the line names the boundary.
      (let ((line (harness-provider-diagnostics-test--request-line)))
        (should (equal "diverged" (harness-provider-diagnostics-test--field line "prefix")))
        (should (string-match-p "at=2:system/0" line))))))

(ert-deftest harness-provider-diagnostics-changed-tool-schema-diverges-at-tools ()
  (harness-provider-diagnostics-test--with-state
    (harness-provider-diagnostics-test--settled
     (harness-provider-diagnostics-test--body))
    (let* ((changed (harness-provider-diagnostics-test--body
                     :tools (list (list :type "function"
                                        :function (list :name "read_file"
                                                        :description "Read a file, changed."
                                                        :parameters '(:type "object"))))))
           (second (harness-provider-diagnostics-test--request changed)))
      (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix second)))
      (should (equal "tools-change" (harness-provider-diagnostics-attempt-expected-cold second)))
      (should (string-match-p "at=3:tools"
                              (harness-provider-diagnostics-test--request-line))))))

(ert-deftest harness-provider-diagnostics-tool-order-is-part-of-the-prefix ()
  (harness-provider-diagnostics-test--with-state
    (let ((one (list (list :type "function" :function (list :name "a" :description "" :parameters '(:type "object")))
                     (list :type "function" :function (list :name "b" :description "" :parameters '(:type "object")))))
          (two (list (list :type "function" :function (list :name "b" :description "" :parameters '(:type "object")))
                     (list :type "function" :function (list :name "a" :description "" :parameters '(:type "object"))))))
      (harness-provider-diagnostics-test--settled
       (harness-provider-diagnostics-test--body :tools one))
      (let ((second (harness-provider-diagnostics-test--request
                     (harness-provider-diagnostics-test--body :tools two))))
        (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix second)))
        (should (string-match-p "at=3:tools" (harness-provider-diagnostics-test--request-line)))))))

(ert-deftest harness-provider-diagnostics-model-and-settings-diverge ()
  (harness-provider-diagnostics-test--with-state
    (harness-provider-diagnostics-test--settled
     (harness-provider-diagnostics-test--body))
    (let ((second (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body :model "deepseek/other"))))
      (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix second)))
      (should (equal "model-change" (harness-provider-diagnostics-attempt-expected-cold second))))
    (harness-provider-diagnostics-test--settled
     (harness-provider-diagnostics-test--body))
    (let ((second (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body :stream_options '(:include_usage :false)))))
      (should (equal "settings-change" (harness-provider-diagnostics-attempt-expected-cold second))))))

(ert-deftest harness-provider-diagnostics-wire-field-order-is-part-of-the-prefix ()
  (harness-provider-diagnostics-test--with-state
    (let ((a '(:model "m" :messages ((:role "user" :content "x"))))
          (b '(:messages ((:role "user" :content "x")) :model "m")))
      (harness-provider-diagnostics-test--settled a)
      (let ((second (harness-provider-diagnostics-test--request b)))
        (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix second)))
        (should (equal "settings-change"
                       (harness-provider-diagnostics-attempt-expected-cold second)))))))

(ert-deftest harness-provider-diagnostics-scope-splits-comparability ()
  (harness-provider-diagnostics-test--with-state
    (let ((one (harness-provider-diagnostics-test--request
                (harness-provider-diagnostics-test--body) "session-a"))
          (two (harness-provider-diagnostics-test--request
                (harness-provider-diagnostics-test--body) "session-b")))
      (should (equal "first" (harness-provider-diagnostics-attempt-prefix two)))
      (should-not (equal (harness-provider-diagnostics-attempt-final one)
                         (harness-provider-diagnostics-attempt-final two)))
      (should-not (equal (harness-provider-diagnostics-attempt-scope-id one)
                         (harness-provider-diagnostics-attempt-scope-id two))))))

(ert-deftest harness-provider-diagnostics-unicode-and-boundaries-are-unambiguous ()
  (harness-provider-diagnostics-test--with-state
    (let* ((left (harness-provider-diagnostics-test--body
                  :messages (list (list :role "user" :content "é")
                                  (list :role "assistant" :content "𝄞"))))
           (right (harness-provider-diagnostics-test--body
                   :messages (list (list :role "user" :content "é𝄞")
                                   (list :role "assistant" :content ""))))
           (a (harness-provider-diagnostics-test--settled left))
           (b (harness-provider-diagnostics-test--request right)))
      (should a)
      (should b)
      (should-not (equal (harness-provider-diagnostics-attempt-final a)
                         (harness-provider-diagnostics-attempt-final b)))
      ;; The length-prefixed chain makes the split visible even though
      ;; the concatenated text is the same.
      (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix b))))))

(ert-deftest harness-provider-diagnostics-shorter-prefix-is-not-guessed-warm ()
  (harness-provider-diagnostics-test--with-state
    (harness-provider-diagnostics-test--settled
     (harness-provider-diagnostics-test--body
      :messages (list (list :role "user" :content "a")
                      (list :role "assistant" :content "b")
                      (list :role "user" :content "c"))))
    (let ((second (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body
                    :messages (list (list :role "user" :content "a"))))))
      (should (equal "shorter" (harness-provider-diagnostics-attempt-prefix second))))))

;;;; Response correlation and unknowns

(ert-deftest harness-provider-diagnostics-response-keeps-unknowns-unknown ()
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response attempt :status 200 :outcome 'ok :stop 'end-turn)
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should line)
        (dolist (field '("response-id" "generation" "provider" "served-model"
                         "cache-read" "cache-write" "cost" "cost-source" "currency"))
          (should (equal "unknown" (harness-provider-diagnostics-test--field line field))))
        (should (equal "ok" (harness-provider-diagnostics-test--field line "outcome"))))
      ;; A second response for the same attempt changes nothing.
      (let ((before (length (harness-provider-diagnostics-test--lines "response"))))
        (harness-provider-diagnostics-response attempt :status 200 :outcome 'error)
        (should (= before (length (harness-provider-diagnostics-test--lines "response"))))))))

(ert-deftest harness-provider-diagnostics-provider-cost-is-not-an-estimate ()
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response
       attempt :status 200 :provider "Morph" :served-model "deepseek/test"
       :generation "gen-1" :request-id "req-1"
       :usage '(:prompt_tokens 100 :completion_tokens 5 :cost 0.00042
                :prompt_tokens_details (:cached_tokens 40 :cache_write_tokens 10))
       :usage-event '(:type usage :input 50 :output 5 :cache-read 40 :cache-write 10
                      :cost 0.00042 :billing api)
       :currency "USD" :outcome 'ok :stop 'end-turn)
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should (equal "Morph" (harness-provider-diagnostics-test--field line "provider")))
        (should (equal "deepseek/test" (harness-provider-diagnostics-test--field line "served-model")))
        (should (equal "gen-1" (harness-provider-diagnostics-test--field line "response-id")))
        (should (equal "gen-1" (harness-provider-diagnostics-test--field line "generation")))
        (should (equal "req-1" (harness-provider-diagnostics-test--field line "request-id")))
        (should (equal "0.00042" (harness-provider-diagnostics-test--field line "cost")))
        (should (equal "provider" (harness-provider-diagnostics-test--field line "cost-source")))
        (should (equal "USD" (harness-provider-diagnostics-test--field line "currency")))
        (should (equal "40" (harness-provider-diagnostics-test--field line "cache-read")))
        (should (equal "10" (harness-provider-diagnostics-test--field line "cache-write")))
        (should (equal "50" (harness-provider-diagnostics-test--field line "input")))
        (should (equal "5" (harness-provider-diagnostics-test--field line "output")))))))

(ert-deftest harness-provider-diagnostics-plan-cost-is-not-provider-cost ()
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response
       attempt :status 200 :usage '(:prompt_tokens 10 :completion_tokens 2)
       :usage-event '(:type usage :input 10 :output 2 :cost 0.0 :billing subscription)
       :outcome 'ok :stop 'end-turn)
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should (equal "0.0" (harness-provider-diagnostics-test--field line "cost")))
        (should (equal "plan" (harness-provider-diagnostics-test--field line "cost-source")))
        (should (equal "subscription" (harness-provider-diagnostics-test--field line "billing")))))))

(ert-deftest harness-provider-diagnostics-malformed-metadata-is-unknown ()
  "An id, provider or model of the wrong type is no reading, not a guess."
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response
       attempt :status 200 :outcome 'ok :stop 'end-turn
       :generation 42 :request-id :false :provider 7 :served-model (list "x")
       :usage '(:prompt_tokens "100" :completion_tokens nil
                :cost "0.1" :prompt_tokens_details (:cached_tokens "40"))
       :currency "USD")
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should line)
        (dolist (field '("generation" "request-id" "provider" "served-model"
                         "prompt" "output" "cache-read" "cost"
                         "cost-source" "currency"))
          (should (equal "unknown" (harness-provider-diagnostics-test--field line field))))))))

(ert-deftest harness-provider-diagnostics-cancelled-attempt-is-distinct ()
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response attempt :outcome 'cancelled :stop 'cancelled)
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should (equal "cancelled" (harness-provider-diagnostics-test--field line "outcome")))
        (should (equal "cancelled" (harness-provider-diagnostics-test--field line "stop")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "cache-read")))))))

(ert-deftest harness-provider-diagnostics-concurrent-attempts-do-not-overwrite ()
  (harness-provider-diagnostics-test--with-state
    (let* ((one (harness-provider-diagnostics-test--request
                 (harness-provider-diagnostics-test--body :messages (list (list :role "user" :content "one")))))
           (two (harness-provider-diagnostics-test--request
                 (harness-provider-diagnostics-test--body :messages (list (list :role "user" :content "two"))))))
      (should one)
      (should two)
      (should-not (equal (harness-provider-diagnostics-attempt-id one)
                         (harness-provider-diagnostics-attempt-id two)))
      (harness-provider-diagnostics-response one :status 200 :generation "gen-one" :outcome 'ok)
      (harness-provider-diagnostics-response two :status 429 :generation "gen-two" :outcome 'error
                                             :error-kind 'rate-limit :retry-after 7)
      (let ((responses (harness-provider-diagnostics-test--lines "response")))
        (should (= 2 (length responses)))
        (should (cl-some (lambda (line) (string-match-p "generation=gen-one" line)) responses))
        (should (cl-some (lambda (line) (string-match-p "generation=gen-two" line)) responses))
        (should (cl-some (lambda (line) (string-match-p "retry-after=7" line)) responses))))))

;;;; Concurrency and keep-warm refreshes

;; Three faults, each reproduced before it was fixed: a keep-warm refresh
;; becoming the comparison basis of the step after it, two requests in
;; flight being compared with each other, and the in-flight count being
;; taken where it could not be counted.  The point of each test is that a
;; request the harness made on purpose is not reported as a client change.

(ert-deftest harness-provider-diagnostics-keep-warm-is-not-the-basis ()
  "A refresh between two steps does not make the next step look changed."
  (harness-provider-diagnostics-test--with-state
    (let* ((messages (lambda (&rest extra)
                       (append (list (list :role "system" :content "S")
                                     (list :role "user" :content "U"))
                               extra)))
           (turn (harness-provider-diagnostics-test--body :messages (funcall messages)))
           (warm (harness-provider-diagnostics-test--body
                  :messages (funcall messages (list :role "user" :content "WARM"))))
           (next (harness-provider-diagnostics-test--body
                  :messages (funcall messages (list :role "assistant" :content "T")
                                     (list :role "user" :content "R")))))
      (let ((step (harness-provider-diagnostics-test--request turn)))
        (should step)
        ;; The turn's step finished before the refresh was sent: a refresh is
        ;; never in flight with the step it follows, so `after' is compared
        ;; with a finished request rather than guarded as concurrent.
        (harness-provider-diagnostics-response step :status 200 :outcome 'ok)
        (let ((refresh (harness-provider-diagnostics-request
                        warm (list :session (list :id "session-1") :cache-refresh t)
                        :configured "testrouter:deepseek/test" :route 'openrouter
                        :host "openrouter.example")))
          (should (harness-provider-diagnostics-attempt-warm refresh))
          (harness-provider-diagnostics-response refresh :status 200 :outcome 'ok)
          ;; The refresh is not the session's last request ...
          (should (equal (harness-provider-diagnostics-attempt-id step)
                         (harness-provider-diagnostics-attempt-id
                          (harness-provider-diagnostics-last-attempt "session-1"))))
          (let ((after (harness-provider-diagnostics-test--request next)))
            ;; ... so the step after it continues the turn, not the refresh.
            (should (equal "appended" (harness-provider-diagnostics-attempt-prefix after)))
            (should (equal "warm" (harness-provider-diagnostics-attempt-expected-cold after)))
            (should-not (equal "prefix-diverged"
                               (harness-provider-diagnostics-miss-cause "session-1")))))))))

(ert-deftest harness-provider-diagnostics-overlapping-requests-are-concurrent ()
  "Two requests in flight are not a prefix change, and no client cause."
  (harness-provider-diagnostics-test--with-state
    (let ((one (harness-provider-diagnostics-test--request
                (harness-provider-diagnostics-test--body
                 :messages (list (list :role "user" :content "one")))))
          (two (harness-provider-diagnostics-test--request
                (harness-provider-diagnostics-test--body
                 :messages (list (list :role "user" :content "two"))))))
      (should (equal "first" (harness-provider-diagnostics-attempt-prefix one)))
      ;; What the bytes say is reported as it is: two different requests did
      ;; differ.  What they do not say is that the client changed anything.
      (should (equal "diverged" (harness-provider-diagnostics-attempt-prefix two)))
      (should (equal "concurrent" (harness-provider-diagnostics-attempt-expected-cold two)))
      ;; Not a client cause, and not `warm' either: nothing is known.
      (should (equal "unknown" (harness-provider-diagnostics-miss-cause "session-1")))
      ;; A request sent beside an unfinished one is concurrent, not a client
      ;; change -- even once the first of the two has closed, since the
      ;; second is then the basis and it is still open.
      (harness-provider-diagnostics-response one :status 200 :outcome 'ok)
      (let ((three (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body
                     :messages (list (list :role "user" :content "one")
                                     (list :role "user" :content "two"))))))
        (should (equal "concurrent" (harness-provider-diagnostics-attempt-expected-cold three)))
        ;; With every earlier request finished, a request that continues the
        ;; newest one is an append: the guard applies only while a request is
        ;; still open.  THREE is the basis here, so it is the one FOUR must
        ;; continue.
        (harness-provider-diagnostics-response two :status 200 :outcome 'ok)
        (harness-provider-diagnostics-response three :status 200 :outcome 'ok)
        (let ((four (harness-provider-diagnostics-test--request
                     (harness-provider-diagnostics-test--body
                      :messages (list (list :role "user" :content "one")
                                      (list :role "user" :content "two")
                                      (list :role "user" :content "three"))))))
          (should (equal "appended" (harness-provider-diagnostics-attempt-prefix four))))))))

(ert-deftest harness-provider-diagnostics-in-flight-count-rises-and-releases ()
  "The count is taken, rises per request and returns to nothing."
  (harness-provider-diagnostics-test--with-state
    (let* ((body (harness-provider-diagnostics-test--body))
           (one (harness-provider-diagnostics-test--request body))
           (two (harness-provider-diagnostics-test--request body)))
      ;; Counted at all: a `let' init form could not see the attempt, so
      ;; this read nil for every request.
      (should (= 1 (harness-provider-diagnostics-attempt-concurrency one)))
      (should (= 2 (harness-provider-diagnostics-attempt-concurrency two)))
      (should (= 1 (harness-provider-diagnostics-attempt-request-number one)))
      (should (= 2 (harness-provider-diagnostics-attempt-request-number two)))
      (should (= 2 (gethash "session-1" harness-provider-diagnostics--in-flight)))
      ;; Released when each attempt closes, and not before.
      (harness-provider-diagnostics-response one :status 200 :outcome 'ok)
      (should (= 1 (gethash "session-1" harness-provider-diagnostics--in-flight)))
      (harness-provider-diagnostics-response two :status 200 :outcome 'ok)
      (should-not (gethash "session-1" harness-provider-diagnostics--in-flight)))))

(ert-deftest harness-provider-diagnostics-close-survives-a-failed-response-line ()
  "A failure to log a response still releases the in-flight count."
  (harness-provider-diagnostics-test--with-state
    (let* ((attempt (harness-provider-diagnostics-test--request
                     (harness-provider-diagnostics-test--body)))
           (harness-provider-diagnostics-max-line-chars 64))
      (should (= 1 (gethash "session-1" harness-provider-diagnostics--in-flight)))
      (cl-letf (((symbol-function 'harness-provider-diagnostics--log)
                 (lambda (&rest _) (error "no log"))))
        (harness-provider-diagnostics-response attempt :status 200 :outcome 'ok))
      (should-not (gethash "session-1" harness-provider-diagnostics--in-flight)))))

(ert-deftest harness-provider-diagnostics-a-failed-request-line-releases-the-count ()
  "A request whose line cannot be written leaves no count behind.
The count is taken before the line is written, and a request that fails
there returns no attempt, so nothing else would ever close it: every
later request of the session would then read as overlapping a request
that is long over, and report `concurrent' instead of what the bytes
say."
  (harness-provider-diagnostics-test--with-state
    (cl-letf (((symbol-function 'harness-provider-diagnostics--start)
               (lambda (&rest _) (error "no line"))))
      (should-not (harness-provider-diagnostics-test--request
                   (harness-provider-diagnostics-test--body))))
    (should-not (gethash "session-1" harness-provider-diagnostics--in-flight))
    ;; And the next request of the session is counted from one, not two.
    (let ((next (harness-provider-diagnostics-test--request
                 (harness-provider-diagnostics-test--body))))
      (should (= 1 (harness-provider-diagnostics-attempt-concurrency next))))))

;;;; Bounds and privacy

(ert-deftest harness-provider-diagnostics-line-is-bounded ()
  (harness-provider-diagnostics-test--with-state
    (let ((messages (cl-loop for i below 300
                             collect (list :role (if (= 0 (% i 2)) "user" "assistant")
                                           :content (make-string 2000 ?x)))))
      (harness-provider-diagnostics-test--request
       (harness-provider-diagnostics-test--body :messages messages))
      (let ((line (harness-provider-diagnostics-test--request-line)))
        (should line)
        (should (<= (length line) harness-provider-diagnostics-max-line-chars))
        (let ((count (length (split-string
                              (or (harness-provider-diagnostics-test--field line "cps") "")
                              "," t))))
          (should (<= count harness-provider-diagnostics-max-checkpoints)))))))

(ert-deftest harness-provider-diagnostics-large-body-is-skipped ()
  (harness-provider-diagnostics-test--with-state
    (let ((harness-provider-diagnostics-max-bytes 100))
      (let ((attempt (harness-provider-diagnostics-test--request
                      (harness-provider-diagnostics-test--body))))
        (should (eq 'large (harness-provider-diagnostics-attempt-skipped attempt)))
        (should (string-match-p "prefix=skipped-large"
                                (harness-provider-diagnostics-test--request-line)))
        (should-not (harness-provider-diagnostics-attempt-checkpoints attempt))))))

(ert-deftest harness-provider-diagnostics-logs-no-prompt-or-secret ()
  (harness-provider-diagnostics-test--with-state
    (let ((body (harness-provider-diagnostics-test--body
                 :messages (list (list :role "system" :content "PROMPT-SECRET-ONE")
                                 (list :role "user" :content "PROMPT-SECRET-TWO"))
                 :tools (list (list :type "function"
                                    :function (list :name "secret_tool"
                                                    :description "TOOL-SECRET"
                                                    :parameters '(:type "object")))))))
      (let ((attempt (harness-provider-diagnostics-test--request body)))
        (harness-provider-diagnostics-response
         attempt :status 200 :usage '(:prompt_tokens 10 :completion_tokens 1) :outcome 'ok)
        (let ((all (mapconcat #'identity (harness-provider-diagnostics-test--messages) "\n")))
          (dolist (secret '("PROMPT-SECRET-ONE" "PROMPT-SECRET-TWO" "TOOL-SECRET" "secret_tool"))
            (should-not (string-search secret all)))
          (let ((key (harness-provider-diagnostics-test--key-bytes)))
            (should key)
            (should-not (string-search (base64-encode-string key t) all))
            (should-not (string-search key all))))))))

;;;; Responses body

(ert-deftest harness-provider-diagnostics-responses-body-is-chunked ()
  (harness-provider-diagnostics-test--with-state
    (let* ((body (list :model "gpt-test"
                       :instructions "System."
                       :input (harness-json-array
                               (list (list :type "additional_tools"
                                           :tools (list (list :type "function"
                                                              :name "read_file"
                                                              :description "Read."
                                                              :parameters '(:type "object"))))
                                     (list :type "message" :role "user"
                                           :content (list (list :type "input_text" :text "Hi.")))
                                     (list :type "function_call_output" :call_id "c1"
                                           :output "ok")))
                       :store :false :stream t)))
      (let ((attempt (harness-provider-diagnostics-test--request body "responses-session")))
        (should attempt)
        (should (= 6 (harness-provider-diagnostics-attempt-chunks attempt)))
        (should (equal "system/0"
                       (plist-get (nth 2 (harness-provider-diagnostics-attempt-checkpoints
                                          attempt))
                                  :tag)))
        (should (equal "tools"
                       (plist-get (nth 3 (harness-provider-diagnostics-attempt-checkpoints
                                          attempt))
                                  :tag)))))))

(ert-deftest harness-provider-diagnostics-responses-usage-fields ()
  (harness-provider-diagnostics-test--with-state
    (let ((attempt (harness-provider-diagnostics-test--request
                    (harness-provider-diagnostics-test--body))))
      (harness-provider-diagnostics-response
       attempt :status 200 :outcome 'ok :stop 'end-turn :currency "USD"
       :usage '(:input_tokens 100 :output_tokens 7
                :input_tokens_details (:cached_tokens 60 :cache_write_tokens 10))
       :usage-event '(:type usage :input 100 :output 7 :cache-read 60 :cache-write 10
                      :cost 0.0 :billing subscription :context 100))
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should (equal "100" (harness-provider-diagnostics-test--field line "input")))
        (should (equal "7" (harness-provider-diagnostics-test--field line "output")))
        (should (equal "60" (harness-provider-diagnostics-test--field line "cache-read")))
        (should (equal "10" (harness-provider-diagnostics-test--field line "cache-write")))
        (should (equal "plan" (harness-provider-diagnostics-test--field line "cost-source")))))))

;;;; Provider integration (fake HTTP, no network)

(defun harness-provider-diagnostics-test--sse (&rest payloads)
  "Return SSE text for PAYLOADS, strings or plists."
  (mapconcat (lambda (payload)
               (format "data: %s\n\n"
                       (if (stringp payload) payload (harness-json-encode payload))))
             payloads ""))

(defun harness-provider-diagnostics-test--fake-http (response)
  "Return a fake `harness-http-request' replaying RESPONSE.
RESPONSE is (:status N :headers ALIST :chunks (STRING...)), or
\(:hang t).  It records each URL in `--requests', with the body it was
given: `:body' when the transport is handed frozen bytes, and `:json'
when it is handed a plist."
  (lambda (url &rest args)
    (push (list :url url :method (or (plist-get args :method) "GET")
                :json (plist-get args :json) :body (plist-get args :body)
                :args args)
          harness-provider-diagnostics-test--requests)
    (let ((handle (make-harness-http-handle
                   :url url :callback (plist-get args :callback)
                   :on-chunk (plist-get args :on-chunk)
                   :on-headers (plist-get args :on-headers)
                   :started (float-time))))
      (unless (plist-get response :hang)
        (harness-run-soon
         (lambda ()
           (unless (harness-http-handle-cancelled handle)
             (let ((status (or (plist-get response :status) 200)))
               (when (plist-get args :on-headers)
                 (funcall (plist-get args :on-headers) status (plist-get response :headers)))
               (when (plist-get args :on-chunk)
                 (dolist (chunk (plist-get response :chunks))
                   (funcall (plist-get args :on-chunk) chunk)))
               (funcall (plist-get args :callback) status nil "" nil))))))
      handle)))

(defvar harness-provider-diagnostics-test-endpoint
  '(:id testrouter :label "Test router" :base-url "https://openrouter.example/api/v1"
    :api-key "sk-test-not-a-real-key" :flavor openrouter)
  "An OpenRouter-flavoured endpoint with a literal test key.")

(defun harness-provider-diagnostics-test--run (response)
  "Run one completion through the fake HTTP RESPONSE; return the events."
  (let* ((events nil)
         (request (list :model "testrouter:deepseek/test"
                        :session (list :id "provider-session")
                        :system "System."
                        :messages (list (list :role 'user :content "Hi."))
                        :max-tokens 16
                        :on-event (lambda (event) (push event events)))))
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-provider-diagnostics-test--fake-http response)))
      (let ((handle (harness-openai--complete
                     harness-provider-diagnostics-test-endpoint request)))
        (harness-test-wait
         (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5
         "provider done")
        (cons (reverse events) handle)))))

(ert-deftest harness-provider-diagnostics-provider-captures-response-metadata ()
  (harness-provider-diagnostics-test--with-state
    (let* ((usage '(:prompt_tokens 10 :completion_tokens 2 :cost 0.0001
                    :prompt_tokens_details (:cached_tokens 4)))
           (response (list :status 200
                           :headers '(("x-request-id" . "req-abc"))
                           :chunks (list
                                    (harness-provider-diagnostics-test--sse
                                     (list :id "gen-1" :object "chat.completion.chunk"
                                           :model "deepseek/test-served" :provider "Morph"
                                           :choices (list (list :index 0 :delta (list :content "Hi")
                                                                :finish_reason nil))))
                                    (harness-provider-diagnostics-test--sse
                                     (list :id "gen-1" :object "chat.completion.chunk"
                                           :model "deepseek/test-served" :provider "Morph"
                                           :choices (list (list :index 0 :delta (list)
                                                                :finish_reason "stop"))
                                           :usage usage)))))
           (result (harness-provider-diagnostics-test--run response))
           (events (car result)))
      (should (= 1 (cl-count 'usage events :key (lambda (e) (plist-get e :type)))))
      (should (= 1 (cl-count 'done events :key (lambda (e) (plist-get e :type)))))
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should line)
        (should (equal "gen-1" (harness-provider-diagnostics-test--field line "response-id")))
        (should (equal "gen-1" (harness-provider-diagnostics-test--field line "generation")))
        (should (equal "req-abc" (harness-provider-diagnostics-test--field line "request-id")))
        (should (equal "Morph" (harness-provider-diagnostics-test--field line "provider")))
        (should (equal "deepseek/test-served"
                       (harness-provider-diagnostics-test--field line "served-model")))
        (should (equal "provider" (harness-provider-diagnostics-test--field line "cost-source")))
        (should (equal "4" (harness-provider-diagnostics-test--field line "cache-read")))
        (should (equal "0.0001" (harness-provider-diagnostics-test--field line "cost"))))
      ;; Only the completion request: diagnostics sends no request.
      (should (= 1 (length harness-provider-diagnostics-test--requests)))
      (should (string-match-p "/chat/completions\\'"
                              (plist-get (car harness-provider-diagnostics-test--requests) :url)))
      ;; The body sent is the provider's own body, not a diagnostic one.
      ;; It goes out as frozen bytes, so it is decoded back to read it.
      (let* ((sent (car harness-provider-diagnostics-test--requests))
             (json (or (plist-get sent :json)
                       (let ((text (plist-get sent :body)))
                         (and (stringp text) (harness-json-parse text))))))
        (should (equal (plist-get json :model) "deepseek/test"))))))

(ert-deftest harness-provider-diagnostics-provider-error-has-no-error-text ()
  (harness-provider-diagnostics-test--with-state
    (let* ((response (list :status 500 :headers nil
                           :chunks (list (harness-provider-diagnostics-test--sse
                                          (list :error (list :message "SECRET-ERROR-TEXT"))))))
           (result (harness-provider-diagnostics-test--run response)))
      (should (= 1 (cl-count 'done (car result) :key (lambda (e) (plist-get e :type)))))
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should line)
        (should (equal "error" (harness-provider-diagnostics-test--field line "outcome")))
        (should (equal "500" (harness-provider-diagnostics-test--field line "status")))
        (should-not (string-search "SECRET-ERROR-TEXT"
                                   (mapconcat #'identity
                                              (harness-provider-diagnostics-test--messages) "\n")))))))

(ert-deftest harness-provider-diagnostics-provider-missing-metadata-is-unknown ()
  (harness-provider-diagnostics-test--with-state
    (let* ((response (list :status 200 :headers nil
                           :chunks (list (harness-provider-diagnostics-test--sse
                                          (list :choices (list (list :index 0
                                                                     :delta (list :content "Hi")
                                                                     :finish_reason "stop")))))))
           (result (harness-provider-diagnostics-test--run response)))
      (should (= 1 (cl-count 'done (car result) :key (lambda (e) (plist-get e :type)))))
      (let ((line (harness-provider-diagnostics-test--response-line)))
        (should line)
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "response-id")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "generation")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "provider")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "served-model")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "cache-read")))
        (should (equal "unknown" (harness-provider-diagnostics-test--field line "cost")))))))

(ert-deftest harness-provider-diagnostics-provider-cancel-logs-once ()
  (harness-provider-diagnostics-test--with-state
    (let* ((events nil)
           (request (list :model "testrouter:deepseek/test"
                          :session (list :id "provider-session-cancel")
                          :system "System."
                          :messages (list (list :role 'user :content "Hi."))
                          :on-event (lambda (event) (push event events)))))
      (cl-letf (((symbol-function 'harness-http-request)
                 (harness-provider-diagnostics-test--fake-http (list :hang t))))
        (let* ((handle (harness-openai--complete
                        harness-provider-diagnostics-test-endpoint request))
               (cancel (plist-get handle :cancel)))
          (funcall cancel)
          (harness-test-wait
           (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5
           "cancelled done")
          (funcall cancel)
          (should (= 1 (cl-count 'done events :key (lambda (e) (plist-get e :type)))))
          (let ((lines (harness-provider-diagnostics-test--lines "response")))
            (should (= 1 (length lines)))
            (should (equal "cancelled" (harness-provider-diagnostics-test--field (car lines) "outcome")))))))))
(ert-deftest harness-provider-diagnostics-summary-is-content-free ()
  "The public summary keeps the reading and no prompt, tool or key text.
It is what a caller correlates without parsing the log, so it must carry
the same unknowns the line does and nothing raw."
  (let* ((harness-provider-diagnostics-key-file nil)
         (harness-state-directory (harness-test-temp-dir))
         (harness-provider-diagnostics--key 'unset)
         (harness-provider-diagnostics--last (make-hash-table :test #'equal))
         (harness-provider-diagnostics--last-order nil)
         (request (list :model "checkfake:model"
                        :session (list :id "pd-summary-session")
                        :system "SECRET-SYSTEM-MARKER"
                        :messages (list (list :role 'user
                                              :content "SECRET-PROMPT-MARKER"))
                        :tools (list (list :name "SECRET-TOOL-MARKER"))))
         (attempt (harness-provider-diagnostics-request
                   (list :model "checkfake:model"
                         :messages (list (list :role 'user
                                               :content "SECRET-PROMPT-MARKER"))
                         :tools (list (list :name "SECRET-TOOL-MARKER")))
                   request :configured "checkfake:model" :route "openai"
                   :host "example.invalid")))
    (should attempt)
    (harness-provider-diagnostics-response
     attempt :status 200 :generation "gen-one" :request-id "req-one"
     :provider "Morph" :served-model "deepseek/x"
     :usage (list :prompt_tokens 100 :completion_tokens 5 :cost 0.001)
     :currency "USD"
     :outcome 'ok :stop 'end-turn)
    (let* ((summary (harness-provider-diagnostics-session-summary
                     "pd-summary-session"))
           (response (plist-get summary :response))
           (text (prin1-to-string summary)))
      (should summary)
      (should (equal "first" (plist-get summary :expected-cold)))
      (should (equal "Morph" (plist-get response :provider)))
      (should (equal "gen-one" (plist-get response :generation)))
      (should (equal "req-one" (plist-get response :request-id)))
      (should (= 100 (plist-get response :prompt)))
      (should (= 5 (plist-get response :output)))
      (should (equal 'provider (plist-get response :cost-source)))
      (should (equal "USD" (plist-get response :currency)))
      ;; A cost with no currency the provider named is unknown, not USD.
      (should (equal "unknown"
                     (plist-get (harness-provider-diagnostics-usage
                                 (list :cost 0.5) nil)
                                :currency)))
      ;; Missing readings are unknown in the summary too, never zero.
      (should-not (plist-get response :cache-read))
      (should-not (plist-get response :cache-write))
      ;; Nothing raw is in it.
      (should-not (string-match-p "SECRET-SYSTEM-MARKER" text))
      (should-not (string-match-p "SECRET-PROMPT-MARKER" text))
      (should-not (string-match-p "SECRET-TOOL-MARKER" text)))))

(ert-deftest harness-provider-diagnostics-miss-cause-is-honest ()
  "The cold cause is the recorded label, `warm', or `unknown' -- nothing else.
A missing record is unknown, never warm and never a client cause; a
provider name or a zero cache read is not a cause of its own."
  (should (equal "warm" (harness-provider-diagnostics-cold-cause
                           '(:expected-cold "warm"))))
  (should (equal "tools-change" (harness-provider-diagnostics-cold-cause
                                   '(:expected-cold "tools-change"))))
  (should (equal "idle" (harness-provider-diagnostics-cold-cause
                           '(:expected-cold "idle"))))
  (should (equal "unknown" (harness-provider-diagnostics-cold-cause nil)))
  (should (equal "unknown" (harness-provider-diagnostics-cold-cause '())))
  ;; A label the module does not know is not passed through as a cause.
  (should (equal "unknown" (harness-provider-diagnostics-cold-cause
                              '(:expected-cold "provider-eviction")))))

(ert-deftest harness-provider-diagnostics-miss-cause-needs-a-record ()
  "Without a diagnostics record the miss cause is unknown, not a guess."
  (let ((harness-provider-diagnostics--last (make-hash-table :test #'equal)))
    (should (equal "unknown" (harness-provider-diagnostics-miss-cause
                                "no-such-session")))))
(provide 'harness-provider-diagnostics-test)
;;; harness-provider-diagnostics-test.el ends here
