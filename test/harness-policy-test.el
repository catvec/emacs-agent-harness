;;; harness-policy-test.el --- Tests for the policy an administrator sets  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every test reads a policy from a temporary file, as the harness reads
;; /etc/harness/policy.el: `harness-test-with-policy', or a file written
;; here when the test is about the file itself.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-policy)
(require 'cus-edit)

(defvar harness-started)
(defvar harness-corporate-mode)
(defvar harness--self-file)

(defcustom harness-policy-test-mode 'ask
  "A choice, for the tests."
  :type '(choice (const ask) (const yolo) (const auto))
  :safe #'symbolp :group 'harness)

(defcustom harness-policy-test-dirs nil
  "A list of directories, for the tests."
  :type '(repeat string) :group 'harness)

(defun harness-policy-test--file (text)
  "Return a fresh policy file holding TEXT."
  (let ((file (make-temp-file "harness-policy-" nil ".el")))
    (with-temp-file file (insert text))
    file))

(defun harness-policy-test--error (fn)
  "Return the message of the error FN signals, or nil when it signals none."
  (condition-case err (progn (funcall fn) nil)
    (error (error-message-string err))))

(defmacro harness-policy-test--forgetting (names &rest body)
  "Run BODY, then forget the variables NAMES, which BODY defines."
  (declare (indent 1))
  `(unwind-protect (progn ,@body)
     (dolist (name ',names)
       (remove-variable-watcher name #'harness-policy--watch)
       (setq ignored-local-variables (delq name ignored-local-variables))
       (makunbound name)
       (setplist name nil))))

;;;; Reading

(ert-deftest harness-policy-read-takes-one-alist-of-data ()
  "The file holds one alist, which is read, never evaluated; comments
and nothing at all are fine, and no file means no policy."
  (should-not (harness-policy-read nil))
  (should-not (harness-policy-read (expand-file-name "none.el" (harness-test-temp-dir))))
  (dolist (text '("" "\n\n" ";; Nothing set yet.\n" "#| no |#\n;; a\n;; b\n"))
    (let ((file (harness-policy-test--file (string-replace "#| no |#" "" text))))
      (should-not (harness-policy-read file))
      (delete-file file)))
  (let ((file (harness-policy-test--file
               (concat ";;; policy.el --- managed by IT\n"
                       "((harness-corporate-mode . t) ; required\n"
                       " (harness-permission-mode . ask)\n"
                       " ;; Code is data here, never run:\n"
                       " (harness-allowed-models \"claude:*\")\n"
                       " (harness-model-hook . (lambda () (error \"ran\"))))\n"
                       ";; The end.\n"))))
    (unwind-protect
        (should (equal '((harness-corporate-mode . t)
                         (harness-permission-mode . ask)
                         (harness-allowed-models "claude:*")
                         (harness-model-hook lambda () (error "ran")))
                       (harness-policy-read file)))
      (delete-file file))))

(ert-deftest harness-policy-read-refuses-what-it-cannot-trust ()
  "A file that is there but holds anything but one alist of harness
options, each once, is an error naming the file and the fault."
  (pcase-dolist (`(,text ,why)
                 '(("((harness-a . 1)" "ends inside a list")
                   ("((harness-a . 1)) ((harness-b . 2))" "more than one form")
                   ("((harness-a . 1)) )" "more than one form")
                   ("harness-a" "not an alist")
                   ("((harness-a . 1) . 2)" "not an alist")
                   ("((foo-mode . t))" "foo-mode is not a harness option")
                   ("(harness-a)" "harness-a is not an (OPTION . VALUE) entry")
                   ("((\"harness-a\" . 1))" "is not an (OPTION . VALUE) entry")
                   ("((nil . 1))" "is not an (OPTION . VALUE) entry")
                   ("((harness-a . 1) (harness-b . 2) (harness-a . 3))" "harness-a is set twice")
                   ("((harness-a . #1=(x . #1#)))" "not readable Lisp data")))
    (let ((file (harness-policy-test--file text)))
      (unwind-protect
          (let ((message (harness-policy-test--error (lambda () (harness-policy-read file)))))
            (should message)
            (should (string-prefix-p (format "Policy %s: " file) message))
            (should (string-search why message)))
        (delete-file file)))))

(ert-deftest harness-policy-read-refuses-a-file-it-cannot-read ()
  "A policy the user hides by taking the right to read it (or its
directory) away is no policy missing: the harness refuses to start."
  (skip-unless (not (zerop (user-uid))))
  (let* ((dir (harness-test-temp-dir))
         (file (expand-file-name "policy.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "((harness-a . 1))"))
          (set-file-modes file #o000)
          (should (string-search "cannot be read"
                                 (harness-policy-test--error (lambda () (harness-policy-read file)))))
          (set-file-modes file #o644)
          (set-file-modes dir #o000)
          (should (string-search "cannot be read"
                                 (harness-policy-test--error (lambda () (harness-policy-read file))))))
      (set-file-modes dir #o755)
      (delete-directory dir t))))

;;;; Loading and applying

(ert-deftest harness-policy-load-checks-values-and-keeps-the-old-policy ()
  "A value its option's type refuses is an error, and so is a broken
file read again: either way the policy in force stays."
  (harness-test-with-policy '((harness-policy-test-mode . yolo))
    (should (equal '((harness-policy-test-mode . yolo)) (harness-policy-entries)))
    (should (equal policy-file (harness-policy-file-name)))
    (harness-test-write-policy policy-file '((harness-policy-test-mode . banana)))
    (let ((message (harness-policy-test--error #'harness-policy-load)))
      (should (string-search "banana is not a valid value for harness-policy-test-mode" message)))
    (with-temp-file policy-file (insert "((harness-policy-test-mode . auto)"))
    (should-error (harness-policy-load))
    (should (equal '((harness-policy-test-mode . yolo)) (harness-policy-entries)))
    (should (eq 'yolo harness-policy-test-mode))
    ;; A file gone is a policy gone.
    (delete-file policy-file)
    (should-not (harness-policy-load))
    (should-not (harness-policy-file-name))
    (should-not (harness-policy-pinned-p 'harness-policy-test-mode))
    (with-temp-file policy-file (insert ";; back\n"))))

(ert-deftest harness-policy-holds-against-every-way-to-set-an-option ()
  "A policy value stays whatever sets the option: setq, set-default,
setopt, Customize, a custom file, a .dir-locals.el.  A let-binding,
which ends, and a buffer's own value pass."
  (let ((harness-policy-test-mode 'ask)
        (harness-started t)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (unwind-protect
          (harness-test-with-policy '((harness-policy-test-mode . yolo) (harness-policy-test-dirs "/srv"))
            (should (eq 'yolo harness-policy-test-mode))
            (should (equal '("/srv") harness-policy-test-dirs))
            (should (harness-policy-pinned-p 'harness-policy-test-mode))
            (should-not (harness-policy-pinned-p 'harness-policy-test-nothing))
            ;; setq and set-default signal, with the reason.
            (should (equal (format "harness-policy-test-mode is set by policy (%s) and cannot be changed"
                                   policy-file)
                           (harness-policy-test--error (lambda () (setq harness-policy-test-mode 'auto)))))
            (should-error (set-default 'harness-policy-test-mode 'auto))
            (should-error (set 'harness-policy-test-dirs nil))
            (should-error (makunbound 'harness-policy-test-mode))
            (should (eq 'yolo harness-policy-test-mode))
            ;; The policy's own value is no change.
            (setq harness-policy-test-mode 'yolo)
            ;; setopt, Customize and a custom file warn and leave it.
            (setopt harness-policy-test-mode 'auto)
            (customize-set-variable 'harness-policy-test-mode 'ask)
            (custom-set-variables '(harness-policy-test-mode 'auto))
            (should (eq 'yolo harness-policy-test-mode))
            (should (= 3 (length warnings)))
            (should (string-search "set by policy" (car warnings)))
            ;; A let-binding and a buffer's own value pass.
            (let ((harness-policy-test-mode 'auto))
              (should (eq 'auto harness-policy-test-mode)))
            (with-temp-buffer
              (setq-local harness-policy-test-mode 'ask)
              (should (eq 'ask harness-policy-test-mode)))
            (should (eq 'yolo harness-policy-test-mode))
            (should (eq 'yolo (default-value 'harness-policy-test-mode))))
        ;; What Customize noted of the attempts.
        (dolist (prop '(customized-value saved-value theme-value))
          (put 'harness-policy-test-mode prop nil))))))

(ert-deftest harness-policy-keeps-dir-locals-from-setting-an-option ()
  "A .dir-locals.el sets a safe option in its files' buffers, unless
the policy sets it."
  (let* ((dir (harness-test-temp-dir))
         (file (expand-file-name "notes.txt" dir))
         (enable-local-variables t)
         (visit (lambda ()
                  (let ((buf (find-file-noselect file)))
                    (prog1 (buffer-local-value 'harness-policy-test-mode buf)
                      (kill-buffer buf))))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".dir-locals.el" dir)
            (insert "((nil . ((harness-policy-test-mode . auto))))"))
          (with-temp-file file (insert "notes\n"))
          (should (eq 'auto (funcall visit)))
          (harness-test-with-policy '((harness-policy-test-mode . yolo))
            (should (memq 'harness-policy-test-mode ignored-local-variables))
            (should (eq 'yolo (funcall visit))))
          ;; Released, the directory's value applies again.
          (should-not (memq 'harness-policy-test-mode ignored-local-variables))
          (should (eq 'auto (funcall visit))))
      (delete-directory dir t))))

(ert-deftest harness-policy-takes-options-defined-later ()
  "An option a module defines after the policy is applied takes the
policy value as it is defined, the value it had before it was defined
\(the harness process gets the user's settings so) included."
  (harness-policy-test--forgetting (harness-policy-test-later harness-policy-test-early
                                                              harness-policy-test-hooked)
    (let ((harness-started nil))
      ;; Set before its module defines it, as the forwarded settings are.
      (customize-set-variable 'harness-policy-test-early 3)
      (customize-set-variable 'harness-policy-test-hooked 3)
      (harness-test-with-policy '((harness-policy-test-later . 7) (harness-policy-test-early . 9)
                                  (harness-policy-test-hooked . 9))
        ;; Not defined yet: neither checked nor set, so nothing fails.
        (should (= 3 harness-policy-test-early))
        (eval '(defcustom harness-policy-test-later 1 "Later." :type 'integer :group 'harness) t)
        (eval '(defcustom harness-policy-test-early 1 "Early." :type 'integer :group 'harness) t)
        ;; A `:set' of its own replaces the guard's until the policy is applied again.
        (eval '(defcustom harness-policy-test-hooked 1 "Hooked." :type 'integer :group 'harness
                 :set (lambda (symbol value) (set-default symbol value)))
              t)
        (should (= 7 harness-policy-test-later))
        (should (= 9 harness-policy-test-early))
        (should (= 3 harness-policy-test-hooked))
        ;; Once every module has loaded, the policy is applied again.
        (harness-policy-apply t)
        (should (= 9 harness-policy-test-hooked))
        (dolist (option '(harness-policy-test-later harness-policy-test-early harness-policy-test-hooked))
          (should-error (set option 1))
          (should (eq #'harness-policy--custom-set (get option 'custom-set))))))))

(ert-deftest harness-policy-reports-what-is-no-option-and-skips-it ()
  "A variable this harness does not define as an option is reported
once every module has loaded, once, and left alone."
  (harness-policy-test--forgetting (harness-policy-test--internal)
    (defvar harness-policy-test--internal 1)
    (let ((logged nil))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (let ((harness-log-hook (list (lambda (level message) (push (cons level message) logged)))))
          (harness-test-with-policy '((harness-policy-test-nonesuch . 1) (harness-policy-test--internal . 2)
                                      (harness-policy-test-mode . auto))
            (harness-policy-apply)
            (should-not (cl-find 'warn logged :key #'car))
            (harness-policy-apply t)
            (harness-policy-apply t)
            (let ((warnings (cl-remove 'warn logged :key #'car :test-not #'eq)))
              (should (= 2 (length warnings)))
              (should (cl-some (lambda (w) (string-search "sets harness-policy-test-nonesuch, which is no option"
                                                          (cdr w)))
                               warnings)))
            (should (= 1 harness-policy-test--internal))
            (should (eq 'auto harness-policy-test-mode))))))))

(ert-deftest harness-policy-release-gives-options-their-own-values-back ()
  "An option the policy stops setting is the user's again: the value
they customized, else its default."
  (let ((harness-policy-test-mode 'ask)
        (harness-policy-test-dirs nil)
        (harness-started nil))
    (unwind-protect
        (progn
          (customize-set-variable 'harness-policy-test-mode 'auto)
          (harness-test-with-policy '((harness-policy-test-mode . yolo) (harness-policy-test-dirs "/srv"))
            (should (eq 'yolo harness-policy-test-mode))
            ;; The administrator drops the mode from the policy.
            (harness-test-write-policy policy-file '((harness-policy-test-dirs "/srv")))
            (harness-policy-load)
            (harness-policy-apply)
            (should (eq 'auto harness-policy-test-mode))
            (should-not (memq 'harness-policy-test-mode ignored-local-variables))
            (setq harness-policy-test-mode 'ask)
            (should-error (setq harness-policy-test-dirs nil))
            ;; No policy at all.
            (harness-policy-clear)
            (should-not (harness-policy-entries))
            (should (null harness-policy-test-dirs))
            (setq harness-policy-test-dirs '("/tmp"))))
      (put 'harness-policy-test-mode 'customized-value nil))))

(ert-deftest harness-policy-refuses-changes-made-for-the-user ()
  "Code that changes an option for the user is refused with the reason."
  (harness-test-with-policy '((harness-policy-test-mode . yolo))
    (should-not (harness-policy-refuse 'harness-policy-test-dirs))
    (should (string-search "set by policy"
                           (harness-policy-test--error
                            (lambda () (harness-policy-refuse 'harness-policy-test-mode)))))
    (let ((saved nil))
      (cl-letf (((symbol-function 'harness-call) (lambda (&rest args) (push args saved))))
        (should-error (harness-save-user-option 'harness-policy-test-mode 'auto)))
      (should-not saved))))

(ert-deftest harness-policy-forces-corporate-mode ()
  "Corporate mode is an option like any other: a policy turns it on for good."
  (let ((harness-started nil))
    (harness-test-with-policy '((harness-corporate-mode . t))
      (should (eq t harness-corporate-mode))
      (should (harness-corporate-p))
      (should-error (setq harness-corporate-mode nil))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (let ((harness-started t))
          (setopt harness-corporate-mode nil)))
      (should (harness-corporate-p)))))

;;;; Starting and reloading

(defmacro harness-policy-test--with-harness (policy &rest body)
  "Run BODY in a harness started from a module of its own, under POLICY.
POLICY is the text of the policy file, `policy-file'.  The module
defines `harness-policy-test-level' (an integer, 1 by default) and the
method `policy-demo/level' returning it; `file' is its source.  A
reload loads a stand-in for harness.el, so that it loads the module
alone however often it runs: the real one would define the loader
anew, and every reload after the first would load the whole harness."
  (declare (indent 1))
  `(progn
     (harness-test-reset-bus)
     (let* ((dir (harness-test-temp-dir))
            (moddir (expand-file-name "lisp/modules" dir))
            (file (expand-file-name "harness-policydemo.el" moddir))
            (policy-file (expand-file-name "policy.el" dir))
            (harness-policy-file policy-file)
            (harness--self-file (expand-file-name "harness.el" dir))
            (harness-started nil))
       (make-directory moddir t)
       (with-temp-file harness--self-file
         (insert ";;; A stand-in for harness.el, which the test's reloads load.\n"))
       (with-temp-file file
         (insert ";;; -*- lexical-binding: t -*-\n"
                 "(defcustom harness-policy-test-level 1 \"A level.\" :type 'integer :group 'harness)\n"
                 "(harness-define-module 'policydemo)\n"
                 "(harness-register-method 'policy-demo/level (lambda () harness-policy-test-level))\n"
                 "(provide 'harness-policydemo)\n"))
       (with-temp-file policy-file (insert ,policy))
       (unwind-protect
           (cl-letf (((symbol-function 'harness--path) (lambda (rel) (expand-file-name rel dir))))
             (let ((harness-module-directories '("lisp/modules"))
                   (harness--core-files nil)
                   (harness--library-files nil)
                   (harness-process nil))
               ,@body))
         (harness-policy-clear)
         (remove-variable-watcher 'harness-policy-test-level #'harness-policy--watch)
         (makunbound 'harness-policy-test-level)
         (setplist 'harness-policy-test-level nil)
         (setq features (delq 'harness-policydemo features))
         (delete-directory dir t)))))

(ert-deftest harness-policy-start-applies-the-policy-to-every-module ()
  "`harness-start' reads the policy, and an option a module defines has
the policy's value before the module starts; a reload reads it again."
  (harness-policy-test--with-harness "((harness-policy-test-level . 5))"
    (should (harness-start))
    (should (= 5 (harness-call 'policy-demo/level)))
    (should-error (setq harness-policy-test-level 6))
    ;; A reload reads the file again.
    (with-temp-file policy-file (insert "((harness-policy-test-level . 8))"))
    (should (harness-reload))
    (should (= 8 (harness-call 'policy-demo/level)))
    ;; One that cannot be trusted fails the reload and changes nothing.
    (with-temp-file policy-file (insert "((harness-policy-test-level . \"nine\"))"))
    (should-not (harness-reload))
    (should (= 8 (harness-call 'policy-demo/level)))
    (should (equal '((harness-policy-test-level . 8)) (harness-policy-entries)))
    ;; A policy dropped from the file gives the option back.
    (with-temp-file policy-file (insert ";; Nothing is managed now.\n"))
    (should (harness-reload))
    (should (= 1 (harness-call 'policy-demo/level)))
    (setq harness-policy-test-level 2)))

(ert-deftest harness-policy-start-refuses-a-policy-it-cannot-trust ()
  "The harness does not start under a policy that cannot be trusted."
  (harness-policy-test--with-harness "((harness-policy-test-level . 5)"
    (let ((message (harness-policy-test--error #'harness-start)))
      (should (string-search policy-file message))
      (should (string-search "ends inside a list" message)))
    (should-not harness-started)
    (should-not (harness-method-exists-p 'policy-demo/level))))

(ert-deftest harness-policy-start-refuses-a-value-a-module-type-refuses ()
  "A value that does not fit the type of an option a module defines
stops the start too, once the module has defined it."
  (harness-policy-test--with-harness "((harness-policy-test-level . \"five\"))"
    (let ((message (harness-policy-test--error #'harness-start)))
      (should (string-search "\"five\" is not a valid value for harness-policy-test-level" message)))
    (should-not harness-started)))

;;;; The documentation

(defun harness-policy-test--doc-policies (file)
  "Return the example policies FILE, Markdown of the repository, shows.
They are its elisp blocks written as the policy file, which start with
the comment \";; /etc/harness/policy.el\"."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file harness-test-root))
    (let (out)
      (while (re-search-forward
              "^```elisp\n\\(;; /etc/harness/policy\\.el\\(?:.\\|\n\\)*?\n\\)```$" nil t)
        (push (match-string 1) out))
      (nreverse out))))

(ert-deftest harness-policy-the-documented-examples-are-policies ()
  "The policies docs/policy.md and the README show are ones the harness
takes: every option they set is one its modules define, and every
value fits."
  (harness-test-with-temp-state
    (dolist (m '(store project config tools perms provider sandbox))
      (harness-test-load-module m))
    (dolist (doc '("docs/policy.md" "README.md"))
      (let ((examples (harness-policy-test--doc-policies doc)))
        ;; None found would pass the checks below without checking anything.
        (should examples)
        (dolist (text examples)
          (let ((harness-policy-file (harness-policy-test--file text)))
            (unwind-protect
                (let ((entries (harness-policy-load)))
                  (should (> (length entries) 3))
                  (dolist (entry entries)
                    (should (custom-variable-p (car entry)))
                    (should (harness-policy--type-match-p (car entry) (cdr entry)))))
              (harness-policy-clear)
              (delete-file harness-policy-file))))))))

(provide 'harness-policy-test)
;;; harness-policy-test.el ends here
