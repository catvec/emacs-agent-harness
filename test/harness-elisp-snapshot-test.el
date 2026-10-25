;;; harness-elisp-snapshot-test.el --- The elisp tool, started from a copy of the user's Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; With `snapshot' the `elisp' tool starts its background Emacs from a
;; copy of the user's: the harness asks the Emacs a client lent it for
;; the copy, slice by slice (lisp/harness-snapshot.el), puts it in a file
;; and the child reads it as data before the code runs
;; (lisp/harness-elisp.el).  The Emacs these tests lend is the one they
;; run in, narrowed to the fake variables and buffers each test defines.
;; They check what the child sees and can compute over, that what it
;; changes stays in the copy, that credentials are not in the file, that
;; what the child needs for itself is not overwritten, that such a child
;; is read-only and offline whatever the session has (under the real
;; bwrap, where that can start) and is refused where no sandbox can give
;; that, and that the user's Emacs is not asked then.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-snapshot)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-sandbox--backend)
(defvar harness-sandbox-policy)
(defvar harness-tools-shell--snapshots)
(defvar harness-tools-shell--snapshot-ttl)
(defvar harness-tools-shell--snapshot-seconds)
(declare-function harness-acp-drop-client "harness-acp")
(declare-function harness-sandbox-detect "harness-sandbox")

(defun harness-elisp-snapshot-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-elisp-snapshot-test--drop-clients ()
  "Drop every client connected to the harness, left by the tests before."
  (let ((harness-acp--server-enabled nil))
    (harness-test-load-module 'acp))
  (dolist (client (copy-sequence harness-acp--clients))
    (harness-acp-drop-client client)))

(defun harness-elisp-snapshot-test--setup ()
  "Load the tools, lend this Emacs to the harness, allow every call."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-elisp-snapshot-test--drop-clients)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-elisp-snapshot-test--allow 10)
  (setq harness-tools-shell--snapshots nil
        harness-snapshot--states nil))

(defmacro harness-elisp-snapshot-test--without-methods (names &rest body)
  "Run BODY with the bus methods NAMES, symbols, removed; put them back afterwards."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (name) (cons name (gethash name harness--methods))) ,names)))
     (dolist (m saved) (remhash (car m) harness--methods))
     (unwind-protect (progn ,@body)
       (dolist (m saved) (when (cdr m) (puthash (car m) (cdr m) harness--methods))))))

(defun harness-elisp-snapshot-test--call (&rest input)
  "Execute the elisp tool with INPUT for a session and wait; return the result."
  (harness-await (harness-call 'tools/execute "s1" (list :id "c1" :name "elisp" :input input)) 60))

(defmacro harness-elisp-snapshot-test--lending (regexp buffers &rest body)
  "Run BODY with this Emacs lending only the variables matching REGEXP and BUFFERS.
The Emacs the tests run in has tens of thousands of variables; a copy
of the few each test defines is quick for the child to read."
  (declare (indent 2))
  `(let ((only ,buffers))
     (cl-letf (((symbol-function 'harness-snapshot--collect)
                (lambda (state)
                  (let (entries)
                    (mapatoms (lambda (symbol)
                                (when (and (default-boundp symbol)
                                           (string-match-p ,regexp (symbol-name symbol)))
                                  (push (cons (symbol-name symbol) symbol) entries))))
                    (setf (harness-snapshot--state-buckets state) (list entries)))))
               ((symbol-function 'buffer-list) (lambda (&optional _frame) only)))
       ,@body)))

(defmacro harness-elisp-snapshot-test--in-dir (&rest body)
  "Run BODY with `default-directory' a fresh temporary directory named ROOT."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((root (harness-test-temp-dir))
            (default-directory root))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(defmacro harness-elisp-snapshot-test--with-methods (methods &rest body)
  "Run BODY with the bus METHODS, an alist of name to function, registered."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (m) (cons (car m) (gethash (car m) harness--methods))) ,methods)))
     (dolist (m ,methods) (harness-register-method (car m) (cdr m)))
     (unwind-protect (progn ,@body)
       (dolist (m saved)
         (if (cdr m) (puthash (car m) (cdr m) harness--methods) (remhash (car m) harness--methods))))))

