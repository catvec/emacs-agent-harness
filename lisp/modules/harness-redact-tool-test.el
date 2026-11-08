;;; harness-redact-tool-test.el --- Tests for the redact_secret tool and how it reaches ACP  -*- lexical-binding: t; -*-

;;; Commentary:

;; `redact_secret' is how an agent takes a secret out of the harness's
;; stores.  Its call and its result are kept in the transcript of the
;; session that made them, so the tool must never need the secret in
;; either: it names the secret by where it is read, and what it answers
;; is made of labels, fingerprints, ids and counts.  These tests run it
;; through `tools/execute' and through real turns of the agent with the
;; demo provider, then count the fake secrets in what was stored.  They
;; also check how the permission chain weighs a call (a scan and a shape
;; are reads, a redaction is not), and what ACP does with the methods
;; and events of the redaction: it calls them, forwards them, refuses a
;; secret's text from a client on another device, and logs nothing a
;; request was given.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  A test that fails shows values it
;; compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)
(require 'harness-acp)

(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-redact--pending)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-authorize-functions)
(defvar harness-acp-token)
(defvar harness-perms--allowed-dirs)
(defvar harness-perms--turn-dirs)
(defvar harness-perms--session-rules)
(defvar harness-perms--waiting)
(defvar harness-perms--judging)
(defvar harness-perms--steered)
(defvar harness-perms-rules)
(declare-function harness-session-flush "harness-session")
(declare-function harness-perms--call-kind "harness-perms")
(declare-function harness-perms--redact-read-p "harness-perms")
(declare-function harness-acp--extension-allowed-p "harness-acp")
(declare-function harness-acp--secret-method-p "harness-acp")
(declare-function harness-tool-get "harness-tools")
(declare-function harness-tools--paths "harness-tools")

;;;; The fake secrets, the files that hold them, and sessions

(defconst harness-redact-tool-test--key (concat "FAKE/tool+" (make-string 24 ?t) "\"q")
  "A fake secret key, with a slash and a quote for JSON to escape.")

(defconst harness-redact-tool-test--id (concat "FAKETOOLID" (make-string 10 ?y))
  "A fake access key id, made of letters only so that a regexp can hold it.")

(defun harness-redact-tool-test--secrets ()
  "Return the fake key and id as secrets."
  (list (harness-redaction-secret harness-redact-tool-test--key "tool.secret_key")
        (harness-redaction-secret harness-redact-tool-test--id "tool.access_key")))

(defun harness-redact-tool-test--fp (index)
  "Return the fingerprint of the fake secret number INDEX, 0 the key and 1 the id."
  (plist-get (nth index (harness-redact-tool-test--secrets)) :fingerprint))

(defun harness-redact-tool-test--write (dir name text)
  "Write TEXT to the file NAME in DIR; return its name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert text))
    file))

(defun harness-redact-tool-test--state-file (dir)
  "Write a fake state file in DIR, holding the fake id and key; return its name.
They are under outputs.keys.value, beside a value that is no secret and one that
is too short to be one."
  (harness-redact-tool-test--write
   dir "state.json"
   (harness-json-encode-text
    (list :outputs (list :keys (list :value (list :access_key harness-redact-tool-test--id
                                                  :secret_key harness-redact-tool-test--key)))
          :other "unrelated"
          :pin "1234"))))

