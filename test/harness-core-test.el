;;; harness-core-test.el --- Tests for the module bus  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(ert-deftest harness-core-methods-roundtrip ()
  (harness-test-reset-bus)
  (harness-register-method 'test/add (lambda (a b) (+ a b)) :doc "add")
  (should (= 3 (harness-call 'test/add 1 2)))
  (should (harness-method-exists-p 'test/add))
  (should-error (harness-call 'test/missing) :type 'harness-no-such-method)
  (should (equal '(:name test/add :doc "add" :module nil :params nil)
                 (car (harness-methods)))))

(ert-deftest harness-core-call-async-wraps-values-and-errors ()
  (harness-test-reset-bus)
  (harness-register-method 'test/val (lambda () 42))
  (harness-register-method 'test/boom (lambda () (error "boom")))
  (should (= 42 (harness-await (harness-call-async 'test/val))))
  (should-error (harness-await (harness-call-async 'test/boom))))

(ert-deftest harness-core-events-priority-and-isolation ()
  (harness-test-reset-bus)
  (let (log)
    (harness-on 'test/ev (lambda (x) (push (list 'b x) log)) 60)
    (harness-on 'test/ev (lambda (_x) (error "ignored")) 10)
    (harness-on 'test/ev (lambda (x) (push (list 'a x) log)) 20)
    (harness-on '* (lambda (ev args) (push (list 'any ev args) log)))
    (should (= 3 (harness-emit 'test/ev 1)))
    (should (equal '((any test/ev (1)) (b 1) (a 1)) log))))

(ert-deftest harness-core-events-dedupe-and-off ()
  (harness-test-reset-bus)
  (let ((n 0))
    (defalias 'harness-test--counter (lambda () (cl-incf n)))
    (harness-on 'test/ev #'harness-test--counter)
    (let ((h (harness-on 'test/ev #'harness-test--counter)))
      (harness-emit 'test/ev)
      (should (= n 1))
      (harness-off h)
      (harness-emit 'test/ev)
      (should (= n 1)))))

(ert-deftest harness-core-sync-filter ()
  (harness-test-reset-bus)
  (harness-add-filter 'test/f (lambda (v _ctx) (* v 2)) 20)
  (harness-add-filter 'test/f (lambda (v ctx) (+ v ctx)) 10)
  (should (= 8 (harness-run-filter 'test/f 1 3))))

(ert-deftest harness-core-async-filter-chain-and-final ()
  (harness-test-reset-bus)
  (harness-add-filter 'test/af (lambda (v next) (run-at-time 0.01 nil next (plist-put v :a t))) 10)
  (harness-add-filter 'test/af (lambda (v next) (funcall next (plist-put v :b t))) 20)
  (harness-add-filter 'test/af (lambda (v _next) (harness-resolved (plist-put v :c t))) 30)
  (let ((r (harness-await (harness-run-filter-async 'test/af (list :start t)))))
    (should (plist-get r :a)) (should (plist-get r :b)) (should (plist-get r :c)))
  ;; :final stops the chain.
  (harness-add-filter 'test/af2 (lambda (v next) (funcall next (plist-put v :final t))) 10)
  (harness-add-filter 'test/af2 (lambda (v next) (funcall next (plist-put v :never t))) 20)
  (should-not (plist-get (harness-await (harness-run-filter-async 'test/af2 nil)) :never)))

(ert-deftest harness-core-promises ()
  (let ((p (harness-make-promise)))
    (should-not (harness-promise-settled-p p))
    (harness-resolve p 1)
    (should (= 2 (harness-await (harness-then p #'1+)))))
  (let ((p (harness-rejected '(error "x"))))
    (should (equal 'recovered (harness-await (harness-then p nil (lambda (_e) 'recovered))))))
  (should (equal '(1 2 3) (harness-await (harness-all (list (harness-resolved 1) 2 (harness-resolved 3))))))
  (let ((p (harness-with-promise (resolve _reject) (run-at-time 0.01 nil resolve 'later))))
    (should (eq 'later (harness-await p))))
  (should-error (harness-await (harness-with-promise (_r _j) (error "inside")))))

(ert-deftest harness-core-promise-chains-do-not-recurse ()
  ;; A long chain of promises resolving one another must not grow the stack.
  (let ((max-lisp-eval-depth 800)
        (p (harness-resolved 0)))
    (dotimes (_ 3000)
      (setq p (harness-then p #'1+)))
    (should (= 3000 (harness-await p))))
  ;; Nested adoption: each promise resolved with the next one.
  (let ((max-lisp-eval-depth 800)
        (head (harness-make-promise)) (cur nil))
    (setq cur head)
    (dotimes (_ 3000)
      (let ((next (harness-make-promise)))
        (harness-resolve cur next)
        (setq cur next)))
    (harness-resolve cur 'end)
    (should (eq 'end (harness-await head)))))

(ert-deftest harness-core-modules-order-and-failure-isolation ()
  (harness-test-reset-bus)
  (let (order)
    (harness-define-module 'c :requires '(b) :init (lambda () (push 'c order)))
    (harness-define-module 'a :init (lambda () (push 'a order)))
    (harness-define-module 'b :requires '(a) :init (lambda () (push 'b order)))
    (harness-define-module 'bad :init (lambda () (error "nope")))
    (harness-define-module 'dep-on-bad :requires '(bad) :init (lambda () (push 'never order)))
    (let ((ready (harness-modules-init)))
      (should (equal '(a b c) (reverse order)))
      (should (equal '(a b c) (sort (copy-sequence ready) (lambda (x y) (string< x y)))))
      (should (eq 'failed (harness-module-state (harness-module-get 'bad))))
      (should (eq 'failed (harness-module-state (harness-module-get 'dep-on-bad)))))
    ;; Redefinition keeps a ready module ready.
    (harness-define-module 'a :doc "new doc" :init (lambda () (push 'again order)))
    (should (harness-module-ready-p 'a))
    (harness-modules-init)
    (should-not (memq 'again order))))

(ert-deftest harness-core-defmethod-records-module ()
  (harness-test-reset-bus)
  (let ((harness--defining-module 'demo))
    (eval '(harness-defmethod test/hello (name) "Say hello." (format "hi %s" name)) t))
  (should (equal "hi x" (harness-call 'test/hello "x")))
  (should (eq 'demo (plist-get (car (harness-methods)) :module))))

(ert-deftest harness-util-json-conventions ()
  (should (equal "{\"a\":1,\"b\":[1,2],\"c\":null,\"d\":false,\"e\":true,\"f\":{},\"g\":[]}"
                 (harness-json-encode '(:a 1 :b (1 2) :c nil :d :false :e t :f :empty :g []))))
  (should (equal '(:a 1 :b (1 2) :c nil :d :false)
                 (harness-json-parse "{\"a\":1,\"b\":[1,2],\"c\":null,\"d\":false}")))
  (should (equal "[{\"x\":1}]" (harness-json-encode '((:x 1)))))
  (should (equal "{\"lines\":[2,30]}" (harness-json-encode '(:lines (2 . 30))))))

(ert-deftest harness-util-json-encode-text ()
  ;; Since Emacs 30 `harness-json-encode' gives bytes, which become raw-byte
  ;; characters inside other text and then cannot be encoded again.  The
  ;; text variant gives characters.
  (let* ((s "\N{U+2717} caf\N{U+E9} \N{U+D7} \N{U+2026}")
         (obj (list :s s))
         (text (harness-json-encode-text obj)))
    (should (multibyte-string-p text))
    (should (equal (concat "{\"s\":\"" s "\"}") text))
    (should (equal obj (harness-json-parse text)))
    ;; The same bytes on the wire either way.
    (should (equal (encode-coding-string text 'utf-8-unix)
                   (encode-coding-string (harness-json-encode obj) 'utf-8-unix)))
    ;; Inside other text, and that text inside other JSON, it stays text.
    (let ((outer (format "Input (JSON):\n%s\nNote: %s" text s)))
      (should (equal outer (plist-get (harness-json-parse (harness-json-encode (list :text outer))) :text)))))
  (should (equal "{\"a\":[1,\"b\"]}" (harness-json-encode-text '(:a (1 "b"))))))

(ert-deftest harness-util-json-parse-long-whitespace ()
  "Parsing takes time linear in a long run of spaces inside the JSON.
The check for empty input used `string-trim', whose time is quadratic in
such a run: tens of seconds for one of 100,000."
  (let ((json (concat "{\"s\":\"x" (make-string 100000 ?\s) "y\"}"))
        (start (float-time)))
    (should (= 100002 (length (plist-get (harness-json-parse json) :s))))
    (should (< (- (float-time) start) 2)))
  (should-not (harness-json-parse " \n\t "))
  (should-not (harness-json-parse nil)))

(ert-deftest harness-util-grep-hit ()
  "A line of grep -H output splits at its file name, however long the line."
  (should (equal '("abc" . "{\"a\":1}")
                 (harness-grep-hit "/state/sessions/abc.nodes.jsonl:{\"a\":1}" ".nodes.jsonl")))
  ;; At the first such name: the text can mention another.
  (should (equal '("abc" . "see x.nodes.jsonl:3")
                 (harness-grep-hit "sessions/abc.nodes.jsonl:see x.nodes.jsonl:3" ".nodes.jsonl")))
  (should-not (harness-grep-hit "Binary file abc.nodes.jsonl matches" ".nodes.jsonl"))
  ;; A line of megabytes, past where a backtracking regexp overflows.
  (let* ((text (concat "{\"output\":\"" (make-string 2000000 ?x) "\"}"))
         (hit (harness-grep-hit (concat "/state/sessions/abc.nodes.jsonl:" text) ".nodes.jsonl")))
    (should (equal "abc" (car hit)))
    (should (equal text (cdr hit)))))

(ert-deftest harness-util-misc ()
  (should (= 36 (length (harness-uuid))))
  (should (equal "12.3k" (harness-format-tokens 12345)))
  (should (equal "1.20M" (harness-format-tokens 1200000)))
  (should (equal "abc…xyz" (harness-truncate-middle "abcdefghijklmnopqrstuvwxyz" 7)))
  (should (harness-path-within-p "/tmp" "/tmp/a/b"))
  (should-not (harness-path-within-p "/tmp/a" "/tmp/ab"))
  (should (harness-fuzzy-score "hcl" "harness-core.el"))
  (should-not (harness-fuzzy-score "zzz" "harness"))
  (should (equal '("harness-core.el" "harness-http.el")
                 (sort (harness-fuzzy-filter "hel" '("readme" "harness-core.el" "harness-http.el"))
                       #'string<))))

(ert-deftest harness-util-senders ()
  "Who sent a message reads the same before and after JSON (kind a string)."
  (let* ((system (harness-sender-system "tasks"))
         (session (harness-sender-session '(:id "s1" :name "Fix the parser" :model "x")))
         (parsed (harness-json-parse (harness-json-encode system))))
    (should (equal '(:kind system :source "tasks") system))
    (should (equal '(:kind session :id "s1" :name "Fix the parser") session))
    (should (equal '(:kind "system" :source "tasks") parsed))
    (should (eq 'system (harness-sender-kind parsed)))
    (should (eq 'session (harness-sender-kind session)))
    ;; The user: no sender, or nothing that names a kind.
    (dolist (none '(nil (:source "x") (:kind nil) (:kind "") (:kind :false)))
      (should-not (harness-sender-kind none)))
    (should (equal parsed (harness-node-sender (list :kind 'user :meta (list :steering t :from parsed)))))
    (should-not (harness-node-sender '(:kind user :meta (:steering t))))
    (should-not (harness-node-sender '(:kind user :meta (:from (:source "x")))))
    (should (equal "the harness (tasks)" (harness-sender-description parsed)))
    (should (equal "the harness" (harness-sender-description '(:kind system))))
    (should (equal "session s1 \"Fix the parser\"" (harness-sender-description session)))
    (should (equal "session s2" (harness-sender-description '(:kind "session" :id "s2"))))
    (should (equal "the user" (harness-sender-description nil)))))

(ert-deftest harness-http-sse-parser ()
  (let (events)
    (let ((f (harness-http-sse-parser (lambda (ev data) (push (cons ev data) events)))))
      (funcall f "event: ping\ndata: {\"a\":1}\n\n: comment\ndata: line1\ndata: li")
      (funcall f "ne2\n\n"))
    (should (equal '(("ping" . "{\"a\":1}") (nil . "line1\nline2")) (reverse events)))))

(ert-deftest harness-loader-start-and-reload-with-temp-module ()
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (moddir (expand-file-name "lisp/modules" dir))
         (file (expand-file-name "harness-demo.el" moddir)))
    (make-directory moddir t)
    (with-temp-file file
      (insert ";;; -*- lexical-binding: t -*-\n(harness-define-module 'demo :init (lambda () (harness-register-method 'demo/ping (lambda () 'pong))))\n(provide 'harness-demo)\n"))
    (cl-letf (((symbol-function 'harness--path)
               (lambda (rel) (expand-file-name rel dir))))
      (let ((harness-module-directories '("lisp/modules"))
            (harness--core-files nil)
            (harness--library-files nil)
            (harness-process nil))
        (should (harness-start))
        (should (eq 'pong (harness-call 'demo/ping)))
        (should (harness-module-ready-p 'demo))
        ;; A broken edit is refused and leaves the old definitions intact.
        (with-temp-file file (insert "(harness-define-module 'demo :init (lambda () (oops"))
        (should-not (harness-reload))
        (should (eq 'pong (harness-call 'demo/ping)))
        ;; A good edit is picked up.
        (with-temp-file file
          (insert ";;; -*- lexical-binding: t -*-\n(harness-define-module 'demo :init #'ignore)\n(harness-register-method 'demo/ping (lambda () 'pong2))\n(provide 'harness-demo)\n"))
        (should (harness-reload))
        (should (eq 'pong2 (harness-call 'demo/ping)))))
    (delete-directory dir t)))

(ert-deftest harness-loader-reloads-library-files ()
  "Library files load compiled at start and again at every reload.
A module reloaded after an update must find the libraries it requires
as they are now, not as this Emacs first loaded them, and a library
that does not compile refuses the reload like a module does."
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (lib (expand-file-name "lisp/harness-testlib.el" dir))
         (moddir (expand-file-name "lisp/modules" dir))
         (version (lambda (n)
                    (with-temp-file lib
                      (insert (format ";;; -*- lexical-binding: t -*-\n(defun harness-testlib-answer () %d)\n(provide 'harness-testlib)\n" n))))))
    (make-directory moddir t)
    (funcall version 1)
    (with-temp-file (expand-file-name "harness-libuser.el" moddir)
      (insert ";;; -*- lexical-binding: t -*-\n(require 'harness-testlib)\n(harness-define-module 'libuser)\n"
              "(harness-register-method 'libuser/answer (lambda () (harness-testlib-answer)))\n(provide 'harness-libuser)\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'harness--path)
                   (lambda (rel) (expand-file-name rel dir))))
          (let ((harness-module-directories '("lisp/modules"))
                (harness--core-files nil)
                (harness--library-files '("lisp/harness-testlib.el"))
                (harness-process nil))
            (should (harness-start))
            (should (equal 1 (harness-call 'libuser/answer)))
            (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                             (symbol-function 'harness-testlib-answer)))
            ;; Broken, it refuses the reload and the old definitions stay.
            (with-temp-file lib (insert "(defun harness-testlib-answer () (oops"))
            (should-not (harness-reload))
            (should (equal 1 (harness-call 'libuser/answer)))
            ;; Updated, the reload loads it again.
            (funcall version 2)
            (should (harness-reload))
            (should (equal 2 (harness-call 'libuser/answer)))))
      (makunbound 'harness-testlib-answer)
      (fmakunbound 'harness-testlib-answer)
      (setq features (delq 'harness-testlib features))
      (delete-directory dir t))))

;;;; Modules of the user's own

(defun harness-core-test--write-elisp (file &rest forms)
  "Write FORMS to FILE, a file of lexical Emacs Lisp."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t -*-\n")
    (dolist (form forms)
      (prin1 form (current-buffer))
      (insert "\n"))))

(ert-deftest harness-loader-picks-extra-modules-by-side ()
  "Which modules of `harness-extra-module-directories' an Emacs loads.
They load after the harness's own.  A UI module (ui-NAME) loads where
lisp/ui does and any other where lisp/modules does: both in a harness
with no process of its own, only the UI ones in the UI of a harness
process, and only the others in that process.  One whose name the
harness has already, a library's included, is left out with a warning;
the enabled and disabled lists filter them as they do the harness's own."
  (let* ((config (harness-test-temp-dir))
         (mine (expand-file-name "my-modules/" config))
         (warned nil)
         (harness-log-hook
          (list (lambda (level msg)
                  (when (and (eq level 'warn) (string-match "\\`module \\([^:]+\\): .* is left out" msg))
                    (push (match-string 1 msg) warned)))))
         (left-out (lambda () (prog1 (sort warned #'string<) (setq warned nil))))
         (user-emacs-directory config)
         ;; Relative to `user-emacs-directory'; one that does not exist is
         ;; no error.
         (harness-extra-module-directories '("my-modules" "/nonexistent/harness-modules"))
         (harness-enabled-modules t)
         (harness-disabled-modules nil)
         (mine-of (lambda (files)
                    (mapcar #'file-name-nondirectory
                            (cl-remove-if-not (lambda (f) (string-prefix-p mine f)) files)))))
    (dolist (name '("hello" "ui-hello" "session" "ui-chat" "files"))
      (harness-core-test--write-elisp (expand-file-name (format "harness-%s.el" name) mine)
                                      '(ignore)))
    ;; Not modules: the files a module of the directory may require.
    (harness-core-test--write-elisp (expand-file-name "hello-util.el" mine) '(ignore))
    (harness-core-test--write-elisp (expand-file-name "harness_hello.el" mine) '(ignore))
    (unwind-protect
        (progn
          ;; A harness with no process of its own loads both, after its own.
          (let* ((harness-process nil)
                 (harness-module-directories '("lisp/modules" "lisp/ui"))
                 (files (harness--module-files)))
            (should (equal (list (expand-file-name "harness-hello.el" mine)
                                 (expand-file-name "harness-ui-hello.el" mine))
                           (last files 2)))
            (should (equal '("harness-hello.el" "harness-ui-hello.el") (funcall mine-of files)))
            ;; The harness's own of the names taken stay.
            (should (member (harness--path "lisp/modules/harness-session.el") files))
            (should (member (harness--path "lisp/ui/harness-ui-chat.el") files))
            (should (equal '("files" "session" "ui-chat") (funcall left-out))))
          ;; The UI of a harness process loads the UI one.
          (let ((harness-process t)
                (harness-module-directories '("lisp/modules" "lisp/ui")))
            (should (equal '("harness-ui-hello.el") (funcall mine-of (harness--module-files))))
            (should (equal '("ui-chat") (funcall left-out))))
          ;; The harness process, which loads lisp/modules, the other.
          (let ((harness-process nil)
                (harness-module-directories '("lisp/modules")))
            (should (equal '("harness-hello.el") (funcall mine-of (harness--module-files))))
            (should (equal '("files" "session") (funcall left-out))))
          ;; The enabled and disabled lists name them as they do any other.
          (let ((harness-process nil)
                (harness-module-directories '("lisp/modules" "lisp/ui")))
            (let ((harness-disabled-modules '(hello)))
              (should (equal '("harness-ui-hello.el") (funcall mine-of (harness--module-files)))))
            (let ((harness-enabled-modules '(hello session)))
              (should (equal (list (harness--path "lisp/modules/harness-session.el")
                                   (expand-file-name "harness-hello.el" mine))
                             (harness--module-files))))))
      (delete-directory config t))))

(ert-deftest harness-loader-starts-and-reloads-extra-modules ()
  "Modules of `harness-extra-module-directories' start and reload as the harness's own.
They load compiled and record their source, not that compiled copy.
They require the other files of their directory, which is on
`load-path'.  `harness-reload' loads them again: it refuses a broken
edit, naming the file, and picks up a good one."
  (harness-test-reset-bus)
  (harness-test-with-temp-state
    (let* ((tree (harness-test-temp-dir))
           (config (harness-test-temp-dir))
           (mine (expand-file-name "my-modules/" config))
           (hello (expand-file-name "harness-hello.el" mine))
           (ui-hello (expand-file-name "harness-ui-hello.el" mine))
           (write-hello
            (lambda (fmt)
              (harness-core-test--write-elisp
               hello
               '(require 'harness-core)
               '(require 'hello-util)
               '(defcustom harness-hello-greeting "hello" "How to greet."
                  :type 'string :group 'harness)
               `(harness-defmethod hello/greet (name)
                  "Greet NAME."
                  (format ,fmt (hello-util-greet harness-hello-greeting name)))
               '(harness-define-module 'hello :doc "Says hello.")
               '(provide 'harness-hello)))))
      (harness-core-test--write-elisp (expand-file-name "lisp/modules/harness-own.el" tree)
                                      '(harness-define-module 'own :doc "The harness's own.")
                                      '(provide 'harness-own))
      (harness-core-test--write-elisp (expand-file-name "hello-util.el" mine)
                                      '(defun hello-util-greet (greeting name)
                                         (format "%s, %s" greeting name))
                                      '(provide 'hello-util))
      (funcall write-hello "%s")
      (harness-core-test--write-elisp ui-hello
                                      '(require 'harness-core)
                                      '(defun harness-ui-hello-greet (name)
                                         (harness-call 'hello/greet name))
                                      '(harness-define-module 'ui-hello :doc "Its UI."
                                                              :requires '(hello))
                                      '(provide 'harness-ui-hello))
      (unwind-protect
          (cl-letf (((symbol-function 'harness--path)
                     (lambda (rel) (expand-file-name rel tree))))
            (let ((harness-module-directories '("lisp/modules" "lisp/ui"))
                  (harness--core-files nil)
                  (harness--library-files nil)
                  (harness-process nil)
                  (user-emacs-directory config)
                  (harness-extra-module-directories '("my-modules"))
                  (load-path load-path))
              (should (harness-start))
              (should (equal '(hello own ui-hello) (mapcar #'harness-module-name (harness-modules))))
              (should (harness-module-ready-p 'ui-hello))
              (should (equal "hello, you" (harness-ui-hello-greet "you")))
              ;; Compiled, in the state directory; the module records its source.
              (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                               (symbol-function 'harness-ui-hello-greet)))
              (should (equal (harness--compiled-name hello) (symbol-file 'harness-hello-greeting 'defvar)))
              (should (equal hello (harness-module-file (harness-module-get 'hello))))
              (should (equal (list hello ui-hello)
                             (mapcar (lambda (d) (plist-get d :file))
                                     (cl-remove 'own (harness-module-descriptions)
                                                :key (lambda (d) (plist-get d :name))))))
              ;; On `load-path', after everything else.
              (should (equal (directory-file-name mine) (car (last load-path))))
              ;; A broken edit is refused and leaves the old definitions.
              (with-temp-file hello (insert "(harness-define-module 'hello :init (lambda () (oops"))
              (let ((problems (plist-get (harness--reload) :refused)))
                (should (equal 1 (length problems)))
                (should (string-prefix-p "harness-hello.el: " (car problems))))
              (should (equal "hello, you" (harness-ui-hello-greet "you")))
              ;; A good one is picked up, and the module stays ready.
              (funcall write-hello "%s!")
              (should (harness-reload))
              (should (equal "hello, you!" (harness-ui-hello-greet "you")))
              (should (harness-module-ready-p 'hello))
              (should (equal hello (harness-module-file (harness-module-get 'hello))))
              (harness-stop)))
        (fmakunbound 'harness-ui-hello-greet)
        (fmakunbound 'hello-util-greet)
        (makunbound 'harness-hello-greeting)
        (setq features (cl-remove-if (lambda (f) (memq f '(harness-own harness-hello harness-ui-hello hello-util)))
                                     features))
        (delete-directory tree t)
        (delete-directory config t)))))

(ert-deftest harness-core-describe-modules-lists-every-emacs ()
  "`harness-describe-modules' lists the modules of this Emacs, then of others.
A module from outside the harness's tree names its file, and a failed
one its error.  The modules of another Emacs, such as the harness
process, fill their section when they arrive, or it says why not."
  (harness-test-reset-bus)
  (let* ((outside (expand-file-name "harness-hello.el" (harness-test-temp-dir)))
         (process (harness-make-promise))
         (remote (harness-make-promise))
         (harness-describe-modules-functions
          (list (lambda () (cons "Modules of the harness process" process))
                #'ignore
                (lambda () (cons "Modules of the harness at there:1" remote)))))
    (let ((harness--defining-module 'own)
          (harness--defining-file (expand-file-name "lisp/modules/harness-own.el" harness-directory)))
      (harness-define-module 'own :doc "The harness's own."))
    (let ((harness--defining-module 'hello)
          (harness--defining-file outside))
      (harness-define-module 'hello :doc "Says hello."))
    ;; Defined as another module's file loads: its file is not that one.
    (let ((harness--defining-module 'hello)
          (harness--defining-file outside))
      (harness-define-module 'broken :doc "Fails." :init (lambda () (error "No luck"))))
    (harness-modules-init)
    (should-not (harness-module-file (harness-module-get 'broken)))
    (harness-describe-modules)
    (with-current-buffer harness--modules-buffer-name
      (let ((text (buffer-string)))
        (should (string-prefix-p "Modules of this Emacs\n\n" text))
        (should (string-match-p "^  broken +failed +Fails\\.\n +error: No luck\n" text))
        (should (string-match-p (concat "^  hello +ready +Says hello\\.\n +"
                                        (regexp-quote (abbreviate-file-name outside)) "\n")
                                text))
        ;; The harness's own names no file.
        (should (string-match-p "^  own +ready +The harness's own\\.\n\nModules of the harness process\n\n  …\n" text))
        (should (string-suffix-p "Modules of the harness at there:1\n\n  …\n" text))))
    (harness-resolve process (list (list :name 'session :state 'ready :doc "Sessions." :file nil :error nil)
                                   (list :name "hi" :state "failed" :doc "Hi." :file outside :error "Oops")))
    (harness-reject remote '(acp-error -32603 "Connection lost" nil))
    (harness-test-wait (lambda ()
                         (with-current-buffer harness--modules-buffer-name
                           (not (string-search "…" (buffer-string)))))
                       5 "the other Emacs's modules")
    (with-current-buffer harness--modules-buffer-name
      (let ((text (buffer-string)))
        (should (string-search
                 (concat "Modules of the harness process\n\n"
                         (format "  %-22s %-10s %s\n" "session" "ready" "Sessions.")
                         (format "  %-22s %-10s %s\n" "hi" "failed" "Hi.")
                         (format "  %-22s %-10s %s\n" "" "" (abbreviate-file-name outside))
                         (format "  %-22s %-10s error: %s\n" "" "" "Oops")
                         "\nModules of the harness at there:1\n\n"
                         "  They could not be listed: Connection lost\n")
                 text))))
    (kill-buffer harness--modules-buffer-name)))

(ert-deftest harness-util-run-command ()
  (let ((r (harness-await (harness-run-command '("sh" "-c" "echo out; echo err >&2; exit 3")))))
    (should (= 3 (plist-get r :exit)))
    (should (equal "out\n" (plist-get r :stdout)))
    (should (equal "err\n" (plist-get r :stderr))))
  (should (equal "abc" (plist-get (harness-await (harness-run-command '("cat") :stdin "abc")) :stdout)))
  (should (eq 'timeout (plist-get (harness-await (harness-run-command '("sleep" "5") :timeout 0.2)) :exit))))

(provide 'harness-core-test)
;;; harness-core-test.el ends here
