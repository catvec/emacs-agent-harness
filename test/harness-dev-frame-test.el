;;; harness-dev-frame-test.el --- No task path raises or focuses a frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; Automation must never steal the user's focus.  These tests audit every
;; production source file a task's path can run -- scripts/dev.sh, the
;; dev-frame helpers and the capture path -- for the calls that raise,
;; focus or delete an Emacs frame.  They also load the dev-frame helpers
;; and check that the frame they make is mapped without focus, refuses
;; focus and is lowered, and that taking a picture lowers it again.

;;; Code:

(require 'harness-test-helpers)

(defvar server-socket-dir)

(defconst harness-dev-frame-test--banned
  '(raise-frame select-frame-set-input-focus x-focus-frame focus-frame
    delete-frame delete-other-frames)
  "Functions a task's path must never call.
They raise a frame, give it the input focus, or delete one.")

(defconst harness-dev-frame-test--banned-regexp
  (concat "\\_<" (regexp-opt (mapcar #'symbol-name harness-dev-frame-test--banned)) "\\_>")
  "Regexp matching a banned call in a shell script.")

(defun harness-dev-frame-test--read-forms (file)
  "Return every top-level form of the Emacs Lisp FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms done)
      (while (not done)
        (condition-case nil
            (push (read (current-buffer)) forms)
          (end-of-file (setq done t))))
      (nreverse forms))))

(defun harness-dev-frame-test--banned-symbols (form)
  "Return the banned symbols found anywhere in FORM."
  (let ((found nil)
        (stack (list form)))
    (while stack
      (let ((x (pop stack)))
        (cond ((symbolp x)
               (when (memq x harness-dev-frame-test--banned)
                 (push x found)))
              ((consp x)
               (push (car x) stack)
               (push (cdr x) stack))
              ((vectorp x)
               (dolist (y (append x nil)) (push y stack))))))
    found))

(defun harness-dev-frame-test--elisp-files ()
  "Return the production Emacs Lisp files a task's path can run.
That is the harness itself, its modules and UI, this repository's
plugins, and the development scripts.  Vendored libraries and the tests
themselves are left out: they are not a task's path."
  (let* ((root harness-test-root)
         (vendor (expand-file-name "lisp/vendor/" root)))
    (cl-remove-if (lambda (file)
                    (or (string-match-p "-test\\.el\\'" file)
                        (string-prefix-p vendor file)))
                  (append
                   (list (expand-file-name "harness.el" root))
                   (directory-files-recursively (expand-file-name "lisp" root) "\\.el\\'")
                   (directory-files-recursively (expand-file-name ".harness" root) "\\.el\\'")
                   (directory-files-recursively (expand-file-name "scripts" root) "\\.el\\'")))))

(defun harness-dev-frame-test--shell-files ()
  "Return the production shell scripts a task's path can run."
  (let ((root harness-test-root))
    (append
     (directory-files (expand-file-name "scripts" root) t "\\.sh\\'")
     (directory-files-recursively (expand-file-name "scripts/analysis" root) "\\.sh\\'"))))

(ert-deftest harness-dev-frame-no-production-path-raises-or-focuses-a-frame ()
  "No production code that runs for a task raises, focuses or deletes a frame."
  (let ((found nil)
        (files (harness-dev-frame-test--elisp-files))
        (scripts (harness-dev-frame-test--shell-files)))
    ;; The audit must cover the paths this task is about.
    (dolist (file '("harness.el" "scripts/harness-dev.el"
                    ".harness/plugins/dev/harness-tools-dev.el"
                    ".harness/plugins/dev/harness-ui-tools-dev.el"))
      (should (member (expand-file-name file harness-test-root) files)))
    (should (member (expand-file-name "scripts/dev.sh" harness-test-root) scripts))
    (dolist (file files)
      (dolist (form (harness-dev-frame-test--read-forms file))
        (dolist (symbol (harness-dev-frame-test--banned-symbols form))
          (push (format "%s: %s" (file-relative-name file harness-test-root) symbol)
                found))))
    (dolist (file scripts)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward harness-dev-frame-test--banned-regexp nil t)
          (push (format "%s: %s" (file-relative-name file harness-test-root)
                        (match-string-no-properties 0))
                found))))
    (should-not (nreverse found))))

