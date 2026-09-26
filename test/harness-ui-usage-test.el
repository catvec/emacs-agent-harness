;;; harness-ui-usage-test.el --- Tests for the usage page -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-ui)
(require 'harness-ui-usage)

(harness-module-load 'harness-ui)
(harness-module-load 'harness-ui-usage)

(defun harness-ui-usage-test--summary ()
  "A canned usage summary."
  (list :totals (list :sessions 3 :input 1500 :output 300
                      :cache-read 100 :cache-write 50
                      :cost (list :amount 0.7 :currency "USD"))
        :periods (list (list :period 'daily :spent 0.1)
                       (list :period 'weekly :spent 0.4)
                       (list :period 'monthly :spent 0.7))
        :projects (list (list :key "/tmp/project-a" :sessions 2 :input 1000 :output 200
                              :cost (list :amount 0.5 :currency "USD"))
                        (list :key "/tmp/project-b" :sessions 1 :input 500 :output 100
                              :cost (list :amount 0.2 :currency "USD")))
        :models (list (list :key "openai/gpt-x" :sessions 3 :input 1500 :output 300
                            :cost (list :amount 0.7 :currency "USD")))
        :sessions (vector (list :sessionId "s1" :title "One" :projectRoot "/tmp/project-a"
                                :model "openai/gpt-x" :status "idle" :updatedEpoch (float-time)
                                :usage '(:input 500 :output 100) :cost (list :amount 0.2 :currency "USD"))
                          (list :sessionId "s2" :title "Two" :projectRoot "/tmp/project-a"
                                :model "openai/gpt-x" :status "idle" :updatedEpoch (float-time)
                                :usage '(:input 500 :output 100) :cost (list :amount 0.3 :currency "USD"))
                          (list :sessionId "s3" :title "Three" :projectRoot "/tmp/project-b"
                                :model "openai/gpt-x" :status "idle" :updatedEpoch (float-time)
                                :usage '(:input 500 :output 100) :cost (list :amount 0.2 :currency "USD")))
        :budgets (list (list :label "project-a budget (monthly)" :scope 'project
                             :project "/tmp/project-a" :period 'monthly
                             :amount 0.5 :spent 0.6 :remaining -0.1 :hard t :over t
                             :currency "USD"))))

(defun harness-ui-usage-test--with-page (function)
  "Open the usage page with a stubbed ACP and call FUNCTION with the buffer."
  (let ((original (symbol-function 'harness-ui-request)))
    (unwind-protect
        (progn
          (fset 'harness-ui-request
                (lambda (_method &optional _params)
                  (let ((deferred (harness-deferred-new)))
                    (harness-deferred-resolve deferred (harness-ui-usage-test--summary))
                    deferred)))
          (let ((buffer (harness-ui-usage)))
            (funcall function buffer)))
      (fset 'harness-ui-request original)
      (when-let* ((buffer (get-buffer "*harness-usage*")))
        (kill-buffer buffer)))))

(defun harness-ui-usage-test--text (buffer)
  "Buffer text of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest harness-ui-usage-renders-report ()
  (harness-ui-usage-test--with-page
   (lambda (buffer)
     (let ((text (harness-ui-usage-test--text buffer)))
       (should (string-match-p "Harness usage" text))
       (should (string-match-p "sessions" text))
       (should (string-match-p "1\\.5k" text))
       (should (string-match-p "\\$0\\.70" text))
       ;; Period spend lines.
       (should (string-match-p "daily" text))
       ;; Budget with a hard marker.
       (should (string-match-p "project-a budget (monthly)" text))
       (should (string-match-p "(hard)" text))
       ;; Breakdowns and the session table heading.
       (should (string-match-p "By project" text))
       (should (string-match-p "By model" text))
       (should (string-match-p "Sessions" text))))
   ))

(ert-deftest harness-ui-usage-session-table-is-populated ()
  (harness-ui-usage-test--with-page
   (lambda (buffer)
     (with-current-buffer buffer
       (should (equal (length tabulated-list-entries) 3))
       ;; Costliest session first.
       (should (equal (caar tabulated-list-entries) "s2"))
       (should (equal (mapcar #'car tabulated-list-entries) '("s2" "s1" "s3")))
       ;; The report above the table is read-only.
       (goto-char (point-min))
       (should (get-text-property (point) 'read-only))
       ;; The table itself is not.
       (goto-char (point-max))
       (should-not (get-text-property (point) 'read-only))))))

(ert-deftest harness-ui-usage-over-budget-bar-is-red ()
  (harness-ui-usage-test--with-page
   (lambda (buffer)
     (with-current-buffer buffer
       (goto-char (point-min))
       (should (search-forward "project-a budget (monthly)" nil t))
       (let ((faces nil))
         (let ((end (line-end-position)))
           (while (< (point) end)
             (let ((face (get-text-property (point) 'face)))
               (when face (push face faces)))
             (forward-char 1)))
         ;; The fill takes its colour from the theme's error face.
         (should (cl-some (lambda (face)
                            (and (listp face)
                                 (equal (plist-get face :background)
                                        (face-attribute 'error :foreground nil t))))
                          faces)))))))

(ert-deftest harness-ui-usage-formatting ()
  (should (equal (harness-ui-usage--tokens 999) "999"))
  (should (equal (harness-ui-usage--tokens 1500) "1.5k"))
  (should (equal (harness-ui-usage--tokens 2500000) "2.5M"))
  (should (equal (harness-ui-usage--money 0.0005) "$0.0005"))
  (should (equal (harness-ui-usage--money 1.5) "$1.50")))

(provide 'harness-ui-usage-test)
;;; harness-ui-usage-test.el ends here
