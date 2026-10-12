;;; harness-tasks-redact-test.el --- Tests for redacting task records  -*- lexical-binding: t; -*-

;;; Commentary:

;; `task/redact' takes a secret out of the task records and out of the
;; files that keep them.  Every secret here is a fake one, built when the
;; test runs, so that no value that looks real is committed; a test that
;; fails shows the values it compared, and they are made up.  The tests
;; put records in the table themselves: no task is submitted, so no
;; session, model or worktree is involved.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks--naming)
(defvar harness-tasks-store-in-repository)
(declare-function harness-tasks--put "harness-tasks")
(declare-function harness-tasks--load "harness-tasks")
(declare-function harness-tasks--project "harness-tasks")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks--global-store "harness-tasks")
(declare-function harness-tasks--repository-store "harness-tasks")
(declare-function harness-tasks--open-project "harness-tasks")
(declare-function harness-tasks-flush "harness-tasks")

(defmacro harness-tasks-redact-test-with (&rest body)
  "Load the modules the task records need in a throwaway state directory, run BODY.
Tasks are kept in the state directory, not in repositories, unless a
test binds `harness-tasks-store-in-repository' itself."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project provider tools session agent tasks))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--naming)
     (harness-tasks--forget-stores)
     ;; Nothing waits to be written over this test's files.
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil)
     (let ((harness-tasks-store-in-repository nil))
       ,@body)))

(defun harness-tasks-redact-test--value (n)
  "Return the Nth fake secret value, built now and never committed.
The first has a slash and a plus; the second a quote and a backslash,
which a JSON store writes escaped."
  (if (= n 1)
      (concat "FAKE" "/key+" (make-string 8 ?q) "/" (make-string 16 ?z))
    (concat "FAKE" "\"quote\\back" (make-string 8 ?w))))

(defun harness-tasks-redact-test--secret (n)
  "Return the Nth fake value as a secret, labelled."
  (harness-redaction-secret (harness-tasks-redact-test--value n) (format "fake key %d" n) "test"))

(defun harness-tasks-redact-test--project (name)
  "Make the directory NAME in the state directory; return its project root.
The root is as the tasks module keeps it in a record's `:project'."
  (let ((dir (expand-file-name (concat name "/") harness-state-directory)))
    (make-directory dir t)
    (harness-tasks--project dir)))

(defun harness-tasks-redact-test--make-repo (name)
  "Make a git repository NAME in the state directory; return its root."
  (let ((root (expand-file-name (concat name "/") harness-state-directory)))
    (make-directory root t)
    (let ((default-directory root))
      (unless (zerop (call-process "git" nil nil nil "init" "-q"))
        (error "Git init failed")))
    (harness-tasks--project root)))

