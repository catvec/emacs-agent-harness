;;; harness-ui-worktree-test.el --- Tests for the worktree manager -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-ui)
(require 'harness-ui-worktree)

(harness-module-load 'harness-ui)
(harness-module-load 'harness-ui-worktree)

(defvar harness-ui-worktree-test--requests nil)

(defun harness-ui-worktree-test--worktrees ()
  "Canned worktree list response."
  (list :worktrees
        (vector (list :path "/tmp/repo/" :branch "main" :head "abcdef1234567890" :main t)
                (list :path "/tmp/worktrees/fix/" :branch "harness/fix"
                      :head "1234567890abcdef"))))

(defun harness-ui-worktree-test--infos ()
  "Canned session infos: one session lives in the second worktree."
  (vector (list :sessionId "s1" :title "Fix" :cwd "/tmp/worktrees/fix/")))

(defun harness-ui-worktree-test--response (method)
  "Canned response for METHOD."
  (pcase method
    ("_harness/worktree/list" (harness-ui-worktree-test--worktrees))
    ("_harness/session/infos" (harness-ui-worktree-test--infos))
    (_ (make-hash-table))))

(defun harness-ui-worktree-test--with-stubs (function)
  "Call FUNCTION with stubbed ACP responses."
  (let ((original (symbol-function 'harness-ui-request)))
    (unwind-protect
        (progn
          (setq harness-ui-worktree-test--requests nil)
          (fset 'harness-ui-request
                (lambda (method &optional params)
                  (push (cons method params) harness-ui-worktree-test--requests)
                  (let ((deferred (harness-deferred-new)))
                    (harness-deferred-resolve deferred
                                              (harness-ui-worktree-test--response method))
                    deferred)))
          (funcall function))
      (fset 'harness-ui-request original)
      (when-let* ((buffer (get-buffer "*harness-worktrees*")))
        (kill-buffer buffer)))))

(ert-deftest harness-ui-worktree-lists-worktrees-with-sessions ()
  (harness-ui-worktree-test--with-stubs
   (lambda ()
     (let ((buffer (harness-ui-worktrees "/tmp/repo")))
       (with-current-buffer buffer
         (should (= (length tabulated-list-entries) 2))
         (let* ((rows (mapcar (lambda (entry) (append (cadr entry) nil))
                              tabulated-list-entries)))
           (should (equal (nth 1 (car rows)) "main"))
           (should (equal (nth 1 (cadr rows)) "harness/fix"))
           ;; The session in the second worktree is counted.
           (should (equal (nth 3 (car rows)) "0"))
           (should (equal (nth 3 (cadr rows)) "1"))))
       ;; Both data requests were made over ACP.
       (should (member "_harness/worktree/list"
                       (mapcar #'car harness-ui-worktree-test--requests)))
       (should (member "_harness/session/infos"
                       (mapcar #'car harness-ui-worktree-test--requests)))))))

(ert-deftest harness-ui-worktree-refuses-to-remove-the-main-worktree ()
  (harness-ui-worktree-test--with-stubs
   (lambda ()
     (let ((buffer (harness-ui-worktrees "/tmp/repo")))
       (with-current-buffer buffer
         (goto-char (point-min))
         (should-error (harness-ui-worktree-remove) :type 'user-error))))))

(ert-deftest harness-ui-worktree-opens-an-existing-session ()
  (harness-ui-worktree-test--with-stubs
   (lambda ()
     (let ((buffer (harness-ui-worktrees "/tmp/repo"))
           (opened nil))
       (with-current-buffer buffer
         (goto-char (point-min))
         (forward-line 1)
         (cl-letf (((symbol-function 'harness-ui-chat-open)
                    (lambda (session-id &optional position)
                      (setq opened (list session-id position)))))
           (harness-ui-worktree-open-session)))
       (should (equal (car opened) "s1"))
       (should (equal (cadr opened) 'full))))))

(provide 'harness-ui-worktree-test)
;;; harness-ui-worktree-test.el ends here
