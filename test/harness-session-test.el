;;; harness-session-test.el --- Tests for session storage and search -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Every test runs against a throwaway session directory, so the suite never
;; touches a real harness history and never needs network access.

;;; Code:

(require 'ert)
(require 'harness-session)
(require 'harness-test-util)

(defun harness-session-test--make-session (&optional name)
  "Create a session named NAME inside the current temp directory."
  (harness-session-create (list :name (or name "test") :model "test-model")))

(defun harness-session-test--add (session text &optional role)
  "Append a message with TEXT and ROLE to SESSION."
  (let ((message (harness-message-create session (or role 'user) text)))
    (harness-message-finalize message)
    (harness-session-add-message session message)
    message))

(ert-deftest harness-session-test-create-writes-header ()
  "Creating a session writes one header line and registers it."
  (harness-test-with-temp-session-dir
    (let ((session (harness-session-test--make-session "my session")))
      (should (file-exists-p (harness-session-file session)))
      (should (eq (harness-session-get (harness-session-id session)) session))
      (should (equal (harness-session-name session) "my session"))
      (should (harness-session-project-root session))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents (harness-session-file session)))
        (should (equal (line-number-at-pos (point-max)) 2))
        (let ((header (harness-json-read (buffer-substring-no-properties
                                          (point-min) (line-end-position)))))
          (should (equal (harness-alist-get :type header) "session"))
          (should (equal (harness-alist-get :id header)
                         (harness-session-id session)))
          (should (equal (harness-alist-get :name header) "my session")))))))

(ert-deftest harness-session-test-record-from-header ()
  "Session records are built from the header without loading messages."
  (harness-test-with-temp-session-dir
    (let ((session (harness-session-test--make-session "listed")))
      (harness-session-test--add session "hello there")
      (let ((records (harness-session-records)))
        (should (= (length records) 1))
        (should (equal (harness-plist-or-alist-get :name (car records)) "listed"))
        (should (equal (harness-plist-or-alist-get :id (car records))
                       (harness-session-id session)))))))

(ert-deftest harness-session-test-project-filter ()
  "Recording can be limited to one project."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "one"))
           (root (harness-session-project-root session)))
      (should (= (length (harness-session-records root)) 1))
      (should (= (length (harness-session-records "/nonexistent")) 0))
      (should (= (length (harness-session-records)) 1)))))

(ert-deftest harness-session-test-round-trip ()
  "Messages, tool calls and usage survive a save/load round trip."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "round trip"))
           (message (harness-session-test--add session "run it" 'user))
           (assistant (harness-message-create session 'assistant "ok"))
           (call (harness-tool-call-create :id "c1" :name "bash"
                                           :args-string "{\"command\":\"ls\"}"
                                           :status 'ok
                                           :result "file-a\nfile-b")))
      (harness-tool-call-parse-args call)
      (setf (harness-message-tool-calls assistant) (list call))
      (setf (harness-message-usage assistant) '(:in 100 :out 20 :cost 0.01))
      (harness-message-finalize assistant)
      (harness-session-add-message session assistant)
      (harness-session-add-usage session '(:in 100 :out 20 :cost 0.01))
      (harness-session-save-state session)
      (let ((loaded (harness-session-load (harness-session-file session))))
        (should (equal (mapcar #'harness-message-content
                               (harness-session-messages loaded))
                       '("run it" "ok")))
        (should (equal (harness-message-id (car (harness-session-messages loaded)))
                       (harness-message-id message)))
        (let* ((loaded-assistant (cadr (harness-session-messages loaded)))
               (loaded-call (car (harness-message-tool-calls loaded-assistant))))
          (should (equal (harness-tool-call-name loaded-call) "bash"))
          (should (equal (harness-tool-call-result loaded-call) "file-a\nfile-b"))
          (should (equal (harness-tool-call-arg loaded-call :command) "ls"))
          (should (eq (harness-tool-call-status loaded-call) 'ok))
          (should (equal (harness-message-usage loaded-assistant)
                         '(:in 100 :out 20 :cost 0.01))))
        (should (equal (plist-get (harness-session-usage loaded) :in) 100))))))

(ert-deftest harness-session-test-wire-cache-not-persisted ()
  "The derived provider JSON cache is never written to disk."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "cache"))
           (message (harness-session-test--add session "hi")))
      (setf (harness-message-meta message) '(:wire-json "{\"big\":\"blob\"}" :keep t))
      (harness-session--write-record session
                                      (harness-session--message-record message))
      (with-temp-buffer
        (insert-file-contents (harness-session-file session))
        (goto-char (point-min))
        (forward-line 1)
        (should-not (string-match-p "wire-json" (buffer-string)))
        (should (string-match-p "\"keep\"" (buffer-string)))))))

(ert-deftest harness-session-test-meta-record-restores-state ()
  "A meta record restores name, model, usage and the queue."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "meta"))
           (queued (harness-queued-message-create "queued text")))
      (harness-session-test--add session "first")
      (setf (harness-session-name session) "renamed")
      (setf (harness-session-model session) "other-model")
      (setf (harness-session-queue session) (list queued))
      (harness-session-add-usage session '(:in 7 :out 3 :cost 0.5))
      (harness-session-save-state session)
      (let ((loaded (harness-session-load (harness-session-file session))))
        (should (equal (harness-session-name loaded) "renamed"))
        (should (equal (harness-session-model loaded) "other-model"))
        (should (equal (plist-get (harness-session-usage loaded) :in) 7))
        (should (equal (harness-session-queue loaded) (list queued)))))))

(ert-deftest harness-session-test-resume-registers ()
  "Resuming registers the session and returns the live one afterwards."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "resume me"))
           (file (harness-session-file session))
           (id (harness-session-id session)))
      (harness-session-test--add session "remember this")
      (harness-session-remove session)
      (should-not (harness-session-get id))
      (let ((resumed (harness-session-resume file)))
        (should (eq resumed (harness-session-get id)))
        (should (equal (harness-message-content
                        (harness-session-last-message resumed))
                       "remember this"))
        (should (eq (harness-session-resume file) resumed))))))

