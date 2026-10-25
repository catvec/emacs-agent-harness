;;; harness-snapshot-test.el --- A copy of the user's Emacs, in slices  -*- lexical-binding: t; -*-

;;; Commentary:

;; lisp/harness-snapshot.el is the user's Emacs's side of the `elisp'
;; tool's `snapshot' option: it reads that Emacs and gives a copy of its
;; variables and buffers away as text, in slices, leaving out what looks
;; like a credential.  These tests take copies of this Emacs, narrowed to
;; the fake variables and buffers each test defines, read the text back
;; and check what is in it and what is not.  The last takes a whole copy
;; of the Emacs the tests run in.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-snapshot)

;;;; Helpers

(defun harness-snapshot-test--only (regexp)
  "Return a replacement for `harness-snapshot--collect' that lists only REGEXP.
It puts the variables whose names match into the one bucket the copy
reads, so that a test copies its own variables and not this Emacs's tens
of thousands."
  (lambda (state)
    (let (entries)
      (mapatoms (lambda (symbol)
                  (when (and (default-boundp symbol) (string-match-p regexp (symbol-name symbol)))
                    (push (cons (symbol-name symbol) symbol) entries))))
      (setf (harness-snapshot--state-buckets state) (list entries)))))

(defmacro harness-snapshot-test--with (regexp &rest body)
  "Run BODY with copies narrowed to the variables whose names match REGEXP."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'harness-snapshot--collect) (harness-snapshot-test--only ,regexp)))
     ,@body))