(defun harness-redact-tool-test--session (dir name &rest nodes)
  "Create a session called NAME working in DIR, with NODES appended; return its id."
  (let ((id (plist-get (harness-call 'session/create :cwd dir :name name :model "demo:scripted") :id)))
    (dolist (n nodes) (harness-call 'session/append id n))
    id))

(defun harness-redact-tool-test--dirty (dir name)
  "Create a session called NAME in DIR whose transcript holds the fake secrets.
The key is in a message, in the input of a call and in its result, the id
in the result: four occurrences."
  (harness-redact-tool-test--session
   dir name
   (list :kind 'user :content (format "use the key %s please" harness-redact-tool-test--key))
   (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run: echo"
         :input (list :command (format "echo %s" harness-redact-tool-test--key)))
   (list :kind 'tool-result :call-id "c1"
         :output (format "AccessKeyId: %s\nvalue: %s\n" harness-redact-tool-test--id harness-redact-tool-test--key))
   '(:kind assistant :content "Understood, nothing secret here.")))

(defun harness-redact-tool-test--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))

(defun harness-redact-tool-test--record-file (sid)
  "Return the file name of the record of session SID."
  (expand-file-name (format "sessions/%s.json" sid) harness-state-directory))

(defun harness-redact-tool-test--key-secret ()
  "Return the fake key as a secret, on its own."
  (list (car (harness-redact-tool-test--secrets))))

(defun harness-redact-tool-test--id-secret ()
  "Return the fake access key id as a secret, on its own."
  (last (harness-redact-tool-test--secrets)))

(defun harness-redact-tool-test--raw (file &optional secrets)
  "Return how many times SECRETS occur in the bytes of FILE.
SECRETS are both fake secrets unless given: a request that redacts one of
them leaves the other where it was."
  (harness-redaction-file-count file (or secrets (harness-redact-tool-test--secrets))))

(defun harness-redact-tool-test--stored-count (&optional secrets)
  "Return how many times SECRETS occur in the bytes of the state directory.
SECRETS are both fake secrets unless given."
  (cl-loop for file in (directory-files-recursively harness-state-directory "")
           sum (harness-redact-tool-test--raw file secrets)))

(defun harness-redact-tool-test--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redact-tool-test--holds-p (&rest objects)
  "Non-nil when any of OBJECTS, printed, holds a fake secret.
It is looked for as it is and as JSON writes it."
  (cl-some (lambda (object)
             (> (harness-redaction-count (prin1-to-string object t) (harness-redact-tool-test--secrets)) 0))
           objects))

(defun harness-redact-tool-test--node (sid kind)
  "Return the first node of KIND in the transcript of session SID."
  (cl-find kind (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))

(defun harness-redact-tool-test--last-node (sid kind)
  "Return the last node of KIND in the transcript of session SID."
  (cl-find kind (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)) :from-end t))

(defun harness-redact-tool-test--hints (sid)
  "Return the text of the hints in the transcript of session SID, oldest first."
  (cl-loop for n in (harness-call 'session/nodes sid)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(defun harness-redact-tool-test--redactions (sid)
  "Return the redaction records in the `ext' of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :redactions))

(defun harness-redact-tool-test--summary (result)
  "Return what the tool RESULT keeps of the report: its `:redaction' meta."
  (plist-get (plist-get result :meta) :redaction))

;;;; Running the tool

(defmacro harness-redact-tool-test-with (&rest body)
  "Load the modules the tool needs, with everything allowed; run BODY.
They are the session, agent, tools, secrets and redaction modules."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (default-directory dir))
       ,@body)))

(defmacro harness-redact-tool-test-with-perms (&rest body)
  "Run BODY with the permission chain deciding.
The rest is as in `harness-redact-tool-test-with'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent secrets redact perms))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-perms--turn-dirs)
     (clrhash harness-perms--session-rules)
     (clrhash harness-perms--waiting)
     (clrhash harness-perms--judging)
     (setq harness-perms--steered nil
           harness-perms-rules nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (default-directory dir))
       ,@body)))

(defun harness-redact-tool-test--run (sid input)
  "Run redact_secret with INPUT as session SID; return the result of the call.
It goes through `tools/execute', as a turn's call does."
  (harness-test-await
   (harness-call 'tools/execute sid (list :id (harness-short-id) :name "redact_secret" :input input))
   30))

(defun harness-redact-tool-test--turn (sid input)
  "Run a turn of session SID in which the model calls redact_secret with INPUT."
  (let ((harness-provider-demo-script-override
         `((:type tool-call :id "rs1" :name "redact_secret" :input ,input)
           (:type text :delta "Done.")
           (:type done :stop-reason end-turn))))
    (harness-test-await (harness-call 'agent/prompt sid "please redact") 30)))

(defun harness-redact-tool-test--ref (&optional json-path)
  "Return the source of the fake state file, relative to the session's directory."
  (list :file "state.json" :json_path (or json-path "outputs.keys.value")))

;;;; The tool is there

(ert-deftest harness-redact-tool-is-offered-with-its-schema ()
  "The tool is registered, takes a reference and no value, and says what it does not do."
  (harness-redact-tool-test-with
    (let* ((spec (harness-call 'tools/get "redact_secret"))
           (schema (plist-get spec :schema))
           (properties (plist-get schema :properties)))
      (should (equal "Redact secret" (plist-get spec :label)))
      (should (eq 'meta (plist-get spec :kind)))
      (should (equal '("source") (plist-get schema :required)))
      (dolist (key '(:mode :source :label :scope :sessions :project :include_forks :reason))
        (should (plist-member properties key)))
      (should (equal '("scan" "redact" "shape") (plist-get (plist-get properties :mode) :enum)))
      (should (equal '("self" "sessions" "project" "all") (plist-get (plist-get properties :scope) :enum)))
      (let ((source (plist-get (plist-get properties :source) :properties)))
        (dolist (key '(:file :json_path :regexp :env))
          (should (plist-member source key)))
        ;; No way to give the secret itself, or to run something.
        (should-not (plist-member source :literal))
        (should-not (plist-member source :command)))
      (should (string-search "never by its value" (plist-get spec :description)))
      (should (string-search "cannot recall what the model provider already received"
                             (plist-get spec :description)))
      (should (member "redact_secret" (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list)))))))

(ert-deftest harness-redact-tool-title-names-the-mode-and-what-it-is-about ()
  "A call is titled by its mode, then by its label, else its file's name, else its variable.
The title is what the permission prompt and the chat show; it never
signals, whatever the input is, and holds nothing of a regexp."
  (harness-redact-tool-test-with
    (cl-flet ((title (input) (harness-tool-title "redact_secret" input)))
      (should (equal "Redact secret: scan state.json"
                     (title (list :source (list :file "some/dir/state.json" :json_path "a")))))
      (should (equal "Redact secret: shape state.json"
                     (title (list :mode "shape" :source (list :file "state.json")))))
      (should (equal "Redact secret: redact spaces-key"
                     (title (list :mode "redact" :label "spaces-key" :source (list :file "state.json" :json_path "a")))))
      (should (equal "Redact secret: scan DO_TOKEN" (title (list :source (list :env "DO_TOKEN")))))
      ;; The regexp, which is where a careless call would put the value, is not in it.
      (should (equal "Redact secret: redact creds.txt"
                     (title (list :mode "redact"
                                  :source (list :file "creds.txt"
                                                :regexp (format "token=\\(%s\\)" harness-redact-tool-test--id))))))
      ;; Input the tool would refuse still gets a title.
      (dolist (input (list nil "scan" 'scan (list :mode 1) (list :mode "frob" :source "x")
                           (list :source (list :file nil)) (list :Mode "redact") (list :source (list :file ""))))
        (should (stringp (title input)))
        (should (string-prefix-p "Redact secret" (title input)))))))

;;;; Redacting through a turn of the agent

(ert-deftest harness-redact-tool-redacts-another-session-and-its-own-nodes-hold-nothing ()
  "A turn that calls the tool leaves no copy in any store, its own call and result included.
The caller's stored call and result, and its raw node log, hold no
value; the session redacted has its secret replaced and a record of it."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (file (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (c (harness-redact-tool-test--session cwd "clean" '(:kind user :content "nothing here"))))
      (harness-session-flush)
      (should (> (harness-redact-tool-test--raw (harness-redact-tool-test--log b)) 0))
      (harness-redact-tool-test--turn
       a (list :mode "redact" :source (harness-redact-tool-test--ref) :label "tool"
               :scope "sessions" :sessions (list b) :reason "leaked in a diff"))
      (harness-session-flush)
      (let* ((call (harness-redact-tool-test--node a 'tool-call))
             (result (harness-redact-tool-test--node a 'tool-result))
             (summary (harness-redact-tool-test--summary result)))
        ;; The call names where the secret is; the result says what was done.
        (should (equal "redact_secret" (plist-get call :tool)))
        (should (equal "state.json" (plist-get (plist-get (plist-get call :input) :source) :file)))
        (should (string-search "Redact secret" (plist-get call :title)))
        (should-not (plist-get result :is-error))
        (should (string-search "Redaction of" (plist-get result :output)))
        (should (string-search "cannot recall what the model provider already received"
                               (plist-get result :output)))
        (should (string-search (format "sha256:%s" (harness-redact-tool-test--fp 0)) (plist-get result :output)))
        (should (equal (list b) (plist-get summary :sessions)))
        (should (eq t (plist-get summary :complete)))
        (should (equal '("tool.access_key" "tool.secret_key")
                       (sort (mapcar (lambda (s) (plist-get s :label)) (plist-get summary :secrets)) #'string<)))
        ;; Not a value anywhere in what the caller stored, in memory or on disk.
        (should-not (harness-redact-tool-test--holds-p call result summary (harness-call 'session/get a)
                                                       (harness-call 'session/nodes a)))
        (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log a))))
        (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--record-file a))))
        (should-not (harness-redact-tool-test--redactions a)))
      ;; The session redacted: the placeholder stands where the secret was.
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log b))))
      (should-not (harness-redact-tool-test--holds-p (harness-call 'session/nodes b)))
      (should (string-search (format "[redacted: tool.secret_key sha256:%s]" (harness-redact-tool-test--fp 0))
                             (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (let ((record (car (harness-redact-tool-test--redactions b))))
        (should (equal (format "session %s" (substring a 0 8)) (plist-get record :by)))
        (should (equal "leaked in a diff" (plist-get record :reason))))
      (should (string-prefix-p "Redacted 2 secrets" (car (last (harness-redact-tool-test--hints b)))))
      ;; The session out of scope was left alone, and so was the source.
      (should-not (harness-redact-tool-test--redactions c))
      (should-not (harness-redact-tool-test--hints c))
      (should (> (harness-redact-tool-test--raw file) 0))
      (should (= 0 (harness-redact-tool-test--stored-count))))))

(ert-deftest harness-redact-tool-scope-all-redacts-every-session-and-the-caller-stays-clean ()
  "The scope all redacts every session that holds the secret; the caller's call and result hold none."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty one"))
           (d (harness-redact-tool-test--dirty cwd "dirty two"))
           (c (harness-redact-tool-test--session cwd "clean" '(:kind user :content "nothing here"))))
      (harness-session-flush)
      (harness-redact-tool-test--turn
       a (list :mode "redact" :source (harness-redact-tool-test--ref) :label "tool" :scope "all"
               :reason "leaked in a diff"))
      (let ((result (harness-redact-tool-test--node a 'tool-result)))
        (should-not (plist-get result :is-error))
        (should (equal (sort (list b d) #'string<)
                       (sort (copy-sequence (plist-get (harness-redact-tool-test--summary result) :sessions))
                             #'string<)))
        (should-not (harness-redact-tool-test--holds-p result (harness-call 'session/nodes a))))
      (dolist (sid (list a b d))
        (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log sid)))))
      (should (= 0 (harness-redact-tool-test--stored-count)))
      (dolist (sid (list b d))
        (should (= 1 (length (harness-redact-tool-test--redactions sid)))))
      (should-not (harness-redact-tool-test--redactions c))
      (should-not (harness-redact-tool-test--redactions a)))))

(ert-deftest harness-redact-tool-a-copy-left-behind-is-an-error-to-the-model ()
  "A redaction that could not clean a file says so as an error, and never calls itself done.
A binary file in the state directory is counted and left alone; the
sessions are cleaned all the same, and the result names the file."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (db (expand-file-name "usage.db" harness-state-directory))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty")))
      (let ((coding-system-for-write 'binary))
        (write-region (encode-coding-string (concat "SQLite format 3\0" harness-redact-tool-test--key) 'utf-8)
                      nil db nil 'silent))
      (harness-session-flush)
      (let* ((result (harness-redact-tool-test--run
                      a (list :mode "redact" :source (harness-redact-tool-test--ref "outputs.keys.value.secret_key")
                              :scope "all" :reason "leaked in a diff")))
             (summary (harness-redact-tool-test--summary result)))
        (should (plist-get result :is-error))
        (should (string-search "NOT everything is clean" (plist-get result :content)))
        (should (string-search "usage.db" (plist-get result :content)))
        (should (eq :false (plist-get summary :complete)))
        (should (>= (plist-get summary :remaining) 1))
        (should-not (harness-redact-tool-test--holds-p result)))
      ;; What could be cleaned was; the file was counted and left.
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log b)
                                                  (harness-redact-tool-test--key-secret))))
      (should (= 1 (harness-redact-tool-test--raw db (harness-redact-tool-test--key-secret)))))))

(ert-deftest harness-redact-tool-a-session-redacts-itself-while-its-turn-runs ()
  "The default scope is the caller: a session that holds a secret takes it out of itself.
The turn that calls the tool is running, so its log and nodes are
cleaned at once and the rest waits for the turn to end; the call and the
result it stores hold no value, the placeholder stands where the secret
was, and the record says what was done and when it finished."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--dirty cwd "dirty caller")))
      (harness-session-flush)
      (should (= 4 (harness-redact-tool-test--raw (harness-redact-tool-test--log a))))
      (harness-redact-tool-test--turn
       a (list :mode "redact" :source (harness-redact-tool-test--ref) :label "tool"
               :reason "leaked in a diff"))
      ;; The turn is over; whatever waited for it has gone on.
      (harness-test-wait (lambda () (zerop (hash-table-count harness-redact--pending))) 10 "the redaction to go on")
      (harness-session-flush)
      (let* ((call (harness-redact-tool-test--last-node a 'tool-call))
             (result (harness-redact-tool-test--last-node a 'tool-result))
             (summary (harness-redact-tool-test--summary result)))
        (should (equal "redact_secret" (plist-get call :tool)))
        (should-not (plist-get result :is-error))
        (should (equal (list a) (plist-get summary :sessions)))
        ;; It was running when the tool answered: the rest of the work waited for the turn's end.
        (should (equal (list a) (plist-get summary :deferred)))
        (should (string-search "Waiting for a running turn to end" (plist-get result :output)))
        (should-not (harness-redact-tool-test--holds-p call result summary)))
      ;; Not one copy, in memory or on disk, and the placeholder where the key was.
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log a))))
      (should (= 0 (harness-redact-tool-test--stored-count)))
      (should-not (harness-redact-tool-test--holds-p (harness-call 'session/nodes a) (harness-call 'session/get a)))
      (should (string-search (format "[redacted: tool.secret_key sha256:%s]" (harness-redact-tool-test--fp 0))
                             (plist-get (harness-redact-tool-test--node a 'user) :content)))
      ;; Nothing is left waiting, and the records say it was done twice: during the turn, and after it.
      (should-not (plist-get (plist-get (harness-call 'session/get a) :ext) :redaction-pending))
      (let ((records (harness-redact-tool-test--redactions a)))
        (should (>= (length records) 1))
        (should (equal (format "session %s" (substring a 0 8)) (plist-get (car records) :by)))
        (should-not (harness-redact-tool-test--holds-p records (harness-redact-tool-test--hints a))))
      (should (string-search "after its turn ended" (car (last (harness-redact-tool-test--hints a))))))))

(ert-deftest harness-redact-tool-an-input-that-holds-the-value-adds-the-caller-to-the-scope ()
  "A regexp that spells the value out puts the value in the call; the caller is redacted too.
The scope names another session, but the call that asked held the
secret, so the session that made it is added, and its node log ends with
no occurrence."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--write cwd "creds.txt"
                                               (format "token=%s\nother=1\n" harness-redact-tool-test--id)))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty")))
      (harness-session-flush)
      (harness-redact-tool-test--turn
       a (list :mode "redact"
               :source (list :file "creds.txt" :regexp (format "token=\\(%s\\)" harness-redact-tool-test--id))
               :label "tok" :scope "sessions" :sessions (list b) :reason "spelled out"))
      ;; The turn is over; whatever waited for it has gone on.
      (harness-test-wait (lambda () (zerop (hash-table-count harness-redact--pending))) 10 "the redaction to go on")
      (harness-session-flush)
      (let ((call (harness-redact-tool-test--node a 'tool-call))
            (result (harness-redact-tool-test--node a 'tool-result)))
        (should-not (plist-get result :is-error))
        (should (string-search "which made it, is included" (plist-get result :output)))
        ;; The regexp in the call kept its shape and lost the value.
        (should (string-search "[redacted: tok" (plist-get (plist-get (plist-get call :input) :source) :regexp)))
        (should-not (harness-redact-tool-test--holds-p call result (harness-call 'session/nodes a)
                                                       (harness-call 'session/get a))))
      ;; The caller held neither fake secret in the end; the dirty session lost the id, which
      ;; the regexp names, and still holds the key, which no request named.
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log a))))
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log b)
                                                  (harness-redact-tool-test--id-secret))))
      (should (= 3 (harness-redact-tool-test--raw (harness-redact-tool-test--log b)
                                                  (harness-redact-tool-test--key-secret))))
      (should (= 0 (harness-redact-tool-test--stored-count (harness-redact-tool-test--id-secret))))
      ;; The record in the caller says what was done, without the value.
      (should (>= (length (harness-redact-tool-test--redactions a)) 1))
      (should-not (harness-redact-tool-test--holds-p (harness-redact-tool-test--redactions a)
                                                     (harness-redact-tool-test--hints a))))))

(ert-deftest harness-redact-tool-a-label-that-holds-the-value-is-made-safe ()
  "A label that is the secret itself does not stand in the placeholder, nor stay in the call.
The call held the value, so its session is redacted too; the placeholder
is labelled by the fingerprint instead."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty")))
      (harness-session-flush)
      (harness-redact-tool-test--turn
       a (list :mode "redact" :source (harness-redact-tool-test--ref "outputs.keys.value.secret_key")
               :label harness-redact-tool-test--key :scope "sessions" :sessions (list b)
               :reason (format "the key %s leaked" harness-redact-tool-test--key)))
      (harness-test-wait (lambda () (zerop (hash-table-count harness-redact--pending))) 10 "the redaction to go on")
      (harness-session-flush)
      (let ((call (harness-redact-tool-test--node a 'tool-call))
            (result (harness-redact-tool-test--node a 'tool-result)))
        (should-not (plist-get result :is-error))
        (should (string-search (format "secret-%s" (harness-redact-tool-test--fp 0)) (plist-get result :output)))
        (should-not (harness-redact-tool-test--holds-p call result (harness-call 'session/nodes a)
                                                       (harness-redact-tool-test--redactions a)
                                                       (harness-redact-tool-test--redactions b)
                                                       (harness-redact-tool-test--hints a)
                                                       (harness-redact-tool-test--hints b))))
      ;; The key is gone from every store, the caller's included; the id, which no request
      ;; named, is still where the dirty session had it, once.
      (should (= 0 (harness-redact-tool-test--stored-count (harness-redact-tool-test--key-secret))))
      (should (= 0 (harness-redact-tool-test--raw (harness-redact-tool-test--log a))))
      (should (= 1 (harness-redact-tool-test--raw (harness-redact-tool-test--log b)
                                                  (harness-redact-tool-test--id-secret)))))))

(ert-deftest harness-redact-tool-redacts-a-secret-read-from-an-environment-variable ()
  "A source that names a variable works, and the variable's name is all the call holds."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (process-environment (cons (concat "HARNESS_TEST_REDACT_TOOL=" harness-redact-tool-test--id)
                                      process-environment)))
      (let ((result (harness-redact-tool-test--run
                     a (list :mode "redact" :source (list :env "HARNESS_TEST_REDACT_TOOL") :label "tool-id"
                             :scope "sessions" :sessions (list b) :reason "env"))))
        (should-not (plist-get result :is-error))
        (should (equal (list b) (plist-get (harness-redact-tool-test--summary result) :sessions)))
        (should-not (harness-redact-tool-test--holds-p result)))
      (should (= 0 (harness-redaction-file-count (harness-redact-tool-test--log b)
                                                 (list (car (last (harness-redact-tool-test--secrets)))))))
      ;; The key was not the variable's: it is still there.
      (should (> (harness-redaction-file-count (harness-redact-tool-test--log b)
                                               (list (car (harness-redact-tool-test--secrets))))
                 0)))))

;;;; Scanning and looking at the shape

(ert-deftest harness-redact-tool-scan-changes-nothing ()
  "A scan counts, by session, and changes no store, no record, no transcript."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (_flush (harness-session-flush))
           (log (harness-redact-tool-test--read (harness-redact-tool-test--log b)))
           (record (harness-redact-tool-test--read (harness-redact-tool-test--record-file b)))
           (nodes (harness-call 'session/nodes b))
           (events nil))
      (dolist (event '(session/redacted secrets/redacted))
        (let ((event event)) (harness-on event (lambda (&rest args) (push (cons event args) events)))))
      (dolist (mode '("scan" nil))
        (let ((result (harness-redact-tool-test--run
                       a (append (list :source (harness-redact-tool-test--ref) :scope "all")
                                 (and mode (list :mode mode))))))
          (should-not (plist-get result :is-error))
          (should (string-search "nothing was changed" (plist-get result :content)))
          (should (string-search "Call again with mode redact" (plist-get result :content)))
          (let ((summary (harness-redact-tool-test--summary result)))
            (should (equal "scan" (plist-get summary :mode)))
            (should (equal (list b) (plist-get summary :sessions)))
            (should (> (plist-get summary :total) 0)))
          (should-not (harness-redact-tool-test--holds-p result))))
      (should (equal log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (harness-session-flush)
      (should (equal record (harness-redact-tool-test--read (harness-redact-tool-test--record-file b))))
      (should (equal nodes (harness-call 'session/nodes b)))
      (should-not (harness-redact-tool-test--redactions b))
      (should-not events)
      (should (= 0 (hash-table-count harness-redact--pending))))))

(ert-deftest harness-redact-tool-shape-gives-keys-and-types-only ()
  "A shape lists the paths and the types of a JSON file, and never a value or a length."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller")))
      (let* ((result (harness-redact-tool-test--run a (list :mode "shape" :source (list :file "state.json"))))
             (text (plist-get result :content)))
        (should-not (plist-get result :is-error))
        (should (string-search "outputs.keys.value.secret_key  string" text))
        (should (string-search "outputs.keys.value.access_key  string" text))
        (should (string-search "outputs.keys  object" text))
        (should (string-search "other  string" text))
        (should (string-search "pin  string" text))
        ;; Neither a secret nor the value that is no secret nor the short one.
        (should-not (harness-redact-tool-test--holds-p result))
        (should-not (string-search "unrelated" text))
        (should-not (string-search "1234" text))
        ;; Below the heading, every line is a path and a type, and nothing else.
        (let ((lines (cddr (split-string text "\n" t))))
          (should (>= (length lines) 6))
          (dolist (line lines)
            (should (string-match-p "\\`  [^ ]+  \\(object\\|array\\|string\\|number\\|boolean\\|null\\)\\'" line))))
        (should (eq :false (plist-get (plist-get (plist-get result :meta) :shape) :truncated)))))))

(ert-deftest harness-redact-tool-shape-of-a-part-and-of-what-is-no-json ()
  "A json_path limits the shape to a part; a file that is no JSON is said to be, without its text."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (_text (harness-redact-tool-test--write cwd "notes.txt"
                                                   (format "not json, but it holds %s\n" harness-redact-tool-test--key)))
           (a (harness-redact-tool-test--session cwd "caller")))
      (let ((text (plist-get (harness-redact-tool-test--run
                              a (list :mode "shape" :source (list :file "state.json" :json_path "outputs.keys")))
                             :content)))
        (should (string-search "outputs.keys.value.secret_key  string" text))
        (should-not (string-search "other  string" text)))
      (let ((result (harness-redact-tool-test--run a (list :mode "shape" :source (list :file "notes.txt")))))
        (should (plist-get result :is-error))
        (should (string-search "not valid JSON" (plist-get result :content)))
        (should-not (harness-redact-tool-test--holds-p result)))
      ;; A shape reads a JSON file; a regexp or a variable has none.
      (dolist (source (list (list :file "state.json" :regexp "x\\(y\\)") (list :env "HOME")))
        (let ((result (harness-redact-tool-test--run a (list :mode "shape" :source source))))
          (should (plist-get result :is-error))
          (should (string-search "Mode shape reads" (plist-get result :content))))))))

;;;; What the tool refuses

(ert-deftest harness-redact-tool-refuses-a-literal-and-a-command-and-runs-nothing ()
  "The tool takes no secret's text and no command; it says so without quoting either, and runs nothing."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (marker (expand-file-name "ran" cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (_flush (harness-session-flush))
           (log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (dolist (input (list
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :literal harness-redact-tool-test--key))
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :command (format "touch %s" marker)))
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :file "state.json" :json_path "outputs.keys.value"
                                          :literal harness-redact-tool-test--key))
                      ;; Not in the source, but beside it, or under another name.
                      (list :mode "redact" :scope "all" :reason "x" :literal harness-redact-tool-test--key
                            :source (harness-redact-tool-test--ref))
                      (list :mode "redact" :scope "all" :reason "x" :allow_unsafe_sources t
                            :source (list :literal harness-redact-tool-test--key))
                      (list :mode "scan" :scope "all" :value harness-redact-tool-test--key
                            :source (harness-redact-tool-test--ref))
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :file "state.json" :json_path "outputs.keys.value"
                                          :text harness-redact-tool-test--key))))
        (let ((result (harness-redact-tool-test--run a input)))
          (should (plist-get result :is-error))
          (should-not (harness-redact-tool-test--holds-p result))
          (should-not (string-search marker (plist-get result :content)))))
      (should-not (file-exists-p marker))
      ;; Nothing was redacted by any of them.
      (should (equal log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (should-not (harness-redact-tool-test--redactions b))
      (should (string-search "never what it is"
                             (plist-get (harness-redact-tool-test--run
                                         a (list :source (list :literal harness-redact-tool-test--key)))
                                        :content))))))

(ert-deftest harness-redact-tool-reads-its-keys-as-the-schema-spells-them ()
  "A key spelled another way is refused, not read case-blind: what the jail and the permission chain see is what runs."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (_flush (harness-session-flush))
           (log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (dolist (input (list
                      (list :Mode "redact" :scope "all" :reason "x" :source (harness-redact-tool-test--ref))
                      (list :mode "redact" :scope "all" :reason "x" :Source (harness-redact-tool-test--ref))
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :File "state.json" :json_path "outputs.keys.value"))
                      (list :mode "redact" :scope "all" :reason "x"
                            :source (list :file "state.json" :JSON_PATH "outputs.keys.value"))
                      (list :mode "redact" :scope "all" :reason "x" :include-Forks :false
                            :source (harness-redact-tool-test--ref))))
        (let ((result (harness-redact-tool-test--run a input)))
          (should (plist-get result :is-error))
          (should (or (string-search "takes mode, source" (plist-get result :content))
                      (string-search "source says where" (plist-get result :content))))))
      (should (equal log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      ;; The kebab spellings of a Lisp caller are the same keys.
      (let ((result (harness-redact-tool-test--run
                     a (list :mode "scan" :scope "all" :include-forks :false
                             :source (list :file "state.json" :json-path "outputs.keys.value")))))
        (should-not (plist-get result :is-error))
        (should (equal (list b) (plist-get (harness-redact-tool-test--summary result) :sessions)))))))

(ert-deftest harness-redact-tool-says-what-is-wrong-without-quoting-the-input ()
  "A call that cannot be understood is answered with a message that quotes none of it."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (odd harness-redact-tool-test--key))
      (cl-flet ((fails (input &optional text)
                  (let ((result (harness-redact-tool-test--run a input)))
                    (should (plist-get result :is-error))
                    (should-not (harness-redact-tool-test--holds-p result))
                    (should-not (string-search odd (plist-get result :content)))
                    (when text (should (string-search text (plist-get result :content)))))))
        ;; No source, or one that is no reference.
        (fails nil "source says where the secret can be read")
        (fails (list :mode "scan") "source says where")
        (fails (list :source odd) "source says where")
        (fails (list :source (list :file "state.json")) "needs a json_path or a regexp")
        (fails (list :source (list :file "state.json" :json_path "a" :regexp "b")) "not both")
        (fails (list :source (list :env "HOME" :file "state.json")) "stands alone")
        ;; A mode, a scope or a flag that is none.
        (fails (list :mode odd :source (harness-redact-tool-test--ref)) "The mode must be one of")
        (fails (list :scope odd :source (harness-redact-tool-test--ref)) "The scope must be one of")
        (fails (list :scope "all" :include_forks odd :source (harness-redact-tool-test--ref)) "true or false")
        ;; A redaction needs a reason, and a scope its sessions or its project.
        (fails (list :mode "redact" :scope "all" :source (harness-redact-tool-test--ref)) "needs a reason")
        (fails (list :mode "redact" :reason "x" :scope "sessions" :source (harness-redact-tool-test--ref))
               "needs sessions")
        (fails (list :mode "redact" :reason "x" :scope "project" :source (harness-redact-tool-test--ref))
               "needs project")
        (fails (list :scope "all" :sessions (list b) :source (harness-redact-tool-test--ref))
               "goes with the scope sessions")
        (fails (list :scope "all" :project cwd :source (harness-redact-tool-test--ref))
               "goes with the scope project")
        ;; A variable that is not set, and a name that is none.
        (fails (list :scope "all" :source (list :env "HARNESS_TEST_REDACT_TOOL_UNSET"))
               "not set in the harness process")
        (fails (list :scope "all" :source (list :env odd)) "name of a variable")
        ;; A file that is not there, a path that selects nothing.
        (fails (list :scope "all" :source (list :file "missing.json" :json_path "a")) "Cannot read")
        (fails (list :scope "all" :source (list :file "state.json" :json_path "outputs.nothing"))
               "No value at JSON path")
        (fails (list :scope "all" :source (list :file "state.json" :json_path "pin")) "shorter than")))))

