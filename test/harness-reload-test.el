;;; harness-reload-test.el --- Tests for safe reloading -*- lexical-binding: t; -*-

;;; Commentary:

;; DESIGN.md: a bad edit must never brick an existing session.  These tests
;; rewrite a module file and check that a broken version is refused before
;; unloading, that a version which fails at load time is rolled back, and
;; that reloaded modules keep their sessions.

;;; Code:

(require 'ert)
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

(provide 'harness-reload-test)
;;; harness-reload-test.el ends here