(defmacro harness-snapshot-test--buffers (buffers &rest body)
  "Run BODY with copies seeing only BUFFERS, a list, of this Emacs's buffers.
Other tests leave buffers behind: ERT visits the file of a test that
fails, to say where it is."
  (declare (indent 1))
  `(let ((only ,buffers))
     (cl-letf (((symbol-function 'buffer-list) (lambda (&optional _frame) only)))
       ,@body)))

(defun harness-snapshot-test--take (&optional params)
  "Take a whole copy with PARAMS for each slice; return (TEXT . SLICES)."
  (let ((cursor nil) (chunks nil) (slices nil))
    (catch 'done
      (while t
        (let ((answer (harness-snapshot-slice (append (and cursor (list :cursor cursor)) params))))
          (push answer slices)
          (push (plist-get answer :chunk) chunks)
          (setq cursor (plist-get answer :next))
          (when (eq (plist-get answer :done) t) (throw 'done nil))
          (should cursor))))
    (cons (apply #'concat (nreverse chunks)) (nreverse slices))))

(defun harness-snapshot-test--forms (text)
  "Return the forms of TEXT, read as the child reads them: as data only."
  (let ((read-eval nil) (forms nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (progn (skip-chars-forward " \t\n") (not (eobp)))
        (push (read (current-buffer)) forms)))
    (nreverse forms)))

(defun harness-snapshot-test--value (forms name)
  "Return the value the variable NAME has in FORMS, or `:absent'."
  (let ((form (cl-find-if (lambda (f) (and (eq (car-safe f) 'v) (equal (symbol-name (cadr f)) name))) forms)))
    (if form (nth 2 form) :absent)))

(defun harness-snapshot-test--buffer (forms name)
  "Return the plist of the buffer NAME in FORMS, or nil."
  (cl-some (lambda (f) (and (eq (car-safe f) 'b) (equal (plist-get (cdr f) :name) name) (cdr f))) forms))

(defun harness-snapshot-test--manifest (forms)
  "Return the manifest plist of FORMS."
  (cdr (cl-find-if (lambda (f) (eq (car-safe f) 'manifest)) forms)))

(defun harness-snapshot-test--object-p (value kind)
  "Non-nil when VALUE is the placeholder `harness-user-object' for a KIND."
  (and (recordp value) (eq (aref value 0) 'harness-user-object) (eq (aref value 1) kind)))

;;;; The values

(defvar harness-snapshot-test--plain '(1 "two" (3.5 [4 5]) ((a . b) (c . d)) nil t :key))
(defvar harness-snapshot-test--text (concat "café \"quoted\" \\ back\nline\t" (propertize "bold" 'face 'bold) " λ\U0001F600"))
(defvar harness-snapshot-test--numbers (list 1.5 1.0e+INF -1.0e+INF 0.0e+NaN (expt 10 40) -7 most-positive-fixnum))
(defvar harness-snapshot-test--shared (let ((x (list 1 2))) (list x x)))
(defvar harness-snapshot-test--circular (let ((l (list 1 2 3))) (setcdr (last l) l) l))
(defvar harness-snapshot-test--car-circle (let ((x (list nil))) (setcar x x) x))
(defvar harness-snapshot-test--hash
  (let ((h (make-hash-table :test 'equal)))
    (puthash "k" '(1 2) h) (puthash 'sym [a b] h) (puthash 3 "three" h) h))
(cl-defstruct harness-snapshot-test-rec name (size 3) tags)
(defvar harness-snapshot-test--record (make-harness-snapshot-test-rec :name "fred" :tags '(a b)))
(defvar harness-snapshot-test--bool (make-bool-vector 5 t))

(ert-deftest harness-snapshot-a-value-is-copied-as-data ()
  "Numbers, strings, lists, vectors, hash tables, records, circles and
shared structure come back as the data they are; text properties do not."
  (harness-snapshot-test--with "\\`harness-snapshot-test--"
    (let* ((forms (harness-snapshot-test--forms (car (harness-snapshot-test--take))))
           (v (lambda (name) (harness-snapshot-test--value forms (concat "harness-snapshot-test--" name)))))
      (should (equal harness-snapshot-test--plain (funcall v "plain")))
      (should (equal (substring-no-properties harness-snapshot-test--text) (funcall v "text")))
      (should-not (text-properties-at 0 (funcall v "text")))
      (should (equal (take 2 harness-snapshot-test--numbers) (take 2 (funcall v "numbers"))))
      (should (equal (expt 10 40) (nth 4 (funcall v "numbers"))))
      (should (= most-positive-fixnum (nth 6 (funcall v "numbers"))))
      (should (isnan (nth 3 (funcall v "numbers"))))
      (let ((shared (funcall v "shared")))
        (should (equal '((1 2) (1 2)) shared))
        (should (eq (car shared) (cadr shared))))
      (let ((circle (funcall v "circular")))
        (should (equal '(1 2 3) (take 3 circle)))
        (should (eq circle (nthcdr 3 circle))))
      (let ((circle (funcall v "car-circle")))
        (should (eq circle (car circle))))
      (let ((hash (funcall v "hash")))
        (should (hash-table-p hash))
        (should (eq 'equal (hash-table-test hash)))
        (should (equal '(1 2) (gethash "k" hash)))
        (should (equal [a b] (gethash 'sym hash)))
        (should (equal "three" (gethash 3 hash))))
      (let ((record (funcall v "record")))
        (should (recordp record))
        (should (eq 'harness-snapshot-test-rec (aref record 0)))
        (should (equal '("fred" 3 (a b)) (cl-loop for i from 1 below (length record) collect (aref record i)))))
      (should (equal harness-snapshot-test--bool (funcall v "bool"))))))

(ert-deftest harness-snapshot-the-text-is-plain-ascii-on-one-line-a-value ()
  "A value is printed on one line with the non-ASCII escaped, so that the
text crosses a pipe, a JSON string and a file whatever the user's Emacs
holds."
  (harness-snapshot-test--with "\\`harness-snapshot-test--text\\'"
    (let* ((text (car (harness-snapshot-test--take)))
           (line (cl-find-if (lambda (l) (string-prefix-p "(v harness-snapshot-test--text " l))
                             (split-string text "\n"))))
      (should line)
      (should-not (string-match-p "[^\x20-\x7e]" line))
      (should-not (string-match-p "\n" line)))))

;;;; What data cannot hold

(ert-deftest harness-snapshot-objects-that-are-not-data-are-placeholders ()
  "A buffer, marker, window, frame, process, overlay, subr, function,
char-table and obarray are `#s(harness-user-object KIND \"DESCRIPTION\")'
in the copy: readable, naming what the object was and calling nothing.
A process is named by its name and status, never its command line."
  (let ((process (make-pipe-process :name "harness-snapshot-test-proc" :noquery t))
        (buffer (generate-new-buffer "harness-snapshot-test-buffer")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "some text")
          (let ((overlay (make-overlay 2 4))
                (marker (copy-marker 3)))
            (defvar harness-snapshot-test--objects nil)
            (setq harness-snapshot-test--objects
                  (list buffer marker (selected-window) (selected-frame) process overlay
                        (symbol-function 'car) (lambda (x) x) (byte-compile (lambda (y) (+ y 1)))
                        (make-char-table 'harness-snapshot-test) (obarray-make)))
            (harness-snapshot-test--with "\\`harness-snapshot-test--objects\\'"
              (let* ((forms (harness-snapshot-test--forms (car (harness-snapshot-test--take))))
                     (objects (harness-snapshot-test--value forms "harness-snapshot-test--objects")))
                (should (= 11 (length objects)))
                (cl-loop for kind in '(buffer marker window frame process overlay subr function function
                                              char-table obarray)
                         for object in objects
                         do (should (harness-snapshot-test--object-p object kind)))
                (should (equal "harness-snapshot-test-buffer" (aref (nth 0 objects) 2)))
                (should (string-search "harness-snapshot-test-buffer" (aref (nth 1 objects) 2)))
                (should (string-search "harness-snapshot-test-proc" (aref (nth 4 objects) 2)))
                (should (equal "car" (aref (nth 6 objects) 2)))
                ;; Byte-code is never copied: a reader would turn it back into code.
                (should-not (cl-some #'byte-code-function-p objects))))))
      (delete-process process)
      (kill-buffer buffer))))

;;;; Bounds

(defvar harness-snapshot-test--big-string nil)
(defvar harness-snapshot-test--big-list nil)
(defvar harness-snapshot-test--deep nil)
(defvar harness-snapshot-test--small 42)

(ert-deftest harness-snapshot-a-value-too-big-is-marked-and-never-walked ()
  "A value that prints to more than 64 KB is `#s(harness-user-truncated
NAME SIZE)', and a value of millions of pieces is given up after a bounded
walk: the copy never spends more on one value than its budget, so a
huge variable cannot keep the user's Emacs busy."
  (setq harness-snapshot-test--big-string (make-string 100000 ?x)
        harness-snapshot-test--big-list (make-list 3000000 1)
        harness-snapshot-test--deep (let ((x nil)) (dotimes (_ 5000) (setq x (list x))) x))
  (unwind-protect
      (harness-snapshot-test--with "\\`harness-snapshot-test--\\(big\\|deep\\|small\\)"
        (let* ((start (float-time))
               (text (car (harness-snapshot-test--take)))
               (elapsed (- (float-time) start))
               (forms (harness-snapshot-test--forms text))
               (manifest (harness-snapshot-test--manifest forms)))
          (should (< elapsed 5))
          (should (= 42 (harness-snapshot-test--value forms "harness-snapshot-test--small")))
          (let ((string (harness-snapshot-test--value forms "harness-snapshot-test--big-string")))
            (should (eq 'harness-user-truncated (aref string 0)))
            (should (equal "harness-snapshot-test--big-string" (aref string 1)))
            (should (> (aref string 2) 100000)))
          (let ((list (harness-snapshot-test--value forms "harness-snapshot-test--big-list")))
            (should (eq 'harness-user-truncated (aref list 0)))
            (should (> (aref list 2) 1000)))
          ;; Nesting 5000 deep is cut where the copy stops, not an error.
          (let ((deep (harness-snapshot-test--value forms "harness-snapshot-test--deep")) (depth 0))
            (while (consp deep) (setq deep (car deep) depth (1+ depth)))
            (should (< 50 depth 200))
            (should (harness-snapshot-test--object-p deep 'too-deep)))
          (should (equal '("harness-snapshot-test--big-list" "harness-snapshot-test--big-string")
                         (sort (mapcar #'car (plist-get manifest :too-big)) #'string<)))))
    (setq harness-snapshot-test--big-string nil harness-snapshot-test--big-list nil
          harness-snapshot-test--deep nil)))

;;;; Slices

(ert-deftest harness-snapshot-a-copy-comes-in-slices-with-a-cursor ()
  "Each request answers a chunk, the cursor of the next and whether that
was the last, and works for about the time it is given: a copy that does
not fit a chunk comes in several, and the chunks put together are the
copy."
  (dotimes (i 300) (set (intern (format "harness-snapshot-test--many-%03d" i)) (make-string 50 (+ ?a (% i 26)))))
  (unwind-protect
      (harness-snapshot-test--buffers nil
       (harness-snapshot-test--with "\\`harness-snapshot-test--many-"
        ;; One variable per chunk at least: small chunks, many slices.
        (let* ((taken (harness-snapshot-test--take (list :maxChars 1000)))
               (slices (cdr taken)))
          (should (> (length slices) 20))
          (dolist (slice (butlast slices))
            (should (stringp (plist-get slice :next)))
            (should (eq :false (plist-get slice :done)))
            ;; The header is 4 KB of features; an item is not cut.
            (should (< (length (plist-get slice :chunk)) 8000)))
          (let ((last (car (last slices))))
            (should (eq t (plist-get last :done)))
            (should-not (plist-get last :next)))
          ;; The same copy in one go is the same forms.
          (let ((whole (harness-snapshot-test--take (list :maxChars (* 1024 1024) :seconds 0.25))))
            (should (equal (mapcar (lambda (f) (if (eq (car-safe f) 'v) f (car f)))
                                   (cl-remove-if (lambda (f) (memq (car-safe f) '(snapshot manifest b)))
                                                 (harness-snapshot-test--forms (car whole))))
                           (mapcar (lambda (f) (if (eq (car-safe f) 'v) f (car f)))
                                   (cl-remove-if (lambda (f) (memq (car-safe f) '(snapshot manifest b)))
                                                 (harness-snapshot-test--forms (car taken))))))
            (should (< (length (cdr whole)) (length slices)))))
        ;; The time asked for is the time worked: a tiny budget gives tiny slices.
        (let* ((answer (harness-snapshot-slice (list :seconds 0.001 :maxChars (* 1024 1024)))))
          (should (stringp (plist-get answer :next)))
          (should (< (length (plist-get answer :chunk)) 20000))
          (harness-snapshot-slice (list :cursor (plist-get answer :next) :release t)))))
    (dotimes (i 300) (makunbound (intern (format "harness-snapshot-test--many-%03d" i))))))

(ert-deftest harness-snapshot-a-cursor-cannot-skip-repeat-or-outlive-its-copy ()
  "A slice asked for out of order is refused, so none is lost or given
twice; a cursor nobody knows, or of a copy that was idle too long, is an
error; `release' drops a copy; and only a few copies are in the making."
  (harness-snapshot-test--with "\\`harness-snapshot-test--small\\'"
    (let* ((first (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001)))
           (cursor (plist-get first :next)))
      (should (string-match "\\`\\(.+\\):1\\'" cursor))
      ;; Not the next slice.
      (should-error (harness-snapshot-slice (list :cursor (concat (match-string 1 cursor) ":2"))))
      (should-error (harness-snapshot-slice (list :cursor (concat (match-string 1 cursor) ":0"))))
      (should-error (harness-snapshot-slice (list :cursor "snap999-0000:1")))
      (should-error (harness-snapshot-slice (list :cursor "nonsense")))
      ;; The next one, whole.
      (let ((rest (harness-snapshot-slice (list :cursor cursor :maxChars (* 1024 1024) :seconds 0.25))))
        (should (eq t (plist-get rest :done))))
      ;; A finished copy is gone.
      (should-error (harness-snapshot-slice (list :cursor cursor)))
      ;; Release.
      (let* ((a (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001))))
        (should (plist-get (harness-snapshot-slice (list :cursor (plist-get a :next) :release t)) :released))
        (should-error (harness-snapshot-slice (list :cursor (plist-get a :next)))))
      ;; Idle too long.
      (let* ((a (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001)))
             (harness-snapshot-idle-seconds -1))
        (should-error (harness-snapshot-slice (list :cursor (plist-get a :next)))))
      ;; At most two in the making: a third drops the oldest.
      (let* ((a (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001)))
             (b (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001)))
             (c (harness-snapshot-slice (list :maxChars 1000 :seconds 0.001))))
        (should-error (harness-snapshot-slice (list :cursor (plist-get a :next))))
        (should (plist-get (harness-snapshot-slice (list :cursor (plist-get b :next) :maxChars (* 1024 1024) :seconds 0.25))
                           :chunk))
        (harness-snapshot-slice (list :cursor (plist-get c :next) :release t))))
    (setq harness-snapshot--states nil)))

;;;; Credentials

(defvar harness-snapshot-test--password "GLOBAL-SECRET-VALUE")
(defvar harness-snapshot-test--api-key "APIKEY-SECRET-VALUE")
(defvar-local harness-snapshot-test--session-token "LOCAL-TOKEN-VALUE")
(defvar harness-snapshot-test--visible "VISIBLE-VALUE")
(defvar harness-snapshot-test--config
  '((name . "visible-name") (password . "ALIST-PASSWORD-VALUE") (:api-key . "ALIST-KEY-VALUE") (port . 22)))
(defvar harness-snapshot-test--plist '(:host "visible-host" :token "PLIST-TOKEN-VALUE" :port 22))
(defvar harness-snapshot-test--list-style '("password" "LIST-PASSWORD-VALUE" "visible-after"))
(defvar harness-snapshot-test--table
  (let ((h (make-hash-table :test 'equal)))
    (puthash "password" "TABLE-PASSWORD-VALUE" h) (puthash "name" "visible-name" h) h))
(cl-defstruct harness-snapshot-test-conn host password (port 22))
(defvar harness-snapshot-test--struct
  (make-harness-snapshot-test-conn :host "visible-host" :password "STRUCT-PASSWORD-VALUE"))

(defconst harness-snapshot-test--secrets
  '("GLOBAL-SECRET-VALUE" "APIKEY-SECRET-VALUE" "LOCAL-TOKEN-VALUE" "ALIST-PASSWORD-VALUE"
    "ALIST-KEY-VALUE" "PLIST-TOKEN-VALUE" "LIST-PASSWORD-VALUE" "TABLE-PASSWORD-VALUE"
    "STRUCT-PASSWORD-VALUE" "ENV-TOKEN-VALUE" "ENV-KEY-VALUE" "URLPASS-VALUE" "BUFFER-SECRET-TEXT")
  "The fake secrets of these tests; none may be in a copy.")

(ert-deftest harness-snapshot-credentials-are-withheld-by-name ()
  "A variable named like a credential is left out, global or buffer-local;
the value after a key named like one, in an alist, a plist, a list, a
hash table or a structure, is withheld; an environment variable named
like one has its value withheld; a buffer named for credentials, or
visiting such a file, is left out.  The manifest names them, and nothing
else of them: no copy holds any of the fake secrets, which is checked on
the text, not on the forms read from it."
  (let ((env-buffer (generate-new-buffer "harness-snapshot-test-env"))
        (named (generate-new-buffer "harness-snapshot-test-passwords"))
        (visiting (generate-new-buffer "harness-snapshot-test-visiting"))
        (plain (generate-new-buffer "harness-snapshot-test-plain")))
    (unwind-protect
        (progn
          (with-current-buffer env-buffer
            (setq-local harness-snapshot-test--session-token "LOCAL-TOKEN-VALUE"))
          (with-current-buffer named (insert "BUFFER-SECRET-TEXT"))
          (with-current-buffer visiting
            (insert "BUFFER-SECRET-TEXT")
            (setq buffer-file-name "/home/someone/.authinfo.gpg"))
          (with-current-buffer plain (insert "plain text") (setq buffer-file-name "/home/someone/notes.txt"))
          (let ((process-environment
                 (append '("HARNESS_TEST_PLAIN=visible-env" "HARNESS_TEST_API_TOKEN=ENV-TOKEN-VALUE"
                           "HARNESS_TEST_KEY=ENV-KEY-VALUE" "DATABASE_URL=postgres://user:URLPASS-VALUE@host/db")
                         process-environment)))
            (harness-snapshot-test--buffers (list env-buffer named visiting plain)
             (harness-snapshot-test--with "\\`\\(harness-snapshot-test--\\|process-environment\\'\\)"
              (let* ((text (car (harness-snapshot-test--take)))
                     (forms (harness-snapshot-test--forms text))
                     (manifest (harness-snapshot-test--manifest forms))
                     (v (lambda (name) (harness-snapshot-test--value forms name))))
                (dolist (secret harness-snapshot-test--secrets)
                  (let ((pos (string-search secret text)))
                    (when pos
                      (let ((start (or (string-match-p "\n([^\n]*\\'" (substring text 0 pos)) 0)))
                        (ert-fail (list "a fake secret is in the copy" secret
                                        (substring text start (min (length text) (+ start 100)))))))))
                ;; Left out, and named.
                (should (eq :absent (funcall v "harness-snapshot-test--password")))
                (should (eq :absent (funcall v "harness-snapshot-test--api-key")))
                (should (eq :absent (funcall v "harness-snapshot-test--session-token")))
                (should (member "harness-snapshot-test--password" (plist-get manifest :withheld-variables)))
                (should (member "harness-snapshot-test--session-token" (plist-get manifest :withheld-variables)))
                ;; The rest is there.
                (should (equal "VISIBLE-VALUE" (funcall v "harness-snapshot-test--visible")))
                ;; Nested: the value after a key that names a credential.
                (should (equal '((name . "visible-name") (password . "<withheld>") (:api-key . "<withheld>") (port . 22))
                               (funcall v "harness-snapshot-test--config")))
                (should (equal '(:host "visible-host" :token "<withheld>" :port 22)
                               (funcall v "harness-snapshot-test--plist")))
                (should (equal '("password" "<withheld>" "visible-after")
                               (funcall v "harness-snapshot-test--list-style")))
                (let ((table (funcall v "harness-snapshot-test--table")))
                  (should (equal "<withheld>" (gethash "password" table)))
                  (should (equal "visible-name" (gethash "name" table))))
                (let ((struct (funcall v "harness-snapshot-test--struct")))
                  (should (equal "visible-host" (aref struct 1)))
                  (should (equal "<withheld>" (aref struct 2)))
                  (should (equal 22 (aref struct 3))))
                (should (>= (plist-get manifest :masked-values) 6))
                ;; The environment, entry by entry.
                (let ((env (funcall v "process-environment")))
                  (should (member "HARNESS_TEST_PLAIN=visible-env" env))
                  (should (member "HARNESS_TEST_API_TOKEN=<withheld>" env))
                  (should (member "HARNESS_TEST_KEY=<withheld>" env))
                  (should (member "DATABASE_URL=<withheld>" env)))
                ;; Buffers: the plain one is there; the others are named, not copied.
                (should (harness-snapshot-test--buffer forms "harness-snapshot-test-plain"))
                (should (equal "plain text" (plist-get (harness-snapshot-test--buffer forms "harness-snapshot-test-plain") :text)))
                (should-not (harness-snapshot-test--buffer forms "harness-snapshot-test-passwords"))
                (should-not (harness-snapshot-test--buffer forms "harness-snapshot-test-visiting"))
                (should (member "harness-snapshot-test-passwords" (plist-get manifest :left-out-buffers)))
                (should (member "harness-snapshot-test-visiting" (plist-get manifest :left-out-buffers)))
                ;; The local value in a buffer is withheld by the name of its variable.
                (should-not (assq 'harness-snapshot-test--session-token
                                  (plist-get (harness-snapshot-test--buffer forms "harness-snapshot-test-env") :locals))))))))
      (mapc #'kill-buffer (list env-buffer named visiting plain)))))

(ert-deftest harness-snapshot-the-lists-of-what-is-withheld-are-the-users-to-extend ()
  "The regexps are options: a name the user adds is withheld, one they
take away is not, the harness's own `harness-config-secret-regexp' adds
to the first, and a regexp that does not compile stops the copy instead
of letting everything through."
  (defvar harness-snapshot-test--mine "MINE-VALUE")
  (let ((buffer (generate-new-buffer "harness-snapshot-test-diary")))
    (unwind-protect
        (harness-snapshot-test--buffers (list buffer)
         (harness-snapshot-test--with "\\`harness-snapshot-test--\\(mine\\|visible\\|password\\)\\'"
          (with-current-buffer buffer (insert "diary"))
          (let* ((forms (harness-snapshot-test--forms (car (harness-snapshot-test--take))))
                 (v (lambda (name) (harness-snapshot-test--value forms name))))
            (should (equal "MINE-VALUE" (funcall v "harness-snapshot-test--mine")))
            (should (harness-snapshot-test--buffer forms "harness-snapshot-test-diary")))
          ;; Added.
          (let* ((harness-snapshot-withheld-regexp (concat harness-snapshot-withheld-regexp "\\|--mine\\'"))
                 (harness-snapshot-withheld-buffers-regexp (concat harness-snapshot-withheld-buffers-regexp "\\|diary"))
                 (forms (harness-snapshot-test--forms (car (harness-snapshot-test--take)))))
            (should (eq :absent (harness-snapshot-test--value forms "harness-snapshot-test--mine")))
            (should-not (harness-snapshot-test--buffer forms "harness-snapshot-test-diary"))
            (should (member "harness-snapshot-test-diary"
                            (plist-get (harness-snapshot-test--manifest forms) :left-out-buffers))))
          ;; Taken away: the user decides.
          (let* ((harness-snapshot-withheld-regexp "nothing-matches-this")
                 (forms (harness-snapshot-test--forms (car (harness-snapshot-test--take)))))
            (should (equal "GLOBAL-SECRET-VALUE" (harness-snapshot-test--value forms "harness-snapshot-test--password"))))
          ;; The harness's own option, where it is defined.
          (defvar harness-config-secret-regexp)
          (let* ((harness-config-secret-regexp "visible\\'")
                 (forms (harness-snapshot-test--forms (car (harness-snapshot-test--take)))))
            (should (eq :absent (harness-snapshot-test--value forms "harness-snapshot-test--visible"))))
          ;; A regexp that does not compile fails closed.
          (let ((harness-snapshot-withheld-regexp "\\(unclosed"))
            (should-error (harness-snapshot-test--take)))
          (setq harness-snapshot--states nil)))
      (kill-buffer buffer))))

(ert-deftest harness-snapshot-the-default-lists-hold-back-what-they-should-and-little-else ()
  "Names of credentials, caches of authentication and what the user typed
or copied are withheld; ordinary variables and `load-history' are not."
  (dolist (name '("password-cache" "my-api-key" "my_API_KEY" "github-token" "client-secret" "url-cookie-storage"
                  "auth-source-cache" "auth-sources" "plstore-cache" "epa-file-name-regexp" "tramp-cache-data"
                  "kill-ring" "minibuffer-history" "search-ring" "register-alist" "oauth2-token"
                  "harness-acp-remote--sessions" "harness-redact--pending" "harness-secrets--entries"
                  "harness-openai-api-key" "ssh-passphrase" "my-private-key" "harness-snapshot--states"))
    (should (harness-snapshot--withheld-name-p name)))
  (dolist (name '("load-path" "fill-column" "major-mode" "load-history" "harness-model" "case-fold-search"
                  "default-directory" "features" "auto-mode-alist" "harness-state-directory"))
    (should-not (harness-snapshot--withheld-name-p name)))
  (dolist (name '("/home/u/.authinfo" "/home/u/.netrc" "secrets.gpg" "id_rsa" "my-password-notes"
                  "/home/u/.ssh/config" "/x/.aws/credentials" "kubeconfig" "k3s.yaml" ".env" "api-token.txt"))
    (let ((buffer (generate-new-buffer name)))
      (unwind-protect (should (harness-snapshot--withheld-buffer-p buffer))
        (kill-buffer buffer))))
  (dolist (name '("*scratch*" "init.el" "README.md" "harness-snapshot.el"))
    (let ((buffer (generate-new-buffer name)))
      (unwind-protect (should-not (harness-snapshot--withheld-buffer-p buffer))
        (kill-buffer buffer)))))

;;;; Buffers

(ert-deftest harness-snapshot-buffers-are-copied-within-bounds ()
  "A buffer comes with its name, mode, file, directory, point, modified
flag, local variables and text; one too long is cut to the part round
point and says which; hidden buffers are left out and counted; and no
more than the limit are copied, the manifest saying how many were not."
  (let ((buffers nil))
    (unwind-protect
        (progn
          (dotimes (i 4)
            (push (generate-new-buffer (format "harness-snapshot-test-b%d" i)) buffers))
          (setq buffers (nreverse buffers))
          (with-current-buffer (nth 0 buffers)
            (text-mode)
            (insert "alpha\nbeta\ngamma\n")
            (goto-char 7)
            (setq buffer-file-name "/tmp/harness-snapshot-test-b0.txt")
            (setq default-directory "/tmp/")
            (setq-local fill-column 33)
            (setq-local harness-snapshot-test--visible '(a b)))
          (with-current-buffer (nth 1 buffers)
            (insert (apply #'concat (mapcar (lambda (i) (format "line %04d\n" i)) (number-sequence 1 200))))
            (goto-char (point-min))
            (forward-line 100))
          (with-current-buffer (generate-new-buffer " harness-snapshot-test-hidden") (insert "hidden"))
          (harness-snapshot-test--with "\\`nothing-matches-this\\'"
           (harness-snapshot-test--buffers (append buffers (list (get-buffer " harness-snapshot-test-hidden")))
            (let* ((harness-snapshot-buffer-chars 200)
                   (forms (harness-snapshot-test--forms (car (harness-snapshot-test--take))))
                   (manifest (harness-snapshot-test--manifest forms))
                   (b0 (harness-snapshot-test--buffer forms "harness-snapshot-test-b0"))
                   (b1 (harness-snapshot-test--buffer forms "harness-snapshot-test-b1")))
              (should (equal "alpha\nbeta\ngamma\n" (plist-get b0 :text)))
              (should (eq 'text-mode (plist-get b0 :mode)))
              (should (equal "/tmp/harness-snapshot-test-b0.txt" (plist-get b0 :file)))
              (should (equal "/tmp/" (plist-get b0 :directory)))
              (should (= 7 (plist-get b0 :point)))
              (should (eq t (plist-get b0 :modified)))
              (should (= 17 (plist-get b0 :size)))
              (should (= 33 (alist-get 'fill-column (plist-get b0 :locals))))
              (should (equal '(a b) (alist-get 'harness-snapshot-test--visible (plist-get b0 :locals))))
              ;; A long one is cut round point, and says so.
              (should (= 200 (length (plist-get b1 :text))))
              (should (<= (plist-get b1 :text-from) (plist-get b1 :point) (plist-get b1 :text-to)))
              (should (= 200 (- (plist-get b1 :text-to) (plist-get b1 :text-from))))
              (should (string-match-p "line 0101" (plist-get b1 :text)))
              (should (assoc "harness-snapshot-test-b1" (plist-get manifest :cut-buffers)))
              ;; Hidden buffers are counted, not copied.
              (should-not (harness-snapshot-test--buffer forms " harness-snapshot-test-hidden"))
              (should (>= (plist-get manifest :hidden-buffers) 1)))))
          ;; Only so many, the most recently used first.
          (harness-snapshot-test--with "\\`nothing-matches-this\\'"
           (harness-snapshot-test--buffers buffers
            (let* ((harness-snapshot-max-buffers 2)
                   (forms (harness-snapshot-test--forms (car (harness-snapshot-test--take))))
                   (manifest (harness-snapshot-test--manifest forms)))
              (should (= 2 (plist-get manifest :buffers)))
              (should (= 2 (cl-count 'b forms :key #'car-safe)))
              (should (> (plist-get (plist-get manifest :not-reached) :buffers) 0))))))
      (mapc #'kill-buffer (cl-remove-if-not #'buffer-live-p buffers))
      (when (get-buffer " harness-snapshot-test-hidden") (kill-buffer " harness-snapshot-test-hidden")))))

(ert-deftest harness-snapshot-the-manifest-says-what-the-copy-leaves-out ()
  "A copy that reaches its size stops where it is and says how many
variables it did not reach; the manifest counts the variables and the
characters, and names the limits it worked under; the copy is never
longer than the limit."
  (dotimes (i 12) (set (intern (format "harness-snapshot-test--filler-%d" i)) (make-string 30000 ?z)))
  (unwind-protect
      (harness-snapshot-test--buffers nil
       (harness-snapshot-test--with "\\`harness-snapshot-test--filler-"
        (let* ((harness-snapshot-max-chars 200000)
               (text (car (harness-snapshot-test--take)))
               (forms (harness-snapshot-test--forms text))
               (manifest (harness-snapshot-test--manifest forms)))
          (should (<= (length text) 200000))
          (should (<= (plist-get manifest :chars) 200000))
          (should (> (plist-get manifest :variables) 2))
          (should (> (plist-get (plist-get manifest :not-reached) :variables) 0))
          (should (= 12 (+ (plist-get manifest :variables)
                           (plist-get (plist-get manifest :not-reached) :variables))))
          (should (= (plist-get manifest :variables) (cl-count 'v forms :key #'car-safe)))
          (should (= harness-snapshot-max-chars (plist-get (plist-get manifest :limits) :max-chars)))
          (should (= 1 (plist-get manifest :version))))))
    (dotimes (i 12) (makunbound (intern (format "harness-snapshot-test--filler-%d" i))))))

;;;; Reading changes nothing

(defvar harness-snapshot-test--ran nil
  "Set by anything of the user's that a copy wrongly calls.")
(defvar harness-snapshot-test--watched '(1 2 3))
(cl-defstruct harness-snapshot-test-printed a)
(cl-defmethod cl-print-object ((_o harness-snapshot-test-printed) _stream)
  (setq harness-snapshot-test--ran 'cl-print-object))

(ert-deftest harness-snapshot-a-copy-changes-and-calls-nothing-of-the-users ()
  "Taking a copy creates no buffer and interns no symbol, and runs none of
what the user's Emacs has set up to run on a read: a variable watcher,
the print method of a structure, the test of a hash table, a function
among the variables, or the accessor of a structure."
  (define-hash-table-test 'harness-snapshot-test-ht
    (lambda (a b) (setq harness-snapshot-test--ran 'hash-test) (equal a b))
    (lambda (k) (setq harness-snapshot-test--ran 'hash-fn) (sxhash-equal k)))
  (let ((table (make-hash-table :test 'harness-snapshot-test-ht)))
    (puthash "a" 1 table)
    (defvar harness-snapshot-test--userland nil)
    (setq harness-snapshot-test--userland
          (list table (make-harness-snapshot-test-printed :a 1)
                (lambda () (setq harness-snapshot-test--ran 'lambda))
                'harness-snapshot-test--ran))
    (add-variable-watcher 'harness-snapshot-test--watched
                          (lambda (&rest _) (setq harness-snapshot-test--ran 'watcher)))
    (advice-add 'harness-snapshot-test-printed-a :before
                (lambda (&rest _) (setq harness-snapshot-test--ran 'accessor))
                '((name . harness-snapshot-test)))
    (unwind-protect
        (harness-snapshot-test--with "\\`harness-snapshot-test--\\(userland\\|watched\\|ran\\)\\'"
          (let ((buffers (buffer-list))
                (kill-ring-before (copy-sequence kill-ring))
                (symbols 0))
            (setq harness-snapshot-test--ran nil)
            (mapatoms (lambda (_) (cl-incf symbols)))
            (let* ((text (car (harness-snapshot-test--take)))
                   (after 0))
              (mapatoms (lambda (_) (cl-incf after)))
              (should-not harness-snapshot-test--ran)
              (should (equal buffers (buffer-list)))
              (should (equal kill-ring-before kill-ring))
              (should (= symbols after))
              ;; What was copied is data.
              (let ((forms (harness-snapshot-test--forms text)))
                (should (eq 'harness-user-object
                            (aref (nth 2 (harness-snapshot-test--value forms "harness-snapshot-test--userland")) 0)))))))
      (advice-remove 'harness-snapshot-test-printed-a 'harness-snapshot-test)
      (remove-variable-watcher 'harness-snapshot-test--watched
                               (car (get-variable-watchers 'harness-snapshot-test--watched))))))

;;;; The whole Emacs

(ert-deftest harness-snapshot-this-whole-emacs-is-copied-in-slices-and-read-back ()
  "A copy of the Emacs the tests run in has its variables and buffers,
reads back as data, holds none of the fake secrets, and arrives in
slices that each work for about the time they are given."
  (defvar harness-snapshot-test--whole 'present)
  (let* ((start (float-time))
         (cursor nil) (chunks nil) (slices 0) (slowest 0))
    (catch 'done
      (while t
        (let* ((t0 (float-time))
               (answer (harness-snapshot-slice (and cursor (list :cursor cursor)))))
          (setq slowest (max slowest (- (float-time) t0)))
          (cl-incf slices)
          (push (plist-get answer :chunk) chunks)
          (setq cursor (plist-get answer :next))
          (when (eq t (plist-get answer :done)) (throw 'done nil)))))
    (let* ((text (apply #'concat (nreverse chunks)))
           (forms (harness-snapshot-test--forms text))
           (manifest (harness-snapshot-test--manifest forms)))
      (should (eq 'snapshot (car (car forms))))
      (should (equal emacs-version (plist-get (cdr (car forms)) :emacs-version)))
      (should (memq 'harness-snapshot (plist-get (cdr (car forms)) :features)))
      (should (eq 'present (harness-snapshot-test--value forms "harness-snapshot-test--whole")))
      (should (equal load-path (harness-snapshot-test--value forms "load-path")))
      (should (> (plist-get manifest :variables) 500))
      (should (= (plist-get manifest :variables) (cl-count 'v forms :key #'car-safe)))
      (should (harness-snapshot-test--buffer forms "*scratch*"))
      (should (> slices 1))
      ;; Slices are quick; the bound is loose so a busy machine does not fail it.
      (should (< slowest 1.0))
      (message "snapshot: %d variables, %d characters, %d slices, slowest %.0f ms, total %.1f s"
               (plist-get manifest :variables) (length text) slices (* 1000 slowest) (- (float-time) start))
      ;; The user's own value of a hook is data too, and `kill-emacs-hook' is in it.
      (should-not (eq :absent (harness-snapshot-test--value forms "kill-emacs-hook"))))))

(provide 'harness-snapshot-test)
;;; harness-snapshot-test.el ends here
