;;; harness-subagents-test.el --- Tests for the sub-agent tool -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-provider)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-tools)
(require 'harness-subagents)
(require 'harness-test-helpers)

(harness-module-load 'harness-provider)
(harness-module-load 'harness-session)
(harness-module-load 'harness-agent)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-subagents)

(defvar harness-subagents-test--requests nil
  "Provider requests seen by the fake provider.")

(defvar harness-subagents-test--storage nil)

(defun harness-subagents-test--setup ()
  "Isolate storage and register a provider that replies with text."
  (setq harness-subagents-test--storage (make-temp-file "harness-subagents-" t)
        harness-subagents-test--requests nil)
  (clrhash harness-session--active)
  (clrhash harness-session--project-ids)
  (setq harness-session--by-project nil)
  (dolist (name (hash-table-keys harness-provider--registry))
    (harness-provider-unregister name))
  (harness-provider-register
   "subtest"
   :description "Sub-agent test provider."
   :capabilities '(streaming tool-calls)
   :models (list (list :model "sub-agent-model" :name "Sub Agent Model"
                       :context-window 10000 :input-price 1.0 :output-price 1.0))
   :complete
   (lambda (request)
     (push request harness-subagents-test--requests)
     (let ((deferred (harness-deferred-new)))
       (harness-deferred-resolve
        deferred
        (list :text "sub-agent report: all done"
              :stop-reason "end_turn"
              :usage '(:input-tokens 5 :output-tokens 3)
              :tool-calls []))
       deferred))))

(defmacro harness-subagents-test--with-storage (&rest body)
  "Run BODY with isolated session storage."
  (declare (indent 0))
  `(let ((harness-session-storage-directory harness-subagents-test--storage))
     ,@body))

(defun harness-subagents-test--parent ()
  "Create a parent session with the fake model configured."
  (let ((session (harness-session-create :cwd (make-temp-file "harness-parent-" t))))
    (harness-session-set-config session "model" "subtest/sub-agent-model")
    session))

(defun harness-subagents-test--call (arguments session)
  "Call the subagent tool with ARGUMENTS from SESSION."
  (let* ((context (harness-tool-context-create
                   :session-id (harness-session-id session)
                   :cwd (harness-session-cwd session)))
         (deferred (harness-tools-execute "subagent" arguments context)))
    (harness-test-settle deferred 20)
    (harness-deferred-value deferred)))

(ert-deftest harness-subagents-registers-tool ()
  (harness-subagents-test--setup)
  (let ((tool (harness-tool-get "subagent")))
    (should tool)
    (should (equal (harness-tool-kind tool) 'other))
    (should (harness-tool-handler tool))))

(ert-deftest harness-subagents-runs-a-child-session ()
  (harness-subagents-test--setup)
  (harness-subagents-test--with-storage
    (let* ((parent (harness-subagents-test--parent))
           (result (harness-subagents-test--call '(:prompt "count the widgets") parent))
           (text (harness-tools--text-of (plist-get result :content))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "sub-agent report: all done" text))
      ;; The child session exists, is parented to this session, and got the
      ;; models inherited from the parent.
      (let* ((children (harness-session-children (harness-session-id parent)))
             (child-id (car children))
             (child (harness-session-load child-id)))
        (should (= (length children) 1))
        (should (equal (harness-session-parent-id child) (harness-session-id parent)))
        (should (equal (harness-session-model child) "subtest/sub-agent-model")))
      ;; The provider saw the wrapped prompt in the child's turn (a later
      ;; request may follow for automatic session naming).
      (let* ((request (seq-find (lambda (request)
                                  (not (string-match-p
                                        "short title"
                                        (or (plist-get request :system) ""))))
                                harness-subagents-test--requests))
             (messages (append (plist-get request :messages) nil))
             (user (car (last messages)))
             (content (plist-get user :content))
             (text (plist-get (aref content 0) :text)))
        (should (string-match-p "You are a sub-agent" text))
        (should (string-match-p "count the widgets" text))))))

(ert-deftest harness-subagents-honours-directory-and-title ()
  (harness-subagents-test--setup)
  (harness-subagents-test--with-storage
    (let* ((parent (harness-subagents-test--parent))
           (directory (make-temp-file "harness-subdir-" t))
           (result (harness-subagents-test--call
                    (list :prompt "look around" :directory directory :title "Scout")
                    parent))
           (child (harness-session-load (car (harness-session-children
                                              (harness-session-id parent))))))
      (should-not (plist-get result :is-error))
      (should (equal (file-name-as-directory (file-truename (harness-session-cwd child)))
                     (file-name-as-directory (file-truename directory))))
      (should (equal (harness-session-title child) "Scout")))))

(ert-deftest harness-subagents-refuses-empty-prompt ()
  (harness-subagents-test--setup)
  (harness-subagents-test--with-storage
    (let* ((parent (harness-subagents-test--parent))
           (result (harness-subagents-test--call '(:prompt "  ") parent)))
      (should (plist-get result :is-error))
      (should (string-match-p "needs a prompt"
                              (harness-tools--text-of (plist-get result :content)))))))

(ert-deftest harness-subagents-caps-nesting-depth ()
  (harness-subagents-test--setup)
  (harness-subagents-test--with-storage
    (let* ((harness-subagents-max-depth 1)
           (parent (harness-subagents-test--parent))
           (child (harness-session-create :cwd (harness-session-cwd parent)
                                          :parent-id (harness-session-id parent)))
           (result (harness-subagents-test--call '(:prompt "go deeper") child)))
      (should (plist-get result :is-error))
      (should (string-match-p "nested"
                              (harness-tools--text-of (plist-get result :content))))
      ;; No grandchild session was created.
      (should-not (harness-session-children (harness-session-id child))))))

(ert-deftest harness-subagents-forks-when-asked ()
  (harness-subagents-test--setup)
  (harness-subagents-test--with-storage
    (let* ((parent (harness-subagents-test--parent)))
      (harness-session-append parent
                              (list :sessionUpdate "user_message_chunk"
                                    :content (list :type "text" :text "original context")
                                    :messageId "m1"))
      (harness-session-append parent
                              (list :sessionUpdate "agent_message_chunk"
                                    :content (list :type "text" :text "original reply")
                                    :messageId "m2"))
      (harness-session-save parent)
      (let* ((result (harness-subagents-test--call
                      (list :prompt "continue from here" :fork "yes") parent))
             (child (harness-session-load (car (harness-session-children
                                                (harness-session-id parent))))))
        (harness-test-settle (harness-session-ensure-entries child) 5)
        (should-not (plist-get result :is-error))
        ;; The fork carried the parent's transcript along (plus the new
        ;; prompt of the sub-agent turn).
        (should (>= (length (harness-session-entries child)) 2))
        (should (equal (plist-get (plist-get (aref (harness-session-entries child) 1)
                                             :content)
                                  :text)
                       "original reply"))))))

(provide 'harness-subagents-test)
;;; harness-subagents-test.el ends here
