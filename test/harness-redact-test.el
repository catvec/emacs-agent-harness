;;; harness-redact-test.el --- Tests for redacting a secret from every store  -*- lexical-binding: t; -*-

;;; Commentary:

;; `secrets/redact' names a secret by where it can be read, takes it out
;; of the node logs, memory and records of the sessions in scope, of the
;; search index, of the logs of the hosted providers and of the task
;; records, resets the provider conversations that held it (or waits for
;; a running turn to end first), and records what it did without a value
;; in it.  A reset of a hosted loop's conversation drops the prompt cache
;; of it too: the report says whose, and a scan says whose it would drop.
;; These tests drive the engine with the real session module and
;; stand-ins for the stores that other suites test on their own (the
;; provider logs, the task records, and the search index in most tests),
;; and with the real search index in one.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  A test that fails shows values it
;; compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-providers)
(defvar harness-agent--turns)
(defvar harness-redact--pending)
(defvar harness-redact--records-limit)
(defvar harness-provider-claude-program)
(defvar harness-provider-claude-projects-directory)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(defvar harness-provider-claude-api-key)
(defvar harness-provider-claude--api-base)
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude--forget-listing "harness-provider-claude")
(declare-function harness-provider--forget "harness-provider")
(defvar harness-session-search-index)
(defvar harness-session-search-embedding-model)
(defvar harness-session-search--timer)
(defvar harness-session-search--dirty)
(declare-function harness-redact--init "harness-redact")
(declare-function harness-redact--short-id "harness-redact")
(declare-function harness-redact--cache-tokens "harness-redact")
(declare-function harness-redact--cache-line "harness-redact")
(declare-function harness-redact-run-ids "harness-redact")
(declare-function harness-redact-run-secrets "harness-redact")
(declare-function harness-redact-run-dry-p "harness-redact")
(declare-function harness-redact-run-prop "harness-redact")
(declare-function harness-redact-run-set-prop "harness-redact")
(declare-function harness-redact-entry-incr "harness-redact")
(declare-function harness-redact-entry-add "harness-redact")
(declare-function harness-redact-add-store "harness-redact")
(declare-function harness-redact-add-lines "harness-redact")
(declare-function harness-method/session/redact-text "harness-session")
(declare-function harness-session--load-all "harness-session")
(declare-function harness-redact--filter-output "harness-redact")
(declare-function harness-redact--filter-text "harness-redact")
(declare-function harness-session-search--db "harness-session-search")
(declare-function harness-session-search--sync "harness-session-search")
(declare-function harness-session-search--files "harness-session-search")
(declare-function harness-session-flush "harness-session")

;;;; The fake secrets, a state file that holds them, and sessions

(defconst harness-redact-test--key (concat "FAKE/key+" (make-string 24 ?k) "\"q")
  "A fake secret key, with a slash and a quote for JSON to escape.")

(defconst harness-redact-test--id (concat "FAKEID" (make-string 14 ?x))
  "A fake access key id.")

(defun harness-redact-test--secrets ()
  "Return the fake key and id as secrets, the longest first as a resolution has them."
  (list (harness-redaction-secret harness-redact-test--key "spaces.secret_key")
        (harness-redaction-secret harness-redact-test--id "spaces.access_key")))

(defun harness-redact-test--fp (index)
  "Return the fingerprint of the fake secret number INDEX, 0 the key and 1 the id."
  (plist-get (nth index (harness-redact-test--secrets)) :fingerprint))

(defun harness-redact-test--source (&rest more)
  "Write a fake state file; return its name.
It holds the fake id and key under outputs.keys.value, and MORE, a
plist, beside them."
  (let ((file (expand-file-name "state.json" (harness-test-temp-dir))))
    (with-temp-file file
      (insert (harness-json-encode-text
               (list :outputs (list :keys (list :value (append (list :access_key harness-redact-test--id
                                                                     :secret_key harness-redact-test--key)
                                                               more)))
                     :other "unrelated"))))
    file))

(defun harness-redact-test--ref (&optional file)
  "Return the reference to the fake secrets in FILE, a fake state file by default."
  (list :file (or file (harness-redact-test--source)) :json-path "outputs.keys.value" :label "spaces"))

(defvar harness-redact-test--running nil
  "The ids of the sessions the stand-in `agent/running' says run a turn.")

(defvar harness-redact-test--calls nil
  "The calls the stand-in stores got, (METHOD . ARGS), newest first.")

(defvar harness-redact-test--events nil
  "The events watched, (EVENT . ARGS), newest first.")

(defmacro harness-redact-test-with (&rest body)
  "Run BODY with the session modules and the engine in a fresh state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-redact--pending)
     (let ((default-directory dir)
           (harness-redact-test--running nil)
           (harness-redact-test--calls nil)
           (harness-redact-test--events nil))
       (harness-register-method 'agent/running
                                (lambda (&optional sid) (and sid (member sid harness-redact-test--running) t)))
       ,@body)))

(defun harness-redact-test--watch ()
  "Record `session/redacted' and `secrets/redacted' in `harness-redact-test--events'."
  (setq harness-redact-test--events nil)
  (dolist (event '(session/redacted secrets/redacted))
    (let ((event event))
      (harness-on event (lambda (&rest args) (push (cons event args) harness-redact-test--events))))))

(defun harness-redact-test--stub (name fn)
  "Make NAME a method that notes its calls and answers what FN does with them."
  (harness-register-method name (lambda (&rest args)
                                  (push (cons name args) harness-redact-test--calls)
                                  (apply fn args))))

(defun harness-redact-test--calls-of (name)
  "Return the calls of the stand-in NAME, oldest first, each the list of its arguments."
  (reverse (cl-loop for call in harness-redact-test--calls
                    when (eq (car call) name) collect (cdr call))))

(defun harness-redact-test--session (name &rest nodes)
  "Create a session called NAME with NODES appended; return its id."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name name) :id)))
    (dolist (n nodes) (harness-call 'session/append id n))
    id))

