;;; harness-provider-openrouter-health-test.el --- Health routing tests -*- lexical-binding: t; -*-
(require 'harness-provider-openrouter-test-helpers)
(require 'harness-replay)

(defun harness-openrouter-health-test--reading (&optional status)
  "Fresh, exact identities and prices, with primary health STATUS."
  (list :at (float-time) :canonical-slug harness-openrouter-test-model
        :endpoints
        (harness-openrouter-parse-endpoints
         (harness-json-parse
          (harness-openrouter-test--catalogue-json
           (append (harness-openrouter-test--endpoint-json "deepinfra/fp8" "DeepInfra")
                   (list :status (or status -2)))
           (append (harness-openrouter-test--endpoint-json "cohere/fp8" "Cohere")
                   '(:status 0)))))))

(ert-deftest harness-openrouter-health-nonzero-is-not-price-uncertainty ()
  (dolist (status '(-2 -5 1))
    (let* ((reading (harness-openrouter-health-test--reading status))
           (policy (harness-openrouter-test-policy))
           (records (plist-get reading :endpoints)))
      (should (equal "Cohere" (plist-get (harness-openrouter-select policy records (float-time)) :provider)))
      ;; A health flag must not conceal an unreadable price.
      (setf (plist-get (car records) :prompt) nil)
      (should (eq 'price-unknown (plist-get (harness-openrouter-select policy records (float-time)) :reason))))))

(ert-deftest harness-openrouter-health-malformed-status-fails-closed ()
  (let* ((r (harness-openrouter-health-test--reading "unknown"))
         (d (harness-openrouter-select (harness-openrouter-test-policy)
                                       (plist-get r :endpoints) (plist-get r :at))))
    (should (eq 'health-unknown (plist-get d :reason)))))

(ert-deftest harness-openrouter-health-preference-is-within-policy ()
  (let* ((r (harness-openrouter-health-test--reading 0))
         (p (harness-openrouter-test-policy :prefer '("Cohere" "DeepInfra"))))
    (should (equal "Cohere" (plist-get (harness-openrouter-select p (plist-get r :endpoints) (float-time)) :provider)))
    (setf (plist-get p :prefer) '("Unknown"))
    (should (harness-openrouter-routing-validate p))))

(defun harness-openrouter-health-test--session (state &optional expires)
  "Session with proven STATE, full history and an expired cache by default."
  (let* ((model (concat "openrouter:" harness-openrouter-test-model))
         (session (harness-openrouter-test--session
                   "health-session"
                   (list :openrouter-route (harness-openrouter-test--route)
                         :openrouter-send (list :state state :at (- (float-time) 1000)
                                                :slug "deepinfra/fp8" :model model)))))
    (plist-put session :cache (list :expires (or expires (- (float-time) 100))
                                    :ttl 300 :model model))))

(ert-deftest harness-openrouter-health-uncertainty-warm-partial-and-inflight-refused ()
  (let* ((policy (harness-openrouter-test-policy :cold-failover '(:enabled t :max-input-cost "1")))
         (s (harness-openrouter-health-test--session "sent"))
         (req (harness-openrouter-test--request s)))
    (should (harness-openrouter--reselection-evidence policy req s))
    (dolist (key '(:partial :inflight))
      (let ((copy (copy-tree s)))
        (setf (plist-get (plist-get (plist-get copy :ext) :openrouter-send) key) t)
        (should-not (harness-openrouter--reselection-evidence policy req copy))))
    (should-not (harness-openrouter--reselection-evidence policy req
                   (harness-openrouter-health-test--session "sent" (+ (float-time) 30))))
    (should-not (harness-openrouter--reselection-evidence policy req
                   (harness-openrouter-test--session "legacy")))
    (should-not (harness-openrouter--reselection-evidence (harness-openrouter-test-policy) req s))
    (should-not (harness-openrouter--reselection-evidence policy (plist-put (copy-sequence req) :ephemeral t) s))))

(ert-deftest harness-openrouter-health-cold-cache-must-match-model-and-route ()
  (let* ((s (harness-openrouter-health-test--session "sent"))
         (e (harness-openrouter--send-evidence s)))
    (should (harness-openrouter--cold-evidence s e))
    (dolist (key '(:model :slug))
      (should-not (harness-openrouter--cold-evidence s (plist-put (copy-sequence e) key "different"))))))

(ert-deftest harness-openrouter-health-unused-pin-is-not-a-send ()
  (let* ((s (harness-openrouter-health-test--session "unsent"))
         (p (harness-openrouter-test-policy))
         (r (harness-openrouter-test--request s)))
    (should (equal "unsent" (plist-get (harness-openrouter--reselection-evidence p r s) :kind)))
    (setf (plist-get (plist-get s :ext) :openrouter-send) nil)
    (should-not (harness-openrouter--reselection-evidence p r s))))

(ert-deftest harness-openrouter-health-cold-budget-rejects-and-preserves-body ()
  (let* ((p (harness-openrouter-test-policy :cold-failover '(:enabled t :max-input-cost "1")))
         (route (harness-openrouter-test--route))
         (req (harness-openrouter-test--request))
         (before (copy-tree req)))
    (should (harness-openrouter--cold-cost p route req))
    (setf (plist-get p :cold-failover) '(:enabled t :max-input-cost "0"))
    (should-not (harness-openrouter--cold-cost p route req))
    (should (equal req before))))

(ert-deftest harness-openrouter-health-cold-transition-is-audited-and-keeps-request ()
  (let* ((p (harness-openrouter-test-policy :cold-failover '(:enabled t :max-input-cost "1")))
         (s (harness-openrouter-health-test--session "sent"))
         (req (harness-openrouter-test--request s))
         (before (copy-tree req))
         (reading (harness-openrouter-health-test--reading))
         (sent nil))
    (harness-openrouter-test-with-policy p
      (harness-openrouter-test-with-session s
        (cl-letf (((symbol-function 'harness-openrouter--start-pinned)
                   (lambda (_state snapshot request _event)
                     (setq sent (list snapshot request)))))
          (should (harness-openrouter--health-reselect
                   (list nil nil nil) p (harness-openrouter--route-of s) req #'ignore reading))
          (should (equal req before))
          (should (eq req (cadr sent)))
          (should (equal "Cohere" (plist-get harness-openrouter-test--stored :provider)))
          (should (equal "deepinfra/fp8" (plist-get (plist-get harness-openrouter-test--stored :transition) :from)))
          (should (equal "estimated-expiry" (plist-get (plist-get (plist-get harness-openrouter-test--stored :transition) :cache) :kind))))))))

(ert-deftest harness-openrouter-health-cancelled-transition-does-not-store ()
  (let* ((p (harness-openrouter-test-policy))
         (s (harness-openrouter-health-test--session "unsent"))
         (req (harness-openrouter-test--request s)))
    (harness-openrouter-test-with-policy p
      (harness-openrouter-test-with-session s
        (harness-openrouter--health-reselect (list t nil nil) p (harness-openrouter--route-of s)
                                             req #'ignore (harness-openrouter-health-test--reading))
        (should-not harness-openrouter-test--stored)))))

(defun harness-openrouter-health-test--sent-completions ()
  (cl-remove-if-not (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                    harness-openrouter-test--requests))

(ert-deftest harness-openrouter-health-real-cold-dispatch-keeps-tools-and-guard ()
  (harness-test-with-temp-state
    (let* ((p (harness-openrouter-test-policy :cold-failover '(:enabled t :max-input-cost "1")))
           (s (harness-openrouter-health-test--session "sent"))
           (req (harness-openrouter-test--request s))
           (reading (harness-openrouter-health-test--reading))
           (old (harness-openrouter--route-of s)))
      (setq req (plist-put req :system "Stable Unicode λ system"))
      (setq req (plist-put req :messages
                          '((:role user :content ((:type "text" :text "inspect")))
                            (:role assistant :content ((:type "tool_use" :id "call_1" :name "scene.read" :input (:path "a"))))
                            (:role tool :content ((:type "tool_result" :tool_use_id "call_1" :content "first result")))
                            (:role assistant :content ((:type "tool_use" :id "call_2" :name "scene.read" :input (:path "b"))))
                            (:role tool :content ((:type "tool_result" :tool_use_id "call_2" :content "second result"))))))
      (harness-openrouter-test-with-policy p
        (harness-openrouter-test-with-session s
          (puthash harness-openrouter-test-model reading harness-openrouter--catalogue)
          (let* ((endpoint (harness-openrouter--endpoint))
                 (body (harness-openrouter-test--routed-body p old req))
                 (route (harness-replay-route req endpoint)))
            (harness-replay-seam-keep req (plist-get req :model) route body)
            (harness-openrouter-test-with-fake
                (list (harness-openrouter-test--answer-from "Cohere"))
              (let ((events (harness-openrouter-test--run req)))
                (should-not (plist-get (car (last events)) :error))
                (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
                (should (= 1 (length (harness-openrouter-health-test--sent-completions))))
                (let* ((wire (plist-get (car (harness-openrouter-health-test--sent-completions)) :json)))
                  (should (equal (plist-get wire :messages) (plist-get body :messages))))))
            ;; This genuine subsequent edit must still be rejected.
            (let* ((changed (plist-put (copy-sequence req) :system "different system"))
                   (new (harness-openrouter-test--routed-body p harness-openrouter-test--stored changed)))
              (should (cdr (harness-replay-seam changed (plist-get req :model) route new))))))))))

(ert-deftest harness-openrouter-health-tracking-persists-before-transport-and-cancel ()
  (let* ((s (harness-openrouter-health-test--session "unsent"))
         (req (plist-put (harness-openrouter-test--request s) :openrouter-route (harness-openrouter--route-of s)))
         (called nil) handle callback)
    (harness-openrouter-test-with-session s
      (cl-letf (((symbol-function 'harness-openai--complete)
                 (lambda (_endpoint request)
                   (setq called t callback (plist-get request :on-event))
                   (funcall (plist-get request :before-dispatch))
                   (should (plist-get (harness-openrouter--send-evidence harness-openrouter-test--session-value) :inflight))
                   (list :cancel #'ignore))))
        (setq handle (harness-openrouter--tracked-complete req))
        (should called)
        (funcall callback '(:type text :delta "partial"))
        (funcall (plist-get handle :cancel))
        (let ((e (harness-openrouter--send-evidence harness-openrouter-test--session-value)))
          (should-not (plist-get e :inflight))
          (should (plist-get e :partial)))))))


(ert-deftest harness-openrouter-health-local-replay-refusal-keeps-unused-pin-unsent ()
  (harness-test-with-temp-state
    (let* ((p (harness-openrouter-test-policy))
           (s (harness-openrouter-health-test--session "unsent"))
           (req (plist-put (harness-openrouter-test--request s) :system "original"))
           (old (harness-openrouter--route-of s)))
      (harness-openrouter-test-with-policy p
        (harness-openrouter-test-with-session s
          (puthash harness-openrouter-test-model (harness-openrouter-health-test--reading 0)
                   harness-openrouter--catalogue)
          (harness-replay-seam-keep req (plist-get req :model)
                                   (harness-replay-route req (harness-openrouter--endpoint))
                                   (harness-openrouter-test--routed-body p old req))
          (harness-openrouter-test-with-fake (list (harness-openrouter-test--completion-response))
            (let ((events (harness-openrouter-test--run (plist-put (copy-sequence req) :system "mutated"))))
              (should (eq 'error (plist-get (car (last events)) :stop-reason)))
              (should-not (harness-openrouter-health-test--sent-completions))
              (should (equal "unsent" (plist-get (harness-openrouter--send-evidence harness-openrouter-test--session-value) :state))))))))))

(ert-deftest harness-openrouter-health-durable-evidence-failure-sends-nothing ()
  (let* ((p (harness-openrouter-test-policy))
         (s (harness-openrouter-health-test--session "unsent"))
         (req (harness-openrouter-test--request s)))
    (harness-openrouter-test-with-policy p
      (harness-openrouter-test-with-session s
        (puthash harness-openrouter-test-model (harness-openrouter-health-test--reading 0)
                 harness-openrouter--catalogue)
        (harness-openrouter-test-with-fake (list (harness-openrouter-test--completion-response))
          (let ((real-call (symbol-function 'harness-call)))
            (cl-letf (((symbol-function 'harness-call)
                       (lambda (method &rest args)
                         (if (and (eq method 'session/set-ext)
                                  (eq (nth 1 args) harness-openrouter--send-key)
                                  (nth 4 args))
                             (error "durable evidence unavailable")
                           (apply real-call method args)))))
              (let ((events (harness-openrouter-test--run req)))
                (should (eq 'error (plist-get (car (last events)) :stop-reason)))
                (should-not (harness-openrouter-health-test--sent-completions))))))))))

(ert-deftest harness-openrouter-health-terminal-time-bounds-cold-cache ()
  (let* ((s (harness-openrouter-health-test--session "unsent"))
         (req (plist-put (harness-openrouter-test--request s) :openrouter-route (harness-openrouter--route-of s)))
         (now 1000) callback)
    (harness-openrouter-test-with-session s
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
                ((symbol-function 'harness-openrouter--owner) (lambda () '(:pid 1)))
                ((symbol-function 'harness-openai--complete)
                 (lambda (_endpoint request)
                   (setq callback (plist-get request :on-event))
                   (funcall (plist-get request :before-dispatch))
                   (list :cancel #'ignore))))
        (harness-openrouter--tracked-complete req)
        (setq now 2000)
        (funcall callback '(:type done :stop-reason error))
        (let ((e (harness-openrouter--send-evidence harness-openrouter-test--session-value)))
          (should (= 2000 (plist-get e :at)))
          (should (= 1000 (plist-get e :sent-at)))
          (setf (plist-get harness-openrouter-test--session-value :cache)
                (list :model (plist-get req :model) :expires 1500 :ttl 300))
          (should-not (harness-openrouter--cold-evidence harness-openrouter-test--session-value e))
          (setq now 2301)
          (should (harness-openrouter--cold-evidence harness-openrouter-test--session-value e)))))))

(ert-deftest harness-openrouter-health-admission-hooks-cannot-change-policy ()
  (let* ((p (harness-openrouter-test-policy))
         (s (harness-openrouter-health-test--session "unsent"))
         (req (harness-openrouter-test--request s)))
    (harness-openrouter-test-with-policy p
      (harness-openrouter-test-with-session s
        (puthash harness-openrouter-test-model (harness-openrouter-health-test--reading 0)
                 harness-openrouter--catalogue)
        (harness-openrouter-test-with-fake (list (harness-openrouter-test--completion-response))
          (let ((real-call (symbol-function 'harness-call)))
            (cl-letf (((symbol-function 'harness-call)
                       (lambda (method &rest args)
                         (prog1 (apply real-call method args)
                           (when (and (eq method 'session/set-ext)
                                      (eq (nth 1 args) harness-openrouter--send-key)
                                      (plist-get (nth 2 args) :inflight))
                             (setq harness-openrouter-routing nil))))))
              (let ((events (harness-openrouter-test--run req)))
                (should (eq 'error (plist-get (car (last events)) :stop-reason)))
                (should-not (harness-openrouter-health-test--sent-completions))
                (should (equal "sent" (plist-get (harness-openrouter--send-evidence harness-openrouter-test--session-value) :state))))))))))
)

(ert-deftest harness-openrouter-health-orphaned-marker-recovers-instead-of-wedging ()
  "A marker whose owning process exited must not refuse every later send.
The manual `session/recover-openrouter-send' was the only way to clear
one, so a crash while a send was in flight wedged its session for good:
every retry was refused `routing-inflight' and no retry could undo it."
  (let* ((s (harness-openrouter-health-test--session "sent"))
         (e (plist-get (plist-get s :ext) :openrouter-send))
         (dead nil))
    (setf (plist-get e :inflight) "orphan-token"
          (plist-get e :owner) '(:host "test" :uid 1000 :pid 999 :start 10)
          (plist-get (plist-get s :ext) :openrouter-send) e)
    (harness-openrouter-test-with-session s
      (cl-letf (((symbol-function 'harness-openrouter--owner-dead-p) (lambda (_) dead)))
        ;; While the owner may still be alive the marker stands: the recovery
        ;; hands back exactly the evidence it was given.
        (should (eq e (harness-openrouter--recover-orphan s e)))
        (should (equal "orphan-token" (plist-get e :inflight)))
        (setq dead t)
        (let ((recovered (harness-openrouter--recover-orphan s e)))
          (should-not (plist-get recovered :inflight))
          (should (plist-get recovered :partial))
          (should (equal "sent" (plist-get recovered :state)))
          (should (= 1 (length (plist-get recovered :recoveries))))
          (should (equal "orphan-token" (plist-get (car (plist-get recovered :recoveries)) :token)))
          (should (equal "owner-exited" (plist-get (car (plist-get recovered :recoveries)) :reason))))))))

(ert-deftest harness-openrouter-health-dead-owner-recovery-is-explicit-and-conservative ()
  (let* ((s (harness-openrouter-health-test--session "sent"))
         (req (harness-openrouter-test--request s))
         (e (plist-get (plist-get s :ext) :openrouter-send))
         (owner '(:host "test" :uid 1000 :pid 999 :start 10))
         (dead nil))
    (setf (plist-get s :status) 'idle
          (plist-get e :inflight) "old-token"
          (plist-get e :owner) owner
          (plist-get (plist-get s :ext) :openrouter-send) e)
    (harness-openrouter-test-with-session s
      (let ((real-call (symbol-function 'harness-call))
            (real-exists (symbol-function 'harness-method-exists-p)))
        (cl-letf (((symbol-function 'harness-method-exists-p)
                   (lambda (method) (or (eq method 'agent/running) (funcall real-exists method))))
                  ((symbol-function 'harness-call)
                   (lambda (method &rest args)
                     (unless (eq method 'agent/running) (apply real-call method args))))
                  ((symbol-function 'harness-openrouter--owner-dead-p) (lambda (_) dead)))
          (should (equal "old-token" (plist-get (harness-openrouter--send-evidence (harness-call 'session/get "health-session")) :inflight)))
          (should-error (harness-method/session/recover-openrouter-send "health-session" "old-token"))
          (setq dead t)
          (should-error (harness-method/session/recover-openrouter-send "health-session" "wrong-token"))
          (should (plist-get (harness-method/session/recover-openrouter-send "health-session" "old-token") :recovered))
          (let ((recovered (harness-openrouter--send-evidence harness-openrouter-test--session-value)))
            (should-not (plist-get recovered :inflight))
            (should (plist-get recovered :partial))
            (should (equal "sent" (plist-get recovered :state)))
            (should (= 1 (length (plist-get recovered :recoveries))))
            (should-not (harness-openrouter--reselection-evidence
                         (harness-openrouter-test-policy :cold-failover '(:enabled t :max-input-cost "1"))
                         req harness-openrouter-test--session-value)))
          ;; The old transcript and pin are unchanged; a deliberate same-pin send works.
          (setf (plist-get req :openrouter-route) (harness-openrouter--route-of s))
          (let ((posted nil))
            (cl-letf (((symbol-function 'harness-openai--complete)
                       (lambda (_ request)
                         (funcall (plist-get request :before-dispatch))
                         (setq posted t)
                         (list :cancel #'ignore))))
              (harness-openrouter--tracked-complete req)
              (should posted))))))))


(ert-deftest harness-openrouter-health-partial-preference-keeps-provider-order ()
  (let* ((reading (harness-openrouter-health-test--reading))
         (records (plist-get reading :endpoints))
         (third (copy-tree (cadr records)))
         (p (harness-openrouter-test-policy :providers '("DeepInfra" "Cohere" "Third") :prefer '("DeepInfra"))))
    (setf (plist-get third :provider) "Third"
          (plist-get third :tag) "third/fp8"
          (plist-get third :prompt) '(1 . 1000000000000))
    (should (equal "Cohere" (plist-get (harness-openrouter-select p (append records (list third)) (float-time)) :provider)))))

(ert-deftest harness-openrouter-health-owner-proof-fails-closed ()
  (let ((owner (list :host (system-name) :uid (user-uid) :pid 123 :start 10))
        (attrs '((start . 10))) (exists t)
        (native-comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'process-attributes) (lambda (_) attrs))
              ((symbol-function 'file-directory-p) (lambda (path) (or (equal path "/proc/self") exists))))
      (should-not (harness-openrouter--owner-dead-p owner))
      (setq attrs '((start . 11)))
      (should (harness-openrouter--owner-dead-p owner))
      (setq attrs nil)
      (should-not (harness-openrouter--owner-dead-p owner))
      (setq exists nil)
      (should (harness-openrouter--owner-dead-p owner))
      (should-not (harness-openrouter--owner-dead-p (plist-put (copy-sequence owner) :host "another-host")))
      (should-not (harness-openrouter--owner-dead-p (plist-put (copy-sequence owner) :start nil))))))


(ert-deftest harness-openrouter-health-recovery-survives-disk-roundtrip ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider tools session agent)) (harness-test-load-module m))
    (harness-test-load-module 'provider-openrouter)
    (let* ((s (harness-call 'session/create :cwd dir))
           (id (plist-get s :id))
           (stamp (list :state "sent" :inflight "persisted-token" :at 100
                        :model (concat "openrouter:" harness-openrouter-test-model)
                        :slug "deepinfra/fp8" :owner '(:pid 999 :host "test" :uid 1000 :start 10))))
      (harness-call 'session/set-ext id :openrouter-route (harness-openrouter-test--route) nil t)
      (harness-call 'session/set-ext id :openrouter-send stamp nil t)
      (let ((loaded (harness-call 'store/load (format "sessions/%s.json" id))))
        (should (equal "persisted-token" (plist-get (plist-get (plist-get loaded :ext) :openrouter-send) :inflight)))
        ;; Replace the in-memory session with the actual persisted representation.
        (puthash id (harness-session--from-plist loaded) harness-sessions))
      (cl-letf (((symbol-function 'harness-openrouter--owner-dead-p) (lambda (_) t)))
        (should (plist-get (harness-call 'session/recover-openrouter-send id "persisted-token") :recovered)))
      (let* ((disk (harness-call 'store/load (format "sessions/%s.json" id)))
             (e (plist-get (plist-get disk :ext) :openrouter-send)))
        (should-not (plist-get e :inflight))
        (should (eq t (plist-get e :partial)))
        (should (equal "sent" (plist-get e :state)))
        (should (equal "deepinfra/fp8" (plist-get (plist-get (plist-get disk :ext) :openrouter-route) :slug))))
      ;; Crash during the next deliberate same-pin attempt must not erase
      ;; the prior recovery audit before a terminal callback can restore it.
      (let* ((current (harness-call 'session/get id))
             (req (plist-put (harness-openrouter-test--request current)
                             :openrouter-route (harness-openrouter--route-of current))))
        (cl-letf (((symbol-function 'harness-openai--complete)
                   (lambda (_ request)
                     (funcall (plist-get request :before-dispatch))
                     (list :cancel #'ignore))))
          (harness-openrouter--tracked-complete req))
        (let* ((disk (harness-call 'store/load (format "sessions/%s.json" id)))
               (e (plist-get (plist-get disk :ext) :openrouter-send)))
          (should (plist-get e :inflight))
          (should (equal "persisted-token" (plist-get (car (plist-get e :recoveries)) :token)))
          (puthash id (harness-session--from-plist disk) harness-sessions)
          (should (equal (plist-get e :recoveries)
                         (plist-get (harness-openrouter--send-evidence (harness-call 'session/get id)) :recoveries))))))))

(provide 'harness-provider-openrouter-health-test)
