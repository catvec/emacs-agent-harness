;;; harness-attachments-test.el --- Tests for @-attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-attachments)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-attachments-test-with-session (&rest body)
  "Run BODY in a temporary project with a live `session'."
  (declare (indent 0))
  `(harness-test-with-temp-session-dir
     (let* ((harness-permission-policy '((:default allow)))
            (harness-providers '((:name mock :kind harness-test :script ((:text "ok")))))
            (harness-models '((:provider mock :id "mock-model")))
            (default-directory (file-name-as-directory harness-test--directory))
            (session (harness-session-create '(:name "attach" :model "mock-model"
                                                       :provider mock))))
       (harness-provider-setup)
       ,@body)))

(defun harness-attachments-test--write (name content)
  "Write CONTENT to NAME in the test directory and return the path."
  (let ((path (expand-file-name name default-directory)))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region content nil path nil 'silent))
    path))

(ert-deftest harness-attachments-test-file-content-is-attached ()
  "An @ reference becomes the file's contents, not a path."
  (harness-attachments-test-with-session
    (harness-attachments-test--write "src/a.el" "(provide 'a)\n")
    (let* ((text (harness-attachments-expand session "look at @src/a.el please"))
           (attachment (car (harness-attachments-resolve session text))))
      (should (string-match-p "<attached path=\"src/a.el\" type=\"file\"" text))
      (should (string-match-p "(provide 'a)" text))
      (should (eq (plist-get attachment :kind) 'file)))))

(ert-deftest harness-attachments-test-directory-is-listed ()
  "A directory reference attaches its listing."
  (harness-attachments-test-with-session
    (harness-attachments-test--write "src/one.el" "")
    (harness-attachments-test--write "src/two.el" "")
    (let ((text (harness-attachments-expand session "see @src/")))
      (should (string-match-p "type=\"directory\"" text))
      (should (string-match-p "one.el" text))
      (should (string-match-p "two.el" text)))))

(ert-deftest harness-attachments-test-unknown-path-stays-text ()
  "An at sign that does not name a file is left alone."
  (harness-attachments-test-with-session
    (should (equal (harness-attachments-expand session "mail me at me@example.com")
                   "mail me at me@example.com"))
    (should (equal (harness-attachments-expand session "no @missing/file here")
                   "no @missing/file here"))))

(ert-deftest harness-attachments-test-dedup ()
  "The same file referenced twice is attached once."
  (harness-attachments-test-with-session
    (harness-attachments-test--write "a.txt" "once")
    (should (= 1 (length (harness-attachments-resolve
                          session "@a.txt and again @a.txt"))))))

(ert-deftest harness-attachments-test-size-limit ()
  "A large file is truncated with a note rather than blowing the budget."
  (harness-attachments-test-with-session
    (let ((harness-attachment-max-bytes 100))
      (harness-attachments-test--write "big.txt" (make-string 5000 ?x))
      (let* ((attachments (harness-attachments-resolve session "@big.txt"))
             (attachment (car attachments)))
        (should attachments)
        (should (< (length (plist-get attachment :content)) 300))
        (should (string-match-p "truncated" (plist-get attachment :content)))))))

(ert-deftest harness-attachments-test-total-limit ()
  "The total attached per message is capped."
  (harness-attachments-test-with-session
    (let ((harness-attachment-max-bytes 1000)
          (harness-attachment-max-total-bytes 1200))
      (harness-attachments-test--write "a.txt" (make-string 1000 ?a))
      (harness-attachments-test--write "b.txt" (make-string 1000 ?b))
      (should (<= (length (harness-attachments-resolve
                           session "@a.txt @b.txt @missing.txt"))
                  2)))))

(ert-deftest harness-attachments-test-follows-working-directory ()
  "Attachment lookup follows the session's working directory."
  (harness-attachments-test-with-session
    (let ((other (make-temp-file "attach-other" t)))
      (unwind-protect
          (progn
            (harness-attachments-test--write "here.txt" "root")
            (write-region "there" nil (expand-file-name "there.txt" other) nil 'silent)
            ;; Not in the session's directory yet.
            (should-not (harness-attachments-resolve session "@there.txt"))
            (harness-session-set-working-directory session other)
            (should (harness-attachments-resolve session "@there.txt"))
            (should-not (harness-attachments-resolve session "@here.txt")))
        (delete-directory other t)))))

(ert-deftest harness-attachments-test-completion ()
  "Completion offers files, fuzzy matched, from the working directory."
  (harness-attachments-test-with-session
    (harness-attachments-test--write "src/harness-ui.el" "")
    (harness-attachments-test--write "src/harness-core.el" "")
    (harness-attachments-test--write "src/other.txt" "")
      (with-temp-buffer
        ;; The completion function reads the session from the buffer.
        (setq-local harness-conversation--session session)
        (insert "@huiel")
        (let* ((completion (harness-attachments-completion-at-point))
               (candidates (nth 2 completion)))
          (should completion)
          (should (member "src/harness-ui.el" candidates))
          (should-not (member "src/other.txt" candidates))))))

(ert-deftest harness-attachments-test-renderer ()
  "The renderer handles content with an attachment and declines without one."
  (should-not (harness-attachments-render "just text"))
  (should (harness-attachments-render
           (concat "text\n\n<attached path=\"a\" type=\"file\" bytes=\"3\">\nxyz\n</attached>"))))

(ert-deftest harness-attachments-test-send-attaches ()
  "Sending a message with an @ reference puts the file in the transcript."
  (harness-attachments-test-with-session
    (harness-attachments-test--write "note.txt" "attached contents")
    (harness-agent-send session "read @note.txt")
    (harness-test-wait-for
     (lambda () (memq (harness-session-status session) '(idle))) 20)
    (let ((first (car (harness-session-messages session))))
      (should (string-match-p "@note.txt" (harness-message-content first)))
      (should (string-match-p "attached contents" (harness-message-content first))))))

(provide 'harness-attachments-test)
;;; harness-attachments-test.el ends here
