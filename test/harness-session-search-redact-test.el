;;; harness-session-search-redact-test.el --- Secrets in the search index  -*- lexical-binding: t; -*-

;;; Commentary:

;; The search index keeps a copy of the text of every transcript, so a
;; secret that got into one is in search.db too: in the rows, in the
;; full-text index over them, in the vectors of their chunks, and, after
;; the rows are deleted, still in the pages SQLite freed and in its
;; write-ahead log.  These tests build an index from logs that hold fake
;; secrets, redact the logs by hand (not through the redaction of the
;; harness, which is another suite's), and check that
;; `session/search-redact' scans for the secrets and reads the logs
;; again, that `session/search-purge' leaves no byte of them in
;; search.db, search.db-wal or search.db-shm, that a rebuild leaves none
;; either, and that nothing they return, ask or log holds a secret.  The
;; secrets are fake and built here, so no file holds one whole.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-session-search-index)
(defvar harness-session-search-embedding-model)
(defvar harness-session-search-embedding-dimensions)
(defvar harness-session-search--timer)
(defvar harness-session-search--dirty)
(defvar harness-session-search--doomed)
(defvar harness-session-search--embedding)
(defvar harness-session-search--embed-failure)
(defvar harness-session-search--max-sql-ids)
(defvar harness-session-search--tokenizer)
(defvar harness-session-search--schema)
(declare-function harness-session-search--db "harness-session-search")
(declare-function harness-session-search--step "harness-session-search")
(declare-function harness-session-search--sync "harness-session-search")
(declare-function harness-session-search--files "harness-session-search")
(declare-function harness-session-search--embed-request "harness-session-search")
(declare-function harness-session-search--secret-terms "harness-session-search")

(defmacro harness-session-search-redact-test-with (&rest body)
  "Load sessions, usage and their search in a fresh state directory; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo session usage session-search))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((harness-session-search-index t)
           (harness-session-search-embedding-model nil)
           (harness-session-search-embedding-dimensions nil)
           (default-directory dir))
       ,@body)))

;;;; The fake secrets and the sessions that hold them

(defconst harness-session-search-redact-test--token
  (concat "zkq" (substring (md5 "harness-search-redact-test") 0 12) "vw")
  "A lowercase word of letters and digits: one term of the full-text index.")

(defconst harness-session-search-redact-test--id-term
  (concat "dofake" (substring (md5 "harness-search-redact-key-id") 0 14))
  "The lowercase form of the fake access key id, also one term.")

(defun harness-session-search-redact-test--secrets ()
  "Return two fake secrets, an access key id and a secret key, built here."
  (list (harness-redaction-secret (upcase harness-session-search-redact-test--id-term)
                                  "fake key id")
        (harness-redaction-secret (concat "Zk_" harness-session-search-redact-test--token "/Qx+==")
                                  "fake secret key")))

(defun harness-session-search-redact-test--terms ()
  "Return the terms of the secrets as the full-text index holds them."
  (list harness-session-search-redact-test--id-term harness-session-search-redact-test--token))

(defun harness-session-search-redact-test-session (name &rest nodes)
  "Create a session called NAME holding NODES; return its id.
A node is a plist, or a string: a user message."
  (let ((id (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted" :name name)
                       :id)))
    (dolist (n nodes)
      (harness-call 'session/append id (if (stringp n) (list :kind 'user :content n) n)))
    id))

(defun harness-session-search-redact-test--quiet ()
  "Stop the background of the index: a test drives every step of it itself."
  (clrhash harness-session-search--dirty)
  (when harness-session-search--timer
    (cancel-timer (cdr harness-session-search--timer))
    (setq harness-session-search--timer nil)))

