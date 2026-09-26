;;; harness-reload-test.el --- Tests for safe reloading -*- lexical-binding: t; -*-

;;; Commentary:

;; DESIGN.md: a bad edit must never brick an existing session.  These tests
;; rewrite a module file and check that a broken version is refused before
;; unloading, that a version which fails at load time is rolled back, and
;; that reloaded modules keep their sessions.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-test-helpers)

(require 'harness)                      ; the entry point, for harness-reload

(defvar harness-reload-test--directory nil
  "Temporary directory holding the mutable fixture copy.")

(defvar harness-reload-test--file nil
  "Path of the mutable fixture copy.")

(defconst harness-reload-test--fixture
  (expand-file-name "fixtures/harness-fixture-reload.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defconst harness-reload-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root of the checkout under test.")

(defun harness-reload-test--reset ()
  "Copy the fixture into a fresh temp directory and put it first on `load-path'."
  (when (harness-module-manifest 'harness-fixture-reload)
    (ignore-errors (harness-module-unload 'harness-fixture-reload)))
  (when harness-reload-test--directory
    (ignore-errors (delete-directory harness-reload-test--directory t)))
  (setq harness-reload-test--directory (make-temp-file "harness-reload-" t)
        harness-reload-test--file (expand-file-name "harness-fixture-reload.el"
                                                    harness-reload-test--directory))
  (copy-file harness-reload-test--fixture harness-reload-test--file t)
  (add-to-list 'load-path harness-reload-test--directory)
  harness-reload-test--file)

(defun harness-reload-test--write (content)
  "Overwrite the fixture copy with CONTENT."
  (with-temp-file harness-reload-test--file
    (insert content)))

(defun harness-reload-test--cleanup ()
  "Remove the temp fixture directory."
  (when (harness-module-manifest 'harness-fixture-reload)
    (ignore-errors (harness-module-unload 'harness-fixture-reload)))
  (setq load-path (remove harness-reload-test--directory load-path))
  (when harness-reload-test--directory
    (ignore-errors (delete-directory harness-reload-test--directory t))
    (setq harness-reload-test--directory nil)))

(ert-deftest harness-reload-validates-good-source ()
  (unwind-protect
      (progn (harness-reload-test--reset)
             (should (harness-module-validate 'harness-fixture-reload)))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-validates-broken-source ()
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (harness-reload-test--write "(require 'harness-core)\n(defun broken (")
        (should-not (harness-module-validate 'harness-fixture-reload)))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-validates-the-source-a-reload-would-read ()
  ;; A package manager build: a stale .elc sits beside the .el it was
  ;; compiled from, and `load-prefer-newer' makes reloads read the edited
  ;; source.  Validation must compile that source, not the stale bytecode.
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (let ((byte-compile-warnings nil))
          (byte-compile-file harness-reload-test--file))
        ;; The freshly built bytecode is normally newer than the source.
        ;; Backdate it explicitly: file timestamps can be too coarse to
        ;; order two operations that happen in the same instant.
        (set-file-times (concat harness-reload-test--file "c")
                        (time-subtract nil 60))
        (let ((load-prefer-newer nil))
          (harness-module-load 'harness-fixture-reload))
        (should (string-suffix-p ".elc"
                                 (harness-module-loaded-file 'harness-fixture-reload)))
        (harness-reload-test--write "(require 'harness-core)\n(defun broken (")
        (let ((load-prefer-newer t))
          (should (equal harness-reload-test--file
                         (harness-module-source-file 'harness-fixture-reload)))
          (should-not (harness-module-validate 'harness-fixture-reload))))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-watches-through-a-symlinked-build-directory ()
  ;; Straight.el symlinks files into its build directory; the watcher must
  ;; resolve them so edits to the checkout trigger a reload.
  (let* ((source (make-temp-file "harness-reload-source-" t))
         (build (make-temp-file "harness-reload-build-" t))
         (source-file (expand-file-name "harness-fixture-reload.el" source))
         (link (expand-file-name "harness-fixture-reload.el" build)))
    (unwind-protect
        (progn
          (when (harness-module-manifest 'harness-fixture-reload)
            (ignore-errors (harness-module-unload 'harness-fixture-reload)))
          (copy-file harness-reload-test--fixture source-file t)
          (make-symbolic-link source-file link)
          (add-to-list 'load-path build)
          (harness-module-load 'harness-fixture-reload)
          (should (equal (file-name-directory (file-truename source-file))
                         (harness--module-source-directory 'harness-fixture-reload)))
          (should (member (file-name-directory (file-truename source-file))
                          (harness--watch-directories))))
      (when (harness-module-manifest 'harness-fixture-reload)
        (ignore-errors (harness-module-unload 'harness-fixture-reload)))
      (setq load-path (remove build load-path))
      (delete-directory source t)
      (delete-directory build t))))

(ert-deftest harness-reload-refuses-broken-file-keeps-running-code ()
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (harness-module-load 'harness-fixture-reload)
        (should (equal (harness-service-call "fixture-reload" 'value) "one"))
        (harness-reload-test--write "(require 'harness-core)\n(defun broken (")
        (should-error (harness-module-reload 'harness-fixture-reload)
                      :type 'harness-module-error)
        ;; The running version is untouched.
        (should (equal (harness-service-call "fixture-reload" 'value) "one"))
        (should (equal (harness-fixture-reload-report) "one")))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-restores-when-load-fails ()
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (harness-module-load 'harness-fixture-reload)
        ;; This file compiles but explodes while loading.
        (harness-reload-test--write
         (concat (with-temp-buffer
                   (insert-file-contents harness-reload-test--fixture)
                   (buffer-string))
                 "\n(error \"boom at load time\")\n"))
        (should-error (harness-module-reload 'harness-fixture-reload)
                      :type 'harness-module-error)
        ;; Definitions and setup were restored.
        (should (harness-service-available-p "fixture-reload" 'value))
        (should (equal (harness-service-call "fixture-reload" 'value) "one"))
        (should (harness-module-set-up-p 'harness-fixture-reload)))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-applies-new-code ()
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (harness-module-load 'harness-fixture-reload)
        (should (equal (harness-service-call "fixture-reload" 'value) "one"))
        (harness-reload-test--write
         (string-replace "\n  \"one\")"
                         "\n  \"two\")"
                         (with-temp-buffer
                           (insert-file-contents harness-reload-test--fixture)
                           (buffer-string))))
        (harness-module-reload 'harness-fixture-reload)
        (should (equal (harness-service-call "fixture-reload" 'value) "two")))
    (harness-reload-test--cleanup)))

(ert-deftest harness-reload-keeps-variable-values ()
  (unwind-protect
      (progn
        (harness-reload-test--reset)
        (harness-module-load 'harness-fixture-reload)
        ;; Values are data, not code: a reload must not reset them.
        (setq harness-fixture-reload-value "customized")
        (harness-module-reload 'harness-fixture-reload)
        (should (equal (harness-service-call "fixture-reload" 'variable) "customized")))
    (harness-reload-test--cleanup)
    (when (boundp 'harness-fixture-reload-value)
      (setq harness-fixture-reload-value "one"))))

(ert-deftest harness-entry-point-finds-its-own-sources ()
  ;; With only the checkout root added to `load-path', `harness.el' must
  ;; find the modules under lisp/ itself: that is what lets a checkout
  ;; work with a single `load-path' entry.
  (let* ((program (concat invocation-directory invocation-name))
         (output (with-temp-buffer
                   (should (equal 0
                                  (call-process
                                   program nil '(t t) nil
                                   "-Q" "--batch" "--eval"
                                   (format (concat "(progn"
                                                   " (add-to-list 'load-path %S)"
                                                   " (require 'harness)"
                                                   " (let ((file (harness-module-file"
                                                   "              (harness-module-manifest 'harness-core))))"
                                                   "   (princ (if (string-prefix-p %S file)"
                                                   "              \"ok\" \"wrong\"))))")
                                           harness-reload-test--root
                                           harness-reload-test--root))))
                   (buffer-string))))
    (should (string-match-p "ok" output))))

(ert-deftest harness-entry-point-loads-the-worktree-service ()
  ;; `harness-ui-worktrees' talks to the worktree service; the default
  ;; bundle must load it or the manager opens empty.
  (should (memq 'harness-worktree harness-modules)))

(ert-deftest harness-reload-load-order-is-dependency-first ()
  (let ((order (harness-module-load-order
                '(harness-agent harness-tools harness-core))))
    (should (< (cl-position 'harness-core order)
               (cl-position 'harness-tools order)))
    (should (< (cl-position 'harness-tools order)
               (cl-position 'harness-agent order)))))

(ert-deftest harness-reload-preserves-open-sessions ()
  (let* ((harness-session-storage-directory (make-temp-file "harness-reload-sessions-" t))
         (directory (make-temp-file "harness-reload-project-" t)))
    (unwind-protect
        (progn
          (harness-module-load 'harness-session)
          (clrhash harness-session--active)
          (let* ((info (harness-service-call "session" 'create :cwd directory :title "survivor"))
                 (session-id (plist-get info :sessionId)))
            (harness-service-call "session" 'append
                                  :session-id session-id
                                  :entry (list :sessionUpdate "user_message_chunk"
                                               :content (list :type "text" :text "keep me")))
            (harness-module-reload 'harness-session)
            (let ((session (harness-session-active session-id)))
              (should session)
              (should (equal (harness-session-title session) "survivor"))
              (let ((entries (harness-session-ensure-entries session)))
                (harness-test-settle entries 5)
                (let* ((loaded (harness-session-entries session))
                       (entry (aref loaded 0)))
                  (should (= (length loaded) 1))
                  (should (equal (plist-get (plist-get entry :content) :text)
                                 "keep me")))))))
      (delete-directory directory t))))

(ert-deftest harness-reload-reloads-everything-and-notifies ()
  (let ((harness-modules '(harness-config harness-tools harness-session harness-agent))
        (events nil)
        (directory (make-temp-file "harness-reload-all-" t)))
    (harness-on 'harness-reloaded (lambda (payload) (push payload events)))
    (unwind-protect
        (progn
          (harness-load)
          (should (harness-reload))
          (should (> (length events) 3))
          (should (harness-module-set-up-p 'harness-agent))
          (should (harness-module-set-up-p 'harness-session)))
      (delete-directory directory t))))

(ert-deftest harness-reload-auto-reload-mode-watches-sources ()
  (unwind-protect
      (progn
        (harness-auto-reload-mode 1)
        (should (> (length harness--auto-reload-watches) 0))
        (harness-auto-reload-mode -1)
        (should-not harness--auto-reload-watches))
    (when harness-auto-reload-mode (harness-auto-reload-mode -1))))


;;; harness-reload-test.el ends here

(require 'harness-ui)
(require 'harness-ui-chat)
(harness-module-load 'harness-ui)
(harness-module-load 'harness-ui-chat)

(ert-deftest harness-reload-keeps-ui-handlers-valid ()
  "Reloading must leave UI event handlers as working functions."
  (harness-module-load 'harness-ui-chat)
  (harness-reload)
  (let* ((handlers (gethash 'harness-ui-update harness-core--event-handlers))
         (handler (car handlers)))
    (should (= (length handlers) 1))
    ;; The handler is the symbol, so the newest definition is called.
    (should (eq (harness-event-handler-function handler)
                'harness-ui-chat--on-update)))
  ;; And a session update actually renders after the reload.
  (let ((buffer nil))
    (unwind-protect
        (progn
          (setq buffer (harness-ui-chat--buffer "reload-ui"))
          (harness-emit 'harness-ui-update
                        :session-id "reload-ui"
                        :update (list :sessionUpdate "agent_message_chunk"
                                      :messageId "r1" :final t
                                      :content (list :type "text" :text "AFTER-RELOAD")))
          (harness-test-wait-for
           (lambda ()
             (with-current-buffer buffer
               (string-match-p "AFTER-RELOAD"
                               (buffer-substring-no-properties (point-min) (point-max)))))
           5)
          (with-current-buffer buffer
            (should (string-match-p "AFTER-RELOAD"
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (remhash "reload-ui" harness-ui-chat--buffers))))

(provide 'harness-reload-test)
