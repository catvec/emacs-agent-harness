;;; harness-tools-emacs-test.el --- Tests for the Emacs tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--clients)
(defvar harness-acp--server-enabled)
(declare-function harness-acp-drop-client "harness-acp" (client))

(defun harness-tools-emacs-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-emacs-test--setup ()
  "Load the tools modules, allow everything, and leave one UI client.
A request for the user's Emacs goes to the most recently active Emacs a
client lent, and a chore request reaches every client, so clients
earlier tests connected are dropped first: each test then asks the
Emacs it connected itself, once."
  (harness-test-reset-bus)
  (let ((harness-acp--server-enabled nil))
    (harness-test-load-module 'acp))
  (dolist (client (copy-sequence harness-acp--clients))
    (harness-acp-drop-client client))
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

(ert-deftest harness-tools-emacs-windows ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let* ((r (harness-tools-emacs-test--call "emacs_windows"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "FRAME" c))
      (should (string-search "SEL" c))
      ;; The one window of the batch frame shows the selected buffer.
      (should (string-search (buffer-name (window-buffer (selected-window))) c))
      (should (string-match-p "^1 +\\*" c))
      (should (string-search "(1 window)" c)))))

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

(ert-deftest harness-tools-emacs-open-buffer ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (save-window-excursion
      (let ((buf (generate-new-buffer "harness-test-open-buffer-A")))
        (unwind-protect
            (progn
              (with-current-buffer buf (insert "one\ntwo\nthree\n"))
              (let* ((r (harness-tools-emacs-test--call "emacs_open" :name "harness-test-open-buffer-A" :line 2))
                     (c (plist-get r :content)))
                (should-not (plist-get r :is-error))
                (should (string-search "Showed harness-test-open-buffer-A" c))
                (should (string-search "at line 2" c))
                (should (eq buf (window-buffer (selected-window))))
                (should (= 2 (with-current-buffer buf (line-number-at-pos)))))
              ;; Without a line the buffer is shown where point already is.
              (with-current-buffer buf (goto-char (point-max)))
              (should (string-search "Showed" (plist-get (harness-tools-emacs-test--call
                                                          "emacs_open" :name "harness-test-open-buffer-A")
                                                         :content)))
              (should (= (with-current-buffer buf (point-max))
                         (with-current-buffer buf (point))))
              ;; An unknown name with no file is an error that names both.
              (let ((r (harness-tools-emacs-test--call "emacs_open" :name "harness-test-no-such-buffer-xyz")))
                (should (plist-get r :is-error))
                (should (string-search "No buffer named" (plist-get r :content))))
              (should (plist-get (harness-tools-emacs-test--call "emacs_open") :is-error))
              (should (equal "Open buffer: x.el" (harness-tool-title "emacs_open" '(:name "x.el"))))
              (should (equal '("x.el") (funcall (harness-tool-paths-fn (harness-tool-get "emacs_open")) '(:name "x.el")))))
          (kill-buffer buf))))))

(ert-deftest harness-tools-emacs-open-file ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (save-window-excursion
      (let* ((root (harness-test-temp-dir))
             (file (expand-file-name "open-me.txt" root))
             (rel (expand-file-name "relative.txt" root)))
        (unwind-protect
            (progn
              (write-region "alpha\nbeta\ngamma\n" nil file)
              (write-region "relative\n" nil rel)
              (let* ((r (harness-tools-emacs-test--call "emacs_open" :name file :line 3))
                     (c (plist-get r :content)))
                (should-not (plist-get r :is-error))
                (should (string-search "Visited open-me.txt" c))
                (should (string-search "at line 3" c))
                (let ((buf (find-buffer-visiting file)))
                  (should buf)
                  (should (eq buf (window-buffer (selected-window))))
                  (should (= 3 (with-current-buffer buf (line-number-at-pos))))))
              ;; A second call finds the buffer and says it showed it.
              (should (string-search "Showed open-me.txt"
                                     (plist-get (harness-tools-emacs-test--call "emacs_open" :name file) :content)))
              ;; A relative name is resolved against the session's cwd.
              (let ((default-directory root))
                (should (string-search "Visited relative.txt"
                                       (plist-get (harness-tools-emacs-test--call "emacs_open" :name "relative.txt") :content))))
              ;; Refusals: a directory, a file on another host, a missing
              ;; file and a file over the open limit.  The limit is bound
              ;; here so the test does not need a large file.
              (let ((r (harness-tools-emacs-test--call "emacs_open" :name root)))
                (should (plist-get r :is-error))
                (should (string-search "is a directory" (plist-get r :content))))
              (let ((r (harness-tools-emacs-test--call "emacs_open" :name "/ssh:example.invalid:/tmp/x")))
                (should (plist-get r :is-error))
                (should (string-search "another host" (plist-get r :content))))
              (let ((r (harness-tools-emacs-test--call "emacs_open" :name (expand-file-name "gone.txt" root))))
                (should (plist-get r :is-error))
                (should (string-search "no file at" (plist-get r :content))))
              (let ((harness-tools-emacs--open-max-bytes 4))
                (let ((r (harness-tools-emacs-test--call "emacs_open" :name file)))
                  (should (plist-get r :is-error))
                  (should (string-search "over the" (plist-get r :content))))))
          (dolist (f (list file rel))
            (let ((buf (find-buffer-visiting f))) (when buf (kill-buffer buf))))
          (delete-directory root t))))))

(ert-deftest harness-tools-emacs-insert ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let ((buf (generate-new-buffer "harness-test-insert-A")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "one\ntwo\n") (goto-char 2))
            (let ((r (harness-tools-emacs-test--call "emacs_insert" :name "harness-test-insert-A" :text "X")))
              (should-not (plist-get r :is-error))
              (should (string-search "Inserted 1 characters at point" (plist-get r :content)))
              (should (equal "oXne\ntwo\n" (with-current-buffer buf (buffer-string)))))
            (should (string-search "at the end"
                                   (plist-get (harness-tools-emacs-test--call
                                               "emacs_insert" :name "harness-test-insert-A"
                                               :text "!" :position "end")
                                              :content)))
            (should (string-search "at the start"
                                   (plist-get (harness-tools-emacs-test--call
                                               "emacs_insert" :name "harness-test-insert-A"
                                               :text ">>" :position "start")
                                              :content)))
            (should (equal ">>oXne\ntwo\n!" (with-current-buffer buf (buffer-string))))
            ;; Read-only buffers and system buffers are refused.
            (with-current-buffer buf (setq buffer-read-only t))
            (let ((r (harness-tools-emacs-test--call "emacs_insert" :name "harness-test-insert-A" :text "z")))
              (should (plist-get r :is-error))
              (should (string-search "read-only" (plist-get r :content))))
            (with-current-buffer buf (setq buffer-read-only nil))
            (let ((r (harness-tools-emacs-test--call "emacs_insert" :name "*Messages*" :text "x")))
              (should (plist-get r :is-error))
              (should (string-search "system buffer" (plist-get r :content))))
            (let ((r (harness-tools-emacs-test--call "emacs_insert" :name "harness-test-insert-A")))
              (should (plist-get r :is-error))
              (should (string-search "Missing text" (plist-get r :content))))
            (let ((r (harness-tools-emacs-test--call "emacs_insert" :name "harness-test-insert-A"
                                                     :text "x" :position "middle")))
              (should (plist-get r :is-error))
              (should (string-search "position must be" (plist-get r :content))))
            (should (equal "Insert text: harness-test-insert-A"
                           (harness-tool-title "emacs_insert" '(:name "harness-test-insert-A" :text "x")))))
        (kill-buffer buf)))))

(ert-deftest harness-tools-emacs-save-buffer ()
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let* ((root (harness-test-temp-dir))
           (file (expand-file-name "save-me.txt" root)))
      (unwind-protect
          (let ((buf (find-file-noselect file t)))
            (unwind-protect
                (progn
                  (with-current-buffer buf (insert "hello\n") (set-buffer-modified-p t))
                  (let ((r (harness-tools-emacs-test--call "emacs_save_buffer" :name (buffer-name buf))))
                    (should-not (plist-get r :is-error))
                    (should (string-search "Saved save-me.txt" (plist-get r :content)))
                    (should (equal "hello\n" (with-temp-buffer (insert-file-contents file) (buffer-string))))
                    (should-not (buffer-modified-p buf)))
                  ;; A buffer with no file is refused with a pointer to write_file.
                  (let ((nb (generate-new-buffer "harness-test-no-file")))
                    (unwind-protect
                        (let ((r (harness-tools-emacs-test--call "emacs_save_buffer" :name "harness-test-no-file")))
                          (should (plist-get r :is-error))
                          (should (string-search "not visiting a file" (plist-get r :content)))
                          (should (string-search "write_file" (plist-get r :content))))
                      (kill-buffer nb)))
                  ;; A file that changed on disk is refused, not overwritten.
                  (with-current-buffer buf (insert "more\n") (set-buffer-modified-p t))
                  (cl-letf (((symbol-function 'verify-visited-file-modtime) (lambda (&optional _buf) nil)))
                    (let ((r (harness-tools-emacs-test--call "emacs_save_buffer" :name (buffer-name buf))))
                      (should (plist-get r :is-error))
                      (should (string-search "changed on disk" (plist-get r :content)))))
                  ;; A question during the save (here: the directory does
                  ;; not exist) fails the call instead of waiting for an
                  ;; answer nobody can give.
                  (let* ((missing (expand-file-name "harness-test-no-dir/x.txt" root))
                         (nb (find-file-noselect missing t)))
                    (unwind-protect
                        (progn
                          (with-current-buffer nb (setq buffer-read-only nil) (insert "x") (set-buffer-modified-p t))
                          (let ((r (harness-tools-emacs-test--call "emacs_save_buffer" :name (buffer-name nb))))
                            (should (plist-get r :is-error))
                            (should (string-search "Save stopped at a question" (plist-get r :content)))))
                      (kill-buffer nb)))
                  (should (eq 'write (harness-tool-kind (harness-tool-get "emacs_save_buffer")))))
              (kill-buffer buf)))
        (delete-directory root t)))))

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
  (dolist (name '("emacs_buffers" "emacs_windows" "emacs_buffer" "emacs_open"
                  "emacs_describe" "emacs_messages"))
    (let ((tool (harness-tool-get name)))
      (should tool)
      (should (eq 'read (harness-tool-kind tool)))
      (should (harness-tool-coalescable tool))))
  (dolist (name '("emacs_insert" "emacs_save_buffer"))
    (let ((tool (harness-tool-get name)))
      (should tool)
      (should (eq 'write (harness-tool-kind tool)))
      (should-not (harness-tool-coalescable tool)))))

(provide 'harness-tools-emacs-test)
;;; harness-tools-emacs-test.el ends here
