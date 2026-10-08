;;; harness-tools-emacs-test.el --- Tests for the Emacs tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(require 'trace)
(require 'find-func)

(defvar harness-acp--clients)
(defvar harness-acp--server-enabled)
(defvar harness-tools-max-output-chars)
(defvar harness-test--option)
(defvar harness-test-traced-var)
(declare-function harness-acp-drop-client "harness-acp" (client))
(declare-function harness-emacs-endpoint-handle "harness-emacs-endpoint" (name params))
(declare-function harness-provider-demo--script "harness-provider-demo" (request))
(declare-function harness-test-traced "harness-tools-emacs-test")
(declare-function harness-test-trace-caller "harness-tools-emacs-test")

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

(ert-deftest harness-tools-emacs-describe-debugging ()
  "emacs_describe says what debugging needs, as describe-function and
describe-variable do: how a function is defined and where, its keys,
aliases and advice; a variable's value in a buffer, where it is
buffer-local, whether it left its standard value, and its watchers."
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (eval '(progn
             (defun harness-test--described (x) "Return X." x)
             (defalias 'harness-test--described-alias #'harness-test--described)
             (defun harness-test--watcher (&rest _) nil)
             (defvar harness-test--watched 1 "A variable a test watches.")
             (defcustom harness-test--option 1 "An option a test changes."
               :type 'integer :group 'harness))
          t)
    (let ((buf (generate-new-buffer "harness-test-describe-local")))
      (unwind-protect
          (progn
            ;; A command: how it is defined, where, and its keys.
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "find-file") :content)))
              (should (string-match-p "^\\(native\\|byte\\)-compiled command in .*/files\\.elc?$" c))
              (should (string-match-p "^keys: .*C-x C-f" c))
              ;; The usage line the docstring ends with is the signature's.
              (should (string-prefix-p "command: (find-file filename &optional wildcards)\n" c))
              (should-not (string-search "(fn FILENAME" c)))
            (should (string-search "\nbuilt-in function in C source\n"
                                   (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "car") :content)))
            ;; Advice, also on what an alias names.
            (advice-add 'harness-test--described :around (lambda (f &rest args) (apply f args))
                        '((name . harness-test-advice)))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-test--described-alias")
                                :content)))
              (should (string-prefix-p "function: (harness-test--described-alias x)\ninterpreted function\n" c))
              (should (string-search "\nalias for: harness-test--described\n" c))
              (should (string-search "\nadvice: :around harness-test-advice\n" c)))
            ;; A buffer-local value, in the buffer named, and the global one.
            (with-current-buffer buf (setq-local fill-column 33))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "fill-column"
                                                                :buffer "harness-test-describe-local")
                                :content)))
              (should (string-search "\nvalue: 33 (local to harness-test-describe-local)\n" c))
              (should (string-match-p (format "^global value: %d$" (default-value 'fill-column)) c))
              (should (string-match-p "^buffer-local in [0-9]+ buffers?: .*harness-test-describe-local" c))
              (should (string-search "\nin C source\n" c)))
            (let ((r (harness-tools-emacs-test--call "emacs_describe" :symbol "fill-column"
                                                     :buffer "harness-test-no-such-buffer")))
              (should (plist-get r :is-error))
              (should (string-search "No buffer named \"harness-test-no-such-buffer\"" (plist-get r :content))))
            ;; Watchers, and an option changed from its standard value.
            (add-variable-watcher 'harness-test--watched #'harness-test--watcher)
            (should (string-search "\nwatched by: harness-test--watcher\n"
                                   (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-test--watched")
                                              :content)))
            (setq harness-test--option 2)
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-test--option") :content)))
              (should (string-prefix-p "user option: harness-test--option\nvalue: 2\n" c))
              (should (string-search "\nchanged from its standard value: 1\n" c)))
            (should (equal "Describe symbol: fill-column in b"
                           (harness-tool-title "emacs_describe" '(:symbol "fill-column" :buffer "b")))))
        (advice-remove 'harness-test--described 'harness-test-advice)
        (remove-variable-watcher 'harness-test--watched #'harness-test--watcher)
        (kill-buffer buf)))))

(ert-deftest harness-tools-emacs-find-definition ()
  "emacs_find_definition gives where a definition is and its text, read
from the source without visiting it, or from the buffer visiting it."
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let* ((root (harness-test-temp-dir))
           (file (expand-file-name "harness-test-defs.el" root)))
      (unwind-protect
          (progn
            (write-region
             (concat ";;; harness-test-defs.el --- Definitions to find  -*- lexical-binding: t; -*-\n"
                     "\n"
                     "(defvar harness-test-defs-var 3\n"
                     "  \"A variable to find.\")\n"
                     "\n"
                     "(defun harness-test-defs-fn (a)\n"
                     "  \"Return A in a list.\"\n"
                     "  ;; A comment with a stray paren (\n"
                     "  (list a))\n"
                     "\n"
                     "(defun harness-test-defs-long ()\n"
                     (mapconcat (lambda (n) (format "  (ignore %d \"%s\")\n" n (make-string 50 ?x)))
                                (number-sequence 1 150) "")
                     "  nil)\n")
             nil file)
            (load file nil t)
            (let* ((r (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-fn"))
                   (c (plist-get r :content)))
              (should-not (plist-get r :is-error))
              (should (string-prefix-p "function harness-test-defs-fn: interpreted function\nloaded from " c))
              (should (string-search (format "defined in %s, lines 6-9:\n\n" (abbreviate-file-name file)) c))
              (should (string-search "     6\t(defun harness-test-defs-fn (a)\n" c))
              (should (string-suffix-p "     9\t  (list a))" c))
              ;; Read, never visited.
              (should-not (find-buffer-visiting file)))
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-var")
                                :content)))
              (should (string-prefix-p "variable harness-test-defs-var: variable\n" c))
              (should (string-search ", lines 3-4:" c)))
            ;; A buffer visiting the source is read as it stands.
            (let ((buf (find-file-noselect file)))
              (unwind-protect
                  (progn
                    (with-current-buffer buf (goto-char (point-min)) (insert ";; one\n;; two\n"))
                    (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition"
                                                                        :symbol "harness-test-defs-fn")
                                        :content)))
                      (should (string-search ", lines 8-11 (as its buffer in the user's Emacs has it" c))
                      (should (string-search "     8\t(defun harness-test-defs-fn (a)\n" c))))
                (with-current-buffer buf (set-buffer-modified-p nil))
                (kill-buffer buf)))
            ;; A long definition stops at the read limit, two thirds of
            ;; the output limit as for emacs_buffer.
            (let ((harness-tools-max-output-chars 3000))
              (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-long")
                                  :content)))
                (should (string-search ", lines 11-162:" c))
                (should (string-search "    11\t(defun harness-test-defs-long ()\n" c))
                (should (string-match-p "\\[stopped at 2000 characters, at line [0-9]+; the definition ends at line 162\\]\\'" c))))
            ;; An alias is followed to what it names.
            (defalias 'harness-test-defs-alias #'harness-test-defs-fn)
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-alias")
                                :content)))
              (should (string-prefix-p "harness-test-defs-alias is an alias for harness-test-defs-fn, an interpreted function\n" c))
              (should (string-search "     6\t(defun harness-test-defs-fn (a)" c)))
            ;; A function evaluated outside any file is printed as Emacs holds it.
            (eval '(defun harness-test-defs-evaluated (x) "Double X." (* 2 x)) t)
            (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-evaluated")
                                :content)))
              (should (string-search "No file defines harness-test-defs-evaluated" c))
              (should (string-search "(defun harness-test-defs-evaluated (x)" c))
              (should (string-search "\"Double X.\"" c)))
            ;; One with no docstring holds fewer slots, and prints too.
            (eval '(defun harness-test-defs-bare (x) (* 3 x)) t)
            (let ((r (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-defs-bare")))
              (should-not (plist-get r :is-error))
              (should (string-search "(defun harness-test-defs-bare (x)" (plist-get r :content))))
            ;; Built in, with no C source on this machine.
            (let ((find-function-C-source-directory nil))
              (let ((c (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "car") :content)))
                (should (string-prefix-p "function car: built-in function\n" c))
                (should (string-search "\nfile: src/data.c\n" c))
                (should (string-search "C source is not on this machine" c))))
            ;; Refusals.
            (let ((r (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-no-such-symbol-qqq")))
              (should (plist-get r :is-error))
              (should (string-search "No symbol" (plist-get r :content))))
            (let ((r (harness-tools-emacs-test--call "emacs_find_definition" :symbol "car" :type "macro")))
              (should (plist-get r :is-error))
              (should (string-search "type must be" (plist-get r :content))))
            (should (plist-get (harness-tools-emacs-test--call "emacs_find_definition") :is-error))
            (should (equal "Find definition: variable x"
                           (harness-tool-title "emacs_find_definition" '(:symbol "x" :type "variable")))))
        (let ((buf (find-buffer-visiting file))) (when buf (kill-buffer buf)))
        (delete-directory root t)))))

(ert-deftest harness-tools-emacs-find-definition-reveals-its-file ()
  "emacs_find_definition tells the permission layer which source file it
showed a definition from, for the session that asked, so that reading
the rest of that file asks nobody.  Not for a definition printed from
memory, for one it did not find, or without a session."
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (let* ((root (harness-test-temp-dir))
           (file (expand-file-name "harness-test-reveal.el" root))
           (revealed nil)
           (saved (gethash 'permission/reveal-file harness--methods))
           (find (lambda (symbol)
                   (harness-await (harness-call 'tools/execute "s1"
                                                (list :id (harness-short-id) :name "emacs_find_definition"
                                                      :input (list :symbol symbol)))))))
      (harness-register-method 'permission/reveal-file (lambda (sid f) (push (list sid f) revealed) f))
      (unwind-protect
          (progn
            (write-region (concat ";;; harness-test-reveal.el --- Reveal me  -*- lexical-binding: t; -*-\n\n"
                                  "(defun harness-test-reveal-fn ()\n  \"Return nil.\"\n  nil)\n")
                          nil file)
            (load file nil t)
            (should-not (plist-get (funcall find "harness-test-reveal-fn") :is-error))
            (should (equal '("s1") (mapcar #'car revealed)))
            (should (equal (file-truename file) (file-truename (cadr (car revealed)))))
            (eval '(defun harness-test-reveal-evaluated () nil) t)
            (should-not (plist-get (funcall find "harness-test-reveal-evaluated") :is-error))
            (should (plist-get (funcall find "harness-no-such-symbol-qqq") :is-error))
            (should-not (plist-get (harness-tools-emacs-test--call "emacs_find_definition" :symbol "harness-test-reveal-fn")
                                   :is-error))
            (should (= 1 (length revealed))))
        (if saved
            (puthash 'permission/reveal-file saved harness--methods)
          (remhash 'permission/reveal-file harness--methods))
        (delete-directory root t)))))

(defun harness-tools-emacs-test--trace-output ()
  "Return the text of *trace-output*, or \"\" when there is none."
  (if (get-buffer "*trace-output*")
      (with-current-buffer "*trace-output*" (buffer-string))
    ""))

(ert-deftest harness-tools-emacs-trace ()
  "emacs_trace records the calls of a function and the changes of a
variable into *trace-output*, with their callers when asked, stops a
trace at its limit or on request, and refuses what it cannot trace."
  (harness-tools-emacs-test--setup)
  (harness-test-with-temp-state
    (eval '(progn
             (defun harness-test-traced (x) (* 2 x))
             (defun harness-test-trace-caller () (harness-test-traced 2))
             (defvar harness-test-traced-var 0))
          t)
    (when (get-buffer "*trace-output*") (kill-buffer "*trace-output*"))
    (unwind-protect
        (progn
          (let* ((r (harness-tools-emacs-test--call "emacs_trace" :symbol "harness-test-traced" :callers 1))
                 (c (plist-get r :content)))
            (should-not (plist-get r :is-error))
            (should (string-prefix-p "Tracing function harness-test-traced in the user's Emacs" c))
            (should (string-search "emacs_buffer (name *trace-output*, offset 1)" c))
            (should (string-search " and the function that called it, " c))
            (should (string-search "  function harness-test-traced: 0 of up to 100 calls, each with up to 1 caller" c)))
          (harness-test-trace-caller)
          (let ((c (plist-get (harness-tools-emacs-test--call "emacs_buffer" :name "*trace-output*") :content)))
            (should (string-search "1 -> (harness-test-traced 2)  ; from harness-test-trace-caller\n" c))
            (should (string-match-p "1 <- harness-test-traced: 4  ; [0-9.]+ ms" c)))
          (should (string-search "advice: :around emacs_trace's trace, recording calls in *trace-output*"
                                 (plist-get (harness-tools-emacs-test--call "emacs_describe" :symbol "harness-test-traced")
                                            :content)))
          ;; A variable is watched.
          (should (string-prefix-p "Watching variable harness-test-traced-var"
                                   (plist-get (harness-tools-emacs-test--call "emacs_trace" :symbol "harness-test-traced-var"
                                                                              :type "variable")
                                              :content)))
          (setq harness-test-traced-var 5)
          (with-temp-buffer (setq-local harness-test-traced-var 6))
          (should (string-search "= harness-test-traced-var set to 5\n" (harness-tools-emacs-test--trace-output)))
          (should (string-search "= harness-test-traced-var set to 6 in " (harness-tools-emacs-test--trace-output)))
          (let ((c (plist-get (harness-tools-emacs-test--call "emacs_trace" :action "list") :content)))
            (should (string-search "function harness-test-traced: 1 of up to 100 calls" c))
            (should (string-search "variable harness-test-traced-var: 2 of up to 100 changes" c)))
          ;; Stopping one removes its advice.
          (should (string-search "Stopped:\n  function harness-test-traced: 1 of up to 100 calls"
                                 (plist-get (harness-tools-emacs-test--call "emacs_trace" :action "stop"
                                                                            :symbol "harness-test-traced")
                                            :content)))
          (should-not (advice-member-p trace-advice-name 'harness-test-traced))
          ;; A trace stops itself at its limit.
          (harness-tools-emacs-test--call "emacs_trace" :symbol "harness-test-traced" :limit 2)
          (dotimes (_ 3) (harness-test-traced 7))
          (harness-test-wait (lambda () (not (advice-member-p trace-advice-name 'harness-test-traced)))
                             5 "the trace to stop at its limit")
          (should (string-search "stopped tracing function harness-test-traced after 2 calls, its limit"
                                 (harness-tools-emacs-test--trace-output)))
          (should (= 2 (with-current-buffer "*trace-output*"
                         (how-many (regexp-quote "-> (harness-test-traced 7)") (point-min) (point-max)))))
          ;; What cannot be traced is refused.
          (dolist (case '(("when" . "is a macro") ("if" . "special form") ("apply" . "tracing itself")
                          ("harness-emacs-endpoint--trace-call" . "tracing itself")
                          ("harness-no-such-symbol-qqq" . "No symbol")))
            (let ((r (harness-tools-emacs-test--call "emacs_trace" :symbol (car case))))
              (should (plist-get r :is-error))
              (should (string-search (cdr case) (plist-get r :content)))))
          (should (plist-get (harness-tools-emacs-test--call "emacs_trace") :is-error))
          (should (plist-get (harness-tools-emacs-test--call "emacs_trace" :action "pause" :symbol "car") :is-error))
          (should (plist-get (harness-tools-emacs-test--call "emacs_trace" :symbol "car" :limit 0) :is-error))
          ;; Stopping with no symbol stops every trace.
          (let ((c (plist-get (harness-tools-emacs-test--call "emacs_trace" :action "stop") :content)))
            (should (string-search "variable harness-test-traced-var" c))
            (should (string-search "No traces are running." c)))
          (should-not (get-variable-watchers 'harness-test-traced-var))
          (should (equal "Trace symbol: start find-file" (harness-tool-title "emacs_trace" '(:symbol "find-file")))))
      (harness-emacs-endpoint-handle "trace" '(:action "stop"))
      (when (get-buffer "*trace-output*") (kill-buffer "*trace-output*")))))

(ert-deftest harness-tools-emacs-demo-debug-script ()
  "The demo provider's `debug' script calls the debugging tools, each
with input its tool takes, so they can be tried live without a model."
  (harness-tools-emacs-test--setup)
  (harness-test-load-module 'provider-demo)
  (let* ((events (harness-provider-demo--script
                  '(:messages ((:role user :content ((:type "text" :text "Debug find-file")))))))
         (calls (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'tool-call)) events)))
    (should (equal '("emacs_describe" "emacs_find_definition" "emacs_trace")
                   (mapcar (lambda (e) (plist-get e :name)) calls)))
    (dolist (call calls)
      (let ((schema (harness-tool-schema (harness-tool-get (plist-get call :name)))))
        (dolist (key (harness-plist-keys (plist-get call :input)))
          (should (plist-member (plist-get schema :properties) key)))))))

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
                  "emacs_describe" "emacs_find_definition" "emacs_messages"))
    (let ((tool (harness-tool-get name)))
      (should tool)
      (should (eq 'read (harness-tool-kind tool)))
      (should (harness-tool-coalescable tool))))
  ;; A trace changes the user's Emacs: it adds advice or a watcher.
  (dolist (name '("emacs_insert" "emacs_save_buffer" "emacs_trace"))
    (let ((tool (harness-tool-get name)))
      (should tool)
      (should (eq 'write (harness-tool-kind tool)))
      (should-not (harness-tool-coalescable tool)))))

(provide 'harness-tools-emacs-test)
;;; harness-tools-emacs-test.el ends here
