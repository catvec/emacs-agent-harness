;;; harness-fuzz-acp.el --- Valid ACP conversations for AFL++ -*- lexical-binding: t; -*-

;;; Commentary:
;; AFL mutates compact action bytes, not JSON syntax.  Every pair selects a
;; standard ACP method and valid arguments referencing this run's sessions.
;; Real wire codecs, dispatch, agent, tools and store run in an isolated
;; adapter.  Only the model and the order of deferred callbacks are fixtures.
;; Test helpers are loaded only inside the check, never into a live harness.

;;; Code:
(require 'cl-lib)
(defvar harness-fuzz-directory)
(declare-function harness-fuzz-define-target "harness-fuzz" (name &rest arguments))

(defconst harness-fuzz-acp-methods
  ["session/new" "session/load" "session/list" "session/prompt" "session/cancel"
   "session/set_mode" "session/set_model" "initialize" "authenticate"]
  "Standard ACP methods understood by the bounded action grammar.")

(defun harness-fuzz-acp-actions (bytes)
  "Decode at most 32 method/argument pairs from arbitrary BYTES.
An odd final byte has argument zero.  Session slots resolve at execution,
so mutations never turn a live session identifier into random garbage."
  (cl-loop for offset from 0 below (min 64 (length bytes)) by 2
           collect (list (aref harness-fuzz-acp-methods
                               (mod (aref bytes offset) (length harness-fuzz-acp-methods)))
                         (if (< (1+ offset) (length bytes)) (aref bytes (1+ offset)) 0))))

(defun harness-fuzz-acp--check (bytes)
  "Run BYTES as valid ACP actions and require consistency and recovery."
  (when (bound-and-true-p harness-started)
    (error "Stateful ACP fuzzing requires an isolated adapter"))
  (require 'harness-test-helpers
           (expand-file-name "../../../test/harness-test-helpers.el" harness-fuzz-directory))
  (let ((actions (harness-fuzz-acp-actions bytes)))
    (condition-case err
        (harness-fuzz-acp--scenario actions)
      (error (error "ACP actions %S: %s" actions (error-message-string err))))))

(defun harness-fuzz-acp--scenario (actions)
  "Exercise ACTIONS through the real server and temporary persisted sessions."
  (let* ((dir (file-name-as-directory (make-temp-file "harness-fuzz-acp-" t)))
         (harness-state-directory dir))
    (unwind-protect
        (harness-fuzz-acp--in-state actions dir)
      (ignore-errors (delete-directory dir t)))))

(defun harness-fuzz-acp--in-state (actions dir)
  "Exercise ACTIONS in the isolated state directory DIR."
  (harness-test-reset-bus)
  (let ((harness-acp--server-enabled nil))
    (dolist (module '(store project config provider tools session agent acp))
      (harness-test-load-module module)))
  (clrhash harness-sessions)
  (clrhash harness-tools)
  (clrhash harness-agent--turns)
  (clrhash harness-acp--virtual-state)
  (let* ((default-directory dir) (harness-acp-token "fixture-token")
         (harness-acp-session-list-page-size 100)
         (harness-acp--clients nil)
         (responses (make-hash-table :test 'eql))
         (effects (make-hash-table :test 'equal))
         (plans (make-hash-table :test 'equal))
         (starts 0) (ends 0) (next-id 0) (prompt-index 0)
         jobs producers sessions requests violations client)
    (cl-labels
        ((pump ()
           (let ((budget 512))
             (while jobs
               (when (zerop (cl-decf budget)) (error "Deferred callbacks did not quiesce"))
               (funcall (pop jobs)))))
         (advance (argument)
           (when producers
             (let* ((index (mod argument (length producers)))
                    (fn (nth index producers)))
               (setq producers (append (take index producers) (nthcdr (1+ index) producers)))
               (funcall fn)))
           (pump))
         (drain ()
           (let ((budget 128))
             (pump)
             (while producers
               (when (zerop (cl-decf budget)) (error "Provider loop exceeded its scenario budget"))
               (advance 0))))
         (send (method params &optional notification)
           (let* ((id (unless notification (cl-incf next-id)))
                  (message (append (list :jsonrpc "2.0" :method method :params params)
                                   (when id (list :id id)))))
             (when id (push (cons id method) requests))
             ;; Exercise actual wire encoding and parsing in both directions.
             (harness-acp--server-receive client (harness-acp--parse (harness-json-encode message)))
             (pump)
             id))
         (answer (id)
           (let ((message (gethash id responses)))
             (unless message (error "Missing RPC response for %S" (assq id requests)))
             (when (plist-member message :error)
               (error "Valid ACP command %S failed: %S" (assq id requests) (plist-get message :error)))
             (plist-get message :result)))
         (call (method params) (answer (send method params)))
         (new-session ()
           (let ((sid (plist-get (call "session/new"
                                       (list :cwd dir :mcpServers [] :_harness '(:model "acpfuzz:a"))) :sessionId)))
             (unless (stringp sid) (error "New session has no ID"))
             (setq sessions (append sessions (list sid)))
             sid))
         (prompt (sid argument)
           (send "session/prompt"
                 (list :sessionId sid
                       :prompt (list (list :type "text"
                                           :text (format "fuzz-%d-plan-%d" (cl-incf prompt-index)
                                                         (mod argument 3)))))))
         (check ()
           (when violations (error "RPC delivery violations: %S" violations))
           (unless (memq client harness-acp--clients) (error "ACP client was dropped"))
           (when (> ends starts) (error "More terminal events than turns"))
           (maphash (lambda (key count) (when (> count 1) (error "Repeated tool effect: %s" key))) effects)))
      (harness-add-filter 'permission/decide
                          (lambda (_value next &rest _) (funcall next '(:behavior allow))))
      (harness-on 'agent/turn-started (lambda (&rest _) (cl-incf starts)))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ends)))
      (harness-define-tool "fuzz_count" :label "Count" :kind 'read :description "Pure fixture"
                           :handler (lambda (input _context)
                                      (let ((key (plist-get input :token)))
                                        (puthash key (1+ (gethash key effects 0)) effects))
                                      "counted"))
      (harness-define-provider 'acpfuzz
			       :models (lambda () (harness-resolved '((:name "a") (:name "b"))))
			       :complete
			       (lambda (request)
				 (dolist (message (plist-get request :messages))
				   (dolist (block (plist-get message :content))
				     (when (equal "tool_use" (plist-get block :type))
				       (unless (and (stringp (plist-get block :id))
						    (stringp (plist-get block :name))
						    (string-prefix-p "{" (harness-json-encode (plist-get block :input))))
					 (error "Provider history is not replayable")))))
				 (let* ((emit (plist-get request :on-event))
					(message (cl-find 'user (plist-get request :messages)
							  :key (lambda (item) (plist-get item :role)) :from-end t))
					(text (mapconcat (lambda (block) (or (plist-get block :text) ""))
							 (plist-get message :content) ""))
					(first (not (gethash text plans))))
				   (puthash text t plans)
				   (setq producers
					 (append producers
						 (list
						  (lambda ()
						    (cond
						     ((and first (string-suffix-p "plan-1" text))
						      (let ((call (list :type 'tool-call :id text :name "fuzz_count"
									:input (list :token text))))
							(funcall emit call)
							(funcall emit call)
							(funcall emit '(:type done :stop-reason tool-use))))
						     ((and first (string-suffix-p "plan-2" text))
						      (funcall emit '(:type done :stop-reason error :error "Fixture failure")))
						     (t (funcall emit '(:type text :delta "answer"))
							(funcall emit '(:type done :stop-reason end-turn))))))))
				   (list :cancel (lambda () (funcall emit '(:type done :stop-reason cancelled)))))))
      (setq client
            (harness-acp--make-client
             :kind 'fuzz
             :writer (lambda (_client bytes)
                       (let ((message (harness-acp--parse bytes)))
                         (when (plist-member message :id)
                           (let ((id (plist-get message :id)))
                             (when (or (gethash id responses) (not (assq id requests)))
                               (push (list 'duplicate-or-unknown-response id) violations))
                             (puthash id message responses)))))))
      (push client harness-acp--clients)
      (unwind-protect
          (cl-letf (((symbol-function 'harness-run-soon)
                     (lambda (fn &rest arguments)
                       (setq jobs (append jobs (list (lambda () (apply fn arguments))))) nil)))
            (call "initialize" '(:protocolVersion 1))
            (call "authenticate" '(:methodId "token" :token "fixture-token"))
            (new-session)
            (pcase-dolist (`(,method ,argument) actions)
              (let ((sid (nth (mod argument (length sessions)) sessions)))
                (pcase method
                  ("session/new" (if (< (length sessions) 4) (new-session)
                                   (call "session/list" (list :cwd dir))))
                  ("session/list"
                   (let ((listed (mapcar (lambda (s) (plist-get s :sessionId))
                                         (plist-get (call method (list :cwd dir)) :sessions))))
                     (dolist (known sessions)
                       (unless (member known listed) (error "Session missing from ACP list: %s" known)))))
                  ("session/load" (call method (list :sessionId sid :cwd dir :mcpServers [])))
                  ("session/prompt" (prompt sid argument))
                  ("session/cancel" (send method (list :sessionId sid) t))
                  ("session/set_mode"
                   (let ((mode (aref ["ask" "accept-edits" "auto" "yolo"] (mod argument 4))))
                     (call method (list :sessionId sid :modeId mode))
                     (unless (equal mode (symbol-name (plist-get (harness-call 'session/get sid) :permission-mode)))
                       (error "Mode update did not take effect"))))
                  ("session/set_model"
                   (let ((model (if (cl-evenp argument) "acpfuzz:a" "acpfuzz:b")))
                     (call method (list :sessionId sid :modelId model))
                     (unless (equal model (plist-get (harness-call 'session/get sid) :model))
                       (error "Model update did not take effect"))))
                  ("initialize" (call method '(:protocolVersion 1)))
                  ("authenticate" (call method '(:methodId "token" :token "fixture-token"))))
                (when (>= argument 128) (advance argument))
                (check)))
            (drain)
            (dolist (sid sessions) (send "session/cancel" (list :sessionId sid) t))
            (drain)
            (dolist (request requests) (answer (car request)))
            (when (harness-call 'agent/running) (error "Active turn after scenario cleanup"))
            (dolist (sid sessions)
              (when (or (plist-get (harness-call 'session/get sid) :pending)
                        (plist-get (harness-call 'agent/activity sid) :calls))
                (error "Session retains pending interactions after completion")))
            (unless (= starts ends) (error "Unbalanced turn lifecycle: %d starts, %d ends" starts ends))
            (harness-session-flush)
            (clrhash harness-sessions)
            (harness-session--load-all)
            (when (harness-call 'session/hydration-faults) (error "Cold reload failed"))
            (dolist (sid sessions)
              (call "session/load" (list :sessionId sid :cwd dir :mcpServers []))
              (let ((id (prompt sid 0)))
                (drain)
                (unless (equal "end_turn" (plist-get (answer id) :stopReason))
                  (error "Session unusable after reload"))))
            (check)
            (unless (= starts ends) (error "Recovery left an unfinished turn"))
            (list :methods (delete-dups (mapcar #'cdr requests))
                  :sessions (length sessions) :starts starts :ends ends
                  :plans (hash-table-keys plans)
                  :rpcs (length requests) :responses (hash-table-count responses)
                  :effects (apply #'+ (hash-table-values effects))))
        (harness-acp--drop-client client)
        (harness-test-reset-bus)))))

(harness-fuzz-define-target
 'acp-conversation
 :description "Valid standard ACP command sequences with real dispatch, turns and cold recovery."
 :timeout 20
 :seeds (list "" (unibyte-string 3 1) (unibyte-string 3 1 4 0 3 0)
              (unibyte-string 0 0 3 129 5 1 6 0 1 1 2 0)
              (apply #'unibyte-string (cl-loop for opcode below 9 append (list opcode (+ 128 opcode)))))
 :check #'harness-fuzz-acp--check)

(provide 'harness-fuzz-acp)
;;; harness-fuzz-acp.el ends here
