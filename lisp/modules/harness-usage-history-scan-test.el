;;; harness-usage-history-scan-test.el --- Historical metadata scanner tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Synthetic node logs only.  No real state, provider logs, messages or
;; credentials are opened.  Secret-shaped fixture markers explicitly
;; test that content, tool data and arbitrary metadata are neither
;; decoded by the projecting reader nor returned to its caller.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-usage-history-scan)

(defmacro harness-usage-history-scan-test-with (&rest body)
  "Run BODY with a disposable log directory `dir' and `input'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "harness-history-scan-test-" t))
          (input (list :sessions-dir dir :sessions
                       '((:id "s" :project "/work/tree/" :main "/work/main/")))))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(defun harness-usage-history-scan-test-write (dir sid records &optional suffix)
  "Write synthetic RECORDS to SID's node log in DIR, then raw SUFFIX."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file (expand-file-name (concat sid ".nodes.jsonl") dir)
      (dolist (record records) (insert (harness-json-encode-text record) "\n"))
      (when suffix (insert suffix)))))

(defun harness-usage-history-scan-test-node (id ts usage &optional model meta)
  "Make a synthetic assistant node ID at TS with USAGE, MODEL and extra META."
  (append (list :id id :session "s" :kind "assistant")
          (and ts (list :ts ts))
          (list :meta (append (and model (list :model model)) (list :usage usage) meta))))

(defun harness-usage-history-scan-test-usage (input output &optional extra)
  "Make explicit newer-provider counter provenance from INPUT, OUTPUT and EXTRA."
  (list :input 99999 :output 99999 :cache-read 99999 :cache-write 99999
        :usage (append (and input (list :input input)) (and output (list :output output)) extra)
        :input-semantics "exclusive" :cache-write-status "not-reported"))

(ert-deftest harness-usage-history-scan-normalize-raw-presence-and-whitelist ()
  (let* ((record '(:input 900 :output 900 :cache-write 900
                   :usage (:input 0 :output 5 :cache-read 0 :cache-write nil
                           :context 5 :secret "SECRET-RAW-COUNTERS")
                   :input-semantics "inclusive" :cache-write-status "not-reported"
                   :cost 0.02 :observed-cost 0.015 :cost-source "observed" :billing "api"
                   :pricing (:input 1.5 :output 6 :cache-read 0 :cache-write -1
                             :auth "SECRET-PRICING") :priced-at 100))
         (result (harness-usage-history-scan-normalize record "openai:x" "call" "session-log"))
         (usage (plist-get result :usage)))
    (should (= (plist-get usage :input) 0))
    (should (= (plist-get usage :output) 5))
    (should (= (plist-get usage :cache-read) 0))
    (should-not (plist-member usage :cache-write))
    (should (equal (plist-get result :input-semantics) "inclusive"))
    (should (equal (plist-get result :cache-write-status) "not-reported"))
    (should (equal (plist-get result :cost-source) "observed"))
    (should (= (plist-get result :observed-cost) 0.015))
    (should (= (plist-get result :recorded-cost) 0.02))
    (should (equal (plist-get result :billing) "api"))
    (should (equal (plist-get result :pricing) '(:input 1.5 :output 6 :cache-read 0)))
    (should (= (plist-get result :priced-at) 100))
    (should-not (string-match-p "SECRET" (prin1-to-string result)))))

(ert-deftest harness-usage-history-scan-normalize-explicit-empty-not-legacy-fallback ()
  (let ((result (harness-usage-history-scan-normalize
                 '(:input 100 :output 10 :cache-read 0 :cache-write 0 :usage nil
                   :input-semantics "unknown" :cache-write-status "unknown") "claude:x")))
    (should-not (plist-get result :usage))
    (should (equal (plist-get result :input-semantics) "unknown"))
    (should (equal (plist-get result :cache-write-status) "unknown"))))