(defun harness-redact-test--dirty (name)
  "Create a session called NAME whose transcript holds the fake secrets.
The key is in a user message, in the input of a call (which has a CLI
checkpoint) and in its result, the id in the result: four occurrences."
  (harness-redact-test--session
   name
   (list :kind 'user :content (format "use the key %s please" harness-redact-test--key))
   (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run: echo"
         :input (list :command (format "echo %s" harness-redact-test--key))
         :checkpoint '(:cli-session-id "cli-1" :uuid "u-1"))
   (list :kind 'tool-result :call-id "c1"
         :output (format "AccessKeyId: %s\nvalue: %s\n" harness-redact-test--id harness-redact-test--key))
   '(:kind assistant :content "Understood, nothing secret here.")))

(defun harness-redact-test--call (&rest params)
  "Call `secrets/redact' with the plist PARAMS; return its report."
  (harness-call 'secrets/redact params))

(defun harness-redact-test--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redact-test--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))

(defun harness-redact-test--record-file (sid)
  "Return the file name of the record of session SID."
  (expand-file-name (format "sessions/%s.json" sid) harness-state-directory))

(defun harness-redact-test--stored-count ()
  "Return how many times the fake secrets occur in the bytes of the state directory."
  (cl-loop for file in (directory-files-recursively harness-state-directory "")
           sum (harness-redaction-file-count file (harness-redact-test--secrets))))

(defun harness-redact-test--holds-p (object value)
  "Non-nil when OBJECT, printed either way, holds the string VALUE.
A string prints with its quotes and backslashes escaped by `prin1' and
as it is without: a value with a quote in it hides from a search of the
first, so both are searched."
  (and (or (string-search value (prin1-to-string object t))
           (string-search (substring (prin1-to-string value) 1 -1) (prin1-to-string object)))
       t))

(defun harness-redact-test--holds-any-p (&rest objects)
  "Non-nil when any of OBJECTS, printed, holds a fake secret, as it is or as JSON writes it."
  (cl-some (lambda (object)
             (or (harness-redact-test--holds-p object harness-redact-test--key)
                 (harness-redact-test--holds-p object harness-redact-test--id)
                 (> (harness-redaction-count (prin1-to-string object t) (harness-redact-test--secrets)) 0)))
           objects))

(defun harness-redact-test--hints (sid)
  "Return the text of the hints in the transcript of session SID, oldest first."
  (cl-loop for n in (harness-call 'session/nodes sid)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(defun harness-redact-test--redactions (sid)
  "Return the redaction records in the `ext' of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :redactions))

(defun harness-redact-test--session-ids (report)
  "Return the ids of the sessions the REPORT lists, sorted."
  (sort (mapcar (lambda (s) (plist-get s :id)) (plist-get report :sessions)) #'string<))

(defun harness-redact-test--entry (report sid)
  "Return what the REPORT says of session SID."
  (cl-find sid (plist-get report :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal))

;;;; Scanning

(ert-deftest harness-redact-scan-counts-and-changes-nothing ()
  "A scan names the sessions, the counts and the places, and changes no store."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty (concat "named " harness-redact-test--key)))
           (b (harness-redact-test--session "clean" '(:kind user :content "nothing here")))
           (_ (harness-session-flush))
           (log (harness-redact-test--read (harness-redact-test--log a)))
           (record (harness-redact-test--read (harness-redact-test--record-file a)))
           (nodes (harness-call 'session/nodes a)))
      (harness-redact-test--watch)
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)))
        (should (eq 'scan (plist-get report :mode)))
        (should-not (plist-get report :complete))
        ;; The key in a message, a call's input and a result, the id in the result.
        (should (equal (list a) (harness-redact-test--session-ids report)))
        (let ((entry (harness-redact-test--entry report a)))
          (should (= 4 (plist-get entry :log)))
          (should (= 1 (plist-get entry :record)))
          (should (= 5 (plist-get entry :count)))
          (should (= 3 (length (plist-get entry :nodes))))
          (should (member "output" (plist-get entry :fields)))
          (should (equal '("name") (plist-get entry :record-fields)))
          (should-not (plist-get entry :provider)))
        (should (= 5 (plist-get report :total)))
        (should-not (cl-find b (plist-get report :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal))
        (should (equal '("spaces.secret_key" "spaces.access_key")
                       (mapcar (lambda (s) (plist-get s :label)) (plist-get report :secrets))))
        (should (equal (list (harness-redact-test--fp 0) (harness-redact-test--fp 1))
                       (mapcar (lambda (s) (plist-get s :fingerprint)) (plist-get report :secrets))))
        (should (string-search (format "sha256:%s" (harness-redact-test--fp 0)) (plist-get report :text)))
        (should (string-search "nothing was changed" (plist-get report :text)))
        (should-not (harness-redact-test--holds-any-p report)))
      ;; Nothing changed: not the log, the record, the nodes, the ext, the events.
      (should (equal log (harness-redact-test--read (harness-redact-test--log a))))
      (harness-session-flush)
      (should (equal record (harness-redact-test--read (harness-redact-test--record-file a))))
      (should (equal nodes (harness-call 'session/nodes a)))
      (should-not (harness-redact-test--redactions a))
      (should-not harness-redact-test--events)
      (should (= 0 (hash-table-count harness-redact--pending))))))

(ert-deftest harness-redact-scan-is-the-default-mode ()
  "A request without a mode scans."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (should (eq 'scan (plist-get (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)
                                   :mode)))
      (should (> (harness-redaction-file-count (harness-redact-test--log a) (harness-redact-test--secrets)) 0)))))

(ert-deftest harness-redact-scan-reports-values-too-short-to-be-secrets ()
  "A value shorter than the least length is not redacted, and the report says how many.
The verb agrees with the count: one value was not, two were not."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (ref (harness-redact-test--ref (harness-redact-test--source :pin "abc")))
           (report (harness-redact-test--call :source ref :scope 'session :sessions (list a))))
      (should (= 1 (plist-get report :skipped)))
      (should (= 2 (length (plist-get report :secrets))))
      (should (string-search "shorter than" (plist-get report :text)))
      (should (string-search (format "1 value shorter than %d characters was not treated as a secret."
                                     harness-redaction-min-length)
                             (plist-get report :text)))
      (let* ((ref (harness-redact-test--ref (harness-redact-test--source :pin "abc" :zip "def")))
             (report (harness-redact-test--call :source ref :scope 'session :sessions (list a))))
        (should (= 2 (plist-get report :skipped)))
        (should (string-search (format "2 values shorter than %d characters were not treated as secrets."
                                       harness-redaction-min-length)
                               (plist-get report :text)))))))

(ert-deftest harness-redact-scope-text-counts-the-sessions-in-words ()
  "The scope reads \"all sessions (1 session)\", then \"(2 sessions)\", and so do the others.
A bare number in brackets read as a count of what, in a prompt that asks
\"from all sessions (1)?\"."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "one"))
           (scan (lambda (&rest params)
                   (plist-get (apply #'harness-redact-test--call :source (harness-redact-test--ref) params)
                              :scope)))
           (project (plist-get (harness-call 'session/get a) :project)))
      (should (equal "all sessions (1 session)" (funcall scan :scope 'all)))
      (should (string-match-p "\\`project .* (1 session)\\'" (funcall scan :scope 'project :project project)))
      (should (string-match-p "\\`session [0-9a-f]\\{8\\} and its forks (1 session)\\'"
                              (funcall scan :scope 'session :sessions (list a))))
      ;; A second session working below the project's directory is in the project.
      (let ((below (plist-get (harness-call 'session/create :cwd (expand-file-name "sub/" project)
                                            :project (expand-file-name "sub/" project))
                              :id)))
        (harness-call 'session/append below (list :kind 'user :content harness-redact-test--key))
        (should (string-match-p "\\`project .* (2 sessions)\\'" (funcall scan :scope 'project :project project)))
        (should (equal "all sessions (2 sessions)" (funcall scan :scope 'all)))
        (should (string-match-p ", forks left out (2 sessions)\\'"
                                (funcall scan :scope 'session :sessions (list a below) :include-forks :false)))))))

(ert-deftest harness-redact-scope-text-says-its-forks-of-one-session-and-their-forks-of-several ()
  "A scope of sessions reads \"and its forks\" of the one session named, \"and their forks\" of several.
What its forks make of the scope does not count: one session named with
a fork is \"its\" (2 sessions).  A session named twice, by its id and by
the start of it, is named once.  Leaving the forks out reads the same for
one and for several, and so does naming more than the text lists."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "one"))
           (b (harness-redact-test--dirty "two"))
           (_fork (plist-get (harness-test-await (harness-call 'session/fork a)) :id))
           (scan (lambda (params)
                   (plist-get (apply #'harness-redact-test--call :source (harness-redact-test--ref) params)
                              :scope)))
           (short #'harness-redact--short-id))
      ;; One named: its forks, whether it has any or not.
      (should (equal (format "session %s and its forks (2 sessions)" (funcall short a))
                     (funcall scan (list :scope 'session :sessions (list a)))))
      (should (equal (format "session %s and its forks (1 session)" (funcall short b))
                     (funcall scan (list :scope 'session :sessions (list b)))))
      (should (equal (format "session %s and its forks (1 session)" (funcall short b))
                     (funcall scan (list :scope 'session :sessions (list b (funcall short b))))))
      ;; Several named: their forks.
      (should (equal (format "session %s, session %s and their forks (3 sessions)"
                             (funcall short a) (funcall short b))
                     (funcall scan (list :scope 'session :sessions (list a b)))))
      ;; Forks left out: the same words for one and for several.
      (should (equal (format "session %s, forks left out (1 session)" (funcall short a))
                     (funcall scan (list :scope 'session :sessions (list a) :include-forks :false))))
      (should (equal (format "session %s, session %s, forks left out (2 sessions)"
                             (funcall short a) (funcall short b))
                     (funcall scan (list :scope 'session :sessions (list a b) :include-forks :false))))
      ;; More than the text lists: how many more come first, then the forks.
      (let* ((more (cl-loop repeat 5 collect (harness-redact-test--session "more")))
             (named (append (list a b) more)))
        (should (equal (format "%s and 2 more and their forks (8 sessions)"
                               (mapconcat (lambda (id) (format "session %s" (funcall short id)))
                                          (take 5 named) ", "))
                       (funcall scan (list :scope 'session :sessions named))))))))

;;;; Redacting: every store, the records, the events

(ert-deftest harness-redact-redact-takes-the-secrets-out-of-every-store-and-records-it ()
  "A redaction leaves no copy in the state directory, and says what it did without a value."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty (concat "named " harness-redact-test--key)))
           (b (harness-redact-test--dirty "second"))
           (c (harness-redact-test--session "clean" '(:kind user :content "nothing here"))))
      (harness-session-flush)
      (should (> (harness-redact-test--stored-count) 0))
      (harness-redact-test--watch)
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                               :reason "leaked in a diff"
                                               :origin (list :kind 'session :id c))))
        (should (eq 'redact (plist-get report :mode)))
        (should (plist-get report :complete))
        (should (equal (sort (list a b) #'string<) (harness-redact-test--session-ids report)))
        ;; Every store of the state directory is clean, in memory too.
        (should (= 0 (harness-redact-test--stored-count)))
        (should-not (harness-redact-test--holds-any-p (harness-call 'session/nodes a)
                                                      (harness-call 'session/nodes b)
                                                      (harness-call 'session/get a)))
        ;; The placeholder stands where the secret was.
        (let ((log (harness-redact-test--read (harness-redact-test--log a))))
          (should (string-search (format "[redacted: spaces.secret_key sha256:%s]" (harness-redact-test--fp 0)) log))
          (should (string-search (format "[redacted: spaces.access_key sha256:%s]" (harness-redact-test--fp 1)) log)))
        ;; The record in the session, and the hint in its transcript.
        (let* ((records (harness-redact-test--redactions a))
               (record (car records)))
          (should (= 1 (length records)))
          (should (equal "session " (substring (plist-get record :by) 0 8)))
          (should (equal (harness-redact--short-id c) (substring (plist-get record :by) 8)))
          (should (equal "leaked in a diff" (plist-get record :reason)))
          (should (equal '("spaces.secret_key" "spaces.access_key")
                         (mapcar (lambda (s) (plist-get s :label)) (plist-get record :secrets))))
          (should (equal (list (harness-redact-test--fp 0) (harness-redact-test--fp 1))
                         (mapcar (lambda (s) (plist-get s :fingerprint)) (plist-get record :secrets))))
          (should (= 4 (plist-get (plist-get record :counts) :log)))
          (should (= 1 (plist-get (plist-get record :counts) :record)))
          (should (= 3 (length (plist-get record :nodes))))
          (should (member (harness-redact-test--log a) (plist-get record :files)))
          (should (member (harness-redact-test--record-file a) (plist-get record :files)))
          (should (equal "reset" (plist-get record :provider)))
          (should (numberp (plist-get record :ts)))
          (should-not (harness-redact-test--holds-any-p record)))
        (let ((hint (car (last (harness-redact-test--hints a)))))
          (should (string-prefix-p "Redacted 2 secrets (" hint))
          (should (string-search (format "spaces.secret_key sha256:%s" (harness-redact-test--fp 0)) hint))
          (should (string-search (format "at the request of session %s" (harness-redact--short-id c)) hint))
          (should (string-search "Reason: leaked in a diff" hint))
          (should (string-search "starts over from the redacted transcript" hint)))
        ;; A session without the secret has neither.
        (should-not (harness-redact-test--redactions c))
        (should-not (harness-redact-test--hints c))
        ;; Events: one per session that changed, and one for the request.
        (let ((per-session (cl-remove-if-not (lambda (e) (eq (car e) 'session/redacted)) harness-redact-test--events))
              (summary (cl-remove-if-not (lambda (e) (eq (car e) 'secrets/redacted)) harness-redact-test--events)))
          (should (equal (sort (list a b) #'string<) (sort (mapcar #'cadr per-session) #'string<)))
          (should (= 1 (length summary)))
          (let ((s (cadr (car summary))))
            (should (equal (sort (list a b) #'string<) (sort (copy-sequence (plist-get s :sessions)) #'string<)))
            (should (equal (list (harness-redact-test--fp 0) (harness-redact-test--fp 1))
                           (mapcar (lambda (x) (plist-get x :fingerprint)) (plist-get s :secrets))))
            (should (equal "state.json" (file-name-nondirectory (plist-get (plist-get s :source) :file)))))
          (should-not (harness-redact-test--holds-any-p harness-redact-test--events)))
        (should-not (harness-redact-test--holds-any-p report))
        (should (string-search "Nothing found by this request is left" (plist-get report :text)))))))

(ert-deftest harness-redact-redact-asks-every-store ()
  "A redaction scans and cleans the search index, the logs of both providers and the task
records, takes the pages of the index back, and passes the secrets to each."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (secrets-fp (list (harness-redact-test--fp 0) (harness-redact-test--fp 1)))
           (fps (lambda (secrets) (mapcar (lambda (s) (plist-get s :fingerprint)) secrets))))
      ;; Each store finds the secret in the redaction and is clean when the
      ;; verification scans it again, as a store is when it was cleaned.
      (harness-redact-test--stub 'session/search-redact
                                 (lambda (ids _secrets &optional dry)
                                   (let ((rows (if (< (length (harness-redact-test--calls-of 'session/search-redact)) 3) 2 0)))
                                     (append (list :available t :rows rows :sessions (and (> rows 0) (list (cons a rows))))
                                             (and (not dry) (list :reindexed (and (listp ids) ids)))))))
      (harness-redact-test--stub 'session/search-purge
                                 (lambda (&optional _secrets)
                                   (list :available t :seconds 0.5 :bytes-before 100 :bytes-after 40
                                         :wal-truncated t :file-counts nil :term-counts nil)))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (_secrets &optional _ids dry)
                                   (if dry
                                       (list :directory "/claude/projects/" :count 0 :scanned 9 :files nil)
                                     (list :directory "/claude/projects/" :count 3 :scanned 9
                                           :files (list (list :file "/claude/projects/x/cli-1.jsonl"
                                                              :cli-session "cli-1" :owners (list a)
                                                              :count 3 :status 'redacted))))))
      (harness-redact-test--stub 'provider/copilot-redact-logs
                                 (lambda (_secrets &optional _ids _dry)
                                   (list :directory "/copilot/" :count 0 :scanned 2 :files nil)))
      (harness-redact-test--stub 'task/redact
                                 (lambda (_secrets &optional _project _dry)
                                   (list :count 0 :tasks nil :files nil :stores nil)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
        ;; Two rows hold secrets, in one session: the verb agrees with the count.
        (should (string-search "Search index: 2 rows hold secrets, in 1 session." (plist-get report :text)))
        ;; The search index: a scan of every session, then the logs read again,
        ;; then the scan of the verification.
        (let ((calls (harness-redact-test--calls-of 'session/search-redact)))
          (should (= 3 (length calls)))
          (should (eq t (nth 0 (car calls))))
          (should (equal secrets-fp (funcall fps (nth 1 (car calls)))))
          (should (eq t (nth 2 (car calls))))
          (should (equal (list a) (nth 0 (cadr calls))))
          (should-not (nth 2 (cadr calls)))
          (should (eq t (nth 0 (nth 2 calls))))
          (should (eq t (nth 2 (nth 2 calls)))))
        ;; The logs of the providers: all of them, for real, then as a scan.
        (dolist (method '(provider/claude-redact-logs provider/copilot-redact-logs))
          (let ((calls (harness-redact-test--calls-of method)))
            (should (= 2 (length calls)))
            (should (equal secrets-fp (funcall fps (nth 0 (car calls)))))
            (should (eq t (nth 1 (car calls))))
            (should-not (nth 2 (car calls)))
            (should (eq t (nth 1 (cadr calls))))
            (should (nth 2 (cadr calls)))))
        ;; The task records: every project's, for real, then as a scan.
        (let ((calls (harness-redact-test--calls-of 'task/redact)))
          (should (= 2 (length calls)))
          (should (equal secrets-fp (funcall fps (nth 0 (car calls)))))
          (should-not (nth 1 (car calls)))
          (should-not (nth 2 (car calls)))
          (should (nth 2 (cadr calls))))
        ;; The old text goes out of the index's files.
        (let ((calls (harness-redact-test--calls-of 'session/search-purge)))
          (should (= 1 (length calls)))
          (should (equal secrets-fp (funcall fps (nth 0 (car calls))))))
        ;; What the stores found is in the report and the record of the session:
        ;; four in the node log, three in the log of Claude Code.
        (should (= 7 (plist-get report :total)))
        (should (equal '("search index" "Claude Code logs" "Copilot logs" "task records"
                         "transcript files" "spill files" "session temp files" "state files" "log buffers")
                       (mapcar (lambda (s) (plist-get s :store)) (plist-get report :stores))))
        ;; The scan after it found nothing left.
        (should (plist-get (plist-get report :verification) :ok))
        (should (= 0 (plist-get (plist-get report :verification) :total)))
        (let ((entry (harness-redact-test--entry report a)))
          (should (= 2 (plist-get entry :search)))
          (should (= 3 (plist-get entry :claude))))
        (let ((record (car (harness-redact-test--redactions a))))
          (should (= 2 (plist-get (plist-get record :counts) :search)))
          (should (= 3 (plist-get (plist-get record :counts) :cli)))
          (should (member "/claude/projects/x/cli-1.jsonl" (plist-get record :files))))
        (should (plist-get (plist-get (car (plist-get report :stores)) :purge) :wal-truncated))
        (should-not (harness-redact-test--holds-any-p report))))))

(ert-deftest harness-redact-scan-asks-every-store-to-count-only ()
  "A scan passes the dry-run flag to the stores and purges nothing."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (harness-redact-test--stub 'session/search-redact
                                 (lambda (_ids _secrets &optional _dry)
                                   (list :available t :rows 1 :sessions (list (cons a 1)))))
      (harness-redact-test--stub 'session/search-purge (lambda (&rest _) (list :available t)))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _) (list :directory "/c/" :count 0 :scanned 0 :files nil)))
      (harness-redact-test--stub 'provider/copilot-redact-logs
                                 (lambda (&rest _) (list :directory "/p/" :count 0 :scanned 0 :files nil)))
      (harness-redact-test--stub 'task/redact
                                 (lambda (&rest _) (list :count 0 :tasks nil :files nil :stores nil)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)))
        ;; One row holds a secret, in one session: the verb agrees with the count.
        (should (string-search "Search index: 1 row holds a secret, in 1 session." (plist-get report :text))))
      (should (= 1 (length (harness-redact-test--calls-of 'session/search-redact))))
      (should (nth 2 (car (harness-redact-test--calls-of 'session/search-redact))))
      (should (nth 2 (car (harness-redact-test--calls-of 'provider/claude-redact-logs))))
      (should (nth 2 (car (harness-redact-test--calls-of 'provider/copilot-redact-logs))))
      (should (nth 2 (car (harness-redact-test--calls-of 'task/redact))))
      (should-not (harness-redact-test--calls-of 'session/search-purge)))))

(ert-deftest harness-redact-scope-picks-the-ids-the-stores-get ()
  "A scope of sessions passes the conversations of those sessions, not all, and leaves the tasks."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (_ (harness-call 'session/set-provider-state a (list :cli-session-id "cli-2")))
           (b (harness-redact-test--session "copilot" '(:kind user :content "hi")))
           (_ (harness-call 'session/set-provider-state b (list :copilot-session-id "cp-1")))
           (seen nil))
      (dolist (method '(provider/claude-redact-logs provider/copilot-redact-logs))
        (harness-redact-test--stub method (lambda (&rest _) (list :directory "/d/" :count 0 :scanned 0 :files nil))))
      (harness-redact-test--stub 'task/redact (lambda (&rest _) (setq seen t) nil))
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session :sessions (list a b))
      (let ((claude (nth 1 (car (harness-redact-test--calls-of 'provider/claude-redact-logs)))))
        ;; The state's conversation and the one a checkpoint on a node names.
        (should (equal '("cli-1" "cli-2") (sort (copy-sequence claude) #'string<))))
      (should (equal '("cp-1") (nth 1 (car (harness-redact-test--calls-of 'provider/copilot-redact-logs)))))
      (should-not seen)
      ;; A project's tasks are asked for with the project.
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'project
                                 :project (plist-get (harness-call 'session/get a) :project))
      (should (equal (plist-get (harness-call 'session/get a) :project)
                     (nth 1 (car (harness-redact-test--calls-of 'task/redact))))))))

(ert-deftest harness-redact-scope-takes-the-forks-unless-left-out ()
  "The forks of a session are in its scope, unless the request leaves them out."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (fork (plist-get (harness-test-await (harness-call 'session/fork a)) :id)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a))))
        (should (equal (sort (list a fork) #'string<) (harness-redact-test--session-ids report)))
        (should (string-search "and its forks" (plist-get report :scope))))
      (dolist (off (list :false nil))
        (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                                 :sessions (list a) :include-forks off)))
          (should (equal (list a) (harness-redact-test--session-ids report)))))
      ;; Redacting the session alone leaves the fork's copy.
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session :sessions (list a)
                                 :include-forks :false :mode 'redact)
      (should (= 0 (harness-redaction-file-count (harness-redact-test--log a) (harness-redact-test--secrets))))
      (should (> (harness-redaction-file-count (harness-redact-test--log fork) (harness-redact-test--secrets)) 0)))))

(ert-deftest harness-redact-scope-project-takes-the-sessions-of-the-project ()
  "A project scope has the sessions of that directory, and not those of another."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (b (harness-redact-test--dirty "elsewhere"))
           (project (plist-get (harness-call 'session/get a) :project))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'project
                                              :project project)))
      (should (equal (list a) (harness-redact-test--session-ids report)))
      (should-not (member b (harness-redact-test--session-ids report)))
      ;; A session working below the project's directory belongs to it.
      (let* ((below (plist-get (harness-call 'session/create :cwd (expand-file-name "sub/" project)
                                             :project (expand-file-name "sub/" project))
                               :id)))
        (harness-call 'session/append below (list :kind 'user :content harness-redact-test--key))
        (should (member below (harness-redact-test--session-ids
                               (harness-redact-test--call :source (harness-redact-test--ref) :scope 'project
                                                          :project project))))))))

(ert-deftest harness-redact-scope-takes-the-start-of-a-session-id ()
  "A session can be named by the start of its id, if one session has it."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                              :sessions (list (substring a 0 8)))))
      (should (equal (list a) (harness-redact-test--session-ids report)))
      (should-error (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list "no-such-session"))
                    :type 'harness-error))))

(ert-deftest harness-redact-asks-for-a-sound-request ()
  "A request without a source, a scope or what the scope needs, or with a key the engine does not know, is refused."
  (harness-redact-test-with
    (let ((ref (harness-redact-test--ref)))
      (should-error (harness-redact-test--call :scope 'all) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref :scope 'galaxy) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref :scope 'session) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref :scope 'project) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref :scope 'all :mode 'delete) :type 'harness-error)
      (should-error (harness-redact-test--call :source ref :scope 'all :sesions nil) :type 'harness-error)
      (should-error (harness-redact-test--call :source (list :file "/nonexistent/state.json" :json-path "a")
                                               :scope 'all)
                    :type 'harness-error)
      ;; A client may spell the keys and the scope its way.
      (should (eq 'scan (plist-get (harness-call 'secrets/redact
                                                 (list :source (list :file (plist-get ref :file) :json_path "outputs.keys.value")
                                                       :scope "all" :mode "scan" :include_forks :false))
                                   :mode))))))

;;;; A secret that is no reference, a label and a reason that hold it

(ert-deftest harness-redact-refuses-a-secret-given-as-its-text-or-a-command ()
  "A literal or a command is refused, unless the caller allows it, and the refusal says nothing of it."
  (harness-redact-test-with
    (dolist (source (list (list :literal harness-redact-test--key)
                          (list :command "printf '%s' \"$HARNESS_REDACT_TEST_SECRET\"")))
      (let ((err (should-error (harness-redact-test--call :source source :scope 'all) :type 'harness-error)))
        (should-not (harness-redact-test--holds-any-p err)))
      (let ((err (should-error (harness-redact-test--call :source source :scope 'all :allow-unsafe-sources :false)
                               :type 'harness-error)))
        (should-not (harness-redact-test--holds-any-p err))))
    (should-not harness-redact-test--calls)))

(ert-deftest harness-redact-takes-a-literal-or-a-command-when-allowed-and-shows-neither ()
  "The UI may redact a typed value or a command's output; the answer and the events hold neither."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty"))
          (process-environment (cons (concat "HARNESS_REDACT_TEST_SECRET=" harness-redact-test--id)
                                     process-environment)))
      (harness-redact-test--watch)
      (let ((report (harness-redact-test--call :source (list :literal harness-redact-test--key :label "typed")
                                               :scope 'all :mode 'redact :allow-unsafe-sources t)))
        (should (equal (list a) (harness-redact-test--session-ids report)))
        (should (= 0 (harness-redaction-file-count (harness-redact-test--log a)
                                                    (list (car (harness-redact-test--secrets))))))
        (should (equal '(:kind literal) (plist-get (cadr (assq 'secrets/redacted harness-redact-test--events))
                                                   :source)))
        (should (equal "typed" (plist-get (car (plist-get report :secrets)) :label)))
        (should-not (harness-redact-test--holds-any-p report harness-redact-test--events)))
      (setq harness-redact-test--events nil)
      (let ((report (harness-redact-test--call :source (list :command "printf '%s' \"$HARNESS_REDACT_TEST_SECRET\"")
                                               :scope 'all :mode 'redact :allow-unsafe-sources t)))
        (should (= 0 (harness-redact-test--stored-count)))
        (should (equal '(:kind command) (plist-get (cadr (assq 'secrets/redacted harness-redact-test--events))
                                                   :source)))
        (should-not (harness-redact-test--holds-any-p report harness-redact-test--events))))))

(ert-deftest harness-redact-keeps-a-label-or-reason-that-holds-the-secret-out-of-what-it-writes ()
  "A label or a reason with the value in it is replaced before anything is written or returned."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      ;; The label holds the key: the secrets are called secret-FINGERPRINT.
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                               :label (concat "the key " harness-redact-test--key)
                                               :reason (concat "leaked as " harness-redact-test--id))))
        (should (equal (list (format "secret-%s" (harness-redact-test--fp 0))
                             (format "secret-%s" (harness-redact-test--fp 1)))
                       (mapcar (lambda (s) (plist-get s :label)) (plist-get report :secrets))))
        (should (string-search "(withheld: it contained the secret)" (plist-get report :text)))
        (should-not (string-search "leaked as" (plist-get report :text)))
        (should (equal "(withheld: it contained the secret)"
                       (plist-get (car (harness-redact-test--redactions a)) :reason)))
        (should (= 0 (harness-redact-test--stored-count)))
        (should-not (harness-redact-test--holds-any-p report (harness-redact-test--redactions a)
                                                      (harness-redact-test--hints a)
                                                      (harness-call 'session/nodes a)))))))

(ert-deftest harness-redact-keeps-a-label-that-is-not-the-secret ()
  "A label and a reason that hold no value stand as they are."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                              :reason "  it was\nin a diff  ")))
      (should (equal '("spaces.secret_key" "spaces.access_key")
                     (mapcar (lambda (s) (plist-get s :label)) (plist-get report :secrets))))
      (should (equal "it was in a diff" (plist-get (car (harness-redact-test--redactions a)) :reason))))))

(ert-deftest harness-redact-keeps-the-secret-out-of-the-names-it-reports ()
  "A session named after the secret is reported by its placeholder, in a scan and a redaction."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty (concat "Diff for " harness-redact-test--key))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)))
        (should (string-search "[redacted: " (plist-get (harness-redact-test--entry report a) :name)))
        (should-not (harness-redact-test--holds-any-p report)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
        (should (string-search "[redacted: " (plist-get (harness-redact-test--entry report a) :name)))
        (should (string-search "[redacted: " (plist-get (harness-call 'session/get a) :name)))
        (should-not (harness-redact-test--holds-any-p report))))))

(ert-deftest harness-redact-adds-the-session-that-made-a-call-with-the-secret-in-its-input ()
  "The session that asked is in the scope when its call carried the value, and only then."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (origin (harness-redact-test--session
                    "asker"
                    (list :kind 'tool-call :tool "redact_secret" :call-id "r1"
                          :input (list :source (list :literal harness-redact-test--key)))))
           (held (harness-json-encode-text (list :source (list :literal harness-redact-test--key))))
           (clean (harness-json-encode-text (list :source (list :file "/x/state.json" :json-path "a.b")))))
      ;; A client over the wire sends the kind as a string.
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :origin (list :kind "session" :id origin)
                                               :input-text held)))
        (should (equal (sort (list a origin) #'string<) (harness-redact-test--session-ids report)))
        (should (plist-get report :origin-session))
        (should (string-search "The request itself held the secret" (plist-get report :text)))
        (should-not (harness-redact-test--holds-any-p report)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :origin (list :kind 'session :id origin)
                                               :input-text clean)))
        (should (equal (list a) (harness-redact-test--session-ids report)))
        (should-not (plist-get report :origin-session)))
      ;; A request from the user holds no session to add.
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :input-text held)))
        (should (equal (list a) (harness-redact-test--session-ids report)))))))

(ert-deftest harness-redact-redacts-the-session-that-asked-once-its-turn-ends ()
  "The session whose call held the secret is running: it is cleaned now and reset after its turn."
  (harness-redact-test-with
    (let* ((origin (harness-redact-test--session
                    "asker"
                    (list :kind 'tool-call :tool "redact_secret" :call-id "r1"
                          :input (list :source (list :literal harness-redact-test--key)))))
           (held (harness-json-encode-text (list :source (list :literal harness-redact-test--key)))))
      (harness-call 'session/set-provider-state origin (list :cli-session-id "cli-asker"))
      (push origin harness-redact-test--running)
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list (harness-redact-test--dirty "other"))
                                               :origin (list :kind 'session :id origin)
                                               :input-text held :mode 'redact)))
        (should (equal (list origin) (plist-get report :deferred)))
        (should (= 0 (harness-redaction-file-count (harness-redact-test--log origin)
                                                    (harness-redact-test--secrets))))
        (should (plist-get (harness-call 'session/get origin) :provider-state)))
      (setq harness-redact-test--running nil)
      (harness-emit 'agent/turn-ended origin 'end-turn)
      (should-not (plist-get (harness-call 'session/get origin) :provider-state))
      (should (= 0 (hash-table-count harness-redact--pending))))))

;;;; What the stores report, and how it is told

(ert-deftest harness-redact-credits-task-records-to-the-sessions-they-belong-to ()
  "The occurrences in task records count for the session of the task, if it is in scope."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty"))
          (outside (harness-redact-test--session "outside" '(:kind user :content "no secret"))))
      (harness-redact-test--stub 'task/redact
                                 (lambda (_secrets &optional _project _dry)
                                   (list :count 5
                                         :tasks (list (list :id "t-1" :count 3 :fields '(:prompt :report))
                                                      (list :id "t-2" :count 2 :fields '(:prompt)))
                                         :files nil :stores nil)))
      (harness-redact-test--stub 'task/get
                                 (lambda (id) (list :id id :session (if (equal id "t-1") a outside))))
      ;; A scope of sessions leaves the tasks alone.
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :mode 'scan)))
        (should-not (harness-redact-test--calls-of 'task/redact))
        (should (= 4 (plist-get report :total))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'project :mode 'redact
                                               :project (plist-get (harness-call 'session/get a) :project))))
        (should (= 3 (plist-get (harness-redact-test--entry report a) :tasks)))
        (should-not (harness-redact-test--entry report outside))
        (should (= 9 (plist-get report :total)))
        (should (equal '(("t-1" 3 ("prompt" "report")) ("t-2" 2 ("prompt")))
                       (mapcar (lambda (task) (list (plist-get task :id) (plist-get task :count) (plist-get task :fields)))
                               (plist-get (cl-find "task records" (plist-get report :stores)
                                                   :key (lambda (s) (plist-get s :store)) :test #'equal)
                                          :tasks))))
        (should (= 3 (plist-get (plist-get (car (harness-redact-test--redactions a)) :counts) :tasks)))
        (should-not (harness-redact-test--redactions outside))))))

(ert-deftest harness-redact-answers-and-records-in-json ()
  "The report, the events and the records are what JSON carries, and the store keeps them as they are."
  (harness-redact-test-with
    (let ((a (harness-redact-test--hosted "hosted"))
          (log-before (with-current-buffer (get-buffer-create harness-log-buffer-name) (buffer-size))))
      (harness-redact-test--watch)
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _)
                                   (list :directory "/c/" :count 1 :scanned 1
                                         :files (list (list :file "/c/p/cli-1.jsonl" :cli-session "cli-1"
                                                            :owners (list a) :count 1 :status 'redacted)))))
      (let* ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact))
             (json (decode-coding-string (harness-json-encode report) 'utf-8)))
        (should (stringp json))
        (should-not (harness-redact-test--holds-any-p json))
        (let ((parsed (harness-json-parse json)))
          (should (equal (plist-get report :total) (plist-get parsed :total)))
          (should (equal "redact" (plist-get parsed :mode)))
          (should (equal "Claude Code logs" (plist-get (nth 0 (plist-get parsed :stores)) :store))))
        (dolist (event harness-redact-test--events)
          (should (stringp (harness-json-encode (cdr event)))))
        ;; The record was a value the store keeps as it is.
        (with-current-buffer harness-log-buffer-name
          (should-not (string-search "would not survive"
                                     (buffer-substring-no-properties log-before (point-max)))))
        (harness-session-flush)
        (let ((stored (harness-json-parse (harness-redact-test--read (harness-redact-test--record-file a)))))
          (should (equal (plist-get (car (plist-get (plist-get stored :ext) :redactions)) :by) "user")))))))

(ert-deftest harness-redact-resets-an-owner-of-a-provider-log-outside-the-scope ()
  "A session outside the scope that holds a conversation with the secret in it starts over too."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty"))
          (owner (harness-redact-test--session "other session" '(:kind user :content "clean"))))
      (harness-call 'session/set-provider-state owner (list :cli-session-id "cli-1"))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _)
                                   (list :directory "/c/" :count 4 :scanned 1
                                         :files (list (list :file "/c/p/cli-1.jsonl" :cli-session "cli-1"
                                                            :owners (list owner) :count 4 :status 'redacted)))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :mode 'redact)))
        (should (equal (sort (list a owner) #'string<) (harness-redact-test--session-ids report)))
        (should-not (plist-get (harness-call 'session/get owner) :provider-state))
        (should (= 4 (plist-get (harness-redact-test--entry report owner) :claude)))
        (should (= 1 (length (harness-redact-test--redactions owner))))
        (should (= 4 (plist-get (plist-get (car (harness-redact-test--redactions owner)) :counts) :cli)))
        (should (= 1 (length (harness-redact-test--hints owner))))))))

;;;; The provider conversation: reset, or deferred to the end of a turn

(defun harness-redact-test--hosted (name)
  "Create a session called NAME in a CLI conversation, with the fake secrets in its transcript."
  (let ((id (harness-redact-test--dirty name)))
    (harness-call 'session/set-provider-state id (list :cli-session-id "cli-1"))
    (harness-call 'session/set-provider-node id (plist-get (car (last (harness-call 'session/nodes id))) :id))
    id))

(ert-deftest harness-redact-resets-the-provider-of-a-session-that-held-the-secret ()
  "A session whose transcript held the secret starts a new conversation from the redacted one."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--hosted "hosted"))
           (b (harness-redact-test--session "clean" '(:kind user :content "no secret")))
           (_ (harness-call 'session/set-provider-state b (list :cli-session-id "cli-b")))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
      (let ((session (harness-call 'session/get a)))
        (should-not (plist-get session :provider-state))
        (should-not (plist-get session :provider-node)))
      (should-not (cl-some (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes a)))
      (should (= 0 (harness-redaction-file-count (harness-redact-test--log a) (harness-redact-test--secrets))))
      (should (eq 'reset (plist-get (harness-redact-test--entry report a) :provider)))
      (should (equal "reset" (plist-get (car (harness-redact-test--redactions a)) :provider)))
      ;; The continuation is a new conversation from the transcript.
      (should-not (eq 'checkpoint (plist-get (harness-call 'session/provider-continuation a) :mode)))
      ;; A session that held nothing keeps its conversation.
      (should (equal '(:cli-session-id "cli-b") (plist-get (harness-call 'session/get b) :provider-state)))
      (should-not (plist-get report :deferred)))))

(ert-deftest harness-redact-resets-the-owners-of-a-provider-log-that-held-the-secret ()
  "A session whose conversation log held the secret starts over, though its transcript was clean."
  (harness-redact-test-with
    (let ((owner (harness-redact-test--session "owner" '(:kind user :content "no secret in the transcript"))))
      (harness-call 'session/set-provider-state owner (list :cli-session-id "cli-o"))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _)
                                   (list :directory "/c/" :count 2 :scanned 1
                                         :files (list (list :file "/c/p/cli-o.jsonl" :cli-session "cli-o"
                                                            :owners (list owner) :count 2 :status 'redacted)))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list owner) :mode 'redact)))
        (should-not (plist-get (harness-call 'session/get owner) :provider-state))
        (should (eq 'reset (plist-get (harness-redact-test--entry report owner) :provider)))
        (should (= 2 (plist-get (harness-redact-test--entry report owner) :claude)))
        (should (member "/c/p/cli-o.jsonl" (plist-get (car (harness-redact-test--redactions owner)) :files)))
        (should (= 2 (plist-get (plist-get (car (harness-redact-test--redactions owner)) :counts) :cli)))))))

(ert-deftest harness-redact-defers-a-session-that-runs-a-turn-and-goes-on-when-it-ends ()
  "A running session is cleaned now, its provider kept, and the rest done when its turn ends."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--hosted "running"))
           (fps (list (harness-redact-test--fp 0) (harness-redact-test--fp 1))))
      (push a harness-redact-test--running)
      (harness-redact-test--watch)
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                               :reason "leak")))
        (should (equal (list a) (plist-get report :deferred)))
        (should-not (plist-get report :complete))
        (should (eq 'deferred (plist-get (harness-redact-test--entry report a) :provider)))
        (should (string-search "Waiting for a running turn" (plist-get report :text)))
        ;; Cleaned at once ...
        (should (= 0 (harness-redaction-file-count (harness-redact-test--log a) (harness-redact-test--secrets))))
        ;; ... but its conversation stays, and the flag says why, by label and fingerprint.
        (should (equal '(:cli-session-id "cli-1") (plist-get (harness-call 'session/get a) :provider-state)))
        (let ((flag (plist-get (plist-get (harness-call 'session/get a) :ext) :redaction-pending)))
          (should (equal fps (mapcar (lambda (k) (plist-get k :fingerprint)) flag)))
          (should (equal '("spaces.secret_key" "spaces.access_key") (mapcar (lambda (k) (plist-get k :label)) flag)))
          (should-not (harness-redact-test--holds-any-p flag)))
        (should (= 1 (length (gethash a harness-redact--pending))))
        (should (equal "deferred" (plist-get (car (harness-redact-test--redactions a)) :provider)))
        (should (string-search "once the turn ends" (car (last (harness-redact-test--hints a)))))
        (should-not (harness-redact-test--holds-any-p report)))
      ;; The turn writes the secret again before it ends.
      (harness-call 'session/append a (list :kind 'assistant :content (format "The key is %s" harness-redact-test--key)))
      (should (> (harness-redaction-file-count (harness-redact-test--log a) (harness-redact-test--secrets)) 0))
      (setq harness-redact-test--events nil)
      (setq harness-redact-test--running nil)
      (harness-emit 'agent/turn-ended a 'end-turn)
      ;; Now it is clean everywhere, and the provider conversation starts over.
      (should (= 0 (harness-redact-test--stored-count)))
      (should-not (harness-redact-test--holds-any-p (harness-call 'session/nodes a)))
      (should-not (plist-get (harness-call 'session/get a) :provider-state))
      (should-not (plist-get (plist-get (harness-call 'session/get a) :ext) :redaction-pending))
      (should (= 0 (hash-table-count harness-redact--pending)))
      ;; A second record and hint, saying when.
      (let ((records (harness-redact-test--redactions a)))
        (should (= 2 (length records)))
        (should (plist-get (cadr records) :after-turn))
        (should (equal "reset" (plist-get (cadr records) :provider)))
        (should (equal "leak" (plist-get (cadr records) :reason)))
        (should (= 1 (plist-get (plist-get (cadr records) :counts) :log))))
      (let ((hint (car (last (harness-redact-test--hints a)))))
        (should (string-search "after its turn ended" hint))
        (should (string-search "starts over from the redacted transcript" hint)))
      ;; The session is announced again, the request is not.
      (should (assq 'session/redacted harness-redact-test--events))
      (should-not (assq 'secrets/redacted harness-redact-test--events))
      (should-not (harness-redact-test--holds-any-p harness-redact-test--events
                                                    (harness-redact-test--redactions a)
                                                    (harness-redact-test--hints a))))))

(ert-deftest harness-redact-goes-on-only-for-the-session-whose-turn-ended ()
  "The end of another session's turn, or a turn that is not over, goes on with nothing."
  (harness-redact-test-with
    (let ((a (harness-redact-test--hosted "running"))
          (other (harness-redact-test--session "other" '(:kind user :content "hi"))))
      (push a harness-redact-test--running)
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (harness-emit 'agent/turn-ended other 'end-turn)
      (should (gethash a harness-redact--pending))
      ;; Still running: the end event is not the end.
      (harness-emit 'agent/turn-ended a 'end-turn)
      (should (gethash a harness-redact--pending))
      (should (plist-get (harness-call 'session/get a) :provider-state))
      (setq harness-redact-test--running nil)
      (harness-emit 'agent/turn-ended a 'end-turn)
      (should-not (gethash a harness-redact--pending))
      (should-not (plist-get (harness-call 'session/get a) :provider-state)))))

(ert-deftest harness-redact-forgets-a-redaction-that-waits-for-a-session-that-is-gone ()
  "The secrets of a deleted session's pending redaction leave memory."
  (harness-redact-test-with
    (let ((a (harness-redact-test--hosted "running")))
      (push a harness-redact-test--running)
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (should (gethash a harness-redact--pending))
      (harness-call 'session/delete a)
      (should-not (gethash a harness-redact--pending)))))

(ert-deftest harness-redact-masks-tool-output-while-a-redaction-waits ()
  "While a redaction waits for a turn, tool output is masked of its secrets."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--hosted "running"))
           (output (list :content (format "read: %s and %s" harness-redact-test--key harness-redact-test--id)
                         :is-error nil)))
      ;; Nothing waits: the filter lets the output through.
      (should (equal output (harness-redact--filter-output output "s" nil)))
      (push a harness-redact-test--running)
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (let* ((masked (harness-redact--filter-output output "s" nil))
             (meta (plist-get masked :meta)))
        (should-not (harness-redact-test--holds-any-p masked))
        (should (string-search (format "[redacted: spaces.secret_key sha256:%s]" (harness-redact-test--fp 0))
                               (plist-get masked :content)))
        (should (= 2 (length (plist-get meta :masked)))))
      (should-not (harness-redact-test--holds-any-p
                   (harness-redact--filter-text (format "progress %s" harness-redact-test--key) "s")))
      ;; The same filters are in the chain tool results go through.
      (should-not (harness-redact-test--holds-any-p (harness-run-filter 'tools/output output "s" nil)))
      (setq harness-redact-test--running nil)
      (harness-emit 'agent/turn-ended a 'end-turn)
      (should (equal output (harness-redact--filter-output output "s" nil))))))

(ert-deftest harness-redact-settles-a-flagged-session-after-a-restart ()
  "A session flagged as waiting, whose memory a restart lost, starts over and says the redaction must be run again."
  (harness-redact-test-with
    (let ((flagged (harness-redact-test--hosted "flagged"))
          (kept (harness-redact-test--hosted "kept")))
      (dolist (sid (list flagged kept))
        (harness-call 'session/set-ext sid :redaction-pending
                      (list (list :label "spaces.secret_key" :fingerprint "ab12cd34"))))
      ;; The harness still remembers the secrets of one of them.
      (puthash kept (list (list :secrets (harness-redact-test--secrets))) harness-redact--pending)
      (harness-redact--init)
      (should-not (plist-get (harness-call 'session/get flagged) :provider-state))
      (should-not (plist-get (plist-get (harness-call 'session/get flagged) :ext) :redaction-pending))
      (let ((hint (car (last (harness-redact-test--hints flagged)))))
        (should (string-search "stopped before the redaction" hint))
        (should (string-search "spaces.secret_key sha256:ab12cd34" hint))
        (should (string-search "run the redaction again" hint)))
      ;; One that is waiting in memory is left as it is.
      (should (plist-get (harness-call 'session/get kept) :provider-state))
      (should (plist-get (plist-get (harness-call 'session/get kept) :ext) :redaction-pending))
      (should-not (harness-redact-test--hints kept))
      ;; Once only.
      (harness-redact--init)
      (should (= 1 (length (harness-redact-test--hints flagged)))))))

(ert-deftest harness-redact-leaves-the-provider-of-a-session-it-could-not-clean ()
  "A transcript that could not be cleaned is no source for a new conversation: the provider stays."
  (harness-redact-test-with
    (let ((a (harness-redact-test--hosted "stuck")))
      (cl-letf (((symbol-function 'harness-method/session/redact-text)
                 (lambda (&rest _) (signal 'harness-error (list "the node log is not text")))))
        (harness-register-method 'session/redact-text #'harness-method/session/redact-text)
        (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
          (should (cl-some (lambda (e) (string-search "FAILED" e)) (list (plist-get report :text))))
          (should (plist-get report :errors))
          (should (plist-get (harness-call 'session/get a) :provider-state))
          ;; A session that could not be cleaned gets no record: it is in the report.
          (should-not (harness-redact-test--redactions a))
          (should-not (harness-redact-test--hints a))
          (should (cl-some (lambda (l) (string-search "stuck" l)) (list (plist-get report :text))))
          (should (cl-some (lambda (l) (string-search "NOT everything is clean" l)) (list (plist-get report :text)))))))))

;;;; The prompt cache goes with the conversation

;; A hosted loop (Claude Code, Copilot) keeps the conversation, and the
;; provider caches it.  The reset of a redaction drops the conversation,
;; so its cache goes too: the new conversation opens with the redacted
;; transcript as text.  `session/reset-provider' marks the cache dropped,
;; the report says whose went and how many tokens it held, and a scan
;; says it before the redaction is confirmed.  The sessions here sit on
;; `hosted', a fake hosted loop, or on `api', which is sent the whole
;; transcript with every request and so keeps reading its cache.

(defun harness-redact-test--define-provider (id hosted)
  "Define the fake provider ID with one model, a hosted loop when HOSTED."
  (harness-define-provider
   id
   :label (symbol-name id)
   :models (lambda ()
             (harness-resolved (list (list :name "m" :label "M" :context-window 200000))))
   :complete (lambda (_request) (list :cancel #'ignore))
   :capabilities (and hosted '(:hosted-loop t :resume t :fork t))))

(defmacro harness-redact-test-with-hosted (&rest body)
  "Run BODY with the engine and the fake providers `hosted' and `api'."
  (declare (indent 0))
  `(harness-redact-test-with
     (unwind-protect
         (progn
           (harness-redact-test--define-provider 'hosted t)
           (harness-redact-test--define-provider 'api nil)
           ,@body)
       (dolist (p '(hosted api))
         (remhash p harness-providers)
         (harness-provider--forget p)))))

(cl-defun harness-redact-test--cached (name model &key clean (cache t))
  "Create a session called NAME on MODEL, in a conversation with a warm cache.
Its transcript holds the fake key, unless CLEAN.  A session on `hosted'
is in a CLI conversation.  Unless CACHE is nil, a request that read 3000
tokens of cache was made a moment ago: the context is 3020 tokens.  Return
the id."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name name :model model)
                       :id)))
    (dolist (node (if clean
                      '((:kind user :content "refactor the parser")
                        (:kind assistant :content "Done: parser.el rewritten"))
                    (list (list :kind 'user :content (format "use the key %s please" harness-redact-test--key))
                          '(:kind assistant :content "Understood, nothing secret here."))))
      (harness-call 'session/append id node))
    (when (string-prefix-p "hosted:" model)
      (harness-call 'session/set-provider-state id (list :cli-session-id "cli-1")))
    (when cache
      (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 3000 :context 3020
                                                :cache-at (- (float-time) 10))))
    id))

(defun harness-redact-test--cache-of (sid)
  "Return the prompt cache session SID reports."
  (plist-get (harness-call 'session/get sid) :cache))

(defun harness-redact-test--cache-text (verb ids tokens)
  "Return the line a report has about the prompt cache of the sessions IDS.
VERB is the line's own words before the ids, TOKENS the tokens it names."
  (format "%s %s (~%s tokens)" verb
          (mapconcat #'harness-redact--short-id ids ", ") tokens))

(ert-deftest harness-redact-the-cache-line-counts-sessions-and-tokens-as-they-read ()
  "The line about the caches that go says how many, and how many tokens they held.
One session and one token read as such; reports without a context name
no tokens at all."
  (let ((one '(:id "aaaaaaaa-1" :context 1))
        (two '(:id "bbbbbbbb-2" :context 84000))
        (none '(:id "cccccccc-3")))
    (should (equal " (~1 token)" (harness-redact--cache-tokens (list one))))
    (should (equal " (~84.0k tokens)" (harness-redact--cache-tokens (list two))))
    (should (equal " (~84.0k tokens)" (harness-redact--cache-tokens (list two none))))
    (should (equal "" (harness-redact--cache-tokens (list none))))
    (should (equal (concat "The prompt cache of 1 session went with it: aaaaaaaa (~1 token).  "
                           "Its next message asks what goes first, as for a cold cache, "
                           "instead of sending the whole conversation again uncached.")
                   (harness-redact--cache-line (list one) t)))
    (should (equal (concat "It would drop the prompt cache of 3 sessions: aaaaaaaa, bbbbbbbb, cccccccc (~84.0k tokens).  "
                           "Their next messages would then ask what goes first, as for a cold cache, "
                           "instead of sending the whole conversation again uncached.")
                   (harness-redact--cache-line (list one two none) nil)))))

(ert-deftest harness-redact-a-hit-only-in-the-record-resets-no-conversation ()
  "A secret only in a session's queue leaves its provider conversation and its cache alone.
Nothing a provider conversation was sent held it, and a new one would be
made from the nodes: a reset would only throw the conversation and its
cache away.  The queue is cleaned and the session recorded, and neither
the scan nor the report says anything of a provider."
  (harness-redact-test-with-hosted
    (let* ((s (harness-redact-test--cached "queued" "hosted:m" :clean t))
           (_ (harness-call 'session/queue s (format "use the key %s" harness-redact-test--key)))
           (state (plist-get (harness-call 'session/get s) :provider-state))
           (cache (harness-redact-test--cache-of s))
           (usage (plist-get (harness-call 'session/get s) :usage)))
      (should state)
      (should cache)
      ;; The scan finds the queue, and says nothing would start over.
      (let* ((scan (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all))
             (entry (harness-redact-test--entry scan s)))
        (should (= 1 (plist-get entry :record)))
        (should (= 0 (plist-get entry :log)))
        (should-not (plist-get entry :would-reset))
        (should-not (plist-get entry :cache-would-drop))
        (should-not (plist-get entry :context))
        (should-not (string-search "provider conversation" (plist-get scan :text)))
        (should-not (string-search "prompt cache" (plist-get scan :text))))
      (let* ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact))
             (entry (harness-redact-test--entry report s))
             (session (harness-call 'session/get s)))
        (should (plist-get report :complete))
        (should (= 1 (plist-get entry :record)))
        (should-not (plist-member entry :provider))
        (should-not (plist-member entry :cache-dropped))
        (should-not (plist-member entry :context))
        (should-not (string-search "provider conversation" (plist-get report :text)))
        (should-not (string-search "prompt cache" (plist-get report :text)))
        ;; The queue is clean.
        (should-not (harness-redact-test--holds-any-p session))
        ;; The provider conversation and the cache are as they were.
        (should (equal state (plist-get session :provider-state)))
        (should (equal cache (plist-get session :cache)))
        (should (equal usage (plist-get session :usage)))
        (should-not (plist-member (plist-get session :cache) :dropped))
        (should (harness-call 'session/reset-drops-cache-p s))
        ;; The session is recorded and told, with no word of a conversation.
        (let ((record (car (harness-redact-test--redactions s))))
          (should (equal "none" (plist-get record :provider)))
          (should-not (plist-member record :cache-dropped)))
        (should-not (string-search "provider conversation"
                                   (car (last (harness-redact-test--hints s)))))))))

(ert-deftest harness-redact-the-prompt-cache-of-a-reset-hosted-session-goes-with-it ()
  "A redaction that resets a hosted loop's conversation says its prompt cache went with it.
The session reports the cache dropped from then on (`:dropped', which is
its `:expires' too), the report names the session and the tokens the
cache held, and the record says so.  A session sent the whole transcript
with every request starts over too, with its cache, which it still reads
up to the first redacted spot; one with no cache has none to lose."
  (harness-redact-test-with-hosted
    (let* ((h (harness-redact-test--cached "hosted" "hosted:m"))
           (a (harness-redact-test--cached "api" "api:m"))
           (bare (harness-redact-test--cached "no cache" "hosted:m" :cache nil))
           (api-cache (harness-redact-test--cache-of a))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                              :reason "leaked in a diff"))
           (text (plist-get report :text))
           (entry (lambda (sid) (harness-redact-test--entry report sid))))
      (should (plist-get report :complete))
      ;; All three start over; only the hosted one that had a cache loses one.
      (dolist (sid (list h a bare))
        (should (eq 'reset (plist-get (funcall entry sid) :provider))))
      (should (eq t (plist-get (funcall entry h) :cache-dropped)))
      (should (= 3020 (plist-get (funcall entry h) :context)))
      (dolist (sid (list a bare))
        (should-not (plist-member (funcall entry sid) :cache-dropped))
        (should-not (plist-member (funcall entry sid) :context)))
      ;; The text: the conversations, then the one cache, singular as it counts.
      (should (string-search
              "The provider conversation of 3 sessions starts over from the redacted transcript: "
              text))
      (should (string-search
               (concat (harness-redact-test--cache-text "The prompt cache of 1 session went with it:" (list h) "3.0k")
                       ".  Its next message asks what goes first, as for a cold cache,"
                       " instead of sending the whole conversation again uncached.")
               text))
      (should (< (string-search "The provider conversation of 3 sessions" text)
                 (string-search "The prompt cache of 1 session" text)))
      (should-not (string-search "would" text))
      ;; The session says the cache is gone from the reset on, not from its clock.
      (let ((cache (harness-redact-test--cache-of h)))
        (should (numberp (plist-get cache :dropped)))
        (should (= (plist-get cache :dropped) (plist-get cache :expires)))
        (should (<= (plist-get cache :dropped) (float-time)))
        (should (< (plist-get cache :dropped) (+ (plist-get cache :at) (plist-get cache :ttl)))))
      (should (numberp (plist-get (plist-get (harness-call 'session/get h) :usage) :cache-dropped)))
      ;; The session sent the whole transcript keeps what it had.
      (should (equal api-cache (harness-redact-test--cache-of a)))
      (should-not (plist-member (plist-get (harness-call 'session/get a) :usage) :cache-dropped))
      (should-not (harness-redact-test--cache-of bare))
      ;; The records, and no value anywhere.
      (should (eq t (plist-get (car (harness-redact-test--redactions h)) :cache-dropped)))
      (dolist (sid (list a bare))
        (should-not (plist-member (car (harness-redact-test--redactions sid)) :cache-dropped)))
      (should-not (harness-redact-test--holds-any-p report (harness-redact-test--redactions h)
                                                    (harness-redact-test--hints h))))))

(ert-deftest harness-redact-a-scan-says-whose-conversation-would-start-over-and-whose-cache-would-go ()
  "A scan names the conversations a redaction would start over, and the caches it would drop.
It changes nothing: the stamp, the usage and the provider state of every
session are as they were, so the cost is known before it is paid."
  (harness-redact-test-with-hosted
    (let* ((h (harness-redact-test--cached "hosted" "hosted:m"))
           (a (harness-redact-test--cached "api" "api:m"))
           (bare (harness-redact-test--cached "no cache" "hosted:m" :cache nil))
           (clean (harness-redact-test--cached "clean" "hosted:m" :clean t))
           (look (lambda (sid)
                   (let ((s (harness-call 'session/get sid)))
                     (list (plist-get s :usage) (plist-get s :cache) (plist-get s :provider-state)
                           (plist-get s :provider-node) (length (harness-call 'session/nodes sid))))))
           (before (mapcar look (list h a bare clean)))
           (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all))
           (text (plist-get report :text))
           (entry (lambda (sid) (harness-redact-test--entry report sid))))
      (should (eq 'scan (plist-get report :mode)))
      (should-not (plist-get report :complete))
      (dolist (sid (list h a bare))
        (should (eq t (plist-get (funcall entry sid) :would-reset)))
        (should-not (plist-member (funcall entry sid) :provider))
        (should-not (plist-member (funcall entry sid) :cache-dropped)))
      (should (eq t (plist-get (funcall entry h) :cache-would-drop)))
      (should (= 3020 (plist-get (funcall entry h) :context)))
      (dolist (sid (list a bare))
        (should-not (plist-member (funcall entry sid) :cache-would-drop))
        (should-not (plist-member (funcall entry sid) :context)))
      (should-not (funcall entry clean))
      ;; The text: the conversations, then the cache, in the words of a scan.
      (should (string-search
               "A redaction would start the provider conversation of 3 sessions over from the redacted transcript: "
               text))
      (should (string-search
               (concat (harness-redact-test--cache-text "It would drop the prompt cache of 1 session:" (list h) "3.0k")
                       ".  Its next message would then ask what goes first, as for a cold cache,"
                       " instead of sending the whole conversation again uncached.")
               text))
      (should (< (string-search "A redaction would start" text) (string-search "It would drop the prompt cache" text)))
      (should-not (string-search "starts over" text))
      (should-not (string-search "went with it" text))
      (should-not (harness-redact-test--holds-any-p report))
      ;; Nothing changed: not the stamp, nor the usage, the provider state or the nodes.
      (should (equal before (mapcar look (list h a bare clean))))
      (should-not (plist-member (plist-get (harness-call 'session/get h) :usage) :cache-dropped))
      (should (harness-call 'session/reset-drops-cache-p h))
      (should-not (harness-redact-test--redactions h)))))

(ert-deftest harness-redact-a-scan-counts-what-the-redaction-then-resets ()
  "The sessions a scan says would start over are those the redaction resets, cache and all.
A session outside the scope whose conversation log holds the secret
starts over when its own transcript is clean, and its cache with it.  One
whose own transcript still holds the secret keeps its conversation: a
scan does not count it, and the redaction leaves it as it is."
  (harness-redact-test-with-hosted
    (let* ((a (harness-redact-test--cached "in scope" "hosted:m"))
           (owner (harness-redact-test--cached "owner" "hosted:m" :clean t))
           (shared (harness-redact-test--cached "shares" "hosted:m"))
           (cleaned nil)
           (params (list :source (harness-redact-test--ref) :scope 'session :sessions (list a)
                         :include-forks :false)))
      ;; The conversation logs of the two out of the scope hold the secret until a
      ;; redaction takes it out; nothing else is credited.
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (_secrets &optional _ids dry)
                                   (let ((found (not cleaned)))
                                     (unless dry (setq cleaned t))
                                     (list :directory "/c/" :count (if found 8 0) :scanned 2
                                           :files (and found
                                                       (list (list :file "/c/p/cli-o.jsonl" :cli-session "cli-o"
                                                                   :owners (list owner) :count 4
                                                                   :status (if dry 'found 'redacted))
                                                             (list :file "/c/p/cli-s.jsonl" :cli-session "cli-s"
                                                                   :owners (list shared) :count 4
                                                                   :status (if dry 'found 'redacted))))))))
      (let* ((scan (apply #'harness-redact-test--call params))
             (text (plist-get scan :text))
             (entry (lambda (sid) (harness-redact-test--entry scan sid))))
        (should (equal (sort (list a owner shared) #'string<) (harness-redact-test--session-ids scan)))
        (should (eq t (plist-get (funcall entry a) :would-reset)))
        (should (eq t (plist-get (funcall entry owner) :would-reset)))
        (should (eq t (plist-get (funcall entry owner) :cache-would-drop)))
        (should-not (plist-member (funcall entry shared) :would-reset))
        (should-not (plist-member (funcall entry shared) :cache-would-drop))
        (should (string-search "A redaction would start the provider conversation of 2 sessions over" text))
        (should (string-search
                 (concat (harness-redact-test--cache-text "It would drop the prompt cache of 2 sessions:"
                                                          (list a owner) "6.0k")
                         ".  Their next messages would then ask what goes first, as for a cold cache,"
                         " instead of sending the whole conversation again uncached.")
                 text)))
      (should-not cleaned)
      (let* ((report (apply #'harness-redact-test--call :mode 'redact params))
             (text (plist-get report :text))
             (entry (lambda (sid) (harness-redact-test--entry report sid))))
        (should (eq 'reset (plist-get (funcall entry a) :provider)))
        (should (eq 'reset (plist-get (funcall entry owner) :provider)))
        (should (eq 'kept (plist-get (funcall entry shared) :provider)))
        (should (eq t (plist-get (funcall entry a) :cache-dropped)))
        (should (eq t (plist-get (funcall entry owner) :cache-dropped)))
        (should-not (plist-member (funcall entry shared) :cache-dropped))
        (should (string-search
                 (concat (harness-redact-test--cache-text "The prompt cache of 2 sessions went with it:"
                                                          (list a owner) "6.0k")
                         ".  Their next messages ask what goes first, as for a cold cache,"
                         " instead of sending the whole conversation again uncached.")
                 text))
        ;; The one kept has its conversation and its cache.
        (should (plist-get (harness-call 'session/get shared) :provider-state))
        (should-not (plist-member (harness-redact-test--cache-of shared) :dropped))
        (should (numberp (plist-get (harness-redact-test--cache-of owner) :dropped)))))))

(ert-deftest harness-redact-a-scan-does-not-count-a-session-it-could-not-read ()
  "A session whose stores could not be read is no conversation a redaction would start over.
The redaction leaves its provider as it is (`failed'): a new conversation
would be made from a transcript that was not cleaned, so a scan says nothing
of a reset or of a cache for it, and reports the failure as it always did."
  (harness-redact-test-with-hosted
    (let ((s (harness-redact-test--cached "stuck" "hosted:m")))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _)
                                   (list :directory "/c/" :count 2 :scanned 1
                                         :files (list (list :file "/c/p/cli-1.jsonl" :cli-session "cli-1"
                                                            :owners (list s) :count 2 :status 'found)))))
      (cl-letf (((symbol-function 'harness-method/session/redact-text)
                 (lambda (&rest _) (signal 'harness-error (list "the node log is not text")))))
        (harness-register-method 'session/redact-text #'harness-method/session/redact-text)
        (let* ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all))
               (entry (harness-redact-test--entry report s)))
          (should (plist-get report :errors))
          (should (plist-get entry :error))
          (should-not (plist-member entry :would-reset))
          (should-not (plist-member entry :cache-would-drop))
          (should-not (plist-member entry :context))
          (should-not (string-search "provider conversation" (plist-get report :text)))
          (should-not (string-search "prompt cache" (plist-get report :text))))))))

(ert-deftest harness-redact-a-running-session-loses-its-cache-when-its-turn-ends ()
  "A session that runs a turn keeps its cache until the turn ends, then loses it with its conversation.
The scan counts it, as its conversation starts over then.  The report of
the redaction waits for it and says nothing of a cache that is still
there; the second record, written when the turn ended, says it went."
  (harness-redact-test-with-hosted
    (let* ((s (harness-redact-test--cached "running" "hosted:m")))
      (push s harness-redact-test--running)
      (let ((scan (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)))
        (should (eq t (plist-get (harness-redact-test--entry scan s) :cache-would-drop)))
        (should (string-search "It would drop the prompt cache of 1 session" (plist-get scan :text))))
      (let ((cache (harness-redact-test--cache-of s))
            (report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                               :reason "leak")))
        (should (equal (list s) (plist-get report :deferred)))
        (should (eq 'deferred (plist-get (harness-redact-test--entry report s) :provider)))
        (should-not (plist-member (harness-redact-test--entry report s) :cache-dropped))
        (should-not (string-search "prompt cache" (plist-get report :text)))
        ;; Nothing was reset: the cache is warm, as it was.
        (should (equal cache (harness-redact-test--cache-of s)))
        (should-not (plist-member (car (harness-redact-test--redactions s)) :cache-dropped)))
      (setq harness-redact-test--running nil)
      (harness-emit 'agent/turn-ended s 'end-turn)
      (should-not (plist-get (harness-call 'session/get s) :provider-state))
      (let ((cache (harness-redact-test--cache-of s)))
        (should (numberp (plist-get cache :dropped)))
        (should (= (plist-get cache :dropped) (plist-get cache :expires))))
      (let ((records (harness-redact-test--redactions s)))
        (should (= 2 (length records)))
        (should-not (plist-member (car records) :cache-dropped))
        (should (plist-get (cadr records) :after-turn))
        (should (eq t (plist-get (cadr records) :cache-dropped)))))))

;;;; Live sessions, and a store that fails

(ert-deftest harness-redact-loses-no-append-and-tears-no-log-on-a-running-session ()
  "Redacting a running session keeps what it wrote before and after, line by line."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "running"))
           (before (length (harness-call 'session/nodes a))))
      (push a harness-redact-test--running)
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (dotimes (i 5)
        (harness-call 'session/append a (list :kind 'assistant :content (format "after %d" i))))
      (let* ((log (harness-redact-test--read (harness-redact-test--log a)))
             (lines (split-string log "\n" t)))
        (should (string-suffix-p "\n" log))
        ;; Every line is a whole JSON object.
        (dolist (line lines) (should (consp (harness-json-parse line))))
        (should (cl-every (lambda (i) (string-search (format "after %d" i) log)) (number-sequence 0 4))))
      ;; The session reloads from its log with all of them: the four it had, the hint, the five.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= (+ before 1 5) (length (harness-call 'session/nodes a))))
      (should-not (harness-redact-test--holds-any-p (harness-call 'session/nodes a))))))

(ert-deftest harness-redact-goes-on-when-one-store-fails ()
  "A store that fails is reported, and the others are still taken."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _) (signal 'harness-error (list "the projects directory cannot be read"))))
      (harness-redact-test--stub 'provider/copilot-redact-logs
                                 (lambda (&rest _) (list :directory "/p/" :count 0 :scanned 0 :files nil)))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
        (should (= 1 (length (plist-get report :errors))))
        (should-not (plist-get report :complete))
        (should (string-search "claude failed: the projects directory cannot be read"
                               (car (plist-get report :errors))))
        (should (string-search "FAILED" (plist-get report :text)))
        ;; The other store is taken, and scanned again by the verification.
        (should (= 2 (length (harness-redact-test--calls-of 'provider/copilot-redact-logs))))
        (should (= 0 (harness-redact-test--stored-count)))
        (should (harness-redact-test--redactions a))))))

(ert-deftest harness-redact-says-what-a-provider-log-left ()
  "A provider log that is busy, running or unreadable is named as not clean."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (harness-redact-test--stub 'provider/claude-redact-logs
                                 (lambda (&rest _)
                                   (list :directory "/c/" :count 2 :scanned 1
                                         :files (list (list :file "/c/p/cli-1.jsonl" :cli-session "cli-1"
                                                            :owners (list a) :count 2 :status 'busy)))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
        (should (= 1 (length (plist-get report :remaining))))
        (should (string-search "/c/p/cli-1.jsonl" (car (plist-get report :remaining))))
        (should (string-search "NOT everything is clean" (plist-get report :text)))))))

(ert-deftest harness-redact-says-when-the-index-could-not-be-purged ()
  "A purge that fails is in the report as not clean."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (harness-redact-test--stub 'session/search-redact
                                 (lambda (_ids _secrets &optional _dry)
                                   (list :available t :rows 1 :sessions (list (cons a 1)))))
      (harness-redact-test--stub 'session/search-purge
                                 (lambda (&rest _) (signal 'harness-error (list "Cannot vacuum the index: disk full"))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
        (should (string-search "Cannot vacuum the index" (car (plist-get report :remaining))))
        (should (string-search "Cannot vacuum the index" (car (plist-get report :errors))))))))

(ert-deftest harness-redact-says-how-many-secrets-the-index-files-still-hold ()
  "What the purge left in the files of the index is counted, and the verb agrees with the count."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty"))
          (left 1))
      (harness-redact-test--stub 'session/search-redact
                                 (lambda (_ids _secrets &optional _dry)
                                   (list :available t :rows 1 :sessions (list (cons a 1)))))
      (harness-redact-test--stub 'session/search-purge
                                 (lambda (&rest _)
                                   (list :available t :seconds 0.1 :bytes-before 10 :bytes-after 5
                                         :wal-truncated nil :term-counts nil
                                         :file-counts (cl-loop for i below left
                                                               collect (cons (format "/index/search-%d.db" i) 1)))))
      (dolist (case '((1 . "1 occurrence of the secrets is still in its files")
                      (2 . "2 occurrences of the secrets are still in its files")))
        (setq left (car case))
        (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)))
          (should (cl-some (lambda (line) (string-search (cdr case) line)) (plist-get report :remaining)))
          (should (string-search (cdr case) (plist-get report :text))))))))

(ert-deftest harness-redact-names-each-secret-with-its-own-count ()
  "With several secrets, a record counts each on its own."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--session
               "dirty"
               (list :kind 'user :content (format "%s %s %s" harness-redact-test--key
                                                  harness-redact-test--id harness-redact-test--key)))))
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (let ((secrets (plist-get (car (harness-redact-test--redactions a)) :secrets)))
        (should (equal '(2 1) (mapcar (lambda (s) (plist-get s :count)) secrets)))
        (should (equal '("spaces.secret_key" "spaces.access_key") (mapcar (lambda (s) (plist-get s :label)) secrets)))))))

(ert-deftest harness-redact-keeps-the-last-records-of-a-session ()
  "A session keeps at most the last redaction records, and the last is the newest."
  (harness-redact-test-with
    (let ((a (harness-redact-test--session "dirty" '(:kind user :content "no secret yet")))
          (harness-redact--records-limit 4))
      (dotimes (i 7)
        (harness-call 'session/append a (list :kind 'user :content (format "round %d: %s" i harness-redact-test--id)))
        (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                   :reason (format "round %d" i)))
      (should (equal '("round 3" "round 4" "round 5" "round 6")
                     (mapcar (lambda (r) (plist-get r :reason)) (harness-redact-test--redactions a))))
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 4 (length (harness-redact-test--redactions a)))))))

(ert-deftest harness-redact-records-survive-a-restart ()
  "The records are in the session's record on disk, and come back with it."
  (harness-redact-test-with
    (let ((a (harness-redact-test--dirty "dirty")))
      (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((record (car (harness-redact-test--redactions a))))
        (should (equal "user" (plist-get record :by)))
        (should (= 4 (plist-get (plist-get record :counts) :log)))
        (should (equal "spaces.secret_key" (plist-get (car (plist-get record :secrets)) :label)))))))

;;;; The search index, for real

(defmacro harness-redact-test-with-search (&rest body)
  "Run BODY with the session modules, the search index and the engine, in a fresh state."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo session usage session-search secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-redact--pending)
     (let ((harness-session-search-index t)
           (harness-session-search-embedding-model nil)
           (default-directory dir)
           (harness-redact-test--running nil)
           (harness-redact-test--calls nil)
           (harness-redact-test--events nil))
       (harness-register-method 'agent/running
                                (lambda (&optional sid) (and sid (member sid harness-redact-test--running) t)))
       ,@body)))

(defun harness-redact-test--quiet-index ()
  "Stop the background of the search index: the test drives it."
  (clrhash harness-session-search--dirty)
  (when harness-session-search--timer
    (cancel-timer (cdr harness-session-search--timer))
    (setq harness-session-search--timer nil)))

(ert-deftest harness-redact-leaves-no-copy-in-the-search-index ()
  "A redaction reads the logs into the index again and purges it: no store keeps a byte."
  (harness-redact-test-with-search
    (let* ((a (harness-redact-test--dirty "dirty"))
           (b (harness-redact-test--dirty "also dirty"))
           (c (harness-redact-test--session "clean" '(:kind user :content "only an okapi")))
           (db (harness-session-search--db)))
      (dolist (s (list a b c)) (harness-session-search--sync db s))
      (harness-redact-test--quiet-index)
      ;; The index holds the secret, in its files too.
      (should (> (cl-loop for f in (harness-session-search--files)
                          sum (harness-redaction-file-count f (harness-redact-test--secrets)))
                 0))
      (let ((scan (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)))
        (let ((index (cl-find "search index" (plist-get scan :stores)
                              :key (lambda (s) (plist-get s :store)) :test #'equal)))
          (should (= 6 (plist-get index :rows)))
          (should (= 3 (plist-get (harness-redact-test--entry scan a) :search)))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a b) :mode 'redact)))
        (harness-redact-test--quiet-index)
        (let ((index (cl-find "search index" (plist-get report :stores)
                              :key (lambda (s) (plist-get s :store)) :test #'equal)))
          (should (equal (sort (list a b) #'string<) (sort (copy-sequence (plist-get index :reindexed)) #'string<)))
          (should (= 0 (plist-get (plist-get index :purge) :left)))
          (should (plist-get (plist-get index :purge) :wal-truncated)))
        ;; The state directory, search.db and its log among it, holds no copy.
        (should (= 0 (harness-redact-test--stored-count)))
        (should (= 0 (caar (sqlite-select db "SELECT count(*) FROM nodes WHERE instr(text, ?) > 0"
                                          (list harness-redact-test--key)))))
        (should-not (harness-redact-test--holds-any-p report))
        (should (string-search "Search index purged" (plist-get report :text)))))))

;;;; Nothing it logs or emits

(ert-deftest harness-redact-logs-and-emits-no-value-at-all ()
  "Nothing the bus carries or the log keeps during a scan, a redaction and a deferred re-run holds a value."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--hosted "running"))
           (b (harness-redact-test--hosted "idle"))
           (events nil)
           (logged nil)
           (hook (lambda (_level message) (push message logged)))
           (log-start (with-current-buffer (get-buffer-create harness-log-buffer-name) (point-max))))
      (harness-on '* (lambda (event args) (push (cons event args) events)))
      (add-hook 'harness-log-hook hook)
      (unwind-protect
          (progn
            (push a harness-redact-test--running)
            (harness-redact-test--stub 'provider/claude-redact-logs
                                       (lambda (&rest _)
                                         (list :directory "/c/" :count 2 :scanned 3
                                               :files (list (list :file "/c/p/cli-1.jsonl" :cli-session "cli-1"
                                                                  :owners (list a b) :count 2 :status 'redacted)))))
            (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all)
            (harness-redact-test--call :source (harness-redact-test--ref) :scope 'all :mode 'redact
                                       :reason "leak")
            (harness-call 'session/append a (list :kind 'assistant :content harness-redact-test--key))
            (setq harness-redact-test--running nil)
            (harness-emit 'agent/turn-ended a 'end-turn))
        (remove-hook 'harness-log-hook hook))
      (should events)
      ;; Every event of the bus, but the one node the test wrote with the secret in it.
      (should-not (harness-redact-test--holds-any-p
                   (cl-remove-if (lambda (e) (and (eq (car e) 'session/node-added)
                                                  (harness-redact-test--holds-any-p (cdr e))))
                                 events)
                   logged
                   (with-current-buffer harness-log-buffer-name
                     (buffer-substring-no-properties log-start (point-max)))))
      (should (= 1 (cl-count-if (lambda (e) (and (eq (car e) 'session/node-added)
                                                 (harness-redact-test--holds-any-p (cdr e))))
                                events)))
      ;; The engine did log: what, for whom, how many.
      (should (cl-some (lambda (m) (string-search "redact:" m)) logged)))))

;;;; The places for the stores, checks and finishers that other modules add

(defvar harness-redact--store-functions)
(defvar harness-redact--verify-functions)
(defvar harness-redact--finish-functions)

(ert-deftest harness-redact-runs-the-stores-checks-and-finishers-it-is-given ()
  "A store function sees the run, reports a store, credits a session; checks and finishers follow."
  (harness-redact-test-with
    (let* ((a (harness-redact-test--dirty "dirty"))
           (order nil)
           (finished nil)
           (expect-dry nil)
           (harness-redact--store-functions
            (append harness-redact--store-functions
                    (list (lambda (run)
                            (push 'files order)
                            (should (equal (list a) (harness-redact-run-ids run)))
                            (should (equal 2 (length (harness-redact-run-secrets run))))
                            (should (eq expect-dry (harness-redact-run-dry-p run)))
                            (harness-redact-entry-incr run a :files-count 2)
                            (harness-redact-entry-add run a :files (list "/state/outputs/c1.txt"))
                            (harness-redact-add-store run (list :store "output files" :count 2)
                                                      (list "Output files: 2 occurrences."))))))
           (harness-redact--verify-functions
            (list (lambda (run)
                    (push 'verify order)
                    (harness-redact-add-lines run (list "Verified: nothing is left."))
                    (harness-redact-run-set-prop run :verified t))))
           (harness-redact--finish-functions
            (list (lambda (run report)
                    (push 'finish order)
                    (setq finished (list (harness-redact-run-prop run :verified) (plist-get report :total)))))))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a) :mode 'redact)))
        ;; In order: the stores, then the checks, then the finishers, after the report.
        (should (equal '(files verify finish) (reverse order)))
        (should (equal (list t 6) finished))
        (should (= 6 (plist-get report :total)))
        (should (equal "output files" (plist-get (car (last (plist-get report :stores))) :store)))
        (should (string-search "Output files: 2 occurrences." (plist-get report :text)))
        (should (string-search "Verified: nothing is left." (plist-get report :text)))
        (should (member "/state/outputs/c1.txt"
                        (plist-get (car (harness-redact-test--redactions a)) :files))))
      ;; A scan runs the stores and the checks, not the finishers.
      (setq order nil expect-dry t)
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list a))))
        (should (equal '(files verify) (reverse order)))
        (should (string-search "Output files" (plist-get report :text)))))))

;;;; A hosted-loop session, for real

(defmacro harness-redact-test-with-claude (&rest body)
  "Run BODY with sessions whose turns the agent runs on the fake Claude CLI.
The fake keeps its conversations in a store, as the CLI does, and the
CLI's own logs are in a directory of the test's (PROJECTS), never the
user's.  BODY sees CWD, the directory of the sessions, and STORE, where
the fake keeps the conversations."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(provider provider-claude))
       (harness-test-load-module m))
     (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
     (harness-provider-claude-close-all)
     (clrhash harness-provider-claude--sessions)
     (setq harness-provider-claude--status nil
           harness-provider-claude--asked nil
           harness-provider-claude--probe nil
           harness-provider-claude-api-key 'none
           harness-provider-claude--api-base nil)
     (harness-provider-claude--forget-listing)
     (harness-provider--forget 'claude)
     (dolist (m '(store project config provider-demo tools session agent secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (let* ((cwd (harness-test-temp-dir))
            (store (harness-test-temp-dir))
            (projects (harness-test-temp-dir))
            (harness-provider-claude-projects-directory projects)
            (default-directory dir)
            (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_STORE=" store) process-environment)))
       (ignore cwd store projects)
       (unwind-protect (progn ,@body)
         (harness-provider-claude-close-all)))))

(defun harness-redact-test--turn (sid text)
  "Run a turn of session SID asking TEXT; return the argv of the CLI it spawned, or nil."
  (let* ((argv-file (make-temp-file "harness-redact-argv-"))
         (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file) process-environment)))
    (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid text)) :stop-reason)))
    (and (> (or (harness-file-size argv-file) 0) 0)
         (plist-get (harness-json-parse (harness-read-file argv-file)) :argv))))

(defun harness-redact-test--last-reply (sid)
  "Return the text of the last assistant node of session SID."
  (plist-get (cl-find 'assistant (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)) :from-end t)
             :content))

(ert-deftest harness-redact-a-hosted-session-goes-on-from-the-redacted-transcript ()
  "After a redaction the CLI session is not resumed: a new one is made from the redacted transcript.
The fake CLI keeps what it was told, as the real one does, and answers
a prompt that says recall with it: the old conversation holds the
secret, the new one must not."
  (harness-redact-test-with-claude
    (let* ((sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id))
           (argv (harness-redact-test--turn sid (format "keep the key %s in mind" harness-redact-test--key)))
           (cli (plist-get (plist-get (harness-call 'session/get sid) :provider-state) :cli-session-id))
           (log (expand-file-name (format "slug/%s.jsonl" cli) projects)))
      (should argv)
      (should (string-prefix-p "fake-" cli))
      ;; The CLI holds the secret in its own store and in its log.
      (should (> (cl-loop for f in (directory-files store t "\\.json\\'")
                          sum (harness-redaction-file-count f (harness-redact-test--secrets)))
                 0))
      (make-directory (file-name-directory log) t)
      (with-temp-file log
        (insert (harness-json-encode-text
                 (list :type "user" :message (list :content (format "keep the key %s in mind" harness-redact-test--key))))
                "\n"))
      (let ((report (harness-redact-test--call :source (harness-redact-test--ref) :scope 'session
                                               :sessions (list sid) :mode 'redact)))
        (should (equal (list sid) (harness-redact-test--session-ids report)))
        ;; The CLI's log is clean, and the session's own stores.
        (should (= 0 (harness-redaction-file-count log (harness-redact-test--secrets))))
        (should (string-search "[redacted: " (harness-redact-test--read log)))
        (should (= 1 (plist-get (harness-redact-test--entry report sid) :claude)))
        (should (member log (plist-get (car (harness-redact-test--redactions sid)) :files)))
        (should (= 0 (harness-redact-test--stored-count)))
        (should-not (plist-get (harness-call 'session/get sid) :provider-state))
        (should-not (harness-redact-test--holds-any-p report)))
      ;; The next turn starts a new CLI session; it does not resume the old one.
      (let ((argv (harness-redact-test--turn sid "recall")))
        (should argv)
        (should-not (member "--resume" argv))
        (should-not (member "--fork-session" argv)))
      (let ((new-cli (plist-get (plist-get (harness-call 'session/get sid) :provider-state) :cli-session-id)))
        (should (string-prefix-p "fake-" new-cli))
        (should-not (equal cli new-cli)))
      ;; What the new conversation was told is the transcript as the harness has it now.
      (let ((reply (harness-redact-test--last-reply sid)))
        (should (string-prefix-p "I remember: " reply))
        (should (string-search "[redacted: " reply))
        (should-not (harness-redact-test--holds-any-p reply)))
      (should (= 0 (harness-redact-test--stored-count))))))

;;;; Docs and tests of the pieces that only the engine drives

(ert-deftest harness-redact-the-module-needs-the-secrets-the-sessions-and-the-store ()
  "The module is declared with what it needs and the event it emits."
  (harness-redact-test-with
    (let ((module (harness-module-get 'redact)))
      (should (equal '(secrets session store) (harness-module-requires module)))
      (should (harness-module-ready-p 'redact)))
    (should (assq 'secrets/redacted (harness-events)))
    (should (assq 'session/redacted (harness-events)))
    (should (harness-method-exists-p 'secrets/redact))))

(provide 'harness-redact-test)
;;; harness-redact-test.el ends here