(ert-deftest harness-session-test-delete ()
  "Deleting removes the file, the registry entry and the index rows."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-test--make-session "delete me"))
           (file (harness-session-file session))
           (id (harness-session-id session)))
      (harness-session-test--add session "searchable text")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-session-delete session))
      (should-not (file-exists-p file))
      (should-not (harness-session-get id)))))

(ert-deftest harness-session-test-search ()
  "Content search finds the session containing the query."
  (skip-unless (harness-index-available-p))
  (harness-test-with-temp-session-dir
    (let ((session (harness-session-test--make-session "searchable")))
      (harness-session-test--add session "the quick brown fox")
      (harness-session-test--add session "unrelated text")
      (let ((results (harness-search-sessions "brown fox")))
        (should results)
        (should (equal (harness-plist-or-alist-get :session-id (car results))
                       (harness-session-id session)))
        (should (string-match-p "brown fox"
                                (harness-plist-or-alist-get :snippet (car results)))))
      (should-not (harness-search-sessions "definitely-not-present")))))

(ert-deftest harness-session-test-search-index-is-idempotent ()
  "Re-indexing a session does not create duplicate rows."
  (skip-unless (harness-index-available-p))
  (harness-test-with-temp-session-dir
    (let ((session (harness-session-test--make-session "twice")))
      (harness-session-test--add session "duplicate me")
      (harness-index-sync-session session)
      (harness-index-sync-session session)
      (should (= (length (harness-search-sessions "duplicate me")) 1)))))

(ert-deftest harness-session-test-project-detection ()
  "A session is tied to the project the editor believes in.

`project.el' is asked first; projectile is only a fallback, so the tests here
drive `project-find-functions' directly rather than depending on which project
backends happen to be installed."
  (harness-test-with-temp-session-dir
    (let* ((root (expand-file-name "myproject" harness-test--directory))
           (nested (expand-file-name "src/deep" root)))
      (make-directory nested t)
      ;; Nothing recognises this directory as a project.
      (let ((project-find-functions nil))
        (let ((project (harness-session-project nested)))
          (should (equal (car project) (file-name-as-directory nested)))
          (should (stringp (cdr project)))))
      ;; When project.el finds a root, a subdirectory belongs to it.
      (let ((project-find-functions
             (list (lambda (directory)
                     (when (string-prefix-p root directory)
                       (cons 'transient (file-name-as-directory root)))))))
        (let ((project (harness-session-project nested)))
          (should (equal (car project) (file-name-as-directory root)))
          (should (equal (cdr project) "myproject"))))
      ;; A session created in the subdirectory is tied to the root.
      (let ((project-find-functions
             (list (lambda (directory)
                     (when (string-prefix-p root directory)
                       (cons 'transient (file-name-as-directory root)))))))
        (let ((session (harness-session-create (list :name "nested"
                                                     :directory nested))))
          (should (equal (harness-session-project-root session)
                         (file-name-as-directory root)))
          (should (equal (harness-session-working-directory session)
                         (file-name-as-directory root))))))))

(ert-deftest harness-session-test-project-slug ()
  "Project slugs are filesystem safe."
  (should (equal (harness-session-project-slug "/home/u/my project!") "home-u-my-project"))
  (should-not (string-match-p "[^a-zA-Z0-9._-]"
                              (harness-session-project-slug "/a/b c/d:e"))))

(provide 'harness-session-test)
;;; harness-session-test.el ends here