(ert-deftest harness-redact-tool-scopes-sessions-by-prefix-project-and-forks ()
  "The scopes name sessions by id or its start, a project by its directory, and take forks along unless left out."
  (harness-redact-tool-test-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (a (harness-redact-tool-test--session cwd "caller"))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (fork (plist-get (harness-test-await (harness-call 'session/fork b :name "fork of dirty")) :id))
           (elsewhere (harness-redact-tool-test--dirty (harness-test-temp-dir) "elsewhere")))
      (cl-flet ((scan (&rest input)
                  (let ((result (harness-redact-tool-test--run
                                 a (append (list :source (harness-redact-tool-test--ref)) input))))
                    (should-not (plist-get result :is-error))
                    (sort (copy-sequence (plist-get (harness-redact-tool-test--summary result) :sessions))
                          #'string<))))
        ;; Self is the caller and its forks: the caller holds none.
        (should (null (scan)))
        ;; A session by its start; its fork comes along unless left out.
        (should (equal (sort (list b fork) #'string<) (scan :scope "sessions" :sessions (list (substring b 0 12)))))
        (should (equal (list b) (scan :scope "sessions" :sessions (list b) :include_forks :false)))
        (should (equal (sort (list b fork) #'string<) (scan :scope "sessions" :sessions (list b) :include_forks t)))
        ;; A project is its directory, relative to the caller's too.
        (should (equal (sort (list b fork) #'string<) (scan :scope "project" :project (directory-file-name cwd))))
        (should (equal (sort (list b fork) #'string<) (scan :scope "project" :project ".")))
        (should (equal (list elsewhere) (scan :scope "project" :project (plist-get (harness-call 'session/get elsewhere) :cwd))))
        (should (equal (sort (list b fork elsewhere) #'string<) (scan :scope "all")))))))

;;;; The permission chain

(ert-deftest harness-redact-tool-permission-call-kind-weighs-the-mode ()
  "A scan, a shape and a call with no mode are reads; a redaction, and anything not understood, are not."
  (harness-redact-tool-test-with-perms
    (cl-flet ((kind (input &optional tool)
                (harness-perms--call-kind (list :session (list :id "s1") :tool (or tool "redact_secret")
                                                :kind 'meta :input input))))
      (dolist (input (list (list :mode "scan") (list :mode "shape") (list :mode "SCAN") (list :mode " Shape ")
                           (list :mode 'scan) (list :mode 'shape) (list :source (list :env "X")) nil))
        (should (eq 'read (kind input))))
      (dolist (input (list (list :mode "redact") (list :mode "Redact") (list :mode " redact ") (list :mode "frob")
                           (list :mode "") (list :mode 'redact) (list :mode :scan) (list :mode 1)
                           (list :mode '("scan")) (list :mode t) "scan" 'scan))
        (should (eq 'meta (kind input))))
      ;; Only this tool: another one with the same input keeps its kind.
      (should (eq 'meta (kind (list :mode "scan") "session_send")))
      (should (eq 'meta (kind (list :mode "shape") "task_control")))
      ;; A key spelled another way is not the mode: the tool refuses it (see above).
      (should (eq 'read (kind (list :Mode "redact")))))))

(ert-deftest harness-redact-tool-ask-mode-allows-a-scan-and-asks-about-a-redaction ()
  "In ask mode a scan and a shape need no approval; a redaction asks the user."
  (harness-redact-tool-test-with-perms
    (let* ((cwd (harness-test-temp-dir))
           (sid (plist-get (harness-call 'session/create :cwd cwd :name "caller" :model "demo:scripted"
                                         :permission-mode 'ask)
                           :id))
           (session (harness-call 'session/get sid)))
      (cl-flet ((request (input)
                  (list :session session :tool "redact_secret" :kind 'meta :input input
                        :paths (let ((file (plist-get (plist-get input :source) :file)))
                                 (and file (list (expand-file-name file cwd))))
                        :call-id (harness-short-id))))
        (dolist (input (list (list :mode "scan" :source (list :file "state.json" :json_path "a"))
                             (list :mode "shape" :source (list :file "state.json"))
                             (list :source (list :env "HOME"))))
          (should (eq 'allow (plist-get (harness-test-await
                                         (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                                                   (request input)))
                                        :behavior))))
        (should-not (harness-call 'session/pending sid))
        (let ((decision (harness-run-filter-async
                         'permission/decide (list :behavior 'ask)
                         (request (list :mode "redact" :reason "x" :scope "all"
                                        :source (list :file "state.json" :json_path "a"))))))
          (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "the prompt for the redaction")
          (let* ((item (car (harness-call 'session/pending sid)))
                 (payload (plist-get item :payload)))
            (should (equal "redact_secret" (plist-get payload :tool)))
            (should (string-search "Redact secret" (plist-get payload :title)))
            (harness-call 'permission/answer sid (plist-get item :id) "deny-once"))
          (should (eq 'deny (plist-get (harness-test-await decision) :behavior))))))))

(ert-deftest harness-redact-tool-jail-checks-the-file-of-the-source ()
  "The file the tool reads is a path the jail checks: one outside the allowed directories is refused."
  (harness-redact-tool-test-with-perms
    (let* ((cwd (harness-test-temp-dir))
           (outside (harness-test-temp-dir))
           (_ (harness-redact-tool-test--state-file cwd))
           (_ (harness-redact-tool-test--state-file outside))
           (a (plist-get (harness-call 'session/create :cwd cwd :name "caller" :model "demo:scripted"
                                       :permission-mode 'yolo :non-interactive t)
                         :id))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (_flush (harness-session-flush))
           (log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      ;; Inside, with everything allowed by the mode, it runs.
      (let ((result (harness-redact-tool-test--run
                     a (list :mode "shape" :source (list :file "state.json")))))
        (should-not (plist-get result :is-error))
        (should (string-search "outputs.keys" (plist-get result :content))))
      ;; Outside, for every mode, it does not.
      (dolist (mode '("shape" "scan" "redact"))
        (let ((result (harness-redact-tool-test--run
                       a (list :mode mode :scope "all" :reason "x"
                               :source (list :file (expand-file-name "state.json" outside)
                                             :json_path "outputs.keys.value")))))
          (should (plist-get result :is-error))
          (should (plist-get result :denied))
          (should (string-search "outside the allowed directories" (plist-get result :content)))))
      ;; Nor does a spelling the tool would not read get it past the jail.
      (let ((result (harness-redact-tool-test--run
                     a (list :mode "shape" :Source (list :File (expand-file-name "state.json" outside))))))
        (should (plist-get result :is-error))
        (should-not (string-search "outputs.keys" (plist-get result :content))))
      (should (equal log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
      (should-not (harness-redact-tool-test--redactions b))
      ;; The tool's paths are the file, as the jail resolves it.
      (should (equal (list (expand-file-name "state.json" cwd))
                     (harness-tools--paths (harness-tool-get "redact_secret")
                                           (list :source (list :file "state.json"))
                                           (list :cwd cwd))))
      (should (null (harness-tools--paths (harness-tool-get "redact_secret")
                                          (list :source (list :env "HOME")) (list :cwd cwd)))))))

;;;; ACP

(defmacro harness-redact-tool-test-with-acp (&rest body)
  "Load the state layer, the redaction and the ACP module (no server); run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent secrets redact acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (setq harness-acp--clients nil)
     (let ((harness-acp-token nil)
           (harness-acp-authorize-functions nil)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-redact-tool-test--log-text ()
  "Return the text of the harness log buffer."
  (with-current-buffer (get-buffer-create harness-log-buffer-name) (buffer-string)))

(defun harness-redact-tool-test--client (&optional address)
  "Add a client of a test transport, on another device when ADDRESS is given.
Return (CLIENT . SENT): SENT's car collects the messages the server writes."
  (let* ((sent (list nil))
         (client (harness-acp-add-client
                  'test :writer (lambda (_c text) (push (harness-json-parse text) (car sent)))
                  :remote (and address (list :address address)))))
    (cons client sent)))

(defun harness-redact-tool-test--ask (client sent id method params)
  "Send request ID, METHOD with PARAMS, as CLIENT; return the answer from SENT."
  (harness-acp-client-receive client (harness-json-encode (list :jsonrpc "2.0" :id id :method method
                                                                :params (or params :empty))))
  (harness-test-wait (lambda () (cl-find id (car sent) :key (lambda (m) (plist-get m :id)))) 5 method)
  (cl-find id (car sent) :key (lambda (m) (plist-get m :id))))

(ert-deftest harness-redact-tool-acp-offers-the-methods-and-forwards-the-events ()
  "The methods under secrets/ are callable as _harness/NAME, and clients hear the redactions."
  (harness-redact-tool-test-with-acp
    (dolist (name '("secrets/redact" "secrets/shape" "secrets/log" "secrets/sources" "secrets/add-source"))
      (should (harness-acp--extension-allowed-p name)))
    (dolist (name '("secrets" "secretsx/redact" "secret/redact" "store/save"))
      (should-not (harness-acp--extension-allowed-p name)))
    (should (memq 'session/redacted harness-acp--forwarded-events))
    (should (memq 'secrets/redacted harness-acp--forwarded-events))
    ;; Both are declared on the bus, so a client can list them.
    (should (assq 'session/redacted (harness-events)))
    (should (assq 'secrets/redacted (harness-events)))
    ;; And a client hears them, as `_harness/event' notifications.
    (pcase-let ((`(,_client . ,sent) (harness-redact-tool-test--client)))
      (harness-emit 'session/redacted "s-1" (list :ts 1.0 :by "user"
                                                  :secrets (list (list :label "x" :fingerprint "abcd1234"))))
      (harness-emit 'secrets/redacted (list :source (list :env "X") :sessions (list "s-1")))
      (harness-test-wait (lambda () (= 2 (length (car sent)))) 5 "the two events")
      (let ((events (mapcar (lambda (m) (plist-get (plist-get m :params) :event)) (reverse (car sent)))))
        (should (equal '("session/redacted" "secrets/redacted") events)))
      (let ((first (car (last (car sent)))))
        (should (equal "_harness/event" (plist-get first :method)))
        (should (equal "s-1" (car (plist-get (plist-get first :params) :args))))))))

(ert-deftest harness-redact-tool-acp-calls-the-redaction-for-a-local-client ()
  "A client on this machine redacts by a reference, or by the text the UI reads with `read-passwd'."
  (harness-redact-tool-test-with-acp
    (let* ((cwd (harness-test-temp-dir))
           (file (harness-redact-tool-test--state-file cwd))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (conn (harness-acp-connect)))
      (cl-flet ((call (method params) (harness-test-await (harness-acp-request conn method params))))
        ;; The shape: keys and types.
        (let ((shape (call "_harness/secrets/shape" (list :file file :jsonPath "outputs.keys"))))
          (should (cl-some (lambda (e) (equal "outputs.keys.value.secret_key" (plist-get e :path)))
                           (append (plist-get shape :paths) nil)))
          (should-not (harness-redact-tool-test--holds-p shape)))
        ;; A scan by a reference.
        (let ((report (call "_harness/secrets/redact"
                            (list :params (list :source (list :file file :json-path "outputs.keys.value")
                                                :scope "all")))))
          (should (equal "scan" (format "%s" (plist-get report :mode))))
          (should (> (plist-get report :total) 0))
          (should-not (harness-redact-tool-test--holds-p report)))
        ;; A scan by the text itself, as the UI sends what `read-passwd' read.
        (let ((report (call "_harness/secrets/redact"
                            (list :params (list :source (list :literal harness-redact-tool-test--key :label "typed")
                                                :allow-unsafe-sources t :scope "all")))))
          (should (> (plist-get report :total) 0))
          (should-not (harness-redact-tool-test--holds-p report)))
        ;; The redaction, with the camel case a client may write.
        (let ((report (call "_harness/secrets/redact"
                            (list :params (list :source (list :literal harness-redact-tool-test--key :label "typed")
                                                :allowUnsafeSources t :scope "session" :sessions (list b)
                                                :mode "redact" :reason "typed by the user")))))
          (should (plist-get report :complete))
          (should-not (harness-redact-tool-test--holds-p report)))
        (should (= 0 (harness-redaction-file-count (harness-redact-tool-test--log b)
                                                   (list (car (harness-redact-tool-test--secrets))))))
        ;; Nothing a request was given reached the log.
        (should-not (string-search harness-redact-tool-test--key (harness-redact-tool-test--log-text))))
      (harness-acp-close conn))))

(ert-deftest harness-redact-tool-acp-refuses-a-secrets-text-from-another-device ()
  "A client on another device names where a secret is; it gives neither its text nor a command."
  (harness-redact-tool-test-with-acp
    (let* ((cwd (harness-test-temp-dir))
           (file (harness-redact-tool-test--state-file cwd))
           (b (harness-redact-tool-test--dirty cwd "dirty"))
           (log (harness-redact-tool-test--read (harness-redact-tool-test--log b)))
           (marker (expand-file-name "ran" cwd)))
      (pcase-let ((`(,client . ,sent) (harness-redact-tool-test--client "192.0.2.9")))
        (let ((harness-acp-authorize-functions (list (lambda (c) (eq c client)))))
          (harness-redact-tool-test--ask client sent 1 "initialize" '(:protocolVersion 1))
          (let ((id 1))
            (cl-flet ((ask (method params)
                        (harness-redact-tool-test--ask client sent (cl-incf id) method params)))
              ;; A reference is for every client.
              (let ((answer (ask "_harness/secrets/redact"
                                 (list :params (list :source (list :file file :json-path "outputs.keys.value")
                                                     :scope "all")))))
                (should-not (plist-get answer :error))
                (should (> (plist-get (plist-get answer :result) :total) 0)))
              ;; The text, a command, the leave to accept them: refused, however spelled and wherever put.
              (dolist (params (list
                               (list :params (list :source (list :literal harness-redact-tool-test--key) :scope "all"
                                                   :allow-unsafe-sources t))
                               (list :params (list :source (list :literal harness-redact-tool-test--key) :scope "all"
                                                   :allowUnsafeSources t))
                               (list :params (list :source (list :command (format "touch %s" marker)) :scope "all"
                                                   :allow_unsafe_sources t))
                               (list :params (list :source (list :file file :json-path "outputs.keys.value") :scope "all"
                                                   :allow-unsafe-sources t))
                               (list :params (list :source (list (list :command "x")) :scope "all"))))
                (let* ((answer (ask "_harness/secrets/redact" params))
                       (e (plist-get answer :error)))
                  (should e)
                  (should (string-search "only from the Emacs on this machine" (plist-get e :message)))
                  (should-not (harness-redact-tool-test--holds-p answer))))
              (let ((answer (ask "_harness/secrets/add-source" (list :ref (list :command (format "touch %s" marker))))))
                (should (string-search "only from the Emacs on this machine"
                                       (plist-get (plist-get answer :error) :message))))
              (should-not (file-exists-p marker))
              (should (null (harness-call 'secrets/sources)))))
          (should (equal log (harness-redact-tool-test--read (harness-redact-tool-test--log b))))
          (should-not (harness-redact-tool-test--redactions b)))))))

(ert-deftest harness-redact-tool-acp-never-logs-or-answers-with-what-a-request-held ()
  "A method that takes a secret fails without its params reaching the log or the answer.
The kind of error is all that is kept of a Lisp error from such a
method, in a notification's failure, which is logged, and in a request's,
which is answered; any other method fails as it always did."
  (harness-redact-tool-test-with-acp
    (let ((odd (concat "ODD-VALUE-" (make-string 12 ?v))))
      (harness-register-method 'secrets/test-boom
                               (lambda (&rest _) (signal 'wrong-type-argument (list 'stringp odd))))
      (harness-register-method 'secrets/test-says
                               (lambda (&rest _) (signal 'harness-error (list "Nothing to say about that."))))
      (harness-register-method 'session/test-boom
                               (lambda (&rest _) (signal 'wrong-type-argument (list 'stringp odd))))
      (pcase-let ((`(,client . ,sent) (harness-redact-tool-test--client)))
        ;; A request is answered with the kind of the error.
        (let* ((answer (harness-redact-tool-test--ask client sent 1 "_harness/secrets/test-boom" (list :value odd)))
               (e (plist-get answer :error)))
          (should (string-search "wrong-type-argument" (plist-get e :message)))
          (should-not (harness-redact-tool-test--holds-p answer))
          (should-not (string-search odd (prin1-to-string answer t)))
          (should (equal "wrong-type-argument" (plist-get (plist-get e :data) :type))))
        ;; An error that only says what is wrong is kept.
        (let ((answer (harness-redact-tool-test--ask client sent 2 "_harness/secrets/test-says" nil)))
          (should (equal "Nothing to say about that." (plist-get (plist-get answer :error) :message))))
        ;; Any other method answers as it did.
        (let ((answer (harness-redact-tool-test--ask client sent 3 "_harness/session/test-boom" (list :value odd))))
          (should (string-search odd (plist-get (plist-get answer :error) :message))))
        ;; A notification is logged when it fails, with the kind of error, and not its data.
        (harness-acp-client-receive
         client (harness-json-encode (list :jsonrpc "2.0" :method "_harness/secrets/test-boom"
                                           :params (list :value odd))))
        (harness-test-wait (lambda () (string-search "notification _harness/secrets/test-boom failed"
                                                     (harness-redact-tool-test--log-text)))
                           5 "the log line of the failed notification")
        (should (string-search "wrong-type-argument" (harness-redact-tool-test--log-text)))
        (should-not (string-search odd (harness-redact-tool-test--log-text)))
        ;; The control: a method that takes no secret is logged as it was.
        (harness-acp-client-receive
         client (harness-json-encode (list :jsonrpc "2.0" :method "_harness/session/test-boom"
                                           :params (list :value odd))))
        (harness-test-wait (lambda () (string-search "notification _harness/session/test-boom failed"
                                                     (harness-redact-tool-test--log-text)))
                           5 "the log line of the other notification")
        (should (string-search odd (harness-redact-tool-test--log-text)))))))

(ert-deftest harness-redact-tool-acp-secret-methods-are-those-under-secrets ()
  "Which methods take a secret in their params: those under secrets/, with or without _harness/.
Nothing else does: a method that called another with Lisp arguments
\(`harness/call', now gone) was the only one that carried a secret under
another method's name."
  (should (harness-acp--secret-method-p "secrets/redact"))
  (should (harness-acp--secret-method-p "_harness/secrets/add-source"))
  (should-not (harness-acp--secret-method-p "_harness/session/get"))
  (should-not (harness-acp--secret-method-p "secretsredact"))
  (should-not (harness-acp--secret-method-p nil))
  (should-not (harness-acp--secret-method-p 'secrets/redact))
  (should-not (harness-acp--secret-method-p "_harness/harness/call"))
  (should-not (harness-acp--secret-method-p "harness/call")))

(provide 'harness-redact-tool-test)
;;; harness-redact-tool-test.el ends here