(ert-deftest harness-usage-history-scan-normalize-legacy-inclusive-and-missing-counters ()
  (dolist (model '("openai:x" "responses:x" "chatgpt:x"))
    (let* ((result (harness-usage-history-scan-normalize
                    '(:input 100 :output 10 :cache-read 80 :cache-write 0 :context 100) model "call"))
           (usage (plist-get result :usage)))
      (should (= (plist-get usage :input) 100))
      (should (= (plist-get usage :cache-read) 80))
      (should-not (plist-member usage :cache-write))
      (should (equal (plist-get result :input-semantics) "inclusive"))
      (should (equal (plist-get result :cache-write-status) "not-reported"))))
  (let* ((result (harness-usage-history-scan-normalize
                  '(:input 100 :output 0 :cache-read nil :cache-write 0) "openai:x"))
         (usage (plist-get result :usage)))
    (should (equal (plist-get result :input-semantics) "unknown"))
    (should-not (plist-member usage :output))
    (should-not (plist-member usage :cache-read))
    (should-not (plist-member usage :cache-write))))

(ert-deftest harness-usage-history-scan-normalize-legacy-exclusive-and-hosted-zero-gaps ()
  (dolist (model '("deepseek:x" "bedrock:x" "claude:x" "copilot:x"))
    (let ((result (harness-usage-history-scan-normalize
                   '(:input 20 :output 5 :cache-read 80 :cache-write 0 :context 100) model "unknown")))
      (should (equal (plist-get result :input-semantics) "exclusive"))
      (should-not (plist-member (plist-get result :usage) :cache-write))))
  (dolist (model '("claude:x" "copilot:x"))
    (let ((result (harness-usage-history-scan-normalize
                   '(:input 10 :output 0 :cache-read 0 :cache-write 0 :context 10) model "turn")))
      (should (equal (plist-get result :input-semantics) "unknown"))
      (should (equal (plist-get result :cache-write-status) "unknown"))
      (should-not (plist-member (plist-get result :usage) :cache-read)))))

(ert-deftest harness-usage-history-scan-normalize-context-is-evidence-not-model-spelling ()
  (let ((inclusive (harness-usage-history-scan-normalize
                    '(:input 100 :cache-read 80 :context 100) "openrouter:deepseek/alias" "call"))
        (exclusive (harness-usage-history-scan-normalize
                    '(:input 20 :cache-read 80 :context 100) "openrouter:deepseek/alias" "call"))
        (unknown (harness-usage-history-scan-normalize
                  '(:input 100 :cache-read 80) "openrouter:deepseek/alias" "call"))
        (hosted (harness-usage-history-scan-normalize
                 '(:input 100 :cache-read 80 :context 100) "custom:x" "turn")))
    (should (equal (plist-get inclusive :input-semantics) "inclusive"))
    (should (equal (plist-get exclusive :input-semantics) "exclusive"))
    (should (equal (plist-get unknown :input-semantics) "unknown"))
    (should (equal (plist-get hosted :input-semantics) "unknown"))))

(ert-deftest harness-usage-history-scan-normalize-observed-versus-recorded-cost ()
  (let* ((row '(:input 100 :output 5 :cost 0.12 :list-cost 0.3))
         (legacy (harness-usage-history-scan-normalize row "openai:x" "unknown" "ledger"))
         (event (harness-usage-history-scan-normalize row "openai:x" "call" "session-log"))
         (plan (harness-usage-history-scan-normalize '(:cost 0 :billing "subscription") "claude:x"))
         (estimate (harness-usage-history-scan-normalize
                    '(:cost 0.5 :cost-source "estimated" :observed-cost 100 :billing "extra-usage") "copilot:x")))
    (should (equal (plist-get legacy :cost-source) "unknown"))
    (should-not (plist-get legacy :observed-cost))
    (should (= (plist-get legacy :recorded-cost) 0.12))
    (should (equal (plist-get event :cost-source) "observed"))
    (should (= (plist-get event :observed-cost) 0.12))
    (should (equal (plist-get plan :cost-source) "subscription"))
    (should-not (plist-get plan :observed-cost))
    (should (equal (plist-get estimate :cost-source) "estimated"))
    (should-not (plist-get estimate :observed-cost))
    (should (equal (plist-get estimate :billing) "extra-usage"))))

(ert-deftest harness-usage-history-scan-projects-only-metadata-never-private-values ()
  (harness-usage-history-scan-test-with
    (let* ((secret "SECRET-CONTENT-API-KEY-fixture-only")
           (usage (harness-usage-history-scan-test-usage 10 5 '(:cache-read 0)))
           (node (append (harness-usage-history-scan-test-node "n-a" 100 usage "openai:x"
                                                              (list :project "/work/tree/" :debug secret :signature secret))
                         (list :content secret :input (list :password secret)
                               :output secret :blocks (list (list :text secret)) :tool secret)))
           (parse (symbol-function 'json-parse-string)) decoded)
      (harness-usage-history-scan-test-write dir "s" (list node))
      (cl-letf (((symbol-function 'json-parse-string)
                 (lambda (string &rest opts)
                   (push string decoded)
                   (apply parse string opts))))
        (let* ((result (harness-usage-history-scan input))
               (sample (car (plist-get result :samples))))
          (should (= (length (plist-get result :samples)) 1))
          (should (= (plist-get (plist-get sample :usage) :input) 10))
          (should (equal (plist-get sample :project) "/work/tree/"))
          (should (equal (plist-get sample :main) "/work/main/"))
          (should (equal (plist-get sample :source) "session-log"))
          (should-not (string-match-p secret (prin1-to-string result)))
          (should-not (cl-some (lambda (value) (string-match-p secret value)) decoded)))))))

(ert-deftest harness-usage-history-scan-updates-and-duplicate-node-identity ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list '(:id "u" :session "s" :kind "user" :ts 90)
                     '(:id "a" :session "s" :kind "assistant" :ts 100 :content "SECRET-INITIAL")
                     (list :_op "update" :id "a" :content "SECRET-FINAL"
                           :meta (list :model "openai:first" :usage usage))
                     (harness-usage-history-scan-test-node "a" 100 usage "openai:first")))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples))
             (sample (car samples)) (coverage (plist-get result :coverage)))
        (should (= (length samples) 1))
        (should (= (plist-get sample :ts) 100))
        (should (equal (plist-get sample :turn) "u"))
        (should (equal (plist-get sample :turn-source) "user-node"))
        (should (equal (plist-get sample :model) "openai:first"))
        (should (= (plist-get coverage :duplicate-nodes) 1))
        (should (equal (plist-get coverage :status) "partial"))))))

(ert-deftest harness-usage-history-scan-forks-only-count-originating-session ()
  (harness-usage-history-scan-test-with
    (let* ((usage (harness-usage-history-scan-test-usage 10 5))
           (parent (list :id "p-a" :session "p" :kind "assistant" :ts 100
                         :meta (list :model "openai:x" :usage usage)))
           (child (harness-usage-history-scan-test-node "c-a" 120 usage "openai:x")))
      (harness-usage-history-scan-test-write dir "p" (list parent))
      (harness-usage-history-scan-test-write dir "s" (list parent child))
      (setf (plist-get input :sessions)
            '((:id "p" :project "/parent/" :main "/main/")
              (:id "s" :project "/fork/" :main "/main/")))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= (length samples) 2))
        (should (equal (mapcar (lambda (s) (plist-get s :session)) samples) '("p" "s"))))
      (should (= (plist-get (plist-get (harness-usage-history-scan input) :coverage) :inherited-nodes) 1)))))

(ert-deftest harness-usage-history-scan-deletes-orphans-and-readded-identities ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "gone" 100 usage "openai:x")
                     '(:_op "delete" :id "gone")
                     (list :_op "update" :id "orphan" :meta (list :usage usage))
                     (harness-usage-history-scan-test-node "gone" 120 usage "openai:x")))
      (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
        (should (= (length (plist-get result :samples)) 1))
        (should (= (plist-get (car (plist-get result :samples)) :ts) 120))
        (should (= (plist-get coverage :deleted-nodes) 1))
        (should (= (plist-get coverage :orphan-updates) 1))))))

(ert-deftest harness-usage-history-scan-request-and-message-snapshots-never-sum ()
  (harness-usage-history-scan-test-with
    (let* ((u1 (harness-usage-history-scan-test-usage 10 5))
           (u2 (harness-usage-history-scan-test-usage 10 8)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 u1 "openai:x" '(:request-id "r"))
                     (harness-usage-history-scan-test-node "b" 101 u2 "openai:x" '(:request-id "r"))
                     (harness-usage-history-scan-test-node "c" 110 u1 "openai:x" '(:message-id "m"))
                     (harness-usage-history-scan-test-node "d" 111 u2 "openai:x" '(:message-id "m"))))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= (length samples) 2))
        (should (equal (mapcar (lambda (s) (plist-get s :ts)) samples) '(100 110)))
        (should (equal (mapcar (lambda (s) (plist-get (plist-get s :usage) :output)) samples) '(8 8)))
        (should (= (plist-get (plist-get result :coverage) :duplicate-samples) 2))))))

(ert-deftest harness-usage-history-scan-request-message-alias-discovery ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 usage "openai:x" '(:message-id "m"))
                     (harness-usage-history-scan-test-node "b" 101 usage "openai:x" '(:message-id "m" :request-id "r"))
                     (harness-usage-history-scan-test-node "c" 102 usage "openai:x" '(:request-id "r"))))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= (length samples) 1))
        (should (= (plist-get (car samples) :ts) 100))
        (should (= (plist-get (plist-get result :coverage) :duplicate-samples) 2))))))

(ert-deftest harness-usage-history-scan-late-request-message-bridge-unions-existing-records ()
  (harness-usage-history-scan-test-with
    (let ((early (harness-usage-history-scan-test-usage 10 5))
          (final (harness-usage-history-scan-test-usage 10 9)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 early "openai:x" '(:message-id "m"))
                     (harness-usage-history-scan-test-node "b" 101 early "openai:x" '(:request-id "r"))
                     (harness-usage-history-scan-test-node "c" 102 final "openai:x" '(:request-id "r" :message-id "m"))
                     (harness-usage-history-scan-test-node "d" 103 final "openai:x" '(:message-id "m"))))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= 1 (length samples)))
        (should (= 100 (plist-get (car samples) :ts)))
        (should (= 9 (plist-get (plist-get (car samples) :usage) :output)))
        (should (= 3 (plist-get (plist-get result :coverage) :duplicate-samples)))))))

(ert-deftest harness-usage-history-scan-legacy-missing-owner-and-duplicate-descriptors ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "s" '((:id "a" :kind "assistant" :ts 100
                 :meta (:model "openai:x" :usage (:input 10 :output 5)))))
    (setf (plist-get input :sessions) '((:id "s" :project "/work/") (:id "s" :project "/work/")))
    (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
      (should (= (length (plist-get result :samples)) 1))
      (should (= (plist-get coverage :files-requested) 1))
      (should (= (plist-get coverage :missing-owner-nodes) 1))
      (should (member "missing-node-owner" (plist-get coverage :gaps))))))

(ert-deftest harness-usage-history-scan-turn-cumulative-snapshots-last-only ()
  (harness-usage-history-scan-test-with
    (let* ((u1 (append (harness-usage-history-scan-test-usage 10 5) '(:scope "turn" :turn-id "t1" :request-id "r1")))
           (u2 (append (harness-usage-history-scan-test-usage 20 8) '(:scope "turn" :turn-id "t1" :request-id "r2"))))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 u1 "claude:x")
                     (harness-usage-history-scan-test-node "b" 110 u2 "claude:x")))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples))
             (sample (car samples)))
        (should (= (length samples) 1))
        (should (= (plist-get sample :ts) 110))
        (should (= (plist-get (plist-get sample :usage) :input) 20))
        (should (equal (plist-get sample :granularity) "turn"))
        (should (equal (plist-get sample :turn) "t1"))
        (should (equal (plist-get sample :turn-source) "recorded"))))))

(ert-deftest harness-usage-history-scan-unknown-cumulative-snapshots-conservative ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "s" (list (harness-usage-history-scan-test-node "a" 100 '(:input 10 :output 5) "custom:x")
                   (harness-usage-history-scan-test-node "b" 110 '(:input 20 :output 8) "custom:x")))
    (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
      (should (= (length samples) 1))
      (should (= (plist-get (plist-get (car samples) :usage) :input) 20))
      (should (equal (plist-get (car samples) :granularity) "unknown"))
      (should (= (plist-get (plist-get result :coverage) :ambiguous-samples) 2)))))

(ert-deftest harness-usage-history-scan-stale-chunks-dedup-within-not-across-turns ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list '(:id "u1" :session "s" :kind "user" :ts 90)
                     (harness-usage-history-scan-test-node "a" 100 usage "openai:x")
                     '(:id "steer" :session "s" :kind "user" :ts 101 :meta (:steering t))
                     (harness-usage-history-scan-test-node "b" 102 usage "openai:x")
                     '(:id "u2" :session "s" :kind "user" :ts 110)
                     (harness-usage-history-scan-test-node "c" 120 usage "openai:x")))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= (length samples) 2))
        (should (equal (mapcar (lambda (s) (plist-get s :turn)) samples) '("u1" "u2")))
        (should (= (plist-get (plist-get result :coverage) :duplicate-samples) 1))))))

(ert-deftest harness-usage-history-scan-model-changes-and-missing-model-no-current-fallback ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (setf (plist-get input :sessions)
            '((:id "s" :project "/work/tree/" :main "/work/main/" :model "openai:CURRENT")))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 usage "openai:old")
                     (harness-usage-history-scan-test-node "b" 110 usage "openai:new")
                     (harness-usage-history-scan-test-node "c" 120 usage nil)))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (= (length samples) 3))
        (should (equal (mapcar (lambda (s) (plist-get s :model)) samples) '("openai:old" "openai:new" nil)))
        (should (= (plist-get (plist-get result :coverage) :model-gaps) 1))
        (should-not (string-match-p "CURRENT" (prin1-to-string result)))))))

(ert-deftest harness-usage-history-scan-half-open-boundaries-after-dedup ()
  (harness-usage-history-scan-test-with
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "before" 99 usage "openai:x" '(:request-id "r0"))
                     (harness-usage-history-scan-test-node "chunk" 101 usage "openai:x" '(:request-id "r0"))
                     (harness-usage-history-scan-test-node "since" 100 usage "openai:x" '(:request-id "r1"))
                     (harness-usage-history-scan-test-node "last" 199 usage "openai:x" '(:request-id "r2"))
                     (harness-usage-history-scan-test-node "until" 200 usage "openai:x" '(:request-id "r3"))))
      (setf (plist-get input :since) 100 (plist-get input :until) 200)
      (let ((samples (plist-get (harness-usage-history-scan input) :samples)))
        (should (equal (mapcar (lambda (s) (plist-get s :node)) samples) '("since" "last")))))))

(ert-deftest harness-usage-history-scan-undated-cumulative-and-missing-usage-are-gaps ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "s" (list (harness-usage-history-scan-test-node "undated" nil '(:input 10 :output 5) "openai:x")
                   (harness-usage-history-scan-test-node "cumulative" 100 '(:input 1000 :output 500 :scope "session") "openai:x")
                   (harness-usage-history-scan-test-node "missing" 120 nil "openai:x")))
    ;; A session JSON record is not dated event history, even when present.
    (with-temp-file (expand-file-name "s.json" dir)
      (insert "{\"usage\":{\"input\":99999999},\"prompt\":\"SECRET-SESSION-RECORD\"}"))
    (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
      (should-not (plist-get result :samples))
      (should (= (plist-get coverage :undated-samples) 1))
      (should (= (plist-get coverage :unallocated-samples) 1))
      (should (= (plist-get coverage :missing-usage-nodes) 1))
      (should (member "session-cumulative-usage" (plist-get coverage :gaps)))
      (should-not (string-match-p "SECRET" (prin1-to-string result))))))

(ert-deftest harness-usage-history-scan-partial-counters-not-zero ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "s" (list (harness-usage-history-scan-test-node
                     "partial" 100 '(:input 999 :output 999 :cache-write 999
                                     :usage (:input nil :output 5 :cache-read 0 :cache-write -1)
                                     :input-semantics "unknown" :cache-write-status "unknown") "openai:x")))
    (let* ((result (harness-usage-history-scan input)) (sample (car (plist-get result :samples)))
           (usage (plist-get sample :usage)))
      (should (= (plist-get usage :output) 5))
      (should (= (plist-get usage :cache-read) 0))
      (should-not (plist-member usage :input))
      (should-not (plist-member usage :cache-write))
      (should (= (plist-get (plist-get result :coverage) :partial-usage-samples) 1)))))

(ert-deftest harness-usage-history-scan-incremental-corrupt-partial-and-oversized-lines ()
  (harness-usage-history-scan-test-with
    (let ((harness-usage-history-scan--chunk-bytes 23)
          (harness-usage-history-scan--line-bytes 512)
          (usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list (append (harness-usage-history-scan-test-node "large" 90 usage "openai:x")
                             (list :content (make-string 3000 ?x))))
       (concat "{\"id\":\"bad\",\"content\":\"SECRET-CORRUPT\" nonsense}\n"
               (harness-json-encode-text (harness-usage-history-scan-test-node "good" 100 usage "openai:x")) "\n"
               "{\"id\":\"partial\",\"content\":\"SECRET-PARTIAL"))
      (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
        (should (equal (mapcar (lambda (s) (plist-get s :node)) (plist-get result :samples)) '("good")))
        (should (= (plist-get coverage :oversized-lines) 1))
        (should (= (plist-get coverage :malformed-lines) 1))
        (should (= (plist-get coverage :partial-lines) 1))
        (should-not (string-match-p "SECRET" (prin1-to-string result)))))))

(ert-deftest harness-usage-history-scan-missing-files-safe-paths-and-no-directory-enumeration ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "other" (list (harness-usage-history-scan-test-node "SECRET-UNREQUESTED-ID" 100 '(:input 10) "openai:x")))
    (setf (plist-get input :sessions) '((:id "missing") (:id "../other") (:id "s")))
    (make-symbolic-link (expand-file-name "other.nodes.jsonl" dir) (expand-file-name "s.nodes.jsonl" dir))
    (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
      (should-not (plist-get result :samples))
      (should (= (plist-get coverage :files-requested) 3))
      (should (= (plist-get coverage :files-missing) 1))
      (should (= (plist-get coverage :files-rejected) 2))
      (should (equal (plist-get coverage :status) "failed"))
      (should-not (string-match-p "SECRET" (prin1-to-string result))))))

(ert-deftest harness-usage-history-scan-file-read-errors-are-fixed-coverage ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write dir "s" nil)
    (cl-letf (((symbol-function 'harness-usage-history-scan--read)
               (lambda (&rest _) (signal 'file-error '("SECRET-PRIVATE-ERROR")))))
      (let* ((result (harness-usage-history-scan input)) (coverage (plist-get result :coverage)))
        (should (equal (plist-get coverage :status) "failed"))
        (should (= (plist-get coverage :files-unreadable) 1))
        (should-not (string-match-p "SECRET" (prin1-to-string result)))))))

(ert-deftest harness-usage-history-scan-async-worker-roundtrip-and-private-request-sanitization ()
  (harness-usage-history-scan-test-with
    (let ((usage (append (harness-usage-history-scan-test-usage 10 5 '(:cache-read 0))
                         '(:cost 0.1 :observed-cost 0.1 :cost-source "observed" :billing "api")))
          (run (symbol-function 'harness-run-command)) request-dir request-file)
      (setf (plist-get input :secret) "SECRET-INPUT-EXTRA"
            (plist-get input :sessions) '((:id "s" :project "/work/" :main "/main/" :prompt "SECRET-DESCRIPTOR")))
      (harness-usage-history-scan-test-write
       dir "s" (list (append (harness-usage-history-scan-test-node "a" 100 usage "openai:x")
                             '(:content "SECRET-TRANSCRIPT"))))
      (cl-letf (((symbol-function 'harness-run-command)
                 (lambda (command &rest options)
                   (setq request-dir (plist-get options :cwd)
                         request-file (cdr (assoc "HARNESS_USAGE_HISTORY_INPUT" (plist-get options :env))))
                   (should-not (string-match-p "SECRET" (harness-read-file request-file)))
                   (apply run command options))))
        (let* ((promise (harness-usage-history-scan-run input))
               (result (harness-test-await promise 20))
               (sync (harness-usage-history-scan input)))
          (should (harness-promise-p promise))
          (should (equal result sync))
          (should-not (file-exists-p request-dir))
          (should-not (file-exists-p request-file))
          (should-not (string-match-p "SECRET" (prin1-to-string result))))))))

(ert-deftest harness-usage-history-scan-async-failure-timeout-rejection-and-start-cleanup ()
  (harness-usage-history-scan-test-with
    (dolist (mode '(failure timeout rejected start-error))
      (let (request-dir)
        (cl-letf (((symbol-function 'harness-run-command)
                   (lambda (_command &rest options)
                     (setq request-dir (plist-get options :cwd))
                     (pcase mode
                       ('failure (harness-resolved '(:exit 1 :stderr "SECRET-STDERR")))
                       ('timeout (harness-resolved '(:exit timeout :stderr "SECRET-TIMEOUT")))
                       ('rejected (harness-rejected '(file-error "SECRET-REJECTION")))
                       ('start-error (signal 'file-error '("SECRET-START")))))))
          (let ((promise (harness-usage-history-scan-run input)))
            (should (eq (harness-promise-state promise) 'rejected))
            (should-not (string-match-p "SECRET" (prin1-to-string (harness-promise-value promise))))
            (should request-dir)
            (should-not (file-exists-p request-dir))))))))

(ert-deftest harness-usage-history-scan-empty-and-invalid-input ()
  (harness-usage-history-scan-test-with
    (setf (plist-get input :sessions) nil)
    (should (equal (plist-get (plist-get (harness-usage-history-scan input) :coverage) :status) "empty"))
    (setf (plist-get input :since) 200 (plist-get input :until) 100)
    (should-error (harness-usage-history-scan input))
    (should (eq (harness-promise-state (harness-usage-history-scan-run input)) 'rejected))))

(ert-deftest harness-usage-history-scan-moved-session-workspace-is-not-historical-attribution ()
  (harness-usage-history-scan-test-with
    (setf (plist-get input :sessions) '((:id "s" :project "/new/" :main "/new-main/")))
    (let ((usage (harness-usage-history-scan-test-usage 10 5)))
      (harness-usage-history-scan-test-write
       dir "s" (list (harness-usage-history-scan-test-node "a" 100 usage "openai:x"
                                                        '(:request-id "a" :project "/old/"))
                     (harness-usage-history-scan-test-node "b" 110 usage "openai:x" '(:request-id "b"))))
      (let* ((result (harness-usage-history-scan input)) (samples (plist-get result :samples)))
        (should (equal "/old/" (plist-get (car samples) :project)))
        (should (equal "recorded" (plist-get (car samples) :attribution)))
        (should-not (plist-get (cadr samples) :project))
        (should-not (plist-get (cadr samples) :main))
        (should (equal "unknown" (plist-get (cadr samples) :attribution)))
        (should (member "workspace-attribution-unknown" (plist-get (plist-get result :coverage) :gaps))))
      ;; Only sessions whose working directory cannot move can use the
      ;; descriptor's root without a per-node scope stamp.
      (setf (plist-get input :sessions) '((:id "s" :project "/stable/" :main "/main/" :scope-stable t)))
      (let ((sample (cadr (plist-get (harness-usage-history-scan input) :samples))))
        (should (equal "/stable/" (plist-get sample :project)))
        (should (equal "stable-worktree" (plist-get sample :attribution)))))))

(ert-deftest harness-usage-history-scan-explicit-foreign-currency-not-usd ()
  (harness-usage-history-scan-test-with
    (harness-usage-history-scan-test-write
     dir "s" (list (harness-usage-history-scan-test-node "a" 100
                    '(:usage (:output 10) :cost-source "observed" :observed-cost 2 :currency "EUR") "openai:x")))
    (should (equal "EUR" (plist-get (car (plist-get (harness-usage-history-scan input) :samples)) :currency)))))

(provide 'harness-usage-history-scan-test)
;;; harness-usage-history-scan-test.el ends here