(defun harness-tasks-redact-test--record (n project &rest props)
  "Return the record of task N in PROJECT with PROPS after the usual keys."
  (append (list :id (format "t-redact%02d" n) :project project :cwd project
                :state 'review :created (float n))
          props))

(defun harness-tasks-redact-test--add (&rest records)
  "Put RECORDS in the table and write the stores, as a harness that ran would."
  (dolist (record records) (harness-tasks--put record))
  (harness-tasks-flush))

(defun harness-tasks-redact-test--expected (object replacements)
  "Return OBJECT with REPLACEMENTS, (VALUE . PLACEHOLDER), made in its strings.
A check of the library's walk by a plain one: conses and strings only."
  (cond ((stringp object)
         (let ((text object))
           (dolist (r replacements text)
             (setq text (string-replace (car r) (cdr r) text)))))
        ((consp object)
         (cons (harness-tasks-redact-test--expected (car object) replacements)
               (harness-tasks-redact-test--expected (cdr object) replacements)))
        (t object)))

(defun harness-tasks-redact-test--table-text ()
  "Return every record in the table as text, ordered by id."
  (let (all)
    (maphash (lambda (id record) (push (cons id record) all)) harness-tasks--table)
    (prin1-to-string (sort all (lambda (a b) (string< (car a) (car b)))))))

(defun harness-tasks-redact-test--populate (project)
  "Put three tasks in PROJECT and write the stores; return what the tests need.
The first holds a secret in its prompt, the second in its report and
its feedback, the third none.  The value is a plist of the secrets
\(`:secrets', both fakes), the records (`:a', `:b', `:c') and the
text-for-text replacements that redacting them makes (`:replacements')."
  (let* ((s1 (harness-tasks-redact-test--secret 1))
         (s2 (harness-tasks-redact-test--secret 2))
         (v1 (plist-get s1 :value))
         (v2 (plist-get s2 :value))
         (a (harness-tasks-redact-test--record
             1 project :prompt (format "Deploy with KEY=%s and again %s." v1 v1)))
         (b (harness-tasks-redact-test--record
             2 project
             :report (list :summary (format "Printed %s by mistake." v1)
                           :problem "Nothing to fix."
                           :evidence (list (list :kind "note" :text (format "See %s." v2))
                                           (list :kind "code" :language "text"
                                                 :code (format "KEY=%s\nOTHER=%s" v1 v2)))
                           :at 5.0)
             :feedback (list (list :text (format "Please remove %s." v1) :at 6.0))))
         (c (harness-tasks-redact-test--record
             3 project :prompt "Nothing secret here." :recap "A quiet task.")))
    (harness-tasks-redact-test--add a b c)
    (list :secrets (list s1 s2) :a a :b b :c c
          :replacements (list (cons v1 (harness-redaction-placeholder s1))
                              (cons v2 (harness-redaction-placeholder s2))))))

(defun harness-tasks-redact-test--print (object)
  "Return OBJECT printed, as a log or a report would show it."
  (format "%S" object))

(ert-deftest harness-tasks-redact-takes-the-secret-out-of-every-field ()
  "Every string of every record is searched, and the stores keep no copy.
The call writes the stores itself, before anyone hears of the change."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (data (harness-tasks-redact-test--populate project))
           (secrets (plist-get data :secrets))
           (store (harness-tasks--global-store))
           (heard nil))
      ;; Both secrets are in the store, one of them written escaped.
      (should (= 7 (harness-redaction-file-count store secrets)))
      (harness-on 'task/changed
                  (lambda (view)
                    (push (list (plist-get view :id) (harness-redaction-file-count store secrets))
                          heard)))
      (let ((result (harness-call 'task/redact secrets)))
        (should (= 7 (plist-get result :count)))
        (should (equal (list (list :id "t-redact01" :count 2 :fields '(:prompt))
                             (list :id "t-redact02" :count 5 :fields '(:report :feedback)))
                       (plist-get result :tasks)))
        (should-not (plist-get result :files))
        (should (equal (list (list :file store :count 0)) (plist-get result :stores)))
        ;; Neither the report nor the harness log shows a value.
        (dolist (secret secrets)
          (should-not (string-search (plist-get secret :value)
                                     (harness-tasks-redact-test--print result)))
          (with-current-buffer (get-buffer-create harness-log-buffer-name)
            (should-not (string-search (plist-get secret :value) (buffer-string))))))
      ;; Written already: no timer had to fire for the store to be clean.
      (should (= 0 (harness-redaction-file-count store secrets)))
      (should-not harness-tasks--dirty)
      ;; The change was announced after the write, once for each task that held a secret.
      (should (equal '(("t-redact02" 0) ("t-redact01" 0)) heard))
      ;; Only the secrets were replaced, in the table and in the store.
      (should (equal (harness-tasks-redact-test--expected (plist-get data :a) (plist-get data :replacements))
                     (gethash "t-redact01" harness-tasks--table)))
      (should (equal (harness-tasks-redact-test--expected (plist-get data :b) (plist-get data :replacements))
                     (gethash "t-redact02" harness-tasks--table)))
      (should (eq (plist-get data :c) (gethash "t-redact03" harness-tasks--table)))
      (should (string-search (cdr (car (plist-get data :replacements))) (harness-read-file store)))
      (should (equal (list "t-redact01" "t-redact02" "t-redact03")
                     (mapcar (lambda (record) (plist-get record :id))
                             (harness-json-parse (harness-read-file store)))))
      ;; A second call finds nothing.
      (let ((again (harness-call 'task/redact secrets)))
        (should (= 0 (plist-get again :count)))
        (should-not (plist-get again :tasks))))))

(ert-deftest harness-tasks-redact-dry-run-changes-nothing ()
  "A dry run counts what a redaction would replace, in records and in files."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (data (harness-tasks-redact-test--populate project))
           (secrets (plist-get data :secrets))
           (store (harness-tasks--global-store))
           (backup (concat store ".bak"))
           (s1 (car secrets))
           (heard nil))
      (harness-write-file-atomically
       backup (harness-json-encode
               (list (list :id "t-old" :project project :prompt (format "old %s" (plist-get s1 :value))))))
      (let ((table (harness-tasks-redact-test--table-text))
            (store-text (harness-read-file store))
            (backup-text (harness-read-file backup)))
        (harness-on 'task/changed (lambda (view) (push (plist-get view :id) heard)))
        (let ((dry (harness-call 'task/redact secrets nil t)))
          (should (= 8 (plist-get dry :count)))
          (should (equal '("t-redact01" "t-redact02") (mapcar (lambda (task) (plist-get task :id))
                                                              (plist-get dry :tasks))))
          (should (equal (list (list :file backup :count 1)) (plist-get dry :files)))
          (should (equal (list (list :file store :count 7)) (plist-get dry :stores)))
          ;; Nothing changed: not the table, not a file, no news, no write waiting.
          (should (equal table (harness-tasks-redact-test--table-text)))
          (should (equal store-text (harness-read-file store)))
          (should (equal backup-text (harness-read-file backup)))
          (should-not heard)
          (should-not harness-tasks--dirty)
          ;; A redaction after it replaces what it counted.
          (let ((real (harness-call 'task/redact secrets)))
            (should (= (plist-get dry :count) (plist-get real :count)))
            (should (equal (plist-get dry :tasks) (plist-get real :tasks)))
            (should (equal (plist-get dry :files) (plist-get real :files)))
            (should (equal '("t-redact02" "t-redact01") heard))
            (should (= 0 (harness-redaction-file-count store secrets)))
            (should (= 0 (harness-redaction-file-count backup secrets)))))))))

(ert-deftest harness-tasks-redact-project-filter ()
  "A project limits the records, and a directory names the project as `task/list' reads it."
  (harness-tasks-redact-test-with
    (let* ((one (harness-tasks-redact-test--project "one"))
           (two (harness-tasks-redact-test--project "two"))
           (s1 (harness-tasks-redact-test--secret 1))
           (v1 (plist-get s1 :value))
           (secrets (list s1))
           (a1 (harness-tasks-redact-test--record 1 one :prompt (format "key %s" v1)))
           (a2 (harness-tasks-redact-test--record
                2 one :report (list :summary (format "key %s" v1) :evidence nil)))
           (b1 (harness-tasks-redact-test--record 3 two :prompt (format "key %s" v1)))
           (store (harness-tasks--global-store)))
      (harness-tasks-redact-test--add a1 a2 b1)
      (should (= 3 (harness-redaction-file-count store secrets)))
      ;; The first project only.
      (let ((result (harness-call 'task/redact secrets one)))
        (should (= 2 (plist-get result :count)))
        (should (equal '("t-redact01" "t-redact02")
                       (mapcar (lambda (task) (plist-get task :id)) (plist-get result :tasks))))
        ;; The other project's task is untouched, and so is its copy in the store.
        (should (eq b1 (gethash "t-redact03" harness-tasks--table)))
        (should (equal (list (list :file store :count 1)) (plist-get result :stores)))
        (should (= 1 (harness-redaction-file-count store secrets))))
      ;; The second, by a directory without its slash.
      (let ((result (harness-call 'task/redact secrets (directory-file-name two))))
        (should (= 1 (plist-get result :count)))
        (should (equal '("t-redact03")
                       (mapcar (lambda (task) (plist-get task :id)) (plist-get result :tasks))))
        (should (equal (list (list :file store :count 0)) (plist-get result :stores))))
      ;; Nothing is left for the other projects, or for all of them.
      (should (= 0 (plist-get (harness-call 'task/redact secrets) :count)))
      (should (= 0 (harness-redaction-file-count store secrets))))))

(ert-deftest harness-tasks-redact-backup-copy ()
  "The copy of the global store kept from before the move is redacted whole."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (s1 (harness-tasks-redact-test--secret 1))
           (v1 (plist-get s1 :value))
           (secrets (list s1))
           (store (harness-tasks--global-store))
           (backup (concat store ".bak")))
      (harness-tasks-redact-test--add
       (harness-tasks-redact-test--record 1 project :prompt (format "key %s" v1)))
      ;; Without a copy there is none to report; one without a secret is left alone.
      (should-not (plist-get (harness-call 'task/redact secrets nil t) :files))
      (harness-write-file-atomically
       backup (harness-json-encode (list (list :id "t-old" :project project :prompt "nothing secret"))))
      (let ((text (harness-read-file backup)))
        (should-not (plist-get (harness-call 'task/redact secrets nil t) :files))
        (should (equal text (harness-read-file backup))))
      ;; One with two records, one of them holding the secret twice.
      (harness-write-file-atomically
       backup (harness-json-encode
               (list (list :id "t-old1" :project project :created 1.0
                           :prompt (format "first %s and %s" v1 v1) :state "done")
                     (list :id "t-old2" :project project :created 2.0 :prompt "nothing secret"
                           :state "done"))))
      (let ((result (harness-call 'task/redact secrets)))
        ;; One record's occurrence and the copy's two.
        (should (= 3 (plist-get result :count)))
        (should (equal (list (list :file backup :count 2)) (plist-get result :files))))
      (should (= 0 (harness-redaction-file-count backup secrets)))
      (let ((records (harness-json-parse (harness-read-file backup)))
            (placeholder (harness-redaction-placeholder s1)))
        ;; Still a list of the same records, with the placeholder where the secret was.
        (should (equal '("t-old1" "t-old2") (mapcar (lambda (record) (plist-get record :id)) records)))
        (should (equal (format "first %s and %s" placeholder placeholder)
                       (plist-get (car records) :prompt)))
        (should (equal "nothing secret" (plist-get (cadr records) :prompt)))
        (should (equal 1.0 (plist-get (car records) :created)))))))

(ert-deftest harness-tasks-redact-repository-store-and-the-copy-a-save-makes ()
  "A repository's store is written clean, and so is the copy made when records first move."
  (skip-unless (executable-find "git"))
  (harness-tasks-redact-test-with
    (let* ((harness-tasks-store-in-repository t)
           (repo (harness-tasks-redact-test--make-repo "repo"))
           (plain (harness-tasks-redact-test--project "plain"))
           (s1 (harness-tasks-redact-test--secret 1))
           (v1 (plist-get s1 :value))
           (secrets (list s1))
           (global (harness-tasks--global-store))
           (backup (concat global ".bak"))
           (repository (harness-tasks--repository-store repo))
           ;; The store of a harness that kept every task in its state directory.
           (legacy (harness-json-encode
                    (list (list :id "t-legacy01" :project repo :cwd repo :state "done"
                                :outcome "end-turn" :created 1.0 :prompt (format "in git, key %s" v1))
                          (list :id "t-legacy02" :project plain :cwd plain :state "done"
                                :outcome "end-turn" :created 2.0 :prompt (format "outside git, key %s" v1))))))
      (should repository)
      (harness-write-file-atomically global legacy)
      (clrhash harness-tasks--table)
      (setq harness-tasks--loaded nil)
      (harness-tasks--load)
      (should (= 2 (hash-table-count harness-tasks--table)))
      (should-not (file-exists-p backup))
      (let ((result (harness-call 'task/redact secrets)))
        (should (= 4 (plist-get result :count)))
        (should (equal '("t-legacy01" "t-legacy02")
                       (mapcar (lambda (task) (plist-get task :id)) (plist-get result :tasks))))
        ;; The save moved the first record into its repository and copied the
        ;; global store aside as it did, with the secret in it.  The copy is
        ;; redacted after the save, and reported with the stores.
        (should (equal (list (list :file backup :count 2)) (plist-get result :files)))
        (should (equal (list (list :file global :count 0) (list :file repository :count 0))
                       (plist-get result :stores))))
      (should (file-exists-p backup))
      (dolist (file (list global backup repository))
        (should (= 0 (harness-redaction-file-count file secrets))))
      ;; The record lives in its repository's store, redacted.
      (should (string-search (harness-redaction-placeholder s1) (harness-read-file repository)))
      (should (string-search "t-legacy01" (harness-read-file repository)))
      (should-not (string-search "t-legacy01" (harness-read-file global))))))

(ert-deftest harness-tasks-redact-leaves-another-harness-store-alone ()
  "A repository store of another harness is counted, marked, and never written."
  (skip-unless (executable-find "git"))
  (harness-tasks-redact-test-with
    (let* ((harness-tasks-store-in-repository t)
           (repo (harness-tasks-redact-test--make-repo "shared"))
           (store (harness-tasks--repository-store repo))
           (other (harness-test-temp-dir))
           (s1 (harness-tasks-redact-test--secret 1))
           (theirs (harness-json-encode
                    (list :state-directory other
                          :tasks (list (list :id "t-theirs01" :project repo :cwd repo :state "review"
                                             :created 1.0
                                             :prompt (format "their key %s" (plist-get s1 :value))))))))
      (harness-write-file-atomically store theirs)
      (harness-tasks--open-project repo)
      (unwind-protect
          (let ((result (harness-call 'task/redact (list s1) repo)))
            (should-not (gethash "t-theirs01" harness-tasks--table))
            (should (= 0 (plist-get result :count)))
            (should (equal theirs (harness-read-file store)))
            (should (member (list :file store :count 1 :foreign t) (plist-get result :stores))))
        (ignore-errors (delete-directory other t))))))

(ert-deftest harness-tasks-redact-scrubs-the-text-of-a-title-request ()
  "The text a title request is out for is a copy of the prompt; it goes with it."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (s1 (harness-tasks-redact-test--secret 1))
           (prompt (format "Rotate key %s today" (plist-get s1 :value))))
      (harness-tasks-redact-test--add
       (harness-tasks-redact-test--record 1 project :prompt prompt)
       (harness-tasks-redact-test--record 2 project :prompt "Nothing secret"))
      (puthash "t-redact01" prompt harness-tasks--naming)
      (puthash "t-redact02" "Nothing secret" harness-tasks--naming)
      (harness-call 'task/redact (list s1))
      ;; The requests stay out; only the copy lost the secret.
      (should (equal (format "Rotate key %s today" (harness-redaction-placeholder s1))
                     (gethash "t-redact01" harness-tasks--naming)))
      (should (equal "Nothing secret" (gethash "t-redact02" harness-tasks--naming))))))

(ert-deftest harness-tasks-redact-errors-name-no-secret ()
  "A walk that fails says which task, never what it was holding, and changes nothing."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (s1 (harness-tasks-redact-test--secret 1))
           (v1 (plist-get s1 :value))
           (record (harness-tasks-redact-test--record 1 project :prompt (format "key %s" v1)))
           (store (harness-tasks--global-store)))
      (harness-tasks-redact-test--add record)
      (let ((text (harness-read-file store)))
        (cl-letf (((symbol-function 'harness-redaction-value)
                   (lambda (value _secrets) (error "Cannot walk %S" value))))
          (let ((err (should-error (harness-call 'task/redact (list s1)) :type 'harness-error)))
            (should (string-search "t-redact01" (cadr err)))
            (should-not (string-search v1 (harness-tasks-redact-test--print err)))))
        (should (eq record (gethash "t-redact01" harness-tasks--table)))
        (should (equal text (harness-read-file store)))))))

(ert-deftest harness-tasks-redact-a-failed-save-is-tried-again ()
  "The records change in memory even when the write fails, and the write is not forgotten."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (data (harness-tasks-redact-test--populate project))
           (secrets (plist-get data :secrets))
           (store (harness-tasks--global-store))
           (heard nil))
      (harness-on 'task/changed (lambda (view) (push (plist-get view :id) heard)))
      (cl-letf (((symbol-function 'harness-tasks--save) (lambda () (error "Disk full"))))
        (should-error (harness-call 'task/redact secrets)))
      ;; Changed in memory and announced; the store still has the secrets and a write waits.
      (should (equal '("t-redact02" "t-redact01") heard))
      (should (= 7 (harness-redaction-file-count store secrets)))
      (should harness-tasks--dirty)
      (should (= 0 (plist-get (harness-call 'task/redact secrets) :count)))
      (should (= 0 (harness-redaction-file-count store secrets)))
      (should-not harness-tasks--dirty))))

(ert-deftest harness-tasks-redact-refuses-what-is-no-secret-or-project ()
  "A malformed secret or project is refused before anything is touched.
The error shows no part of what it refuses: it could be a secret."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (data (harness-tasks-redact-test--populate project))
           (stray (harness-tasks-redact-test--value 1))
           (table (harness-tasks-redact-test--table-text)))
      (dolist (bad (list stray (list stray) (list (list :label "no value")) (list (list :value 42))))
        (let ((err (should-error (harness-call 'task/redact bad) :type 'harness-error)))
          (should-not (string-search stray (harness-tasks-redact-test--print err)))))
      (dolist (bad (list "" "  " 42 t))
        (should-error (harness-call 'task/redact (plist-get data :secrets) bad) :type 'harness-error))
      ;; False is no project, as JSON says it.
      (should (= 7 (plist-get (harness-call 'task/redact (plist-get data :secrets) :false t) :count)))
      (should (equal table (harness-tasks-redact-test--table-text))))))

(ert-deftest harness-tasks-redact-no-secrets-no-change ()
  "Without a secret there is nothing to find, and no task changes."
  (harness-tasks-redact-test-with
    (let* ((project (harness-tasks-redact-test--project "app"))
           (data (harness-tasks-redact-test--populate project)))
      (let ((table (harness-tasks-redact-test--table-text))
            (result (harness-call 'task/redact nil)))
        (should (= 0 (plist-get result :count)))
        (should-not (plist-get result :tasks))
        (should-not (plist-get result :files))
        (should (equal table (harness-tasks-redact-test--table-text)))
        (should (eq (plist-get data :a) (gethash "t-redact01" harness-tasks--table)))))))

(provide 'harness-tasks-redact-test)
;;; harness-tasks-redact-test.el ends here
