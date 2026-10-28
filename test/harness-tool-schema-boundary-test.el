;;; harness-tool-schema-boundary-test.el --- Optional arguments at provider boundaries -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests serialize the real registered schemas, not abbreviated copies.
;; No network, credentials or live sessions are used.  Provider-side schema
;; normalization is outside this boundary; these tests do not simulate it.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools-agent)
(require 'harness-tools-sessions)
(require 'harness-provider-responses)
(require 'harness-provider-openai)
(require 'harness-provider-claude)

(defun harness-schema-boundary-test--specs ()
  "Return the real tool specs whose optional fields motivated this audit."
  (mapcar (lambda (name) (harness-tool-spec (harness-tool-get name)))
          '("spawn_agent" "session_settings")))

(defun harness-schema-boundary-test--wire ()
  "Return synthetic request objects, serialized and parsed as on the wire."
  (let ((specs (harness-schema-boundary-test--specs)))
    (harness-json-parse
     (harness-json-encode
      (list :responses (harness-responses--body "synthetic-model" (list :tools specs))
            :openai_tools (harness-openai--tools specs)
            :claude_mcp_tools
            (harness-provider-claude--tool-list
             (harness-provider-claude--make-session :tools specs)))))))

(ert-deftest harness-schema-boundary-required-lists-survive-serialization ()
  "The local adapters do not turn optional properties into required ones."
  (let* ((wire (harness-schema-boundary-test--wire))
         (item (car (plist-get (plist-get wire :responses) :input)))
         (response-tools (plist-get item :tools))
         (openai-tools (plist-get wire :openai_tools))
         (claude-tools (plist-get wire :claude_mcp_tools)))
    (should (equal "additional_tools" (plist-get item :type)))
    (should (equal "developer" (plist-get item :role)))
    (cl-loop for spec in (harness-schema-boundary-test--specs)
             for response-tool in response-tools
             for openai-tool in openai-tools
             for claude-tool in claude-tools
             for required in '(("prompt") ("action"))
             do
             (should (plist-member response-tool :strict))
             (should (eq :false (plist-get response-tool :strict)))
             (dolist (schema (list (plist-get response-tool :parameters)
                                  (plist-get (plist-get openai-tool :function) :parameters)
                                  (plist-get claude-tool :inputSchema)))
               (should (equal required (plist-get schema :required)))
               (should (equal (plist-get spec :schema) schema))
               (should (plist-member (plist-get schema :properties) :model))
               (should-not (member "model" (plist-get schema :required)))))))

(ert-deftest harness-schema-boundary-settings-advertises-only-accepted-keys ()
  "Refused settings are explained, not offered as callable parameters."
  (let* ((spec (cadr (harness-schema-boundary-test--specs)))
         (properties (plist-get (plist-get spec :schema) :properties)))
    (cl-loop for (key _value) on properties by #'cddr
             do (should (or (memq key '(:action :session_id))
                            (member (substring (symbol-name key) 1)
                                    harness-tools-sessions--settings-keys))))
    (dolist (refused harness-tools-sessions--settings-refused)
      (should-not (plist-member properties (intern (concat ":" (car refused)))))))
  (should (string-match-p "request_escalation"
                          (plist-get (cadr (harness-schema-boundary-test--specs)) :description))))

(ert-deftest harness-schema-boundary-arguments-keep-presence-and-values ()
  "Neither parser adds fields; Responses emits the same parsed arguments."
  (dolist (case '(("{\"prompt\":\"synthetic\"}" (:prompt "synthetic"))
                  ("{\"prompt\":\"synthetic\",\"model\":\"\",\"thinking\":\"\"}"
                   (:prompt "synthetic" :model "" :thinking ""))
                  ("{\"prompt\":\"synthetic\",\"model\":null,\"thinking\":null}"
                   (:prompt "synthetic" :model nil :thinking nil))
                  ("{\"action\":\"read\"}" (:action "read"))
                  ("{\"action\":\"read\",\"permission_mode\":\"\",\"non_interactive\":false,\"allowed_dirs\":null}"
                   (:action "read" :permission_mode "" :non_interactive :false :allowed_dirs nil))))
    (let ((raw (car case)) (expected (cadr case)) events)
      (dolist (parse '(harness-responses--parse-arguments harness-openai--parse-arguments))
        (should (equal expected (funcall parse raw))))
      (let ((stream (make-harness-responses--stream
                     :on-event (lambda (event) (push event events))
                     :calls (list (cons 0 (list :name "synthetic" :call-id "call-audit"
                                               :arguments raw))))))
        (harness-responses--finish stream 'tool-use))
      (let ((input (plist-get (cl-find 'tool-call events
                                      :key (lambda (event) (plist-get event :type))) :input)))
        (should (equal expected input))
        (should (equal (plist-member expected :model) (plist-member input :model)))))))

(ert-deftest harness-schema-boundary-spawn-omission-null-and-empty ()
  "Omission inherits; JSON null currently does too, but empty strings do not."
  (let ((parent '(:id "synthetic-parent" :model "synthetic:thinker" :thinking "high"))
        created)
    (cl-letf (((symbol-function 'harness-tools-agent-context-limit) (lambda (&rest _) nil))
              ((symbol-function 'harness-tools-agent-context-limit-hint) (lambda (&rest _) nil))
              ((symbol-function 'harness-session--model-levels) (lambda (_model) '("low" "high")))
              ((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (should (eq method 'session/create))
                 (setq created args)
                 (harness-resolved args))))
      (dolist (raw '("{\"prompt\":\"synthetic\"}"
                     "{\"prompt\":\"synthetic\",\"model\":null,\"thinking\":null}"))
        (harness-tools-agent--create-child
         parent (harness-responses--parse-arguments raw) "child" default-directory nil "call" nil)
        (should (equal "synthetic:thinker" (plist-get created :model)))
        (should (equal "high" (plist-get created :thinking))))
      (setq created nil)
      (should-error
       (harness-tools-agent--create-child
        parent (harness-responses--parse-arguments
                "{\"prompt\":\"synthetic\",\"model\":\"\",\"thinking\":\"\"}")
        "child" default-directory nil "call" nil)
       :type 'harness-error)
      (should-not created))))

(ert-deftest harness-schema-boundary-settings-refuses-even-empty-or-null ()
  "A key rejected for permission reasons stays rejected for both actions."
  (let (called)
    (cl-letf (((symbol-function 'harness-call) (lambda (&rest _) (setq called t))))
      (dolist (action '("read" "set"))
        (dolist (refused harness-tools-sessions--settings-refused)
          (dolist (value '("" nil :false [] "synthetic-value"))
            (let ((input (harness-responses--parse-arguments
                          (harness-json-encode
                           (list :action action (intern (concat ":" (car refused))) value)))))
              (should-error (harness-tools-sessions--settings input '(:session-id "synthetic"))
                            :type 'harness-error)))))
      ;; Refusal precedes even session lookup, much less any mutation.
      (should-not called))))

(ert-deftest harness-schema-boundary-settings-minimal-read-reaches-handler ()
  "The valid minimal read works; forbidden blank fields are not needed."
  (let (calls)
    (cl-letf (((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (push (cons method args) calls)
                 '(:id "synthetic")))
              ((symbol-function 'harness-tools-sessions--settings-text)
               (lambda (_session _sid _selfp) "synthetic settings")))
      (dolist (raw '("{\"action\":\"read\"}"
                     "{\"action\":\"read\",\"session_id\":null}"
                     "{\"action\":\"read\",\"session_id\":\"\"}"))
        (should (equal "synthetic settings"
                       (plist-get (harness-tools-sessions--settings
                                   (harness-responses--parse-arguments raw)
                                   '(:session-id "synthetic")) :content))))
      (should (equal calls '((session/get "synthetic") (session/get "synthetic")
                            (session/get "synthetic")))))))

(provide 'harness-tool-schema-boundary-test)
;;; harness-tool-schema-boundary-test.el ends here
