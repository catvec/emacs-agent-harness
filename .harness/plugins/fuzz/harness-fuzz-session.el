;;; harness-fuzz-session.el --- Ordinary session and cache-break soak -*- lexical-binding: t; -*-

;; Each input is a sequence of ordinary turns.  The real agent, tool dispatcher,
;; OpenAI serializer/SSE decoder and frozen replay store run.  Only transport
;; and tool implementation hooks are inert; no network or user state is used.
(require 'cl-lib)
(defvar harness-fuzz-directory)
(declare-function harness-fuzz-define-target "harness-fuzz" (name &rest arguments))

(defconst harness-fuzz-session-actions
  [prompt tools schema description effort thinking system model reload reset-schema history dialect]
  "Between-turn actions; every action is followed by a successful real turn.")

(defun harness-fuzz-session-decode (bytes &optional ordinary-only)
  "Decode BYTES into at most 24 pairs; ORDINARY-ONLY selects text/tools only."
  (let ((catalog (if ordinary-only [prompt tools] harness-fuzz-session-actions)))
    (cl-loop for i from 0 below (min 48 (length bytes)) by 2
           collect (list (aref catalog (mod (aref bytes i) (length catalog)))
                         (if (< (1+ i) (length bytes)) (aref bytes (1+ i)) 0)))))

(defun harness-fuzz-session--input (schema argument &optional depth)
  "Build inert input for SCHEMA, bounded by DEPTH, varying ARGUMENT."
  (let ((depth (or depth 0)))
    (if (> depth 4) nil
      (or (car (append (plist-get schema :enum) nil))
          (pcase (plist-get schema :type)
            ("object"
             (let ((properties (plist-get schema :properties)) out)
               (when (listp properties)
                 (cl-loop for (key value) on properties by #'cddr
                          do (setq out (append out (list key (harness-fuzz-session--input
                                                             value argument (1+ depth)))))))
               (or out :empty)))
            ("array" (vector (harness-fuzz-session--input (plist-get schema :items) argument (1+ depth))))
            ((or "integer" "number") argument)
            ("boolean" (if (cl-evenp argument) t :false))
            (_ (format "fixture-%d" argument)))))))

(defun harness-fuzz-session--null-tool (tool handler &optional schema description)
  "Replace TOOL's implementation hooks with HANDLER, preserving its public spec."
  (harness-define-tool (harness-tool-name tool)
                       :label (harness-tool-label tool)
                       :description (or description (harness-tool-description tool))
                       :schema (or schema (harness-tool-schema tool))
                       :kind (harness-tool-kind tool)
                       :handler (lambda (input context)
                                  (funcall handler (harness-tool-name tool) input context))))

(defun harness-fuzz-session--check (bytes &optional ordinary-only)
  "Run ordinary turns selected by BYTES; any error or inability to continue fails."
  (when (bound-and-true-p harness-started)
    (error "Session soak requires an isolated adapter"))
  (require 'harness-test-helpers
           (expand-file-name "../../../test/harness-test-helpers.el" harness-fuzz-directory))
  (let ((actions (harness-fuzz-session-decode bytes ordinary-only))
        (dir (file-name-as-directory (make-temp-file "harness-session-soak-" t))))
    (unwind-protect
        (condition-case err
            (let ((harness-state-directory dir))
              (harness-fuzz-session--run actions dir))
          (error (error "Session actions %S: %s" actions (error-message-string err))))
      (harness-test-reset-bus)
      (ignore-errors (delete-directory dir t)))))

(defun harness-fuzz-session--run (actions dir)
  "Run ACTIONS through a real persisted session under DIR."
  (harness-test-reset-bus)
  (dolist (module '(store project config provider tools session agent replay))
    (harness-test-load-module module))
  (require 'harness-provider-openai)
  (clrhash harness-sessions)
  (clrhash harness-tools)
  (clrhash harness-agent--turns)
  ;; Read declarations, without starting tool module services.  No real handler,
  ;; path resolver, computer selector or subject implementation is retained.
  (dolist (file (directory-files (expand-file-name "../../../lisp/modules" harness-fuzz-directory)
                                t "\\`harness-tools-.*\\.el\\'"))
    (unless (or (string-suffix-p "-test.el" file)
                (string-suffix-p "-gremlin.el" file))
      (load file nil t)))
  (let* ((default-directory dir)
         (auth-sources nil) (harness-corporate-mode nil)
         (harness-openai--models-cache (make-hash-table :test 'eq))
         (endpoint '(:id soak :base-url "https://fixture.invalid/v1" :api-key "fixture"
                     :dialect (:reasoning-object t)))
         (starts 0) (ends 0) (requests 0) (executions 0) (turns 0)
         (remaining 0) (batch 0) (argument 0) (serial 0) (reloads 0)
         (changed nil) system-revision tool-errors called efforts handler sid)
    (setq handler
          (lambda (name _input _context)
            (cl-incf executions)
            (push name called)
            (if (cl-evenp argument) "inert tool result"
              (let ((promise (harness-make-promise)))
                (harness-run-soon (lambda () (harness-resolve promise "inert deferred result")))
                promise))))
    (maphash (lambda (_ tool) (harness-fuzz-session--null-tool tool handler))
             (copy-hash-table harness-tools))
    (harness-add-filter 'permission/decide
                        (lambda (_ next &rest _) (funcall next '(:behavior allow))))
    (harness-on 'agent/turn-started (lambda (&rest _) (cl-incf starts)))
    (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ends)))
    (harness-on 'tools/finished
                (lambda (_sid call result)
                  (when (plist-get result :is-error)
                    (push (list (plist-get call :name) (plist-get result :content)) tool-errors))))
    (harness-define-provider 'soak
      :models (lambda () (harness-resolved '((:name "a" :context-window 1000000)
                                            (:name "b" :context-window 1000000))))
      :complete (lambda (request)
                  (when system-revision
                    (setq request (plist-put (copy-sequence request) :system system-revision)))
                  (harness-openai--complete endpoint request)))
    ;; A fixture task association exposes hand_in too.  Its handler is inert;
    ;; no task board, merge queue or process is started.
    (harness-register-method 'task/for-session (lambda (_sid) '(:id "fixture-task")))
    (setq sid (plist-get (harness-call 'session/create :cwd dir :model "soak:a" :thinking "max") :id))
    (cl-labels
        ((frame (value) (concat "data: " (harness-json-encode value) "\n\n"))
         (wire (_url &rest args)
           (cl-incf requests)
           ;; Decode the actual frozen wire body, rather than bypassing replay
           ;; with an accepting canonical-event fake.
           (let* ((body (harness-json-parse (decode-coding-string (plist-get args :body) 'utf-8)))
                  (tools (append (plist-get body :tools) nil))
                  (handle (make-harness-http-handle :url "fixture"))
                  (calls (when (> remaining 0)
                           (cl-decf remaining)
                           (cl-loop for i below batch
                                    for spec = (nth (mod (+ argument i) (length tools)) tools)
                                    for name = (plist-get (plist-get spec :function) :name)
                                    for schema = (plist-get (plist-get spec :function) :parameters)
                                    collect (list :index i :id (format "call-%d" (cl-incf serial))
                                                  :type "function"
                                                  :function (list :name name :arguments
                                                                  (harness-json-encode-text
                                                                   (harness-fuzz-session--input schema argument)))))))
                  (payload (concat
                            (frame (list :choices (vector (list :index 0 :delta
                                                               (if calls (list :tool_calls (vconcat calls))
                                                                 '(:content "ordinary answer café 界"))))))
                            (frame (list :choices (vector (list :index 0 :delta :empty
                                                               :finish_reason (if calls "tool_calls" "stop")))
                                         :usage '(:prompt_tokens 10 :completion_tokens 2)))
                            "data: [DONE]\n\n")))
             (push (or (plist-get body :reasoning_effort) (plist-get body :reasoning)) efforts)
             (unless tools (error "No tools offered by ordinary session"))
             (harness-run-soon
              (lambda ()
                (unless (harness-http-handle-cancelled handle)
                  (funcall (plist-get args :on-headers) 200 nil)
                  ;; Vary legal SSE chunk boundaries too, including UTF-8 text.
                  (let ((cut (mod argument (length payload))))
                    (funcall (plist-get args :on-chunk) (substring payload 0 cut))
                    (funcall (plist-get args :on-chunk) (substring payload cut)))
                  (funcall (plist-get args :callback) 200 nil "" nil))))
             handle))
         (turn (arg &optional plain)
           (setq argument arg batch (if plain 0 (1+ (mod arg 3)))
                 remaining (if plain 0 (1+ (mod (/ arg 3) 2))))
           (let* ((before executions) (expected (* batch remaining))
                  (result (harness-test-await
                           (harness-call 'agent/prompt sid (format "Ordinary prompt %d, café 界" (cl-incf turns))) 3)))
             (unless (eq 'end-turn (plist-get result :stop-reason))
               (error "Turn %d cannot continue: %S" turns result))
             (when tool-errors (error "Ordinary tool calls failed: %S" tool-errors))
             (unless (= expected (- executions before))
               (error "Tool dispatch did not reach inert handlers: expected %d got %d"
                      expected (- executions before)))
             (when (or (harness-agent-running-p sid)
                       (plist-get (harness-call 'session/get sid) :pending)
                       (plist-get (harness-call 'agent/activity sid) :calls))
               (error "Turn %d retained active state" turns))))
         (reload ()
           (harness-session-flush)
           (clrhash harness-sessions)
           (harness-session--load-all)
           (when (harness-call 'session/hydration-faults) (error "Session cannot reload"))
           (cl-incf reloads)))
      (cl-letf (((symbol-function 'harness-http-request) #'wire))
        (turn 0 t)
        (pcase-dolist (`(,action ,arg) actions)
          (pcase action
            ((or 'schema 'description)
             (let* ((names (sort (hash-table-keys harness-tools) #'string<))
                    (tool (harness-tool-get (nth (mod arg (length names)) names)))
                    (schema (copy-tree (harness-tool-schema tool))))
               (when (eq action 'schema)
                 (setq schema (plist-put schema :description (format "schema revision %d" arg))))
               (harness-fuzz-session--null-tool tool handler schema
                                               (when (eq action 'description) (format "tool revision %d" arg)))))
            ('effort
             ;; A delayed catalogue changes the effort mapping without a user
             ;; setting event, exactly as in the retained reasoning.effort incidents.
             (puthash 'soak (cons (float-time)
                                 (list (list :name "a" :thinking-levels (if (cl-evenp arg)
                                                                                         '("low" "max") '("low" "high")))
                                       (list :name "b" :thinking-levels '("low" "high"))))
                      harness-openai--models-cache))
            ('thinking (harness-call 'session/update sid :thinking (nth (mod arg 3) '("low" "high" "max"))))
            ('system
             ;; Simulate a renderer/reload changing a settled system, rather than
             ;; calling its once-only setter and accidentally doing no mutation.
             (setq system-revision (format "Fixture system revision %d" arg)))
            ('model (harness-call 'session/update sid :model (if (cl-evenp arg) "soak:a" "soak:b")))
            ('dialect
             (setq endpoint (plist-put (copy-tree endpoint) :dialect
                                       (when (cl-evenp arg) '(:reasoning-object t)))))
            ('reload (reload))
            ('reset-schema (harness-call 'session/set-tool-schema sid nil))
            ('history (harness-call 'session/hint sid (format "ordinary background hint %d" arg))))
          (unless (memq action '(prompt tools)) (push action changed))
          (turn arg (eq action 'prompt)))
        (reload)
        (turn 7)
        (turn 0 t))
      (unless (= starts ends turns) (error "Unbalanced turns: %d/%d/%d" starts ends turns))
      (list :turns turns :requests requests :executions executions
            :tools (hash-table-count harness-tools) :called (delete-dups called)
            :efforts (reverse efforts) :reloads reloads :changes (delete-dups changed)))))

(harness-fuzz-define-target
 'session-soak
 :description "Ordinary persisted turns and inert real tool declarations, including cache-breaking changes."
 :timeout 30
 :seeds (list "" (unibyte-string 1 19 1 77 1 255)
              (apply #'unibyte-string (cl-loop for i below 24 append (list 1 (+ 2 (* 3 i)))))
              (unibyte-string 1 74 1 77)
              (unibyte-string 2 46 3 57 4 0 4 1 5 2 6 9 7 1 8 0 9 1 10 7)
              (apply #'unibyte-string (cl-loop for i below 12 append (list i (+ 32 i)))))
 :check #'harness-fuzz-session--check)

(harness-fuzz-define-target
 'session-turns
 :description "Ordinary text/tool turns without deliberate cache mutations; every turn must succeed."
 :timeout 30
 :seeds (list "" (unibyte-string 0 0 1 19 1 77 0 1)
              (apply #'unibyte-string (cl-loop for i below 24 append (list 1 (+ 2 (* 3 i)))))
              (unibyte-string 1 74 1 77))
 :check (lambda (bytes) (harness-fuzz-session--check bytes t)))

(provide 'harness-fuzz-session)
;;; harness-fuzz-session.el ends here
