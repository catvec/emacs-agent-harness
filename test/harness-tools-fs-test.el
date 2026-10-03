;;; harness-tools-fs-test.el --- Tests for the file tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-fs-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-fs-test--setup ()
  "Load the tools modules and allow everything."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-fs)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-tools-fs-test--allow 10))

(defun harness-tools-fs-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input))))

(defmacro harness-tools-fs-test-in-dir (&rest body)
  "Run BODY with `default-directory' bound to a fresh temp dir named ROOT."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((root (harness-test-temp-dir))
            (default-directory root))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(defun harness-tools-fs-test--write (name content)
  "Write CONTENT to NAME under `default-directory'."
  (let ((f (expand-file-name name default-directory)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert content))
    f))

;;;; read_file

(ert-deftest harness-tools-fs-read-file-numbers-lines-and-ranges ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "one\ntwo\nthree\nfour\nfive\n")
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt")))
      (should-not (plist-get r :is-error))
      (should (equal "     1\tone\n     2\ttwo\n     3\tthree\n     4\tfour\n     5\tfive"
                     (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 2 :limit 2)))
      (should (string-prefix-p "     2\ttwo\n     3\tthree" (plist-get r :content)))
      (should (string-search "[a.txt: lines 2-3 of 5]" (plist-get r :content))))
    ;; A limit past the end is clamped, an offset past the end is an error.
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 5 :limit 100)))
      (should-not (plist-get r :is-error))
      (should (string-search "lines 5-5 of 5" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 9)))
      (should (plist-get r :is-error))
      (should (string-search "past the end" (plist-get r :content))))
    ;; Absolute paths work too, and the title shows the range.
    (should-not (plist-get (harness-tools-fs-test--call "read_file" :path (expand-file-name "a.txt" root)) :is-error))
    (should (equal "Read file: src/x.el:10-40" (harness-tool-title "read_file" '(:path "src/x.el" :offset 10 :limit 31))))
    (should (equal "Read file: src/x.el" (harness-tool-title "read_file" '(:path "src/x.el"))))
    ;; Without a path the call is about nothing yet: the label alone.
    (should (equal "Read file" (harness-tool-title "read_file" nil)))))

(ert-deftest harness-tools-fs-read-file-refusals-and-images ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (make-directory (expand-file-name "d" root))
    (let ((r (harness-tools-fs-test--call "read_file" :path "d")))
      (should (plist-get r :is-error))
      (should (string-search "list_dir" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "nope.txt")))
      (should (plist-get r :is-error))
      (should (string-search "not found" (plist-get r :content))))
    (let ((coding-system-for-write 'binary))
      (harness-tools-fs-test--write "blob.bin" (concat "ELF\0\0\1\2" (make-string 100 0))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "blob.bin")))
      (should (plist-get r :is-error))
      (should (string-search "binary" (plist-get r :content))))
    (let ((coding-system-for-write 'binary))
      (harness-tools-fs-test--write "pic.png" "\211PNG\r\n\032\n....."))
    (let ((r (harness-tools-fs-test--call "read_file" :path "pic.png")))
      (should-not (plist-get r :is-error))
      (should (equal "image/png" (plist-get (car (plist-get r :attachments)) :mime)))
      (should (equal (expand-file-name "pic.png" root) (plist-get (car (plist-get r :attachments)) :path))))
    (harness-tools-fs-test--write "empty.txt" "")
    (should (string-search "empty" (plist-get (harness-tools-fs-test--call "read_file" :path "empty.txt") :content)))))

(ert-deftest harness-tools-fs-read-file-context-bomb ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "big.txt"
                                  (mapconcat (lambda (i) (format "line number %d with some padding text" i))
                                             (number-sequence 1 2000) "\n"))
    (let* ((harness-tools-max-output-chars 2000)
           (r (harness-tools-fs-test--call "read_file" :path "big.txt")))
      (should-not (plist-get r :is-error))
      (should (plist-get r :truncated))
      (should (<= (length (plist-get r :content)) 2000))
      (should (string-search "Continue with offset" (plist-get r :content)))
      (should (= 2000 (plist-get (plist-get r :truncated) :total)))
      (should (= 1 (car (plist-get (plist-get r :truncated) :lines))))
      ;; Continuing from the suggested offset works and is not truncated when small.
      (let* ((next (1+ (cdr (plist-get (plist-get r :truncated) :lines))))
             (r2 (harness-tools-fs-test--call "read_file" :path "big.txt" :offset next :limit 5)))
        (should-not (plist-get r2 :truncated))
        (should (string-search (format "%6d\tline number %d" next next) (plist-get r2 :content)))))
    ;; The generic guard still protects other tools.
    (let* ((harness-tools-max-output-chars 300)
           (r (harness-tools-fs-test--call "grep" :pattern "line" :path "big.txt" :max_results 100)))
      (should (plist-get r :truncated))
      (should (string-search "Output truncated" (plist-get r :content)))
      (should (file-exists-p (plist-get (plist-get r :truncated) :path))))))

;;;; write_file / edit_file

(ert-deftest harness-tools-fs-write-file-creates-parents-and-reverts-buffers ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (let ((r (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "hello\nworld\n")))
      (should-not (plist-get r :is-error))
      (should (string-search "Created sub/dir/new.txt (12 bytes, 2 lines)" (plist-get r :content)))
      (should (equal "hello\nworld\n" (harness-read-file (expand-file-name "sub/dir/new.txt" root)))))
    ;; An unmodified buffer visiting the file is reverted by the UI, once
    ;; the `tools/file-written' notification reaches it.
    (let ((buf (find-file-noselect (expand-file-name "sub/dir/new.txt" root))))
      (unwind-protect
          (progn
            (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "changed\n")
            (harness-test-wait (lambda () (equal "changed\n" (with-current-buffer buf (buffer-string)))) 5 "revert")
            (should-not (buffer-modified-p buf))
            ;; A modified buffer is left alone.
            (with-current-buffer buf (goto-char (point-max)) (insert "local edit"))
            (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "again\n")
            (sit-for 0.1)
            (should (string-search "local edit" (with-current-buffer buf (buffer-string)))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))
    (should (string-search "Overwrote" (plist-get (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "x") :content)))
    (should (plist-get (harness-tools-fs-test--call "write_file" :path "sub") :is-error))
    (should (equal "Write file: a.txt (3 bytes)" (harness-tool-title "write_file" '(:path "a.txt" :content "abc"))))))

(ert-deftest harness-tools-fs-edit-file-success-and-failure-modes ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "e.el" "(defun foo ()\n  (bar 1))\n(defun baz ()\n  (bar 1))\n")
    ;; Ambiguous without replace_all.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "(bar 1)" :new_string "(bar 2)")))
      (should (plist-get r :is-error))
      (should (string-search "matches 2 places" (plist-get r :content)))
      (should (string-search "(bar 1)" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Unique with context.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "foo ()\n  (bar 1)" :new_string "foo ()\n  (bar 2)")))
      (should-not (plist-get r :is-error))
      (should (string-search "replaced 1 occurrence at line 1" (plist-get r :content)))
      (should (equal "(defun foo ()\n  (bar 2))\n(defun baz ()\n  (bar 1))\n" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Missing, with a whitespace hint when that is the problem.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "nothing here" :new_string "x")))
      (should (plist-get r :is-error))
      (should (string-search "not found" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "(defun baz ()\n    (bar 1))" :new_string "x")))
      (should (plist-get r :is-error))
      (should (string-search "whitespace" (plist-get r :content))))
    ;; replace_all.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "bar" :new_string "qux" :replace_all t)))
      (should-not (plist-get r :is-error))
      (should (string-search "replaced 2 occurrences" (plist-get r :content)))
      (should-not (string-search "bar" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Bad inputs.
    (should (plist-get (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "" :new_string "x") :is-error))
    (should (plist-get (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "qux" :new_string "qux") :is-error))
    (should (string-search "write_file" (plist-get (harness-tools-fs-test--call "edit_file" :path "missing.el" :old_string "a" :new_string "b") :content)))
    ;; Case-sensitive literal match, no regexp interpretation.
    (harness-tools-fs-test--write "r.txt" "a.b A.B axb\n")
    (harness-tools-fs-test--call "edit_file" :path "r.txt" :old_string "a.b" :new_string "Z")
    (should (equal "Z A.B axb\n" (harness-read-file (expand-file-name "r.txt" root))))))

;;;; list_dir / glob / file_info

(ert-deftest harness-tools-fs-list-dir ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "12345")
    (harness-tools-fs-test--write "sub/b.txt" "x")
    (harness-tools-fs-test--write ".git/config" "hidden")
    (let* ((r (harness-tools-fs-test--call "list_dir"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "a.txt  5 B" c))
      (should (string-search "sub/\n" c))
      (should-not (string-search "b.txt" c))
      (should-not (string-search ".git" c))
      (should (string-search "(2 entries in ., depth 1)" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "list_dir" :path "." :depth 2) :content)))
      (should (string-search "sub/b.txt  1 B" c)))
    (should (string-search "is empty" (plist-get (harness-tools-fs-test--call "list_dir" :path (progn (make-directory "e") "e")) :content)))
    (should (plist-get (harness-tools-fs-test--call "list_dir" :path "a.txt") :is-error))
    (should (plist-get (harness-tools-fs-test--call "list_dir" :path "nope") :is-error))
    (let ((harness-tools-fs--list-limit 1))
      (should (string-search "Listing stopped" (plist-get (harness-tools-fs-test--call "list_dir") :content))))))

(ert-deftest harness-tools-fs-glob ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.el" "")
    (harness-tools-fs-test--write "b.txt" "")
    (harness-tools-fs-test--write "src/c.el" "")
    (harness-tools-fs-test--write "src/deep/d.el" "")
    (harness-tools-fs-test--write ".git/e.el" "")
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "*.el") :content)))
      (should (string-search "a.el" c))
      (should-not (string-search "c.el" c))
      (should (string-search "(1 match" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el") :content)))
      (should (string-search "a.el" c))
      (should (string-search "src/c.el" c))
      (should (string-search "src/deep/d.el" c))
      (should-not (string-search ".git" c))
      (should (string-search "(3 matches" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el" :path "src") :content)))
      (should (string-search "c.el\n" c))
      (should-not (string-search "a.el" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "src/*/*.el") :content)))
      (should (string-search "src/deep/d.el" c))
      (should (string-search "(1 match" c)))
    (should (string-search "No files match" (plist-get (harness-tools-fs-test--call "glob" :pattern "*.zip") :content)))
    (let ((harness-tools-fs--glob-limit 2))
      (should (string-search "showing 2" (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el") :content))))
    (should (plist-get (harness-tools-fs-test--call "glob" :pattern "*" :path "nope") :is-error))
    (should (equal "Find files: **/*.el in src" (harness-tool-title "glob" '(:pattern "**/*.el" :path "src"))))))

(ert-deftest harness-tools-fs-glob-regexp ()
  (harness-tools-fs-test--setup)
  (let ((rx (harness-tools-fs--glob-regexp "src/**/*.el")))
    (should (string-match-p rx "src/a.el"))
    (should (string-match-p rx "src/x/y/a.el"))
    (should-not (string-match-p rx "lib/a.el"))
    (should-not (string-match-p rx "src/a.elc")))
  (should (string-match-p (harness-tools-fs--glob-regexp "*.el") "a.el"))
  (should-not (string-match-p (harness-tools-fs--glob-regexp "*.el") "d/a.el"))
  (should (string-match-p (harness-tools-fs--glob-regexp "a?c.[ch]") "abc.h")))

(ert-deftest harness-tools-fs-file-info ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "f.txt" "a\nb\nc\n")
    (let* ((r (harness-tools-fs-test--call "file_info" :path "f.txt"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "type: file" c))
      (should (string-search "size: 6 bytes" c))
      (should (string-search "lines: 3" c))
      (should (string-search "content: text" c))
      (should (string-search "mime: text/plain" c))
      (should (string-match-p "modified: [0-9]\\{4\\}-" c))
      (should (= 3 (plist-get (plist-get r :meta) :lines))))
    (make-directory "d")
    (harness-tools-fs-test--write "d/x" "")
    (let ((c (plist-get (harness-tools-fs-test--call "file_info" :path "d") :content)))
      (should (string-search "type: directory" c))
      (should (string-search "entries: 1" c)))
    (should (plist-get (harness-tools-fs-test--call "file_info" :path "missing") :is-error))))

;;;; grep

(defun harness-tools-fs-test--grep-fixture ()
  "Create files for the grep tests."
  (harness-tools-fs-test--write "a.txt" "Hello world\nsecond line\nhello again\n")
  (harness-tools-fs-test--write "sub/b.el" "(defun hello () nil)\n")
  (harness-tools-fs-test--write "sub/c.txt" "nothing\n")
  (harness-tools-fs-test--write ".git/HEAD" "hello ref\n"))

(defun harness-tools-fs-test--grep-checks (program)
  "Run the grep assertions expecting PROGRAM to be used."
  (let* ((r (harness-tools-fs-test--call "grep" :pattern "hello"))
         (c (plist-get r :content)))
    (should-not (plist-get r :is-error))
    (should (string-search "a.txt:1: Hello world" c))
    (should (string-search "a.txt:3: hello again" c))
    (should (string-search "sub/b.el:1: (defun hello () nil)" c))
    (should-not (string-search ".git" c))
    (should (string-search "(3 matches)" c)))
  ;; Case sensitive.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :case_sensitive t) :content)))
    (should-not (string-search "Hello world" c))
    (should (string-search "(2 matches)" c)))
  ;; Glob filter and a subdirectory path.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :glob "*.el") :content)))
    (should (string-search "sub/b.el:1:" c))
    (should-not (string-search "a.txt" c)))
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :path "sub") :content)))
    (should (string-search "sub/b.el:1:" c))
    (should-not (string-search "a.txt" c)))
  ;; A single file target.
  (should (string-search "a.txt:2: second line" (plist-get (harness-tools-fs-test--call "grep" :pattern "second" :path "a.txt") :content)))
  ;; max_results caps and says so.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :max_results 1) :content)))
    (should (string-search "3 matches, showing the first 1" c)))
  ;; No matches is not an error.
  (let ((r (harness-tools-fs-test--call "grep" :pattern "zzzzqqq")))
    (should-not (plist-get r :is-error))
    (should (string-search "No matches" (plist-get r :content))))
  ;; A bad regexp is a tool error naming the program.
  (let ((r (harness-tools-fs-test--call "grep" :pattern "(unclosed")))
    (should (plist-get r :is-error))
    (should (string-search program (plist-get r :content))))
  (should (plist-get (harness-tools-fs-test--call "grep" :pattern "x" :path "nope") :is-error)))

(ert-deftest harness-tools-fs-grep-with-rg ()
  (harness-tools-fs-test--setup)
  (skip-unless (executable-find "rg"))
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--grep-fixture)
    (should (equal "rg" (car (harness-tools-fs--grep-command "x" "." nil nil root))))
    (harness-tools-fs-test--grep-checks "rg")))

(ert-deftest harness-tools-fs-grep-with-grep-fallback ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--grep-fixture)
    (let ((real (symbol-function 'executable-find)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &optional remote) (unless (equal name "rg") (funcall real name remote)))))
        (should (equal "grep" (car (harness-tools-fs--grep-command "x" "." nil nil root))))
        (harness-tools-fs-test--grep-checks "grep")))))

(ert-deftest harness-tools-fs-grep-is-async ()
  "grep returns a promise and the handler does not block."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "needle\n")
    (let ((p (harness-call 'tools/execute nil (list :id "c2" :name "grep" :input (list :pattern "needle")))))
      (should (harness-promise-p p))
      (should-not (harness-promise-settled-p p))
      (should (string-search "a.txt:1: needle" (plist-get (harness-await p) :content))))))

;;;; paths and remote resolution

(ert-deftest harness-tools-fs-paths-and-kinds ()
  (harness-tools-fs-test--setup)
  (dolist (spec '(("read_file" read t) ("write_file" write nil) ("edit_file" write nil)
                  ("list_dir" read t) ("glob" read t) ("grep" read t) ("file_info" read t)))
    (let ((tool (harness-tool-get (car spec))))
      (should tool)
      (should (eq (cadr spec) (harness-tool-kind tool)))
      (should (eq (caddr spec) (and (harness-tool-coalescable tool) t)))
      (should (functionp (harness-tool-paths-fn tool)))))
  (should (equal '("x.el") (funcall (harness-tool-paths-fn (harness-tool-get "read_file")) '(:path "x.el"))))
  (should (equal '(".") (funcall (harness-tool-paths-fn (harness-tool-get "grep")) '(:pattern "p"))))
  ;; Relative paths resolve against the session cwd and keep the TRAMP host.
  (should (equal "/ssh:host:/srv/app/src/x.el"
                 (harness-tools-resolve-path "src/x.el" '(:cwd "/srv/app/" :host "/ssh:host:")))))

(provide 'harness-tools-fs-test)
;;; harness-tools-fs-test.el ends here
