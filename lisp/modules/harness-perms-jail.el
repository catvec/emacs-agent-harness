;;; harness-perms-jail.el --- Directory jail rules -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The directory jail keeps a session's file tools inside the session's
;; working directory (plus directories the user has granted).  It answers
;; `ask' for paths outside, and never for paths inside, so later rules
;; (auto mode) still get a say on what happens within the jail.
;;
;; The sandbox already prevents bash from touching anything outside the
;; session directory at the kernel level; this rule covers the Emacs-native
;; file tools, which are not sandboxed because they run in Emacs itself.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-perms)

(defgroup harness-perms-jail nil
  "Directory jail."
  :group 'harness-perms)

(defun harness-perms-jail--truename (path)
  "Return PATH with symlinks resolved as far as possible."
  (or (ignore-errors (file-truename path)) (expand-file-name path)))

(defun harness-perms-jail--inside-p (path root)
  "Return non-nil when PATH is inside ROOT."
  (let ((path (file-name-as-directory (harness-perms-jail--truename path)))
        (root (file-name-as-directory (harness-perms-jail--truename root))))
    (string-prefix-p root path)))

(defun harness-perms-jail--roots (request)
  "Return the allowed roots for REQUEST."
  (let ((roots (list (plist-get request :cwd))))
    (dolist (directory (append (plist-get request :additional-directories) nil))
      (push directory roots))
    (delq nil roots)))

(defun harness-perms-jail-check (request)
  "Return an `ask' decision when REQUEST touches files outside the jail."
  (let* ((tool (plist-get request :tool))
         (arguments (plist-get request :arguments))
         (access (and tool (harness-tool-access-fn tool)))
         (roots (harness-perms-jail--roots request))
         (cwd (plist-get request :cwd))
         (outside nil))
    (when (and access (plist-get request :cwd))
      (dolist (entry (ignore-errors (funcall access arguments)))
        (let* ((raw (plist-get entry :path))
               (path (harness-perms-jail--truename
                      (if (file-name-absolute-p raw)
                          raw
                        (expand-file-name raw cwd)))))
          (unless (seq-some (lambda (root) (harness-perms-jail--inside-p path root)) roots)
            (push (list :path path :mode (plist-get entry :mode)) outside)))))
    (when outside
      (let ((paths (mapcar (lambda (entry) (plist-get entry :path)) outside)))
        (list :decision 'ask
              :paths (vconcat paths)
              :reason (format (concat "This session may not touch %s. "
                                      "Approve it, or use a path inside %s.")
                              (string-join paths ", ")
                              (or (plist-get request :cwd) "the session directory")))))))

(defun harness-perms-jail-setup ()
  "Install the jail rule ahead of the other permission rules."
  (setq harness-permission-functions
        (cons #'harness-perms-jail-check
              (remove #'harness-perms-jail-check harness-permission-functions))))

(defun harness-perms-jail-teardown ()
  "Remove the jail rule."
  (setq harness-permission-functions
        (remove #'harness-perms-jail-check harness-permission-functions)))

(harness-module-define 'harness-perms-jail
  :version harness-version
  :description "Keep file tools inside the session directory."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0")
              (harness-perms "0.1.0"))
  :provides '(harness-perms-jail)
  :setup #'harness-perms-jail-setup
  :teardown #'harness-perms-jail-teardown)

(provide 'harness-perms-jail)
;;; harness-perms-jail.el ends here
