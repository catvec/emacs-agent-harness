;;; harness-tools-emacs-test.el --- Tests for the Emacs introspection tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-emacs-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-emacs-test--setup ()
  "Load the tools modules and allow everything."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-tools-emacs-test--allow 10))

(defun harness-tools-emacs-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input))))

(ert-deftest harness-tools-emacs-buffers ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let ((buf (generate-new-buffer "harness-test-buffer-A"))
          (hidden (generate-new-buffer " harness-test-hidden")))
      (unwind-protect
          (progn
            (with-current-buffer buf (emacs-lisp-mode) (insert "(x)"))
            (let* ((r (harness-tools-emacs-test--call "emacs_buffers"))
                   (c (plist-get r :content)))
              (should-not (plist-get r :is-error))
              (should (string-match-p "harness-test-buffer-A +emacs-lisp-mode +\\* +3 B" c))
              (should-not (string-search "harness-test-hidden" c)))
            (should (string-search "harness-test-hidden"
                                   (plist-get (harness-tools-emacs-test--call "emacs_buffers" :all t) :content)))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_buffers" :filter "buffer-A") :content)))
              (should (string-search "harness-test-buffer-A" c))
              (should (string-search "(1 buffer)" c)))
            (should (string-search "No buffers" (plist-get (harness-tools-emacs-test--call "emacs_buffers" :filter "zzz-none") :content))))
        (kill-buffer buf) (kill-buffer hidden)))))

(ert-deftest harness-tools-emacs-buffer-text ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let ((buf (generate-new-buffer "harness-test-buffer-B")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "one\ntwo\nthree\nfour\n"))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_buffer" :name "harness-test-buffer-B") :content)))
              (should (string-prefix-p "     1\tone\n     2\ttwo\n     3\tthree\n     4\tfour" c))
              (should (string-search "lines 1-4 of 4" c)))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_buffer" :name "harness-test-buffer-B" :offset 2 :limit 2) :content)))
              (should (string-prefix-p "     2\ttwo\n     3\tthree\n" c))
              (should (string-search "lines 2-3 of 4" c)))
            ;; Narrowing does not hide text and point is untouched.
            (with-current-buffer buf (goto-char 3) (narrow-to-region 1 4))
            (should (string-search "four" (plist-get (harness-tools-emacs-test--call "emacs_buffer" :name "harness-test-buffer-B") :content)))
            (should (= 3 (with-current-buffer buf (point))))
            (should (plist-get (harness-tools-emacs-test--call "emacs_buffer" :name "harness-test-buffer-B" :offset 99) :is-error))
            (let ((r (harness-tools-emacs-test--call "emacs_buffer" :name "no-such-buffer-xyz")))
              (should (plist-get r :is-error))
              (should (string-search "emacs_buffers" (plist-get r :content))))
            (should (equal "Read buffer: x:5-9" (harness-tool-title "emacs_buffer" '(:name "x" :offset 5 :limit 5)))))
        (kill-buffer buf)))))

(ert-deftest harness-tools-emacs-describe ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "car") :content)))
      (should (string-match-p "\\`primitive: (car " c))
      (should (string-search "Return the car" c)))
    (let ((fill-column 71))
      (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "fill-column") :content)))
        (should (string-search "user option: fill-column" c))
        (should (string-search "value: 71" c))
        (should (string-search "Column beyond which" c))))
    ;; A symbol that is both.
    (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-log-level") :content)))
      (should (string-search "value: info" c)))
    ;; Long values are truncated.
    (defvar harness-test--long-value (make-string 2000 ?y))
    (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-test--long-value") :content)))
      (should (< (length c) 800))
      (should (string-search "…" c)))
    ;; Macros and commands are labelled.
    (should (string-prefix-p "macro: (when " (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "when") :content)))
    (should (string-prefix-p "command: (find-file " (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "find-file") :content)))
    (let ((r (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-no-such-symbol-qqq")))
      (should (plist-get r :is-error))
      (should (string-search "No symbol" (plist-get r :content))))
    (should (plist-get (harness-tools-emacs-test--call "emacs_describe") :is-error))))

(ert-deftest harness-tools-emacs-messages ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let ((inhibit-message t) (message-log-max t))
      (dotimes (i 5) (message "harness-test-marker-%d" i)))
    (let* ((r (harness-tools-emacs-test--call "emacs_messages" :count 3))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "harness-test-marker-4" c))
      (should (string-search "harness-test-marker-2" c))
      (should-not (string-search "harness-test-marker-1" c))
      (should (= 3 (length (split-string c "\n")))))
    (should (string-search "harness-test-marker-0" (plist-get (harness-tools-emacs-test--call "emacs_messages") :content)))))

(ert-deftest harness-tools-emacs-kinds ()
  (harness-tools-emacs-test--setup)
  (dolist (name '("emacs_buffers" "emacs_buffer" "emacs_describe" "emacs_messages"))
    (let ((tool (harness-tool-get name)))
      (should tool)
      (should (eq 'read (harness-tool-kind tool)))
      (should (harness-tool-coalescable tool)))))

(provide 'harness-tools-emacs-test)
;;; harness-tools-emacs-test.el ends here