(defun harness-dev-frame-test--load-dev-frame ()
  "Load scripts/harness-dev.el without starting a harness.
The file is evaluated without its top-level watch and load calls, so
its frame helpers can be tested in this Emacs."
  (let* ((file (expand-file-name "scripts/harness-dev.el" harness-test-root))
         (forms (cl-remove-if (lambda (form)
                                (and (consp form)
                                     (memq (car form) '(harness-dev-watch-owner
                                                        harness-dev-load))))
                              (harness-dev-frame-test--read-forms file))))
    (let ((load-file-name file)
          (server-socket-dir nil)
          (ring-bell-function ring-bell-function)
          (visible-bell visible-bell)
          (load-prefer-newer load-prefer-newer)
          (native-comp-jit-compilation native-comp-jit-compilation)
          (inhibit-startup-screen inhibit-startup-screen)
          (confirm-kill-processes confirm-kill-processes)
          (debug-on-error debug-on-error)
          (frame-inhibit-implied-resize frame-inhibit-implied-resize)
          (default-frame-alist default-frame-alist))
      (eval (cons 'progn forms) t)
      default-frame-alist)))

(ert-deftest harness-dev-frame-cannot-take-focus ()
  "The dev frame is mapped without focus, refuses it, and is lowered."
  (let ((defaults (harness-dev-frame-test--load-dev-frame)))
    ;; There is no command that would raise or focus it, and every frame
    ;; this daemon makes inherits the same refusal.
    (should-not (fboundp 'harness-dev-focus))
    (should (eq t (alist-get 'no-focus-on-map defaults)))
    (should (eq t (alist-get 'no-accept-focus defaults))))
  (let ((harness-dev-frame nil)
        (parameters nil)
        (lowered nil)
        (banned-called nil))
    (cl-letf (((symbol-function 'make-frame)
               (lambda (params) (setq parameters params) 'the-frame))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (eq frame 'the-frame)))
              ((symbol-function 'lower-frame)
               (lambda (frame) (push frame lowered) frame))
              ((symbol-function 'select-frame) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil))
              ((symbol-function 'raise-frame)
               (lambda (&rest _) (push 'raise-frame banned-called)))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (&rest _) (push 'select-frame-set-input-focus banned-called)))
              ((symbol-function 'x-focus-frame)
               (lambda (&rest _) (push 'x-focus-frame banned-called)))
              ((symbol-function 'delete-frame)
               (lambda (&rest _) (push 'delete-frame banned-called))))
      (should (eq 'the-frame (harness-dev-frame)))
      (should (eq t (alist-get 'no-focus-on-map parameters)))
      (should (eq t (alist-get 'no-accept-focus parameters)))
      (should (equal '(the-frame) lowered))
      (should-not banned-called))))

(ert-deftest harness-dev-shot-lowers-the-frame-before-it-exports-it ()
  "Taking a picture lowers the frame and never raises or focuses it."
  (harness-dev-frame-test--load-dev-frame)
  (let* ((harness-dev-frame 'the-frame)
         (path (make-temp-file "harness-dev-shot-" nil ".png"))
         (order nil)
         (banned-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'frame-live-p) (lambda (&rest _) t))
                  ((symbol-function 'select-frame) (lambda (&rest _) nil))
                  ((symbol-function 'lower-frame)
                   (lambda (frame) (push (list 'lower frame) order) frame))
                  ((symbol-function 'redisplay) (lambda (&rest _) nil))
                  ((symbol-function 'x-export-frames)
                   (lambda (frame type) (push (list 'export frame type) order) "PNG"))
                  ((symbol-function 'raise-frame)
                   (lambda (&rest _) (push 'raise-frame banned-called)))
                  ((symbol-function 'select-frame-set-input-focus)
                   (lambda (&rest _) (push 'select-frame-set-input-focus banned-called)))
                  ((symbol-function 'x-focus-frame)
                   (lambda (&rest _) (push 'x-focus-frame banned-called)))
                  ((symbol-function 'delete-frame)
                   (lambda (&rest _) (push 'delete-frame banned-called))))
          (should (equal path (harness-dev-shot path)))
          (should (equal "PNG" (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))))
          (should (equal '((lower the-frame) (export the-frame png))
                         (nreverse order)))
          (should-not banned-called))
      (delete-file path))))

(provide 'harness-dev-frame-test)
;;; harness-dev-frame-test.el ends here