(defun harness-elisp-snapshot-test--unconfined (_cwd command &rest _opts)
  "Stand in for `sandbox/wrap': COMMAND, run as it is."
  command)

(defun harness-elisp-snapshot-test--content (result)
  "Return the content of RESULT, failing the test if it is an error."
  (when (plist-get result :is-error)
    (ert-fail (list "the call failed" (plist-get result :content))))
  (plist-get result :content))

(defun harness-elisp-snapshot-test--bwrap ()
  "Skip the test unless the real bwrap can start here."
  (unless (executable-find "bwrap") (ert-skip "no bwrap"))
  (dolist (m '(store project config provider session sandbox)) (harness-test-load-module m))
  (harness-sandbox-detect)
  (unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend))
    (ert-skip "bwrap is not the sandbox backend here")))

(defun harness-elisp-snapshot-test--skip-if-bwrap-fails (result)
  "Skip the test when RESULT says bwrap could not start in this environment."
  (when (and (plist-get result :is-error) (string-search "bwrap:" (plist-get result :content)))
    (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get result :content)))))

;;;; The fake user's Emacs

(defvar harness-elisp-snapshot-test--answer 41)
(defvar harness-elisp-snapshot-test--table
  (let ((h (make-hash-table :test 'equal))) (puthash "k" '(1 2 3) h) h))
(defvar harness-elisp-snapshot-test--alist '((one . 1) (two . 2)))
(cl-defstruct harness-elisp-snapshot-test-point x y)
(defvar harness-elisp-snapshot-test--struct (make-harness-elisp-snapshot-test-point :x 3 :y 4))
(defvar harness-elisp-snapshot-test--password "FAKE-SECRET-PASSWORD")
(defvar harness-elisp-snapshot-test--config '((user . "bob") (api-key . "FAKE-SECRET-NESTED")))
(defvar harness-elisp-snapshot-test--hook '(harness-elisp-snapshot-test-hook-function))
(defvar harness-elisp-snapshot-test--function 'harness-elisp-snapshot-test-hook-function)
(defvar harness-elisp-snapshot-test--ran nil)
(defun harness-elisp-snapshot-test-hook-function (&rest _)
  "A function of the user's that the child must never call."
  (setq harness-elisp-snapshot-test--ran t))

(defconst harness-elisp-snapshot-test--variables "\\`harness-elisp-snapshot-test--"
  "The variables these tests lend.")

(defun harness-elisp-snapshot-test--document ()
  "Return a buffer the fake user is working in."
  (let ((buffer (generate-new-buffer "harness-elisp-snapshot-test-doc")))
    (with-current-buffer buffer
      (text-mode)
      (insert "alpha beta\ngamma delta\n")
      (goto-char 7)
      (setq-local fill-column 33)
      (setq default-directory "/tmp/")
      (set-buffer-modified-p t))
    buffer))

;;;; What the child sees

(ert-deftest harness-elisp-snapshot-the-child-sees-and-computes-over-the-users-emacs ()
  "Started from a copy, the child has the values of the user's variables
and the user's buffers, in the state they were in, and the code computes
over them.  The user's value of a variable the child keeps its own value
of is there to read."
  (harness-elisp-snapshot-test--setup)
  (let ((buffer (harness-elisp-snapshot-test--document)))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (harness-elisp-snapshot-test--with-methods
              (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables (list buffer)
              (let* ((result (harness-elisp-snapshot-test--call
                              :snapshot t
                              :code "(list (1+ harness-elisp-snapshot-test--answer)
                                           (gethash \"k\" harness-elisp-snapshot-test--table)
                                           (alist-get 'two harness-elisp-snapshot-test--alist)
                                           (aref harness-elisp-snapshot-test--struct 2)
                                           (with-current-buffer \"harness-elisp-snapshot-test-doc\"
                                             (list (buffer-string) (point) major-mode (buffer-modified-p)
                                                   fill-column default-directory)))"))
                     (content (harness-elisp-snapshot-test--content result)))
                (should (string-prefix-p "=> (42 (1 2 3) 2 4 (\"alpha beta\\ngamma delta\\n\" 7 text-mode t 33 \"/tmp/\"))"
                                         (replace-regexp-in-string "[ \n\t]+" " " content)))
                (should (plist-get (plist-get (plist-get result :meta) :snapshot) :variables))))))
      (kill-buffer buffer))))

(ert-deftest harness-elisp-snapshot-without-snapshot-the-child-knows-nothing-of-the-users-emacs ()
  "A call without `snapshot' is what it always was: the user's variables
are not there, and the user's Emacs is not asked."
  (harness-elisp-snapshot-test--setup)
  (let ((asked 0))
    (harness-elisp-snapshot-test--in-dir
      (harness-elisp-snapshot-test--with-methods
          (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
        (advice-add 'harness-snapshot-slice :before (lambda (&rest _) (cl-incf asked)) '((name . harness-elisp-snapshot-test)))
        (unwind-protect
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
              (should (equal "=> (nil nil)"
                             (harness-elisp-snapshot-test--content
                              (harness-elisp-snapshot-test--call
                               :code "(list (boundp 'harness-elisp-snapshot-test--answer) (fboundp 'harness-snapshot-info-not-there))"))))
              (should (= 0 asked)))
          (advice-remove 'harness-snapshot-slice 'harness-elisp-snapshot-test))))))

(ert-deftest harness-elisp-snapshot-a-change-in-the-child-stays-in-the-copy ()
  "The code changes a variable, a hash table, a structure and a buffer of
its copy; the user's Emacs has all of them as it had."
  (harness-elisp-snapshot-test--setup)
  (let ((buffer (harness-elisp-snapshot-test--document)))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (harness-elisp-snapshot-test--with-methods
              (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables (list buffer)
              (let ((table-before (copy-hash-table harness-elisp-snapshot-test--table)))
                (should (equal "=> (0 (9) 0 \"\")"
                               (replace-regexp-in-string
                                "[ \n\t]+" " "
                                (harness-elisp-snapshot-test--content
                                 (harness-elisp-snapshot-test--call
                                  :snapshot t
                                  :code "(setq harness-elisp-snapshot-test--answer 0)
                                         (puthash \"k\" '(9) harness-elisp-snapshot-test--table)
                                         (aset harness-elisp-snapshot-test--struct 1 0)
                                         (with-current-buffer \"harness-elisp-snapshot-test-doc\" (erase-buffer))
                                         (list harness-elisp-snapshot-test--answer
                                               (gethash \"k\" harness-elisp-snapshot-test--table)
                                               (aref harness-elisp-snapshot-test--struct 1)
                                               (with-current-buffer \"harness-elisp-snapshot-test-doc\" (buffer-string)))")))))
                (should (= 41 harness-elisp-snapshot-test--answer))
                (should (equal '(1 2 3) (gethash "k" harness-elisp-snapshot-test--table)))
                (should (equal (gethash "k" table-before) (gethash "k" harness-elisp-snapshot-test--table)))
                (should (= 3 (harness-elisp-snapshot-test-point-x harness-elisp-snapshot-test--struct)))
                (should (equal "alpha beta\ngamma delta\n" (with-current-buffer buffer (buffer-string))))
                (should (= 7 (with-current-buffer buffer (point))))))))
      (kill-buffer buffer))))

;;;; Credentials

(ert-deftest harness-elisp-snapshot-credentials-are-not-in-the-file-or-the-child ()
  "The file the child reads holds none of the fake secrets, a variable
named like a credential is not in the child, a key named like one has
its value withheld, and the copy's manifest names what was left out."
  (harness-elisp-snapshot-test--setup)
  (let ((secret-buffer (generate-new-buffer "harness-elisp-snapshot-test-passwords")))
    (with-current-buffer secret-buffer (insert "FAKE-SECRET-BUFFER-TEXT"))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (harness-elisp-snapshot-test--with-methods
              (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables (list secret-buffer)
              (let ((content (harness-elisp-snapshot-test--content
                              (harness-elisp-snapshot-test--call
                               :snapshot t
                               :code "(let* ((text (with-temp-buffer
                                                  (insert-file-contents (getenv \"HARNESS_ELISP_SNAPSHOT\"))
                                                  (buffer-string)))
                                            (manifest (plist-get (harness-snapshot-info) :manifest)))
                                       (list :in-file (string-search \"FAKE-SECRET\" text)
                                             :bound (boundp 'harness-elisp-snapshot-test--password)
                                             :nested harness-elisp-snapshot-test--config
                                             :buffer (get-buffer \"harness-elisp-snapshot-test-passwords\")
                                             :withheld (and (member \"harness-elisp-snapshot-test--password\"
                                                                    (plist-get manifest :withheld-variables)) t)
                                             :left-out (plist-get manifest :left-out-buffers)))"))))
                (setq content (replace-regexp-in-string "[ \n\t]+" " " content))
                (should (string-search ":in-file nil" content))
                (should (string-search ":bound nil" content))
                (should (string-search ":nested ((user . \"bob\") (api-key . \"<withheld>\"))" content))
                (should (string-search ":buffer nil" content))
                (should (string-search ":withheld t" content))
                (should (string-search "\"harness-elisp-snapshot-test-passwords\"" content))
                (should-not (string-search "FAKE-SECRET" (replace-regexp-in-string ":in-file nil" "" content)))))))
      (kill-buffer secret-buffer))))

(ert-deftest harness-elisp-snapshot-the-file-is-private-to-the-harness ()
  "The file with the copy is in the call's own directory and readable by
its owner alone."
  (harness-elisp-snapshot-test--setup)
  (harness-elisp-snapshot-test--in-dir
    (harness-elisp-snapshot-test--with-methods
        (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
      (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
        (let ((content (harness-elisp-snapshot-test--content
                        (harness-elisp-snapshot-test--call
                         :snapshot t
                         :code "(file-attribute-modes (file-attributes (getenv \"HARNESS_ELISP_SNAPSHOT\")))"))))
          (should (equal "=> \"-rw-------\"" content)))))))

;;;; What the child keeps for itself

(ert-deftest harness-elisp-snapshot-the-child-keeps-its-own-hooks-and-functions ()
  "A hook, a variable that holds a function, and the variables the child
needs are not set from the copy: the child never calls anything of the
user's, and still works.  Their user values are there to read."
  (harness-elisp-snapshot-test--setup)
  (harness-elisp-snapshot-test--in-dir
    (harness-elisp-snapshot-test--with-methods
        (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
      (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
        (let ((content (harness-elisp-snapshot-test--content
                        (harness-elisp-snapshot-test--call
                         :snapshot t
                         :code "(list :bound (boundp 'harness-elisp-snapshot-test--hook)
                                      :user (harness-user-value 'harness-elisp-snapshot-test--hook)
                                      :function (harness-user-value 'harness-elisp-snapshot-test--function)
                                      :kill-emacs-hook kill-emacs-hook
                                      :works (with-temp-buffer (insert \"x\") (buffer-string)))"))))
          (setq content (replace-regexp-in-string "[ \n\t]+" " " content))
          (should (string-search ":bound nil" content))
          (should (string-search ":user (harness-elisp-snapshot-test-hook-function)" content))
          (should (string-search ":function harness-elisp-snapshot-test-hook-function" content))
          (should (string-search ":kill-emacs-hook nil" content))
          (should (string-search ":works \"x\"" content)))))))

(ert-deftest harness-elisp-snapshot-the-names-the-child-keeps-are-the-ones-it-needs ()
  "What `harness-elisp--snapshot-kept-p' keeps: the child's own load path,
environment, printer, reader, debugger, hooks and function-valued
variables; and not an ordinary variable."
  (dolist (name '(load-path exec-path process-environment features load-history after-load-alist
                  standard-output noninteractive default-directory user-emacs-directory
                  max-lisp-eval-depth print-length print-level read-circle debug-on-error
                  inhibit-quit inhibit-read-only gc-cons-threshold command-line-args
                  invocation-name coding-system-for-read kill-emacs-hook after-change-functions
                  before-save-hook post-command-hook indent-line-function auto-mode-alist
                  file-name-handler-alist timer-list timer-idle-list
                  window-system x-select-enable-clipboard native-comp-speed byte-compile-warnings))
    (should (harness-elisp--snapshot-kept-p name)))
  (dolist (name '(fill-column tab-width case-fold-search indent-tabs-mode kill-ring-max
                  user-full-name harness-model harness-state-directory comment-start major-mode))
    (should-not (harness-elisp--snapshot-kept-p name))))

;;;; Read-only and offline

(ert-deftest harness-elisp-snapshot-the-sandbox-is-read-only-and-offline-whatever-the-session-has ()
  "A snapshot call is given `:read-only t' and `:network nil', and no
capability, whatever a handler of `tools/sandbox-options' asked for,
while the call's own directory stays writable for its result."
  (harness-elisp-snapshot-test--setup)
  (let ((seen nil))
    (harness-elisp-snapshot-test--in-dir
      (harness-elisp-snapshot-test--with-methods
          (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command)))
        (harness-add-filter 'tools/sandbox-options
                            (lambda (options _sid)
                              (plist-put (plist-put (plist-put (copy-sequence options) :network t)
                                                    :read-only nil)
                                         :capabilities '("CAP_NET_RAW")))
                            10)
        (unwind-protect
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
              ;; Without snapshot: as the session asked.
              (harness-elisp-snapshot-test--call :code "(+ 1 2)")
              (let ((plain (cdar seen)))
                (should (eq t (plist-get plain :network)))
                (should (plist-get plain :capabilities)))
              ;; With it: read-only, offline, no capability.
              (should (equal "=> 3" (harness-elisp-snapshot-test--content
                                     (harness-elisp-snapshot-test--call :snapshot t :code "(+ 1 2)"))))
              (let ((opts (cdar seen)))
                (should (eq t (plist-get opts :read-only)))
                (should (plist-member opts :network))
                (should-not (plist-get opts :network))
                (should-not (plist-get opts :capabilities))
                (should (cl-some (lambda (dir) (string-suffix-p "/io/" dir)) (plist-get opts :scratch)))))
          (dolist (f (gethash 'tools/sandbox-options harness--filters))
            (harness-remove-filter 'tools/sandbox-options (cdr f))))))))

(ert-deftest harness-elisp-snapshot-without-a-sandbox-that-can-do-it-the-call-is-refused-and-nothing-is-asked ()
  "Where no sandbox can run a read-only, offline process -- the module is
not loaded, the policy is off, there is no backend -- the call is
refused, whatever the policy otherwise allows, and the user's Emacs is
not asked for a copy of itself."
  (harness-elisp-snapshot-test--setup)
  (let ((asked 0))
    (advice-add 'harness-snapshot-slice :before (lambda (&rest _) (cl-incf asked)) '((name . harness-elisp-snapshot-test)))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
            ;; The sandbox module is not loaded.
            (harness-elisp-snapshot-test--without-methods '(sandbox/wrap)
              (let ((r (harness-elisp-snapshot-test--call :snapshot t :code "(+ 1 2)")))
                (should (plist-get r :is-error))
                (should (string-search "Cannot evaluate" (plist-get r :content)))
                (should (string-search "cannot run unconfined" (plist-get r :content))))
              ;; Without snapshot the same call runs, unconfined, as it always did.
              (should (equal "=> 3" (plist-get (harness-elisp-snapshot-test--call :code "(+ 1 2)") :content))))
            ;; The module is loaded, and there is no backend, or the policy is off.
            (dolist (m '(store project config provider session sandbox)) (harness-test-load-module m))
            (let ((harness-sandbox--backend nil))
              (let ((r (harness-elisp-snapshot-test--call :snapshot t :code "(+ 1 2)")))
                (should (plist-get r :is-error))
                (should (string-search "cannot run unconfined" (plist-get r :content)))))
            (let ((harness-sandbox-policy 'off))
              (let ((r (harness-elisp-snapshot-test--call :snapshot t :code "(+ 1 2)")))
                (should (plist-get r :is-error))
                (should (string-search "cannot run unconfined" (plist-get r :content)))))
            (should (= 0 asked))))
      (advice-remove 'harness-snapshot-slice 'harness-elisp-snapshot-test))))

(ert-deftest harness-elisp-snapshot-under-bwrap-the-child-writes-nothing-and-reaches-no-network ()
  "Under the real bwrap a snapshot child cannot write a file in the working
directory or reach a server on this machine's loopback, which the same
code, without snapshot, can; and it still reports its result."
  (harness-elisp-snapshot-test--setup)
  (harness-elisp-snapshot-test--bwrap)
  (harness-elisp-snapshot-test--in-dir
    (let* ((harness-sandbox-policy 'required)
           (server (make-network-process :name "harness-elisp-snapshot-test-server" :server t
                                         :host "127.0.0.1" :service t :noquery t
                                         :filter #'ignore :sentinel #'ignore))
           (port (process-contact server :service))
           (code (format "(list :write (condition-case err (progn (write-region \"made\" nil \"made.txt\") 'wrote)
                                         (error 'refused))
                                :net (condition-case err
                                         (let ((p (make-network-process :name \"x\" :host \"127.0.0.1\" :service %d
                                                                        :coding 'binary :noquery t)))
                                           (delete-process p) 'connected)
                                       (error 'unreachable)))" port)))
      (unwind-protect
          (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
            ;; The control: without snapshot the child writes and connects.
            (let ((r (harness-elisp-snapshot-test--call :code code)))
              (harness-elisp-snapshot-test--skip-if-bwrap-fails r)
              (should-not (plist-get r :is-error))
              (should (equal "=> (:write wrote :net connected)" (replace-regexp-in-string "[ \n\t]+" " " (plist-get r :content))))
              (should (file-exists-p (expand-file-name "made.txt" root)))
              (delete-file (expand-file-name "made.txt" root)))
            ;; With snapshot: neither.
            (let ((r (harness-elisp-snapshot-test--call :snapshot t :code code)))
              (should-not (plist-get r :is-error))
              (should (equal "=> (:write refused :net unreachable)" (replace-regexp-in-string "[ \n\t]+" " " (plist-get r :content))))
              (should (plist-get (plist-get r :meta) :sandboxed))
              (should-not (file-exists-p (expand-file-name "made.txt" root)))))
        (delete-process server)))))

(ert-deftest harness-elisp-snapshot-under-bwrap-the-child-sees-the-copy ()
  "The real bwrap runs the child, which reads the copy from its call's
directory and computes over it, and the user's Emacs is as it was."
  (harness-elisp-snapshot-test--setup)
  (harness-elisp-snapshot-test--bwrap)
  (let ((buffer (harness-elisp-snapshot-test--document)))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (let ((harness-sandbox-policy 'required))
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables (list buffer)
              (let ((r (harness-elisp-snapshot-test--call
                        :snapshot t
                        :code "(list harness-elisp-snapshot-test--answer
                                     (with-current-buffer \"harness-elisp-snapshot-test-doc\" (buffer-string)))")))
                (harness-elisp-snapshot-test--skip-if-bwrap-fails r)
                (should-not (plist-get r :is-error))
                (should (equal "=> (41 \"alpha beta\\ngamma delta\\n\")"
                               (replace-regexp-in-string "[ \n\t]+" " " (plist-get r :content))))
                (should (plist-get (plist-get r :meta) :sandboxed))))))
      (kill-buffer buffer))))

;;;; The copy: kept, partial, refused

(ert-deftest harness-elisp-snapshot-a-copy-is-kept-for-a-minute-and-fresh-takes-another ()
  "A second call of the session within the minute uses the copy the first
took, so the user's Emacs is not read again; `fresh' asks for a new one."
  (harness-elisp-snapshot-test--setup)
  (let ((begun 0))
    (advice-add 'harness-snapshot--begin :before (lambda (&rest _) (cl-incf begun)) '((name . harness-elisp-snapshot-test)))
    (unwind-protect
        (harness-elisp-snapshot-test--in-dir
          (harness-elisp-snapshot-test--with-methods
              (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
            (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
              (harness-elisp-snapshot-test--content (harness-elisp-snapshot-test--call :snapshot t :code "1"))
              (should (= 1 begun))
              (let ((r (harness-elisp-snapshot-test--call :snapshot t :code "harness-elisp-snapshot-test--answer")))
                (should (= 1 begun))
                (should (plist-get (plist-get (plist-get r :meta) :snapshot) :cached))
                (should (equal "=> 41" (plist-get r :content))))
              ;; Changed since, and still the old copy; fresh sees the change.
              (let ((harness-elisp-snapshot-test--answer 50))
                (should (equal "=> 41" (plist-get (harness-elisp-snapshot-test--call
                                                    :snapshot t :code "harness-elisp-snapshot-test--answer")
                                                   :content)))
                (should (equal "=> 50" (plist-get (harness-elisp-snapshot-test--call
                                                    :snapshot t :fresh t :code "harness-elisp-snapshot-test--answer")
                                                   :content)))
                (should (= 2 begun)))
              ;; A copy older than the time to live is not used.
              (let ((harness-tools-shell--snapshot-ttl -1))
                (harness-elisp-snapshot-test--call :snapshot t :code "1")
                (should (= 3 begun))))))
      (advice-remove 'harness-snapshot--begin 'harness-elisp-snapshot-test))))

(ert-deftest harness-elisp-snapshot-a-copy-that-runs-out-of-time-is-used-and-says-so ()
  "When the time for taking the copy runs out the child starts from what
arrived, and the result says the copy is partial."
  (harness-elisp-snapshot-test--setup)
  (harness-elisp-snapshot-test--in-dir
    (harness-elisp-snapshot-test--with-methods
        (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
      (harness-elisp-snapshot-test--lending harness-elisp-snapshot-test--variables nil
        (let ((harness-tools-shell--snapshot-seconds 0.3))
          ;; A user's Emacs that is slow, and gives a little at a time.
          (advice-add 'harness-snapshot-slice :around
                      (lambda (fn params)
                        (sleep-for 0.25)
                        (funcall fn (plist-put (copy-sequence params) :maxChars 200)))
                      '((name . harness-elisp-snapshot-test-slow)))
          (unwind-protect
              (let ((r (harness-elisp-snapshot-test--call
                        :snapshot t :code "(plist-get (harness-snapshot-info) :partial)")))
                (should-not (plist-get r :is-error))
                (should (string-search "time allowed" (plist-get r :content)))
                (should (string-search "The copy of the user's Emacs is partial" (plist-get r :content)))
                (should (plist-get (plist-get (plist-get r :meta) :snapshot) :partial)))
            (advice-remove 'harness-snapshot-slice 'harness-elisp-snapshot-test-slow)
            (setq harness-snapshot--states nil)))))))

(ert-deftest harness-elisp-snapshot-without-an-emacs-to-ask-the-call-says-so ()
  "With no Emacs lent to the harness there is nothing to copy: the call
fails with that reason and tells the model to go without."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-elisp-snapshot-test--drop-clients)
  (harness-add-filter 'permission/decide #'harness-elisp-snapshot-test--allow 10)
  (setq harness-tools-shell--snapshots nil)
  (harness-elisp-snapshot-test--in-dir
    (harness-elisp-snapshot-test--with-methods
        (list (cons 'sandbox/wrap #'harness-elisp-snapshot-test--unconfined))
      (let ((r (harness-elisp-snapshot-test--call :snapshot t :code "1")))
        (should (plist-get r :is-error))
        (should (string-search "Cannot take a copy of the user's Emacs" (plist-get r :content)))
        (should (string-search "without snapshot" (plist-get r :content)))))))

;;;; The loader

(defun harness-elisp-snapshot-test--child (snapshot-text code)
  "Run CODE in a fresh Emacs that has read SNAPSHOT-TEXT; return its output.
The Emacs is a batch process outside any sandbox: this is the loader
alone, with a file the test wrote."
  (let ((file (make-temp-file "harness-snapshot-" nil ".eld" snapshot-text)))
    (unwind-protect
        (with-temp-buffer
          (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                        "--batch" "-Q" "-L" harness-directory "-L" (expand-file-name "lisp" harness-directory)
                        "-l" "harness-elisp"
                        "--eval" (format "(progn (setq harness-elisp-snapshot-info (harness-elisp-load-snapshot %S)) %s)"
                                         file code))
          (buffer-string))
      (delete-file file))))

(ert-deftest harness-elisp-snapshot-the-loader-reads-data-and-never-evaluates ()
  "The file is read as data: read-time evaluation is refused, so a file
that asks for it runs nothing, and the child reports why it stopped."
  (let* ((marker (make-temp-file "harness-snapshot-marker-"))
         (text (format "(snapshot :version 1)\n(v harness-elisp-snapshot-test--x #.(write-region \"ran\" nil %S))\n"
                       marker))
         (out (harness-elisp-snapshot-test--child
               text "(princ (format \"error=%S\" (plist-get harness-elisp-snapshot-info :error)))")))
    (unwind-protect
        (progn
          (should (string-search "error=" out))
          (should (string-search "#." out))
          (should (equal "" (with-temp-buffer (insert-file-contents marker) (buffer-string)))))
      (delete-file marker))))

(ert-deftest harness-elisp-snapshot-the-loader-sets-keeps-and-skips ()
  "A variable the child lacks becomes a special variable with the user's
value; one it has takes it; one it keeps its own value of does not, and
the user's value is `harness-user-value'; a placeholder does not replace
what the child holds of its own; a buffer is recreated with its text,
mode, point and locals and no hook runs."
  (let* ((text (concat
                "(snapshot :version 1 :time 1.0)\n"
                "(b :name \"doc\" :mode text-mode :file \"/x/y.txt\" :directory \"/x/\" :point 3 :modified t :size 5"
                " :text-from 1 :text-to 6 :locals ((fill-column . 22) (after-change-functions . (ignore))"
                " (harness-elisp-snapshot-test--local . 7)) :locals-cut 0 :text \"hello\")\n"
                "(v harness-elisp-snapshot-test--new (1 2 3))\n"
                "(v fill-column 55)\n"
                "(v load-path (\"/not/a/dir\"))\n"
                "(v kill-emacs-hook (harness-elisp-snapshot-test-boom))\n"
                "(v tab-width #s(harness-user-object buffer \"x\"))\n"
                "(v indent-tabs-mode nil)\n"
                "(manifest :version 1 :withheld-variables (\"secret-thing\"))\n"))
         (out (harness-elisp-snapshot-test--child
               text
               (concat "(princ (format \"%S\" (list"
                       " harness-elisp-snapshot-test--new"
                       " (special-variable-p 'harness-elisp-snapshot-test--new)"
                       " (default-value 'fill-column)"
                       " (> (length load-path) 1) (car (harness-user-value 'load-path))"
                       " kill-emacs-hook (harness-user-value 'kill-emacs-hook)"
                       " (default-value 'tab-width) (default-value 'indent-tabs-mode)"
                       " (with-current-buffer \"doc\" (list (buffer-string) (point) major-mode buffer-file-name"
                       "   default-directory fill-column (buffer-modified-p) after-change-functions"
                       "   harness-elisp-snapshot-test--local))"
                       " (plist-get (plist-get harness-elisp-snapshot-info :loaded) :variables)"
                       " (plist-get (plist-get harness-elisp-snapshot-info :manifest) :withheld-variables)"
                       " (condition-case err (harness-user-value 'secret-thing) (error 'none)))))"))))
    (should (equal (concat "((1 2 3) t 55 t \"/not/a/dir\" nil (harness-elisp-snapshot-test-boom) 8 nil"
                           " (\"hello\" 3 text-mode \"/x/y.txt\" \"/x/\" 22 t nil 7) 3 (\"secret-thing\") none)")
                   out))))

(provide 'harness-elisp-snapshot-test)
;;; harness-elisp-snapshot-test.el ends here