(defun harness-session-search-redact-test--fixture ()
  "Make and index three sessions; return (:a A :b B :c C :secrets SECRETS :db DB).
A holds the secrets in a tool result, a reply and the input of a call
\(three nodes), B in a user message (one), and C holds none."
  (let* ((secrets (harness-session-search-redact-test--secrets))
         (id (plist-get (nth 0 secrets) :value))
         (key (plist-get (nth 1 secrets) :value))
         (a (harness-session-search-redact-test-session
             "Diff the state files"
             "Please diff the two state files"
             '(:kind tool-call :tool "shell" :call-id "c1" :input (:command "diff old new"))
             (list :kind 'tool-result :call-id "c1" :output (format "access_key = %s\nsecret_key = %s" id key))
             (list :kind 'assistant :content (format "The key id is %s and its secret is %s." id key))
             (list :kind 'tool-call :tool "shell" :call-id "c2" :input (list :command (format "echo %s" key)))))
         (b (harness-session-search-redact-test-session "Cut over" (format "The key id was %s" id)))
         (c (harness-session-search-redact-test-session "Unrelated" "Nothing to hide here, only an okapi"))
         (db (harness-session-search--db)))
    (dolist (s (list a b c)) (harness-session-search--sync db s))
    (harness-session-search-redact-test--quiet)
    (list :a a :b b :c c :secrets secrets :db db)))

(defun harness-session-search-redact-test--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))

(defun harness-session-search-redact-test--redact-log (sid secrets)
  "Replace the values of SECRETS by their placeholders in the log of SID, by hand.
The values hold nothing JSON writes differently, so this is a text edit."
  (let ((log (harness-session-search-redact-test--log sid)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8)) (insert-file-contents log))
      (dolist (secret secrets)
        (goto-char (point-min))
        (while (search-forward (plist-get secret :value) nil t)
          (replace-match (harness-redaction-placeholder secret) t t)))
      (let ((coding-system-for-write 'utf-8-unix)) (write-region nil nil log nil 'silent)))))

(defun harness-session-search-redact-test--count (sql &rest args)
  "Return the number SQL with ARGS selects from the index."
  (caar (sqlite-select (harness-session-search--db) sql args)))

(defun harness-session-search-redact-test--raw (secrets)
  "Return how many times SECRETS occur in the bytes of the index's three files."
  (cl-loop for file in (harness-session-search--files)
           sum (harness-redaction-file-count file secrets)))

(defun harness-session-search-redact-test--word-prefixes (secrets)
  "Return what the full-text index stores of the words of SECRETS.
That is each word of 11 characters or more of a value, lowercased, less
its last three characters, which the stemmer may change."
  (cl-loop for secret in secrets
           append (cl-loop for word in (split-string (downcase (plist-get secret :value)) "[^[:alnum:]]+" t)
                           when (>= (length word) 11)
                           collect (substring word 0 (- (length word) 3)))))

(defun harness-session-search-redact-test--words (secrets)
  "Return how many times the words of SECRETS occur in the index's three files."
  (let ((words (mapcar (lambda (word) (list :value word))
                       (harness-session-search-redact-test--word-prefixes secrets))))
    (cl-loop for file in (harness-session-search--files)
             sum (harness-redaction-file-count file words))))

(defun harness-session-search-redact-test--matches (term)
  "Return the rowids the full-text index finds for TERM."
  (mapcar #'car (sqlite-select (harness-session-search--db)
                               "SELECT rowid FROM nodes_fts WHERE nodes_fts MATCH ?"
                               (list (format "\"%s\"" term)))))

(defun harness-session-search-redact-test--add-vector (sid node-id hash)
  "Give the node NODE-ID of session SID in the index a chunk with a vector HASH."
  (let ((rowid (harness-session-search-redact-test--count
                "SELECT id FROM nodes WHERE session = ? AND node = ?" sid node-id)))
    (sqlite-execute (harness-session-search--db)
                    "INSERT OR IGNORE INTO vectors (hash, scale, vec) VALUES (?, 1.0, ?)"
                    (list hash (propertize (unibyte-string 130 126 128) 'coding-system 'binary)))
    (sqlite-execute (harness-session-search--db)
                    "INSERT INTO chunks (node, part, hash) VALUES (?, 0, ?)" (list rowid hash))))

(defun harness-session-search-redact-test--node (sid kind)
  "Return the id of the first node of KIND session SID holds in its log."
  (plist-get (cl-find kind (harness-call 'session/nodes sid)
                      :key (lambda (n) (plist-get n :kind)))
             :id))

(defun harness-session-search-redact-test--sorted (alist)
  "Return the (SESSION . N) pairs of ALIST sorted by session id."
  (sort (copy-sequence alist) (lambda (x y) (string< (car x) (car y)))))

(defun harness-session-search-redact-test--clean-p (secrets &rest things)
  "Non-nil when none of THINGS, printed, holds a value or term of SECRETS."
  (let ((text (mapconcat (lambda (thing) (format "%S" thing)) things "\n")))
    (not (cl-some (lambda (needle) (string-search needle text))
                  (append (mapcar (lambda (s) (plist-get s :value)) secrets)
                          (harness-session-search-redact-test--terms))))))

(defun harness-session-search-redact-test--log-text ()
  "Return the text of the harness log buffer."
  (with-current-buffer (get-buffer-create harness-log-buffer-name)
    (buffer-substring-no-properties (point-min) (point-max))))

;;;; Scanning

(ert-deftest harness-session-search-redact-scan-counts-rows-by-session ()
  "A scan counts the rows that hold a secret in each session, narrowed to
the sessions asked for, and changes nothing."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b)) (c (plist-get fx :c))
           (secrets (plist-get fx :secrets))
           (all (harness-session-search-redact-test--sorted (list (cons a 3) (cons b 1)))))
      (let ((r (harness-call 'session/search-redact t secrets t)))
        (should (eq t (plist-get r :available)))
        (should (= 4 (plist-get r :rows)))
        (should (equal all (plist-get r :sessions)))
        (should-not (plist-member r :reindexed)))
      ;; Each secret alone finds its own rows: the key id is in three nodes
      ;; (two of A and the one of B), the key in the three of A.
      (should (= 3 (plist-get (harness-call 'session/search-redact t (list (nth 0 secrets)) t) :rows)))
      (should (= 3 (plist-get (harness-call 'session/search-redact t (list (nth 1 secrets)) t) :rows)))
      ;; Ids narrow it.
      (should (equal (list (cons a 3)) (plist-get (harness-call 'session/search-redact (list a) secrets t) :sessions)))
      (should (equal (list (cons b 1)) (plist-get (harness-call 'session/search-redact (list b c) secrets t) :sessions)))
      (should (= 0 (plist-get (harness-call 'session/search-redact (list c) secrets t) :rows)))
      (should (= 0 (plist-get (harness-call 'session/search-redact nil secrets t) :rows)))
      ;; More ids than a query names are matched afterwards, with the same answer.
      (let ((harness-session-search--max-sql-ids 1))
        (should (equal all (plist-get (harness-call 'session/search-redact (list a b c) secrets t) :sessions)))
        (should (equal (list (cons b 1)) (plist-get (harness-call 'session/search-redact (list b c) secrets t) :sessions))))
      ;; Nothing to look for, nothing found.
      (should (= 0 (plist-get (harness-call 'session/search-redact t nil t) :rows)))
      (should (= 0 (plist-get (harness-call 'session/search-redact
                                            t (list (harness-redaction-secret "not-in-any-transcript" "other") ) t)
                              :rows)))
      ;; A scan changes nothing: the rows are as they were, and so is the log it has read.
      (should (= 4 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      (should (= 3 (harness-session-search-redact-test--count
                    "SELECT count(*) FROM nodes WHERE session = ? AND instr(text, ?) > 0"
                    a (plist-get (nth 1 secrets) :value)))))))

(ert-deftest harness-session-search-redact-scan-finds-a-secret-as-json-writes-it ()
  "The input of a tool call is kept as JSON text, in which a quote or a
backslash of a secret is escaped: the scan looks for that form too."
  (harness-session-search-redact-test-with
    (let* ((secret (harness-redaction-secret
                    (concat "fa\"ke\\" harness-session-search-redact-test--token "\\q") "quoted"))
           (a (harness-session-search-redact-test-session
               "Quoting"
               (list :kind 'tool-call :tool "shell" :call-id "c"
                     :input (list :command (concat "echo " (plist-get secret :value)))))))
      (harness-session-search--sync (harness-session-search--db) a)
      (harness-session-search-redact-test--quiet)
      (let ((text (harness-session-search-redact-test--count "SELECT text FROM nodes WHERE session = ?" a)))
        (should-not (string-search (plist-get secret :value) text))
        (should (string-search (cadr (harness-redaction-needles secret)) text)))
      (should (equal (list (cons a 1))
                     (plist-get (harness-call 'session/search-redact t (list secret) t) :sessions))))))

(ert-deftest harness-session-search-redact-asks-with-the-secret-bound ()
  "A secret is bound to the queries, never part of their text; nothing a
scan returns or logs holds it."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (secrets (plist-get fx :secrets))
           (sql nil)
           (note (lambda (db query &rest _) (ignore db) (push query sql)))
           (results nil))
      (advice-add 'sqlite-select :before note)
      (advice-add 'sqlite-execute :before note)
      (unwind-protect
          (progn
            (push (harness-call 'session/search-redact t secrets t) results)
            (push (harness-call 'session/search-redact (list (plist-get fx :a)) secrets) results))
        (advice-remove 'sqlite-select note)
        (advice-remove 'sqlite-execute note))
      (should sql)
      (should (harness-session-search-redact-test--clean-p secrets sql))
      (should (harness-session-search-redact-test--clean-p secrets results))
      (should (harness-session-search-redact-test--clean-p secrets (harness-session-search-redact-test--log-text))))))

;;;; Reading the logs again

(ert-deftest harness-session-search-redact-reads-the-redacted-logs-again ()
  "Once the logs are redacted, the sessions are read from their start: no
row holds a secret, the full-text index finds its terms no more, the
placeholder is searchable, and the session goes on being indexed."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b)) (c (plist-get fx :c))
           (secrets (plist-get fx :secrets))
           (fingerprint (plist-get (nth 0 secrets) :fingerprint))
           (rows-of-c (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" c)))
      ;; The terms are found before, in the sessions that hold them.
      (dolist (term (harness-session-search-redact-test--terms))
        (should (harness-session-search-redact-test--matches term)))
      ;; The logs are redacted by hand, a session is open and goes on.
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-session-search-redact-test--redact-log b secrets)
      (let ((r (harness-call 'session/search-redact (list a b) secrets)))
        (should (= 4 (plist-get r :rows)))
        (should (equal (list a b) (plist-get r :reindexed)))
        (should-not (plist-member r :failed))
        (should (harness-session-search-redact-test--clean-p secrets r)))
      ;; No row holds a secret, and every row is there.
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      (should (= 5 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" b)))
      (should (= rows-of-c (harness-session-search-redact-test--count
                            "SELECT count(*) FROM nodes WHERE session = ?" c)))
      ;; The terms are gone from the full-text index, as for any deleted row.
      (dolist (term (harness-session-search-redact-test--terms))
        (should-not (harness-session-search-redact-test--matches term)))
      ;; The background has nothing left to do for them.
      (should-not (gethash a harness-session-search--dirty))
      (should-not (gethash b harness-session-search--dirty))
      (should (= 0 (plist-get (harness-call 'session/search-status) :pending)))
      ;; The placeholder is what a search finds now.
      (let* ((r (harness-test-await (harness-call 'session/search fingerprint) 10))
             (hit (car (plist-get (cl-find a (plist-get r :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal)
                                  :hits))))
        (should (equal "fts" (plist-get r :engine)))
        (should (equal (sort (list a b) #'string<)
                       (sort (mapcar (lambda (s) (plist-get s :id)) (plist-get r :sessions)) #'string<)))
        (should (member (plist-get hit :node)
                        (list (harness-session-search-redact-test--node a 'tool-result)
                              (harness-session-search-redact-test--node a 'assistant)))))
      ;; A node the open session writes next is indexed from where the log ends.
      (harness-call 'session/append a '(:kind assistant :content "A later wombat reply"))
      (should (equal (list a) (mapcar (lambda (s) (plist-get s :id))
                                      (plist-get (harness-test-await (harness-call 'session/search "wombat") 10)
                                                 :sessions))))
      (should (= 6 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a))))))

(ert-deftest harness-session-search-redact-with-t-reads-again-the-sessions-the-scan-found ()
  "For all sessions, only those the scan finds a secret in are read again:
the rows of the others stay as they are.  A false from JSON is no dry run."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b)) (c (plist-get fx :c))
           (secrets (plist-get fx :secrets))
           (rowids (lambda (sid) (sqlite-select (harness-session-search--db)
                                                "SELECT id FROM nodes WHERE session = ? ORDER BY id" (list sid))))
           (before (funcall rowids c)))
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-session-search-redact-test--redact-log b secrets)
      (let ((r (harness-call 'session/search-redact t secrets :false)))
        (should (equal (sort (list a b) #'string<) (plist-get r :reindexed)))
        (should (= 4 (plist-get r :rows))))
      (should (equal before (funcall rowids c)))
      (should (= 5 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      ;; Nothing is left to find, so nothing is read again.
      (should-not (plist-get (harness-call 'session/search-redact t secrets) :reindexed)))))

(ert-deftest harness-session-search-redact-reads-a-log-the-index-had-not-read ()
  "A log the index had read in part is read whole: the offset it recorded
is no use once the log was rewritten, and the part it had not read may
hold the secret, which no scan of the index could have found."
  (harness-session-search-redact-test-with
    (let* ((secrets (harness-session-search-redact-test--secrets))
           (key (plist-get (nth 1 secrets) :value))
           (a (harness-session-search-redact-test-session "Half read" "first message"))
           (db (harness-session-search--db)))
      ;; The index read the first node; the log gets two more, which it has not read.
      (harness-session-search--sync db a)
      (harness-call 'session/append a (list :kind 'user :content (format "the key is %s" key)))
      (harness-call 'session/append a '(:kind user :content "third message"))
      (harness-session-search-redact-test--quiet)
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-redact (list a) secrets t) :rows)))
      (harness-session-search-redact-test--redact-log a secrets)
      (let ((r (harness-call 'session/search-redact (list a) secrets)))
        (should (equal (list a) (plist-get r :reindexed))))
      (should (= 3 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      (should (= (file-attribute-size (file-attributes (harness-session-search-redact-test--log a)))
                 (harness-session-search-redact-test--count "SELECT offset FROM logs WHERE session = ?" a)))
      (should (string-search "[redacted: "
                             (harness-session-search-redact-test--count
                              "SELECT text FROM nodes WHERE session = ? AND text LIKE '%redacted%'" a))))))

(ert-deftest harness-session-search-redact-leaves-a-session-it-cannot-read-to-the-background ()
  "A session whose log cannot be read loses its rows anyway, is reported,
and is left to the background."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b))
           (secrets (plist-get fx :secrets))
           (real (symbol-function 'harness-session-search--sync)))
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-session-search-redact-test--redact-log b secrets)
      (cl-letf (((symbol-function 'harness-session-search--sync)
                 (lambda (db sid &rest args)
                   (if (equal sid a) (error "Cannot read the log of %s" sid) (apply real db sid args)))))
        (let ((r (harness-call 'session/search-redact (list a b) secrets)))
          (should (equal (list b) (plist-get r :reindexed)))
          (should (equal (list (cons a (format "Cannot read the log of %s" a))) (plist-get r :failed)))))
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (gethash a harness-session-search--dirty))
      ;; The background reads it later, and finds the redacted text.
      (harness-test-wait (lambda () (not (harness-session-search--step (harness-session-search--db)
                                                                      (+ (float-time) 1))))
                         10 "the background to index the session")
      (should (= 5 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows))))))

;;;; Purging the files

(ert-deftest harness-session-search-purge-leaves-no-copy-in-the-files ()
  "Reading the logs again leaves the old text in the files; a purge takes
it out of search.db, its write-ahead log and its shared memory, drops the
vector made from it and keeps the vectors that are still in use."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b)) (c (plist-get fx :c))
           (secrets (plist-get fx :secrets))
           (fingerprint (plist-get (nth 0 secrets) :fingerprint))
           (reply (harness-session-search-redact-test--node a 'assistant)))
      ;; A vector for the chunk of the reply that holds the secrets, and one for an unrelated node.
      (harness-session-search-redact-test--add-vector a reply "h-secret")
      (harness-session-search-redact-test--add-vector c (harness-session-search-redact-test--node c 'user) "h-keep")
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (should (> (harness-session-search-redact-test--words secrets) 0))
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-session-search-redact-test--redact-log b secrets)
      (harness-call 'session/search-redact (list a b) secrets)
      ;; Not purged: the index no longer holds the text, the files still do, and so does the vector.
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (should (> (harness-session-search-redact-test--words secrets) 0))
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors WHERE hash = ?" "h-secret")))
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM chunks WHERE hash = ?" "h-secret")))
      ;; Purged.
      (let ((r (harness-call 'session/search-purge secrets)))
        (should (eq t (plist-get r :available)))
        (should (numberp (plist-get r :seconds)))
        (should (> (plist-get r :bytes-before) 0))
        (should (> (plist-get r :bytes-after) 0))
        (should (plist-get r :wal-truncated))
        (should (equal (harness-session-search--files) (mapcar #'car (plist-get r :file-counts))))
        (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :file-counts)))
        (should (equal (harness-session-search--files) (mapcar #'car (plist-get r :term-counts))))
        (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :term-counts)))
        (should (harness-session-search-redact-test--clean-p secrets r)))
      (should (= 0 (harness-session-search-redact-test--raw secrets)))
      (should (= 0 (harness-session-search-redact-test--words secrets)))
      (should (= 0 (file-attribute-size (file-attributes (cadr (harness-session-search--files))))))
      ;; The vector made from the old text is gone, the unrelated one stays, and so do the rows.
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors WHERE hash = ?" "h-secret")))
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors WHERE hash = ?" "h-keep")))
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM chunks WHERE hash = ?" "h-keep")))
      (should (= 5 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (dolist (term (harness-session-search-redact-test--terms))
        (should-not (harness-session-search-redact-test--matches term)))
      ;; The index still searches, by the placeholder, and finds the nodes it stands in.
      (let* ((r (harness-test-await (harness-call 'session/search fingerprint) 10))
             (hits (plist-get (cl-find a (plist-get r :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal)
                              :hits)))
        (should (equal "fts" (plist-get r :engine)))
        (should (equal (sort (list a b) #'string<)
                       (sort (mapcar (lambda (s) (plist-get s :id)) (plist-get r :sessions)) #'string<)))
        (should (equal (sort (list reply (harness-session-search-redact-test--node a 'tool-result)) #'string<)
                       (sort (mapcar (lambda (hit) (plist-get hit :node)) hits) #'string<)))
        (should (cl-every (lambda (hit) (string-search "[redacted: fake key id" (plist-get hit :snippet))) hits)))
      (should (harness-session-search-redact-test--clean-p secrets (harness-session-search-redact-test--log-text))))))

(ert-deftest harness-session-search-purge-counts-nothing-without-secrets ()
  "Without secrets a purge only reports its times and sizes."
  (harness-session-search-redact-test-with
    (harness-session-search-redact-test--fixture)
    (let ((r (harness-call 'session/search-purge)))
      (should (eq t (plist-get r :available)))
      (should-not (plist-get r :file-counts))
      (should (plist-member r :file-counts))
      (should (> (plist-get r :bytes-after) 0)))))

(ert-deftest harness-session-search-purge-drops-the-rows-of-deleted-sessions ()
  "The rows of a session that is gone are dropped by the purge, not left
to the background: deleted through the module, or unknown to it."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b)) (c (plist-get fx :c))
           (secrets (plist-get fx :secrets)))
      ;; B is deleted, as the session module does; A vanishes without a word.
      (harness-call 'session/delete b)
      (harness-session-search-redact-test--quiet)
      (remhash a harness-sessions)
      (delete-file (harness-session-search-redact-test--log a))
      (should (> (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a) 0))
      (should (> (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" b) 0))
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (let ((r (harness-call 'session/search-purge secrets)))
        (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :file-counts))))
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" b)))
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM logs WHERE session IN (?, ?)" a b)))
      (should (> (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" c) 0))
      (should-not harness-session-search--doomed)
      (should (= 0 (harness-session-search-redact-test--raw secrets))))))

;;;; Rebuilding

(ert-deftest harness-session-search-rebuild-leaves-no-copy-in-the-files ()
  "Dropping the tables frees their pages without erasing them: a rebuild
vacuums, and empties the write-ahead log, so the old text is gone before
the index is built again."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a)) (b (plist-get fx :b))
           (secrets (plist-get fx :secrets)))
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-session-search-redact-test--redact-log b secrets)
      (let ((status (harness-call 'session/search-rebuild)))
        (should (plist-get status :vacuumed))
        (should (= 0 (plist-get status :nodes)))
        (should (= 3 (plist-get status :pending))))
      (should (= 0 (harness-session-search-redact-test--raw secrets)))
      ;; The background builds it again, from the redacted logs.
      (harness-test-wait (lambda () (not (harness-session-search--step (harness-session-search--db)
                                                                      (+ (float-time) 1))))
                         10 "the index to be built again")
      (should (= 5 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      (should (= 0 (harness-session-search-redact-test--raw secrets))))))

;;;; Pages the rows freed

;; A few rows are rewritten into the pages they freed, which hides what a
;; VACUUM is for.  A long secret, as a private key is, in many nodes, and
;; replaced by a placeholder a tenth as long, leaves pages with the old
;; text that nothing reuses.

(defun harness-session-search-redact-test--long-secret ()
  "Return a fake secret of 512 characters of base64, as a private key is."
  (harness-redaction-secret
   (base64-encode-string (mapconcat (lambda (i) (md5 (format "harness-fake-key-%d" i)))
                                    (number-sequence 1 12) "")
                         t)
   "fake private key"))

(defun harness-session-search-redact-test--bulk ()
  "Make a session of 40 tool results that hold a long secret, and index it.
The old text is moved into the database file, out of the write-ahead log.
Return (:a A :secrets SECRETS).  SQLite may be built to overwrite what it
deletes (SQLITE_SECURE_DELETE, as many distributions do), which would
hide what these tests are about: this connection does not."
  (let* ((secret (harness-session-search-redact-test--long-secret))
         (a (apply #'harness-session-search-redact-test-session
                   "A big dump"
                   (cl-loop for i below 40
                            collect (list :kind 'tool-result :call-id (format "c%d" i)
                                          :output (format "dump %d: %s" i (plist-get secret :value))))))
         (db (harness-session-search--db)))
    (sqlite-pragma db "secure_delete=OFF")
    (harness-session-search--sync db a)
    (harness-session-search-redact-test--quiet)
    (sqlite-select db "PRAGMA wal_checkpoint(TRUNCATE)")
    (list :a a :secrets (list secret))))

(ert-deftest harness-session-search-purge-takes-the-freed-pages-out-of-the-file ()
  "Reading the logs again leaves pages that nothing reuses, with the old
text in them, in the database file; the merge of the full-text index
takes its dead words out of its live pages, and the VACUUM that follows
frees the file of both."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--bulk))
           (a (plist-get fx :a))
           (secrets (plist-get fx :secrets)))
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (should (> (harness-session-search-redact-test--words secrets) 0))
      (harness-session-search-redact-test--redact-log a secrets)
      (should (equal (list a) (plist-get (harness-call 'session/search-redact (list a) secrets) :reindexed)))
      (should (= 0 (plist-get (harness-call 'session/search-redact t secrets t) :rows)))
      ;; Even with the log moved into the file, the old text is in it.
      (sqlite-select (harness-session-search--db) "PRAGMA wal_checkpoint(TRUNCATE)")
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (should (> (harness-session-search-redact-test--words secrets) 0))
      (let ((r (harness-call 'session/search-purge secrets)))
        (should (< (plist-get r :bytes-after) (plist-get r :bytes-before)))
        (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :file-counts)))
        (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :term-counts))))
      (should (= 0 (harness-session-search-redact-test--raw secrets)))
      (should (= 0 (harness-session-search-redact-test--words secrets)))
      (should (= 40 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE session = ?" a))))))

(ert-deftest harness-session-search-rebuild-takes-the-freed-pages-out-of-the-file ()
  "A rebuild frees every page of the index, which the VACUUM then gives back."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--bulk))
           (a (plist-get fx :a))
           (secrets (plist-get fx :secrets)))
      (should (> (harness-session-search-redact-test--raw secrets) 0))
      (should (> (harness-session-search-redact-test--words secrets) 0))
      (harness-session-search-redact-test--redact-log a secrets)
      (should (plist-get (harness-call 'session/search-rebuild) :vacuumed))
      (should (= 0 (harness-session-search-redact-test--raw secrets)))
      (should (= 0 (harness-session-search-redact-test--words secrets))))))

;;;; The words of a secret

(ert-deftest harness-session-search-redact-knows-the-words-the-index-keeps ()
  "The terms of a secret are what FTS5 makes of its value: lowercased,
split where punctuation is, those of eight characters or more.  The
tokenizer is the one of the index's table."
  (harness-session-search-redact-test-with
    (let ((secrets (list (harness-redaction-secret "AbCdEf12345678/GhIjKlMnOp+QrStUvWx==" "mixed")
                         (harness-redaction-secret "short_ab-Cdefghij1" "other"))))
      (should (equal '("abcdef12345678" "cdefghij1" "ghijklmnop" "qrstuvwx")
                     (sort (harness-session-search--secret-terms secrets) #'string<)))
      (should-not (harness-session-search--secret-terms nil)))
    (should (cl-some (lambda (sql) (string-search harness-session-search--tokenizer sql))
                     harness-session-search--schema))))

;;;; Embeddings

(defun harness-session-search-redact-test--settle ()
  "Run the background of the index until it has nothing left to do."
  (let ((db (harness-session-search--db)))
    (harness-test-wait
     (lambda ()
       (and (not (harness-session-search--step db (+ (float-time) 1)))
            (not harness-session-search--embedding)
            (or harness-session-search--embed-failure
                (zerop (harness-session-search-redact-test--count
                        "SELECT count(*) FROM nodes WHERE embedded IS NULL")))))
     10 "the search index to settle")))

(ert-deftest harness-session-search-redact-embeds-only-what-changed ()
  "The vector of text that held a secret is dropped and made again from the
redacted text; the vectors of text that did not change are kept and not
made again; and no text sent to the model after the redaction holds a secret."
  (harness-session-search-redact-test-with
    (let* ((harness-session-search-embedding-model "demo:embed")
           (secrets (harness-session-search-redact-test--secrets))
           (key (plist-get (nth 1 secrets) :value))
           (a (harness-session-search-redact-test-session
               "Embedded" "The app crashes when I open a file"
               (list :kind 'assistant :content (format "I will use the key %s for that." key))))
           (sent nil)
           (embed (symbol-function 'harness-session-search--embed)))
      (cl-letf (((symbol-function 'harness-session-search--embed)
                 (lambda (texts) (setq sent (append sent texts)) (funcall embed texts))))
        (harness-session-search-redact-test--settle)
        (should (= 2 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors")))
        (should (cl-some (lambda (text) (string-search key text)) sent))
        (setq sent nil)
        (harness-session-search-redact-test--redact-log a secrets)
        (harness-call 'session/search-redact (list a) secrets)
        ;; The reply waits for a vector of its new text; the other node kept its own.
        (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM nodes WHERE embedded IS NULL")))
        (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM chunks")))
        (should (= 2 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors")))
        (let ((r (harness-call 'session/search-purge secrets)))
          (should (cl-every (lambda (pair) (eql 0 (cdr pair))) (plist-get r :file-counts))))
        (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors")))
        (harness-session-search-redact-test--settle)
        (should (= 2 (harness-session-search-redact-test--count "SELECT count(*) FROM chunks")))
        (should (= 2 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors")))
        ;; Only the reply was embedded again, and not with the key.
        (should (= 1 (length sent)))
        (should (string-search "[redacted: " (car sent)))
        (should (harness-session-search-redact-test--clean-p secrets sent))
        (should (= 0 (harness-session-search-redact-test--raw secrets)))))))

(ert-deftest harness-session-search-redact-drops-embeddings-in-flight ()
  "A request for vectors that went out before a redaction does not put
them into the index when it returns: they are of text it no longer holds."
  (harness-session-search-redact-test-with
    (let* ((fx (harness-session-search-redact-test--fixture))
           (a (plist-get fx :a))
           (secrets (plist-get fx :secrets))
           (late (harness-make-promise))
           (fresh (harness-make-promise))
           (vector '((0.5 -0.25 0.125))))
      (cl-letf (((symbol-function 'harness-session-search--embed) (lambda (_texts) late)))
        (harness-session-search--embed-request (list (cons "h-late" "text that held a secret")) nil))
      (should harness-session-search--embedding)
      (harness-session-search-redact-test--redact-log a secrets)
      (harness-call 'session/search-redact (list a) secrets)
      (harness-resolve late vector)
      (harness-test-wait (lambda () (not harness-session-search--embedding)) 10 "the request to return")
      (should (= 0 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors WHERE hash = ?" "h-late")))
      ;; A request made afterwards is kept, as ever.
      (cl-letf (((symbol-function 'harness-session-search--embed) (lambda (_texts) fresh)))
        (harness-session-search--embed-request (list (cons "h-fresh" "redacted text")) nil))
      (harness-resolve fresh vector)
      (harness-test-wait (lambda () (not harness-session-search--embedding)) 10 "the request to return")
      (should (= 1 (harness-session-search-redact-test--count "SELECT count(*) FROM vectors WHERE hash = ?" "h-fresh"))))))

;;;; Without an index, and with bad input

(ert-deftest harness-session-search-redact-says-so-without-an-index ()
  "With no index there is nothing to scan or purge, and the answer says why."
  (harness-session-search-redact-test-with
    (let ((secrets (harness-session-search-redact-test--secrets))
          (harness-session-search-index nil))
      (dolist (r (list (harness-call 'session/search-redact t secrets t)
                       (harness-call 'session/search-redact (list "s-1") secrets)
                       (harness-call 'session/search-purge secrets)))
        (should (equal '(:available nil :reason "harness-session-search-index is off") r))))))

(ert-deftest harness-session-search-redact-refuses-what-is-not-a-secret ()
  "Anything but a list of secrets, and ids but a list of ids or t, is an
error that quotes nothing it was given."
  (harness-session-search-redact-test-with
    (harness-session-search-redact-test--fixture)
    (let ((bad "not-a-secret-but-a-string"))
      (dolist (args (list (list t bad t) (list t (list bad) t) (list t (list (list :value 5)) t)
                          (list bad nil t) (list (list 5) nil t) (list '(:a) '(:value "x" ) t)))
        (let ((err (should-error (apply #'harness-call 'session/search-redact args))))
          (should-not (string-search bad (format "%S" err)))))
      (should-error (harness-call 'session/search-purge bad))
      (should-error (harness-call 'session/search-purge (list (list :value 5)))))))

(provide 'harness-session-search-redact-test)
;;; harness-session-search-redact-test.el ends here
