;;; harness-perms-test.el --- Tests for the permission chain -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-perms)
(require 'harness-perms-jail)
(require 'harness-test-helpers)

(harness-module-load 'harness-tools)
(harness-module-load 'harness-perms)
(harness-module-load 'harness-perms-jail)

(defun harness-perms-test--reset ()
  "Restore the jail-then-auto chain and clear the asker."
  (setq harness-permission-ask-function nil)
  (setq harness-permission-functions (list #'harness-perms-jail-check
                                           #'harness-perms-auto-check)))

(defun harness-perms-test--register-tools ()
  "Register tools the permission tests use."
  (harness-tool-register
   "test-write-tool"
   :description "Write a file."
   :schema '(:type "object" :properties (:path (:type "string")) :required ["path"])
   :kind 'edit
   :module 'harness-perms-test
   :access (lambda (arguments)
             (list (list :path (plist-get arguments :path) :mode "write")))
   :handler (lambda (&rest _) "ok"))
  (harness-tool-register
   "test-readonly-tool"
   :description "Read something."
   :kind 'read
   :read-only t
   :module 'harness-perms-test
   :handler (lambda (&rest _) "ok")))

(defun harness-perms-test--check (tool arguments &rest options)
  "Check TOOL with ARGUMENTS and return the settled decision."
  (let ((deferred (apply #'harness-permission-check tool arguments nil options)))
    (harness-test-settle deferred 5)
    (harness-deferred-value deferred)))

(defmacro harness-perms-test--with-directory (&rest body)
  "Run BODY with `test-directory' bound to a fresh temp directory."
  (declare (indent 0))
  `(let ((test-directory (make-temp-file "harness-perms-" t)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory test-directory t)))))

(ert-deftest harness-perms-default-allows-inside-jail ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "inside.txt")
                     :cwd test-directory :permission-mode 'ask)))
      (should (harness-permission-allowed-p decision)))))

(ert-deftest harness-perms-jail-asks-outside ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((asked nil))
      (setq harness-permission-ask-function
            (lambda (request)
              (setq asked request)
              (let ((deferred (harness-deferred-new)))
                (harness-deferred-resolve deferred (list :outcome "allow" :always t))
                deferred)))
      (let ((decision (harness-perms-test--check
                       "test-write-tool" '(:path "/etc/passwd")
                       :cwd test-directory :permission-mode 'ask)))
        (should (harness-permission-allowed-p decision))
        (should (plist-get decision :always))
        (should asked)
        (should (equal (plist-get asked :tool-name) "test-write-tool"))
        (should (string-match-p "/etc/passwd" (format "%S" (plist-get asked :paths))))
        (should (vectorp (plist-get asked :options)))))))

(ert-deftest harness-perms-jail-asker-can-deny ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (setq harness-permission-ask-function
          (lambda (_request)
            (let ((deferred (harness-deferred-new)))
              (harness-deferred-resolve deferred (list :outcome "deny" :reason "nope"))
              deferred)))
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "/etc/passwd")
                     :cwd test-directory :permission-mode 'ask)))
      (should-not (harness-permission-allowed-p decision))
      (should (equal (plist-get decision :decision) 'deny)))))

(ert-deftest harness-perms-jail-without-asker-denies-constructively ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "/etc/passwd")
                     :cwd test-directory :permission-mode 'ask)))
      (should-not (harness-permission-allowed-p decision))
      (should (string-match-p "no one to ask" (plist-get decision :reason))))))

(ert-deftest harness-perms-jail-additional-directories ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((other (make-temp-file "harness-perms-other-" t)))
      (unwind-protect
          (progn
            (let ((decision (harness-perms-test--check
                             "test-write-tool" (list :path (expand-file-name "x.txt" other))
                             :cwd test-directory :permission-mode 'ask
                             :additional-directories (list other))))
              (should (harness-permission-allowed-p decision))))
        (delete-directory other t)))))

(ert-deftest harness-perms-jail-symlink-escape-is-outside ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((outside (make-temp-file "harness-perms-outside-" t))
          (link (expand-file-name "link" test-directory)))
      (unwind-protect
          (progn
            (make-symbolic-link outside link)
            (let ((decision (harness-perms-test--check
                             "test-write-tool" '(:path "link/secret.txt")
                             :cwd test-directory :permission-mode 'ask)))
              (should (equal (plist-get decision :decision) 'deny))))
        (delete-directory outside t)))))

(ert-deftest harness-perms-jail-ignores-tools-without-access ()
  (harness-perms-test--reset)
  (harness-tool-register "test-shell-tool" :description "Shell." :kind 'execute
                         :module 'harness-perms-test :handler #'ignore)
  (harness-perms-test--with-directory
    (let ((decision (harness-perms-test--check
                     "test-shell-tool" '(:command "rm -rf /")
                     :cwd test-directory :permission-mode 'ask)))
      (should (harness-permission-allowed-p decision)))))

(ert-deftest harness-perms-chain-order-and-deny ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((calls nil))
      (setq harness-permission-functions
            (list (lambda (_request) (push 'first calls) nil)
                  (lambda (_request) (push 'second calls) 'deny)
                  (lambda (_request) (push 'third calls) 'allow)))
      (let ((decision (harness-perms-test--check "test-readonly-tool" nil
                                                 :cwd test-directory)))
        (should-not (harness-permission-allowed-p decision))
        (should (equal (plist-get decision :decision) 'deny))
        ;; The third rule never ran.
        (should (equal (reverse calls) '(first second)))))))

(ert-deftest harness-perms-chain-rule-error-denies ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (setq harness-permission-functions
          (list (lambda (_request) (error "rule exploded"))))
    (let ((decision (harness-perms-test--check "test-readonly-tool" nil
                                               :cwd test-directory)))
      (should-not (harness-permission-allowed-p decision))
      (should (string-match-p "rule exploded" (plist-get decision :reason))))))

(ert-deftest harness-perms-chain-handles-async-rules ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (setq harness-permission-functions
          (list (lambda (_request)
                  (let ((deferred (harness-deferred-new)))
                    (run-at-time 0.01 nil (lambda () (harness-deferred-resolve deferred nil)))
                    deferred))
                (lambda (_request) 'allow)))
    (let ((decision (harness-perms-test--check "test-readonly-tool" nil
                                               :cwd test-directory)))
      (should (harness-permission-allowed-p decision)))))

;;; Auto mode

(defun harness-perms-test--install-fake-provider (reply)
  "Install a provider service that always answers REPLY."
  (harness-service-register
   "provider"
   :module 'harness-perms-test
   :methods
   (list (cons 'complete
               (lambda (&rest _args)
                 (let ((deferred (harness-deferred-new)))
                   (if (functionp reply)
                       (funcall reply deferred)
                     (harness-deferred-resolve deferred (list :text reply)))
                   deferred))))))

(ert-deftest harness-perms-auto-mode-allows-and-denies ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (harness-perms-test--install-fake-provider "ALLOW - safe edit")
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "x.txt")
                     :cwd test-directory :permission-mode 'auto)))
      (should (harness-permission-allowed-p decision))
      (should (string-match-p "Auto mode" (plist-get decision :reason))))
    (harness-perms-test--install-fake-provider "DENY - destructive")
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "x.txt")
                     :cwd test-directory :permission-mode 'auto)))
      (should-not (harness-permission-allowed-p decision))
      (should (string-match-p "destructive" (plist-get decision :reason))))))

(ert-deftest harness-perms-auto-mode-skips-read-only-tools ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (let ((called nil))
      (harness-service-register
       "provider"
       :module 'harness-perms-test
       :methods (list (cons 'complete
                            (lambda (&rest _args) (setq called t)
                              (let ((d (harness-deferred-new)))
                                (harness-deferred-resolve d (list :text "DENY - no"))
                                d)))))
      (let ((decision (harness-perms-test--check
                       "test-readonly-tool" nil
                       :cwd test-directory :permission-mode 'auto)))
        (should (harness-permission-allowed-p decision))
        (should-not called)))))

(ert-deftest harness-perms-auto-mode-error-asks ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (harness-perms-test--install-fake-provider
     (lambda (deferred)
       (harness-deferred-reject deferred '(harness-provider-error "down"))))
    (let ((asked nil))
      (setq harness-permission-ask-function
            (lambda (_request)
              (setq asked t)
              (let ((deferred (harness-deferred-new)))
                (harness-deferred-resolve deferred (list :outcome "deny" :reason "user no"))
                deferred)))
      (let ((decision (harness-perms-test--check
                       "test-write-tool" '(:path "x.txt")
                       :cwd test-directory :permission-mode 'auto)))
        (should asked)
        (should-not (harness-permission-allowed-p decision))))))

(ert-deftest harness-perms-no-provider-falls-through-to-ask ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-service-unregister "provider")
  (harness-perms-test--with-directory
    (let ((decision (harness-perms-test--check
                     "test-write-tool" '(:path "x.txt")
                     :cwd test-directory :permission-mode 'auto)))
      ;; No provider: auto mode declines, nothing else objects, so allow.
      (should (harness-permission-allowed-p decision)))))

(ert-deftest harness-perms-service-surface ()
  (harness-perms-test--reset)
  (harness-perms-test--register-tools)
  (harness-perms-test--with-directory
    (should (vectorp (harness-service-call "permission" 'rules)))
    (let* ((deferred (harness-service-call
                      "permission" 'check
                      :tool-name "test-readonly-tool"
                      :arguments nil
                      :cwd test-directory))
           (decision (progn (harness-test-settle deferred) (harness-deferred-value deferred))))
      (should (harness-permission-allowed-p decision)))))

(provide 'harness-perms-test)
;;; harness-perms-test.el ends here
