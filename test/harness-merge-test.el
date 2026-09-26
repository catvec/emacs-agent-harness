;;; harness-merge-test.el --- Tests for the merge queue -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-provider)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-tools)
(require 'harness-merge)
(require 'harness-test-helpers)

(harness-module-load 'harness-provider)
(harness-module-load 'harness-session)
(harness-module-load 'harness-agent)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-merge)

(defvar harness-merge-test--requests nil)

(defun harness-merge-test--setup ()
  "Isolate storage and install a provider that replies immediately."
  (let ((harness-session-storage-directory (make-temp-file "harness-merge-" t)))
    (clrhash harness-session--active)
    (clrhash harness-session--project-ids)
    (setq harness-session--by-project nil
          harness-merge-test--requests nil)
    (dolist (name (hash-table-keys harness-provider--registry))
      (harness-provider-unregister name))
    (harness-provider-register
     "merge-test"
     :capabilities '(streaming)
     :models (list (list :model "m" :name "M" :context-window 1000
                         :input-price 1.0 :output-price 1.0))
     :complete (lambda (request)
                 (push request harness-merge-test--requests)
                 (let ((deferred (harness-deferred-new)))
                   (harness-deferred-resolve
                    deferred (list :text "merged" :stop-reason "end_turn"
                                   :tool-calls [] :usage '(:input-tokens 1 :output-tokens 1)))
                   deferred)))
    harness-session-storage-directory))

(defun harness-merge-test--configured (session)
  "Give SESSION the test model."
  (harness-session-set-config session "model" "merge-test/m")
  session)

(defun harness-merge-test--pair ()
  "Create a parent session and a child session in different directories."
  (let* ((parent-dir (make-temp-file "harness-merge-parent-" t))
         (child-dir (make-temp-file "harness-merge-child-" t))
         (parent (harness-merge-test--configured
                  (harness-session-create :cwd parent-dir :title "Parent")))
         (child (harness-merge-test--configured
                 (harness-session-create :cwd child-dir :title "Child"
                                         :parent-id (harness-session-id parent)))))
    (cons parent child)))

(defun harness-merge-test--pushed-prompts ()
  "Merge prompts the fake provider saw.
Auto-naming calls reuse the conversation and therefore also mention the
merge window, so they are filtered out by their system prompt."
  (length (seq-filter (lambda (request)
                        (and (not (string-match-p "short title"
                                                  (or (plist-get request :system) "")))
                             (string-match-p "merge window"
                                             (prin1-to-string (plist-get request :messages)))))
                      harness-merge-test--requests)))

(ert-deftest harness-merge-grants-when-the-parent-is-idle ()
  (let ((harness-session-storage-directory (harness-merge-test--setup)))
    (let* ((pair (harness-merge-test--pair))
           (parent (car pair))
           (child (cdr pair))
           (parent-id (harness-session-id parent))
           (child-id (harness-session-id child)))
      (should (equal (harness-merge-request child-id parent-id "please merge")
                     '(:granted t)))
      ;; The parent is locked and the child got the parent's directory.
      (should (equal (harness-merge-lock parent-id) child-id))
      (let ((reloaded-child (harness-session-load child-id)))
        (should (member (harness-session-cwd parent)
                        (harness-session-additional-directories reloaded-child))))
      ;; The parent refuses new turns while the window is open (before any
      ;; waiting: the child's turn runs on a timer and would release it).
      (let ((refused (harness-agent-prompt
                      :session-id parent-id
                      :prompt (vector (list :type "text" :text "do something")))))
        (harness-test-settle refused 5)
        (should (equal (harness-deferred-value refused) "refusal")))
      ;; The child received a merge prompt (the turn starts on a timer).
      (should (harness-test-wait-for
               (lambda () (= (harness-merge-test--pushed-prompts) 1)) 10))
      (let* ((request (car harness-merge-test--requests))
             (messages (append (plist-get request :messages) nil))
             (user (car (last messages)))
             (text (plist-get (aref (plist-get user :content) 0) :text)))
        (should (string-match-p "merge window" text))
        (should (string-match-p "please merge" text)))
      ;; When the merge turn finishes the window closes and the parent's
      ;; extra directory permission is withdrawn.
      (should (harness-test-wait-for
               (lambda () (null (harness-merge-lock parent-id))) 10))
      (let ((reloaded-child (harness-session-load child-id)))
        (should-not (member (harness-session-cwd parent)
                            (harness-session-additional-directories reloaded-child)))))))

(ert-deftest harness-merge-queues-a-second-child ()
  (let ((harness-session-storage-directory (harness-merge-test--setup)))
    (let* ((pair (harness-merge-test--pair))
           (parent (car pair))
           (parent-id (harness-session-id parent))
           (first (harness-merge-test--configured
                   (harness-session-create :cwd (make-temp-file "harness-merge-c1-" t)
                                           :parent-id parent-id)))
           (second (harness-merge-test--configured
                    (harness-session-create :cwd (make-temp-file "harness-merge-c2-" t)
                                            :parent-id parent-id))))
      (should (plist-get (harness-merge-request (harness-session-id first) parent-id)
                         :granted))
      (let ((result (harness-merge-request (harness-session-id second) parent-id)))
        (should (plist-get result :queued))
        (should (= (plist-get result :position) 1)))
      ;; The first child's merge turn finishes and the second is granted
      ;; (its turn then finishes too, so only the end state is stable).
      (should (harness-test-wait-for
               (lambda () (= (harness-merge-test--pushed-prompts) 2)) 10))
      (should (harness-test-wait-for
               (lambda () (null (harness-merge-lock parent-id))) 10))
      (should (null (harness-merge-queue parent-id)))
      ;; Both children were asked to merge, in queue order.
      (let ((asked (mapcar (lambda (request)
                             (let* ((messages (append (plist-get request :messages) nil))
                                    (user (car (last messages))))
                               (plist-get (aref (plist-get user :content) 0) :text)))
                           (seq-filter
                            (lambda (request)
                              (not (string-match-p "short title"
                                                   (or (plist-get request :system) ""))))
                            (reverse harness-merge-test--requests)))))
        (should (= (length asked) 2))
        (should (string-match-p "merge window" (car asked)))
        (should (string-match-p "merge window" (cadr asked)))))))

(ert-deftest harness-merge-tool-needs-a-parent ()
  (let ((harness-session-storage-directory (harness-merge-test--setup)))
    (let* ((lonely (harness-session-create :cwd (make-temp-file "harness-merge-lonely-" t)))
           (context (harness-tool-context-create
                     :session-id (harness-session-id lonely)
                     :cwd (harness-session-cwd lonely)))
           (deferred (harness-tools-execute "merge" '(:message "hi") context)))
      (harness-test-settle deferred 5)
      (let ((result (harness-deferred-value deferred)))
        (should (plist-get result :is-error))
        (should (string-match-p "no parent"
                                (harness-tools--text-of (plist-get result :content))))))))

(ert-deftest harness-merge-tool-queues-for-a-child ()
  (let ((harness-session-storage-directory (harness-merge-test--setup)))
    (let* ((pair (harness-merge-test--pair))
           (parent (car pair))
           (child (cdr pair))
           (parent-id (harness-session-id parent)))
      (should (equal (harness-merge-lock parent-id) nil))
      (let* ((context (harness-tool-context-create
                       :session-id (harness-session-id child)
                       :cwd (harness-session-cwd child)))
             (deferred (harness-tools-execute "merge" '(:message "from the tool") context)))
        (harness-test-settle deferred 5)
        (let ((text (harness-tools--text-of
                     (plist-get (harness-deferred-value deferred) :content))))
          (should (string-match-p "merge window" text))))
      (should (equal (harness-merge-lock parent-id) (harness-session-id child)))
      (harness-test-wait-for
       (lambda () (null (harness-merge-lock parent-id))) 10))))

(provide 'harness-merge-test)
;;; harness-merge-test.el ends here
