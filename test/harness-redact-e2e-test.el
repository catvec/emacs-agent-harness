;;; harness-redact-e2e-test.el --- Redaction, end to end, over every store  -*- lexical-binding: t; -*-

;;; Commentary:

;; The other redaction suites test the pieces: the library, the engine
;; with stand-ins for the stores, each store on its own.  These run the
;; harness process's modules as they are -- the store, session, search
;; index, hosted provider, agent, tools, tasks, secrets and redaction
;; modules, over a throwaway state directory -- and put two fake secrets,
;; a key id and a secret key, in every place the harness keeps text:
;;
;; - the node logs of a session and of its fork, every kind of node, an
;;   update line, a cut tool output and the file it was saved whole to;
;; - the sessions' records (name, queue, todos, plan, `ext'), and their
;;   nodes in memory;
;; - the search index: its rows, its full-text index, its files, and the
;;   vectors and chunks an embedding made of an assistant reply;
;; - the conversation logs of the Claude Code CLI: the session's own, its
;;   tool results, and one a node's checkpoint names, written the way a
;;   foreign writer does, with the slashes escaped;
;; - the session state of the Copilot CLI: the events and the summary of a
;;   session whose own transcript holds nothing, and the state of a
;;   session that none of the harness's owns;
;; - transcript files, one a compaction names in the directory a session
;;   moved from, and the temporary directory of the session;
;; - the harness log, the task records and their store, state files of
;;   every format, and a node log and a record in the sessions directory
;;   that no session of the harness owns.
;;
;; The secret is taken out by reference to the JSON file it is read from
;; (a Terraform state, here a made-up one), and the tests count what is
;; left in each store and in every file of the places the harness
;; writes.  Each store is shown to hold the secret first: a test that
;; cleaned nothing would not pass.
;;
;; What the tests show:
;;
;; - a redaction by reference leaves no copy in any store, finds what a
;;   search of the transcripts finds before and not after, keeps the text
;;   around a secret whatever it is made of, and is as good the second time;
;; - the call and the result of the tool that redacts, run by a session in
;;   a turn of the agent, hold no secret, and nor does anything the bus
;;   carries while it runs;
;; - a session in a running turn is cleaned at once, loses no append and
;;   keeps a log that a restart would load whole, and is finished when
;;   its turn ends: with the secret echoed in a new node, in a reply that
;;   is streaming, and in what a tool prints after the request, which is
;;   masked before it is stored or sent;
;; - a request for one session cleans it and its fork and nothing else, says
;;   that the index files still hold the other sessions' rows, and keeps
;;   the conversation of a fork it leaves out;
;; - a log that no session owns and that was just written is left alone,
;;   and the request says it is not done;
;; - a copy that something wrote back during the request is found by the
;;   second scan.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  A test that fails shows values it
;; compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-redact--pending)
(defvar harness-tasks--table)
(defvar harness-tasks--naming)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-store-in-repository)
(defvar harness-session-search-index)
(defvar harness-session-search-embedding-model)
(defvar harness-session-search--timer)
(defvar harness-session-search--dirty)
(defvar harness-provider-claude-program)
(defvar harness-provider-claude-projects-directory)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(defvar harness-provider-claude-api-key)
(defvar harness-provider-copilot-state-directory)
(defvar harness-provider-claude--api-base)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-tools)
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude--forget-listing "harness-provider-claude")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-session-flush "harness-session")
(declare-function harness-session--load-all "harness-session")
(declare-function harness-session--load-nodes "harness-session")
(declare-function make-harness-session "harness-session")
(declare-function harness-session-nodes "harness-session")
(declare-function harness-session-plist "harness-session")
(declare-function harness-session-search--db "harness-session-search")
(declare-function harness-session-search--sync "harness-session-search")
(declare-function harness-session-search--files "harness-session-search")
(declare-function harness-session-search--chunks "harness-session-search")
(declare-function harness-session-search--quantize "harness-session-search")
(declare-function harness-session-search--finish "harness-session-search")
(declare-function harness-tasks--put "harness-tasks")
(declare-function harness-tasks--project "harness-tasks")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks-flush "harness-tasks")
(declare-function harness-secrets-forget "harness-secrets")
(declare-function harness-define-tool "harness-tools")

;;;; The fake secrets

(defvar harness-redact-e2e--access-key nil
  "The fake access key id of the test running, 20 characters.")

(defvar harness-redact-e2e--secret-key nil
  "The fake secret key of the test running, 44 characters with slashes and a plus.")

(defconst harness-redact-e2e--alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  "The characters the fake secrets are made of, besides their slashes and plus.")

(random t)

(defun harness-redact-e2e--chars (n)
  "Return N random letters and digits."
  (apply #'string (cl-loop repeat n
                           collect (aref harness-redact-e2e--alphabet
                                         (random (length harness-redact-e2e--alphabet))))))

(defun harness-redact-e2e--make-access-key ()
  "Return a fake access key id of 20 characters."
  (concat "FAKEACC" (harness-redact-e2e--chars 13)))

(defun harness-redact-e2e--make-secret-key ()
  "Return a fake secret key of 44 characters, with slashes and a plus in it."
  (concat "sK/" (harness-redact-e2e--chars 18) "+" (harness-redact-e2e--chars 17) "/"
          (harness-redact-e2e--chars 4)))

(defun harness-redact-e2e--secrets ()
  "Return the fake key and id as secrets, the longest first as a resolution has them.
They are labelled as the JSON path of the state file labels them."
  (list (harness-redaction-secret harness-redact-e2e--secret-key "outputs.creds.value.secret_key")
        (harness-redaction-secret harness-redact-e2e--access-key "outputs.creds.value.access_key")))

(defun harness-redact-e2e--fp (index)
  "Return the fingerprint of the fake secret number INDEX, 0 the key and 1 the id."
  (plist-get (nth index (harness-redact-e2e--secrets)) :fingerprint))

(defun harness-redact-e2e--placeholder (index)
  "Return the placeholder of the fake secret number INDEX, 0 the key and 1 the id."
  (harness-redaction-placeholder (nth index (harness-redact-e2e--secrets))))

;;;; Counting

(defun harness-redact-e2e--text-count (object)
  "Return how many times the fake secrets occur in OBJECT, printed (a string as it is).
They are found as they are and as JSON writes them."
  (harness-redaction-count (if (stringp object) object (prin1-to-string object t))
                           (harness-redact-e2e--secrets)))

(defun harness-redact-e2e--file-count (file)
  "Return how many times the fake secrets occur in the bytes of FILE, 0 if it is none."
  (if (file-regular-p file)
      (harness-redaction-file-count file (harness-redact-e2e--secrets))
    0))

(defun harness-redact-e2e--tree-count (root)
  "Return how many times the fake secrets occur in the bytes of every file under ROOT."
  (if (file-directory-p root)
      (cl-loop for file in (directory-files-recursively root "")
               sum (harness-redact-e2e--file-count file))
    0))

(defun harness-redact-e2e--tree-holders (root)
  "Return the files under ROOT that hold a fake secret, relative to it."
  (and (file-directory-p root)
       (cl-loop for file in (directory-files-recursively root "")
                when (> (harness-redact-e2e--file-count file) 0)
                collect (file-relative-name file root))))

(defun harness-redact-e2e--memory (sid)
  "Return everything the harness holds in memory about session SID, printed.
That is every node it has loaded, on its path or not, and its record."
  (let ((s (gethash sid harness-sessions)) nodes)
    (maphash (lambda (_ node) (push node nodes)) (harness-session-nodes s))
    (prin1-to-string (list nodes (harness-session-plist s)) t)))

;;;; Files and paths

(defun harness-redact-e2e--write (file text &optional age)
  "Write TEXT to FILE, making its directory; return FILE.
With AGE, a number of seconds, the file is dated that long ago: a log that
was written in the last minute may have a process at work in it, and a
redaction leaves it alone."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert text)))
  (when age (set-file-times file (time-subtract (current-time) age)))
  file)

(defun harness-redact-e2e--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redact-e2e--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))

(defun harness-redact-e2e--record-file (sid)
  "Return the file name of the record of session SID."
  (expand-file-name (format "sessions/%s.json" sid) harness-state-directory))

(defun harness-redact-e2e--log-lines (sid)
  "Return the lines of the node log of session SID, each checked to be whole JSON.
The log ends in a newline, and no line is torn."
  (let ((text (harness-redact-e2e--read (harness-redact-e2e--log sid))))
    (should (string-suffix-p "\n" text))
    (let ((lines (split-string text "\n" t)))
      (dolist (line lines)
        (should (consp (harness-json-parse line))))
      lines)))

(defun harness-redact-e2e--log-ids (sid)
  "Return the ids of the nodes in the node log of session SID, oldest first.
A node has a line of its own: the lines of its updates and of a discarded
node do not count, so a node whose line was lost is missing here, though
the update of it is still in the log."
  (delete-dups
   (cl-loop for line in (harness-redact-e2e--log-lines sid)
            for record = (harness-json-parse line)
            unless (plist-get record :_op)
            collect (plist-get record :id))))

(defun harness-redact-e2e--replay (sid)
  "Return the nodes of session SID as a restart would load them from its node log.
That is a hash table of id -> node, made by the harness's own loader
from a session that has nothing else."
  (let ((s (make-harness-session :id sid)))
    (harness-session--load-nodes s)
    (harness-session-nodes s)))

(defun harness-redact-e2e--check-replay (sid)
  "Check that the node log of session SID replays to the nodes the harness holds.
Every node and the text of every node: a restart would find the
transcript as the session has it now.  A node line lost in a rewrite, an
update torn off, or a rewrite that cleaned the log and not the memory (or
the other way) shows here."
  (let ((replayed (harness-redact-e2e--replay sid))
        (held (harness-session-nodes (gethash sid harness-sessions))))
    (should (= (hash-table-count held) (hash-table-count replayed)))
    (maphash (lambda (node-id node)
               (let ((disk (gethash node-id replayed)))
                 (should disk)
                 (dolist (key '(:kind :content :output :input :blocks))
                   (should (equal (plist-get node key) (plist-get disk key))))))
             held)))

;;;; Sessions

(defun harness-redact-e2e--add (sid node)
  "Append NODE, a plist, to session SID; return the id of the node."
  (plist-get (harness-call 'session/append sid node) :id))

(defun harness-redact-e2e--hints (sid)
  "Return the text of the hints in the transcript of session SID, oldest first."
  (cl-loop for n in (harness-call 'session/nodes sid)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(defun harness-redact-e2e--redactions (sid)
  "Return the redaction records in the `ext' of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :redactions))

(defun harness-redact-e2e--last-assistant (sid)
  "Return the text of the last reply in the transcript of session SID."
  (plist-get (cl-find 'assistant (harness-call 'session/nodes sid)
                      :key (lambda (n) (plist-get n :kind)) :from-end t)
             :content))

(defun harness-redact-e2e--provider-state (sid)
  "Return the provider state in the record of session SID."
  (plist-get (harness-call 'session/get sid) :provider-state))

;;;; The stack

(defmacro harness-redact-e2e-with (&rest body)
  "Run BODY on the whole stack, in a fresh state directory, with fake secrets.
The sessions run their hosted turns on the fake Claude CLI, which keeps
its conversations in a directory of the test's; the CLIs' own logs are in
others (`harness-provider-claude-projects-directory' and
`harness-provider-copilot-state-directory'), never the user's.  The
search index is on, with no embedding model; everything is allowed;
tasks stay in the state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(provider provider-claude provider-copilot))
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
     (dolist (m '(store project config provider-demo tools session session-search agent tasks
                        secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--naming)
     (harness-tasks--forget-stores)
     ;; Nothing waits to be written over this test's files.
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil)
     (harness-secrets-forget)
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let* ((harness-redact-e2e--access-key (harness-redact-e2e--make-access-key))
            (harness-redact-e2e--secret-key (harness-redact-e2e--make-secret-key))
            (harness-tasks-store-in-repository nil)
            (harness-session-search-index t)
            (harness-session-search-embedding-model nil)
            (harness-provider-claude-projects-directory (harness-test-temp-dir))
            (harness-provider-copilot-state-directory (harness-test-temp-dir))
            (harness-provider-demo--delay 0.005)
            (harness-provider-demo-script-override nil)
            (default-directory dir)
            (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_STORE="
                                               (harness-test-temp-dir))
                                       process-environment)))
       (skip-unless (harness-session-search--db))
       (unwind-protect (progn ,@body)
         (harness-provider-claude-close-all)))))

(defun harness-redact-e2e--quiet-index ()
  "Stop the background of the search index: the test drives it."
  (clrhash harness-session-search--dirty)
  (when harness-session-search--timer
    (cancel-timer (cdr harness-session-search--timer))
    (setq harness-session-search--timer nil)))

;;;; The world: the fake secrets in every store

(defun harness-redact-e2e--state-file (dir)
  "Write a made-up Terraform state in DIR, with the fake secrets in an output; return it.
They are under outputs.creds.value, beside a type and a region that are none."
  (harness-redact-e2e--write
   (expand-file-name "terraform.tfstate" dir)
   (concat (harness-json-encode-text
            (list :version 4
                  :outputs (list :creds (list :value (list :access_key harness-redact-e2e--access-key
                                                           :secret_key harness-redact-e2e--secret-key)
                                              :type (list "object" (list :access_key "string"
                                                                         :secret_key "string"))
                                              :sensitive t)
                                 :region (list :value "nyc3" :type "string"))))
           "\n")))

(defun harness-redact-e2e--cli-line (role text)
  "Return a line of a CLI conversation log: ROLE said TEXT, as the CLI writes it."
  (harness-json-encode-text
   (list :type role :uuid (concat "uuid-" (harness-redact-e2e--chars 6))
         :message (list :role role
                        :content (if (equal role "user")
                                     text
                                   (list (list :type "text" :text text)))))))

(defun harness-redact-e2e--copilot-line (text)
  "Return a line of the events of a Copilot CLI session: the user said TEXT."
  (harness-json-encode-text (list :type "user.message" :data (list :content text))))

(defun harness-redact-e2e--fake-embeddings (db sessions node-id)
  "Give the rows of node NODE-ID of SESSIONS in DB the vectors and chunks an embedding makes.
That is what the background makes when an embedding model is set:
a vector for each chunk of the text, by the hash of the chunk, and the
chunks of the node."
  (dolist (sid sessions)
    (let* ((row (car (sqlite-select db "SELECT id, text FROM nodes WHERE session = ? AND node = ?"
                                    (list sid node-id)))))
      (dolist (piece (harness-session-search--chunks (cadr row)))
        (pcase-let ((`(,scale . ,bytes) (harness-session-search--quantize '(0.1 0.2 0.3))))
          (sqlite-execute db "INSERT OR IGNORE INTO vectors (hash, scale, vec) VALUES (?, ?, ?)"
                          (list (secure-hash 'sha1 piece) scale (propertize bytes 'coding-system 'binary)))))
      (harness-session-search--finish db (list (car row))))))

(defun harness-redact-e2e--world (&optional unlinked)
  "Put the fake secrets in every store; return a plist of where they are.
See the commentary for the stores.  The keys of the plist are the ids of
the session (`:s') and of its fork (`:f'), the file the secret is read
from (`:state-file'), the directories, the files of each store and the
node ids.  The task holds the secret in its prompt and its report and is
the session's, unless UNLINKED: a test that ends the session's turn does
not want the tasks module to move the task meanwhile."
  (let* ((key harness-redact-e2e--secret-key)
         (id harness-redact-e2e--access-key)
         (state harness-state-directory)
         (outside (harness-test-temp-dir))
         (cwd (harness-test-temp-dir))
         (moved-cwd (harness-test-temp-dir))
         (projects (file-name-as-directory harness-provider-claude-projects-directory))
         (slug (expand-file-name "-home-test-qr/" projects))
         (state-file (harness-redact-e2e--state-file outside))
         (cli (concat "cli-" (harness-redact-e2e--chars 10)))
         (cli-old (concat "cli-" (harness-redact-e2e--chars 10)))
         (cli-other (concat "cli-" (harness-redact-e2e--chars 10)))
         (copilot-root (file-name-as-directory harness-provider-copilot-state-directory))
         (copilot (concat "cp-" (harness-redact-e2e--chars 10)))
         (copilot-other (concat "cp-" (harness-redact-e2e--chars 10)))
         (copilot-clean (concat "cp-" (harness-redact-e2e--chars 10)))
         (spill (expand-file-name "outputs/call-2.txt" state))
         (orphan (expand-file-name "outputs/orphan.txt" state))
         (s (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1"
                                     :name (format "Step qr: cut over (%s)" id))
                       :id))
         (c (plist-get (harness-call 'session/create :cwd cwd :model "copilot:claude-sonnet-5"
                                     :name "A Copilot session")
                       :id))
         (id8 (substring s 0 8))
         (moved-file (expand-file-name (format ".harness/transcripts/%s-moved.md" id8) moved-cwd))
         (whole (format (concat "--- terraform.tfstate.backup\n+++ terraform.tfstate\n"
                                " \"access_key\": \"%s\",\n \"secret_key\": \"%s\"\n"
                                "-  \"serial\": 41\n+  \"serial\": 42\n"
                                " \"access_key\": \"%s\",\n \"secret_key\": \"%s\"\n")
                        id key id key))
         (head (substring whole 0 120))
         nodes f f8)
    (cl-flet ((add (sid node) (harness-redact-e2e--add sid node)))
      ;; A Copilot session: its transcript holds nothing, the state of its CLI does.
      (add c (list :kind 'user :content "Say hello."))
      (harness-call 'session/set-provider-state c (list :copilot-session-id copilot :provider "copilot"))
      ;; The conversation of the hosted provider the session is in.
      (harness-call 'session/set-provider-state s
                    (list :cli-session-id cli :model "claude-fable-5-1" :provider "claude"))
      ;; A compaction into a transcript the session wrote before it moved.
      (harness-redact-e2e--write
       moved-file (format "# Compacted conversation\n\n[user] the key is %s\n[result] %s\n" key id))
      (push (cons 'compaction
                  (add s (list :kind 'compaction
                               :content (format (concat "The conversation so far was compacted into a file, "
                                                        "to keep the context small: %s (40 lines, the whole "
                                                        "conversation, oldest first).")
                                                moved-file)
                               :meta (list :compaction "transcript" :file moved-file))))
            nodes)
      (add s (list :kind 'user :content "Compare the two Terraform states and say what changed."))
      (push (cons 'user
                  (add s (list :kind 'user :content (format "I pasted the key by mistake: %s" key)
                               :blocks (list (list :type "text" :text (format "note: the access key is %s" id))))))
            nodes)
      (push (cons 'thinking
                  (add s (list :kind 'thinking
                               :content (format "The output printed the access key %s \u2014 \u00ab cl\u00e9 \u00bb \u5bc6\u94a5 \U0001F511; I must not repeat it." id)
                               :meta (list :signature "sig"))))
            nodes)
      (push (cons 'call
                  (add s (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run: terraform output"
                               :input (list :command (format "terraform output -raw spaces_key | grep -c %s" key))
                               :checkpoint (list :cli-session-id cli :uuid "u-1"))))
            nodes)
      (push (cons 'result
                  (add s (list :kind 'tool-result :call-id "c1"
                               :output (format "{\"access_key\": \"%s\", \"secret_key\": \"%s\"}" id key))))
            nodes)
      (add s (list :kind 'tool-call :tool "bash" :call-id "c2" :title "Run: diff"
                   :input (list :command "diff terraform.tfstate.backup terraform.tfstate")))
      ;; A cut output: the head in the node, the whole in a file of the state directory.
      (harness-redact-e2e--write spill whole)
      (harness-redact-e2e--write orphan (format "left by a node that was discarded: %s\n" key))
      (push (cons 'cut
                  (add s (list :kind 'tool-result :call-id "c2"
                               :output (format (concat "%s\n\n[Output truncated: %d characters, %d lines. "
                                                       "The full output was saved to %s. Read it in ranges "
                                                       "with read_file (offset/limit), or narrow the request.]")
                                               head (length whole) (1+ (cl-count ?\n whole)) spill)
                               :meta (list :truncated (list :path spill :chars (length whole))))))
            nodes)
      ;; A reply that was streamed, and its final text written as an update.
      (let ((streamed (add s (list :kind 'assistant :content "The diff shows"
                                   :checkpoint (list :cli-session-id cli-old :uuid "u-0")))))
        (harness-call 'session/update-node s streamed
                      :content (format "The diff shows that the Spaces key %s was not rotated." id))
        (push (cons 'streamed streamed) nodes))
      (harness-call 'session/update-node s (cdr (assq 'result nodes))
                    :meta (list :duration 0.4 :note (format "echoed %s" key)))
      (harness-call 'session/hint s (format "Tool bash failed: the key %s was rejected." key))
      (push (cons 'reply
                  (add s (list :kind 'assistant :content (format "Done. The secret key is %s." key)
                               :checkpoint (list :cli-session-id cli :uuid "u-2"))))
            nodes)
      (harness-call 'session/set-provider-node s (cdr (assq 'reply nodes)))
      ;; The record.
      (harness-call 'session/queue s (format "also use %s" key))
      (harness-call 'session/set-todos s (list (list :id "1" :text (format "rotate %s" id) :status "pending")))
      (harness-call 'session/set-plan s (format "Plan: stop using %s" key))
      (harness-call 'session/set-ext s :note (format "memo %s" key))
      ;; Its fork, with a message and a plan of its own.
      (setq f (plist-get (harness-test-await (harness-call 'session/fork s :name "Fork of the cut-over")) :id)
            f8 (substring f 0 8))
      (add f (list :kind 'user :content (format "In the fork: %s too." id)))
      (harness-call 'session/set-plan f (format "Fork plan, key %s" key)))
    ;; Transcript files: the one the harness writes, and two named for the sessions.
    (let* ((written (plist-get (harness-call 'session/write-transcript s) :file))
           (named-s (harness-redact-e2e--write
                     (expand-file-name (format ".harness/transcripts/%s-x.md" id8) cwd)
                     (format "# Conversation\n\n[user] %s\n[result] %s\n" key id)))
           (named-f (harness-redact-e2e--write
                     (expand-file-name (format ".harness/transcripts/%s-x.md" f8) cwd)
                     (format "# Conversation\n\n[user] %s\n" id)))
           ;; The CLI's logs: the conversation, what belongs to it, one a
           ;; node's checkpoint names, written with escaped slashes, and one
           ;; that holds nothing.
           (cli-log (harness-redact-e2e--write
                     (expand-file-name (concat cli ".jsonl") slug)
                     (concat (harness-redact-e2e--cli-line "user" (format "keep the key %s in mind \u2014 cl\u00e9 \U0001F511" key)) "\n"
                             (harness-redact-e2e--cli-line "assistant" (format "the access key is %s" id)) "\n"
                             "{\"type\":\"summary\",\"summary\":\"nothing to see here\"}\n")))
           (cli-file (harness-redact-e2e--write
                      (expand-file-name (format "%s/tool-results/toolu_01.txt" cli) slug)
                      (format "terraform output:\naccess_key = %s\nsecret_key = %s\n" id key)))
           (cli-old-log (harness-redact-e2e--write
                         (expand-file-name (concat cli-old ".jsonl") slug)
                         (concat (string-replace "/" "\\/"
                                                 (harness-redact-e2e--cli-line "user" (format "the key is %s" key)))
                                 "\n")
                         3600))
           (cli-other-log (harness-redact-e2e--write
                           (expand-file-name (concat cli-other ".jsonl") slug)
                           (concat (harness-redact-e2e--cli-line "user" "a conversation about something else") "\n")
                           3600))
           ;; A command's output saved in the session's temporary directory.
           (tmp-file (harness-redact-e2e--write
                      (expand-file-name "terraform-output.txt" (harness-call 'session/tmp-dir s))
                      (format "access_key = %s\nsecret_key = %s\n" id key) 3600))
           ;; The Copilot CLI's state: the events of the session and a summary beside them,
           ;; the state of a session of the CLI's own, and one that holds nothing.
           (copilot-events (harness-redact-e2e--write
                            (expand-file-name (format "%s/events.jsonl" copilot) copilot-root)
                            (concat (harness-redact-e2e--copilot-line (format "KEY=%s" key)) "\n"
                                    "{\"type\":\"session.start\"}\n")))
           (copilot-summary (harness-redact-e2e--write
                             (expand-file-name (format "%s/workspace.yaml" copilot) copilot-root)
                             (format "summary: leaked %s\n" id)))
           (copilot-orphan (harness-redact-e2e--write
                            (expand-file-name (format "%s/events.jsonl" copilot-other) copilot-root)
                            (concat (harness-redact-e2e--copilot-line (format "id %s" id)) "\n")
                            3600))
           (copilot-clean-file (harness-redact-e2e--write
                                (expand-file-name (format "%s/events.jsonl" copilot-clean) copilot-root)
                                "{\"type\":\"session.start\"}\n" 3600))
           ;; A node log and a record of a session that was not loaded: the record is torn.
           (orphan-session "0badbeef-0000-4000-8000-000000000000")
           (orphan-log (harness-redact-e2e--write
                        (expand-file-name (format "sessions/%s.nodes.jsonl" orphan-session) state)
                        (concat (harness-json-encode-text
                                 (list :id "n-orphan" :kind "user" :content (format "left behind: %s" key)))
                                "\n")))
           (orphan-record (harness-redact-e2e--write
                           (expand-file-name (format "sessions/%s.json" orphan-session) state)
                           (format "{\"id\":\"%s\",\"name\":\"torn %s\",\n" orphan-session id)))
           ;; State files of every format.
           (state-jsonl (harness-redact-e2e--write
                         (expand-file-name "insights/x.jsonl" state)
                         (concat (harness-json-encode-text (list :ts 1 :note (format "key %s in an output" key))) "\n"
                                 (harness-json-encode-text (list :ts 2 :note "unrelated")) "\n")))
           (state-json (harness-redact-e2e--write
                        (expand-file-name "x.json" state)
                        (concat (harness-json-encode-text (list :note id :other "unrelated")) "\n")))
           (state-text (harness-redact-e2e--write
                        (expand-file-name "x.txt" state) (format "scratch: %s\n" key)))
           (project (harness-tasks--project (progn (make-directory (expand-file-name "app/" state) t)
                                                   (expand-file-name "app/" state))))
           (task-id "t-e2e-0001"))
      ;; The harness log: a line from before the secret was masked.
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "12:00:00.000 INFO  bash printed %s earlier\n" key))))
      ;; A task, with the report it handed in.
      (harness-tasks--put (append
                           (list :id task-id :project project :cwd project :state 'review :created 1.0)
                           (and (not unlinked) (list :session s))
                           (list :prompt (format "Cut qr over to benito, using %s" key)
                                 :report (list :summary (format "Diffed the states; %s was printed." id)
                                               :problem "none"
                                               :evidence (list (list :kind "code" :language "text"
                                                                     :code (format "key=%s" key)))
                                               :at 5.0))))
      (harness-tasks-flush)
      (harness-session-flush)
      ;; The search index: the logs read, and the embedding of a reply.
      (let ((db (harness-session-search--db)))
        (dolist (sid (list s f)) (harness-session-search--sync db sid))
        (harness-redact-e2e--fake-embeddings db (list s f) (cdr (assq 'reply nodes))))
      (harness-redact-e2e--quiet-index)
      (list :s s :f f :c c :cwd cwd :moved-cwd moved-cwd :outside outside :projects projects
            :state-file state-file :nodes nodes
            :cli cli :cli-old cli-old :cli-other cli-other
            :cli-log cli-log :cli-file cli-file :cli-old-log cli-old-log :cli-other-log cli-other-log
            :cli-other-text (harness-redact-e2e--read cli-other-log)
            :copilot-root copilot-root :copilot-events copilot-events :copilot-summary copilot-summary
            :copilot-orphan copilot-orphan :copilot-clean copilot-clean-file
            :copilot-clean-text (harness-redact-e2e--read copilot-clean-file)
            :transcripts (list written named-s named-f moved-file)
            :spill spill :orphan orphan :tmp-file tmp-file
            :state-files (list state-jsonl state-json state-text)
            :orphan-log orphan-log :orphan-record orphan-record
            :task-id task-id))))

;;;; The census: what each store holds

(defun harness-redact-e2e--census (w)
  "Return how many times the fake secrets occur in each store of the world W.
The value is an alist of (STORE . COUNT).  A store of the index that is not
text -- the vectors and chunks of an embedding -- counts its rows."
  (let* ((s (plist-get w :s))
         (f (plist-get w :f))
         (db (harness-session-search--db))
         (key harness-redact-e2e--secret-key)
         (id harness-redact-e2e--access-key)
         (transcripts (plist-get w :transcripts)))
    (list
     (cons "node log of the session" (harness-redact-e2e--file-count (harness-redact-e2e--log s)))
     (cons "node log of the fork" (harness-redact-e2e--file-count (harness-redact-e2e--log f)))
     (cons "record of the session" (harness-redact-e2e--file-count (harness-redact-e2e--record-file s)))
     (cons "record of the fork" (harness-redact-e2e--file-count (harness-redact-e2e--record-file f)))
     (cons "nodes and record of the session in memory" (harness-redact-e2e--text-count (harness-redact-e2e--memory s)))
     (cons "nodes and record of the fork in memory" (harness-redact-e2e--text-count (harness-redact-e2e--memory f)))
     (cons "search index files"
           (cl-loop for file in (harness-session-search--files) sum (harness-redact-e2e--file-count file)))
     (cons "search index rows"
           (caar (sqlite-select db "SELECT count(*) FROM nodes WHERE instr(text, ?) > 0 OR instr(text, ?) > 0"
                                (list key id))))
     (cons "search index vectors and chunks"
           (+ (caar (sqlite-select db "SELECT count(*) FROM chunks"))
              (caar (sqlite-select db "SELECT count(*) FROM vectors"))))
     (cons "Claude Code log of the conversation" (harness-redact-e2e--file-count (plist-get w :cli-log)))
     (cons "Claude Code file of the conversation" (harness-redact-e2e--file-count (plist-get w :cli-file)))
     (cons "Claude Code log a checkpoint names" (harness-redact-e2e--file-count (plist-get w :cli-old-log)))
     (cons "Copilot events of the session" (harness-redact-e2e--file-count (plist-get w :copilot-events)))
     (cons "Copilot summary of the session" (harness-redact-e2e--file-count (plist-get w :copilot-summary)))
     (cons "Copilot state no session owns" (harness-redact-e2e--file-count (plist-get w :copilot-orphan)))
     (cons "transcript the harness wrote" (harness-redact-e2e--file-count (nth 0 transcripts)))
     (cons "transcript named for the session" (harness-redact-e2e--file-count (nth 1 transcripts)))
     (cons "transcript named for the fork" (harness-redact-e2e--file-count (nth 2 transcripts)))
     (cons "transcript a compaction names" (harness-redact-e2e--file-count (nth 3 transcripts)))
     (cons "spill file a node names" (harness-redact-e2e--file-count (plist-get w :spill)))
     (cons "spill file no node names" (harness-redact-e2e--file-count (plist-get w :orphan)))
     (cons "temporary file of the session" (harness-redact-e2e--file-count (plist-get w :tmp-file)))
     (cons "harness log" (harness-redact-e2e--text-count
                          (with-current-buffer (get-buffer-create harness-log-buffer-name) (buffer-string))))
     (cons "task record in memory"
           (harness-redact-e2e--text-count (gethash (plist-get w :task-id) harness-tasks--table)))
     (cons "task store" (harness-redact-e2e--file-count (expand-file-name "tasks.json" harness-state-directory)))
     (cons "state file, JSON lines" (harness-redact-e2e--file-count (nth 0 (plist-get w :state-files))))
     (cons "state file, JSON" (harness-redact-e2e--file-count (nth 1 (plist-get w :state-files))))
     (cons "state file, text" (harness-redact-e2e--file-count (nth 2 (plist-get w :state-files))))
     (cons "node log no session owns" (harness-redact-e2e--file-count (plist-get w :orphan-log)))
     (cons "record no session owns" (harness-redact-e2e--file-count (plist-get w :orphan-record))))))

(defun harness-redact-e2e--roots (w)
  "Return the directories under which a file may hold a copy: where the harness writes.
They are the state directory, the CLIs' state directories, the
`.harness' directories of the sessions' directories and the temporary
directory of the session."
  (list harness-state-directory
        (plist-get w :projects)
        (plist-get w :copilot-root)
        (expand-file-name ".harness" (plist-get w :cwd))
        (expand-file-name ".harness" (plist-get w :moved-cwd))
        (harness-call 'session/tmp-dir (plist-get w :s))))

(defun harness-redact-e2e--holders (w)
  "Return the files of the places the harness writes that still hold a fake secret."
  (cl-loop for root in (harness-redact-e2e--roots w)
           append (mapcar (lambda (file) (expand-file-name file root))
                          (harness-redact-e2e--tree-holders root))))

(defun harness-redact-e2e--private-files (w)
  "Return the files of the world W whose modes a rewrite has to keep, most of them private.
They are the node log of a session, a conversation log of the Claude Code CLI
and a file it saved, the events of the Copilot CLI, a transcript, a file of
cut output and a state file.  The record of a session is the store's: it
is written again, with the usual modes, whenever it is saved."
  (list (harness-redact-e2e--log (plist-get w :s))
        (plist-get w :cli-log) (plist-get w :cli-file) (plist-get w :copilot-events)
        (nth 1 (plist-get w :transcripts)) (plist-get w :spill)
        (nth 2 (plist-get w :state-files))))

(defun harness-redact-e2e--modes (files)
  "Return an alist of (FILE . MODES) for FILES."
  (mapcar (lambda (file) (cons file (file-modes file))) files))

(defun harness-redact-e2e--empty (census)
  "Return the stores of CENSUS, an alist of (STORE . COUNT), that hold nothing."
  (mapcar #'car (cl-remove-if (lambda (cell) (> (cdr cell) 0)) census)))

(defun harness-redact-e2e--full (census)
  "Return the stores of CENSUS, an alist of (STORE . COUNT), that hold something."
  (mapcar #'car (cl-remove-if (lambda (cell) (= (cdr cell) 0)) census)))

(defun harness-redact-e2e--source (w &rest more)
  "Return the parameters of a request that names the secret by the state file of W.
MORE are more parameters."
  (append (list :source (list :file (plist-get w :state-file) :json-path "outputs.creds.value"))
          more))

(defun harness-redact-e2e--redact (w &rest more)
  "Redact the secret of the world W from every session, as the user; return the report.
MORE are more parameters, or replace those of the request."
  (harness-call 'secrets/redact
                (append more
                        (harness-redact-e2e--source w :scope 'all :mode 'redact
                                                     :origin '(:kind user) :reason "test"))))

(defun harness-redact-e2e--search-total (query &optional mode)
  "Return how many sessions the search for QUERY finds, in MODE (text by default).
It is the search a person makes of the transcripts."
  (plist-get (harness-test-await
              (harness-call 'session/search query (and mode (list :mode mode))))
             :total))

;;;; Redaction by reference leaves no copy in any store

(ert-deftest harness-redact-e2e-redaction-by-reference-leaves-no-copy-in-any-store ()
  "The secret is read from a file, never given, and no store keeps a copy of it."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (s (plist-get w :s))
           (f (plist-get w :f))
           (c (plist-get w :c))
           (source-before (harness-redact-e2e--read (plist-get w :state-file)))
           (before (harness-redact-e2e--census w))
           ;; Each kind of file has modes of its own, none of them what the umask would give.
           (modes (cl-loop for file in (harness-redact-e2e--private-files w)
                           for mode in '(#o600 #o600 #o600 #o600 #o640 #o600 #o660)
                           do (set-file-modes file mode)
                           finally return (harness-redact-e2e--modes (harness-redact-e2e--private-files w)))))
      ;; Every store holds the secret to begin with, and so do the places
      ;; the harness writes: a test that cleaned nothing would not pass.
      (should-not (harness-redact-e2e--empty before))
      (should (cl-find-if (lambda (file) (string-search "search.db" (file-name-nondirectory file)))
                          (harness-redact-e2e--holders w)))
      ;; A search of the transcripts finds the secret ...
      (should (> (harness-redact-e2e--search-total harness-redact-e2e--access-key) 0))
      (should (> (harness-redact-e2e--search-total harness-redact-e2e--secret-key 'literal) 0))
      (let ((report (harness-redact-e2e--redact w)))
        ;; Nothing is left, anywhere: not in a store ...
        (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
        ;; ... and not in any file of the state directory (search.db and its
        ;; write-ahead log among them), of the CLI's projects directory, of the
        ;; sessions' `.harness' directories and of the session's temporary one.
        (should-not (harness-redact-e2e--holders w))
        (dolist (root (harness-redact-e2e--roots w))
          (should (= 0 (harness-redact-e2e--tree-count root))))
        (dolist (file (list "search.db" "search.db-wal" "search.db-shm"))
          (should (= 0 (harness-redact-e2e--file-count (expand-file-name file harness-state-directory)))))
        (should (= 0 (harness-redact-e2e--tree-count (expand-file-name "outputs" harness-state-directory))))
        (should (= 0 (harness-redact-e2e--tree-count (expand-file-name ".harness" (plist-get w :cwd)))))
        ;; The request was complete, and says so.
        (should (eq 'redact (plist-get report :mode)))
        (should (plist-get report :complete))
        (should-not (plist-get report :errors))
        (should-not (plist-get report :remaining))
        (should (plist-get (plist-get report :verification) :ok))
        (should (= 0 (plist-get (plist-get report :verification) :total)))
        ;; The sessions, with something found in each: the Copilot one held the secret
        ;; in the state of its CLI only.
        (should (equal (sort (list s f c) #'string<)
                       (sort (mapcar (lambda (e) (plist-get e :id)) (plist-get report :sessions)) #'string<)))
        ;; Every store that is not a session's found a copy.
        (dolist (name '("search index" "Claude Code logs" "Copilot logs" "task records" "transcript files"
                        "spill files" "session temp files" "state files" "log buffers"))
          (let ((store (cl-find name (plist-get report :stores)
                                :key (lambda (st) (plist-get st :store)) :test #'equal)))
            (should store)
            (should (> (or (plist-get store :count) (plist-get store :rows) 0) 0))))
        ;; The report, and what the engine wrote about it, hold no value.
        (should (= 0 (harness-redact-e2e--text-count (plist-get report :text))))
        (should (= 0 (harness-redact-e2e--text-count report)))
        (should (string-search (format "sha256:%s" (harness-redact-e2e--fp 0)) (plist-get report :text)))
        (should (string-search (format "sha256:%s" (harness-redact-e2e--fp 1)) (plist-get report :text)))
        (let ((log-file (expand-file-name "redactions.jsonl" harness-state-directory)))
          (should (file-regular-p log-file))
          (should (= 0 (harness-redact-e2e--file-count log-file)))
          (let ((runs (harness-call 'secrets/log)))
            (should (= 1 (length runs)))
            (should (equal "user" (plist-get (plist-get (car runs) :origin) :kind)))
            (should (equal (sort (list (harness-redact-e2e--fp 0) (harness-redact-e2e--fp 1)) #'string<)
                           (sort (mapcar (lambda (e) (plist-get e :fingerprint))
                                         (plist-get (car runs) :secrets))
                                 #'string<)))
            (should (= 0 (harness-redact-e2e--text-count (car runs)))))))
      ;; ... and no longer, though the sessions are in it, with the placeholders.
      (should (= 0 (harness-redact-e2e--search-total harness-redact-e2e--access-key)))
      (should (= 0 (harness-redact-e2e--search-total harness-redact-e2e--secret-key 'literal)))
      (should (> (harness-redact-e2e--search-total "redacted") 0))
      ;; A rewrite keeps the modes of a file: a conversation made private is not made public.
      (should (equal modes (harness-redact-e2e--modes (harness-redact-e2e--private-files w))))
      ;; The text around a secret is as it was, whatever it is made of: a node and a line of the
      ;; CLI's log hold characters beyond ASCII next to one.
      (let ((thinking (cl-find (cdr (assq 'thinking (plist-get w :nodes))) (harness-call 'session/nodes s)
                               :key (lambda (n) (plist-get n :id)) :test #'equal)))
        (should (equal (format "The output printed the access key %s \u2014 \u00ab cl\u00e9 \u00bb \u5bc6\u94a5 \U0001F511; I must not repeat it."
                               (harness-redact-e2e--placeholder 1))
                       (plist-get thinking :content))))
      (should (equal (format "keep the key %s in mind \u2014 cl\u00e9 \U0001F511" (harness-redact-e2e--placeholder 0))
                     (plist-get (plist-get (harness-json-parse
                                            (car (split-string (harness-redact-e2e--read (plist-get w :cli-log)) "\n" t)))
                                           :message)
                                :content)))
      ;; The placeholder stands where each secret was.
      (let ((log (harness-redact-e2e--read (harness-redact-e2e--log s))))
        (should (string-search (harness-redact-e2e--placeholder 0) log))
        (should (string-search (harness-redact-e2e--placeholder 1) log)))
      (should (string-search (harness-redact-e2e--placeholder 0)
                             (harness-redact-e2e--read (plist-get w :cli-old-log))))
      (should (string-search (harness-redact-e2e--placeholder 1)
                             (harness-redact-e2e--read (plist-get w :cli-file))))
      ;; The session: a hint in its transcript, and a record in its `ext' with
      ;; both fingerprints and no value; its provider conversation starts over.
      (let ((hint (cl-find-if (lambda (h) (string-prefix-p "Redacted " h)) (harness-redact-e2e--hints s)))
            (records (harness-redact-e2e--redactions s)))
        (should hint)
        (should (string-search (format "sha256:%s" (harness-redact-e2e--fp 0)) hint))
        (should (string-search (format "sha256:%s" (harness-redact-e2e--fp 1)) hint))
        (should (= 0 (harness-redact-e2e--text-count hint)))
        (should (= 1 (length records)))
        (let ((record (car records)))
          (should (equal "user" (plist-get record :by)))
          (should (equal "test" (plist-get record :reason)))
          (should (equal (sort (list (harness-redact-e2e--fp 0) (harness-redact-e2e--fp 1)) #'string<)
                         (sort (mapcar (lambda (e) (plist-get e :fingerprint)) (plist-get record :secrets))
                               #'string<)))
          (should (member (harness-redact-e2e--log s) (plist-get record :files)))
          (should (member (plist-get w :cli-log) (plist-get record :files)))
          (should (> (plist-get (plist-get record :counts) :log) 0))
          (should (> (plist-get (plist-get record :counts) :cli) 0))
          (should (> (plist-get (plist-get record :counts) :search) 0))
          (should (equal "reset" (plist-get record :provider)))
          (should (= 0 (harness-redact-e2e--text-count record)))
          ;; When, and what was changed: the nodes and the fields of them, the slots of the record.
          (should (< (abs (- (float-time) (plist-get record :ts))) 300))
          (dolist (kind '(user thinking call result cut streamed reply))
            (should (member (cdr (assq kind (plist-get w :nodes))) (plist-get record :nodes))))
          (dolist (node-id (plist-get record :nodes))
            (should (member node-id (harness-redact-e2e--log-ids s))))
          (dolist (field '("content" "input" "output"))
            (should (member field (plist-get record :fields))))
          (should (equal '("ext" "name" "plan" "queue" "todos") (plist-get record :record-fields)))
          ;; Where the secrets were read from, by file and path, and how many were found of each.
          (dolist (entry (plist-get record :secrets))
            (should (string-search "terraform.tfstate" (plist-get entry :source)))
            (should (string-search "outputs.creds.value" (plist-get entry :source)))
            (should (> (plist-get entry :count) 0)))
          (should (equal '("outputs.creds.value.access_key" "outputs.creds.value.secret_key")
                         (harness-redact-e2e--sorted (mapcar (lambda (e) (plist-get e :label))
                                                             (plist-get record :secrets)))))
          (dolist (key '(:memory :record :transcripts :spill :temp))
            (should (> (plist-get (plist-get record :counts) key) 0)))))
      (should (= 1 (length (harness-redact-e2e--redactions f))))
      (should-not (harness-redact-e2e--provider-state s))
      (should-not (harness-redact-e2e--provider-state f))
      ;; The Copilot session: nothing in its transcript, so its record counts none there; the
      ;; state of its CLI held the secret, so its conversation starts over all the same.
      (let ((record (car (harness-redact-e2e--redactions c)))
            (hint (cl-find-if (lambda (h) (string-prefix-p "Redacted " h)) (harness-redact-e2e--hints c))))
        (should-not (harness-redact-e2e--provider-state c))
        (should (= 1 (length (harness-redact-e2e--redactions c))))
        (should (equal "reset" (plist-get record :provider)))
        (should (= 0 (plist-get (plist-get record :counts) :log)))
        (should (> (plist-get (plist-get record :counts) :cli) 0))
        (should (member (plist-get w :copilot-events) (plist-get record :files)))
        (should (member (plist-get w :copilot-summary) (plist-get record :files)))
        (should-not (member (plist-get w :copilot-orphan) (plist-get record :files)))
        (should hint)
        (should (string-search "in the Copilot log" hint))
        (should (= 0 (harness-redact-e2e--text-count (list record hint)))))
      ;; Nothing leads back to the old conversation of the CLI: no node keeps the checkpoint
      ;; of it, in memory or in the log, so the next turn, at the head or at an earlier node,
      ;; starts a conversation from the redacted transcript.
      (dolist (sid (list s f))
        (should-not (cl-some (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes sid)))
        (should-not (string-search "cli-session-id" (harness-redact-e2e--read (harness-redact-e2e--log sid))))
        (should-not (eq 'checkpoint (plist-get (harness-call 'session/provider-continuation sid) :mode))))
      (should (eq 'fresh (plist-get (harness-call 'session/provider-continuation s (cdr (assq 'call (plist-get w :nodes))))
                                    :mode)))
      ;; A restart would find the transcripts as the sessions hold them.
      (dolist (sid (list s f))
        (harness-redact-e2e--check-replay sid))
      ;; What holds no secret is as it was: a conversation of the CLI about
      ;; something else, and the file the secret was read from.
      (should (equal (plist-get w :cli-other-text) (harness-redact-e2e--read (plist-get w :cli-other-log))))
      (should (equal (plist-get w :copilot-clean-text) (harness-redact-e2e--read (plist-get w :copilot-clean))))
      (should (equal source-before (harness-redact-e2e--read (plist-get w :state-file))))
      (should (> (harness-redact-e2e--file-count (plist-get w :state-file)) 0))
      ;; Asked again, a redaction finds nothing, records nothing more and says it is done.
      (let ((second (harness-redact-e2e--redact w)))
        (should (plist-get second :complete))
        (should (= 0 (plist-get second :total)))
        (should-not (plist-get second :sessions)))
      (dolist (sid (list s f c))
        (should (= 1 (length (harness-redact-e2e--redactions sid)))))
      (should (= 1 (cl-count-if (lambda (h) (string-prefix-p "Redacted " h)) (harness-redact-e2e--hints s))))
      (should (= 2 (length (harness-call 'secrets/log))))
      (should (= 0 (harness-redact-e2e--file-count (expand-file-name "redactions.jsonl" harness-state-directory))))
      ;; Looked for again, the secret is nowhere.
      (let ((again (harness-call 'secrets/redact
                                 (harness-redact-e2e--source w :scope 'all))))
        (should (eq 'scan (plist-get again :mode)))
        (should (= 0 (plist-get again :total)))
        (should-not (plist-get again :sessions))))))

;;;; Turns of the agent, and the bus

(defun harness-redact-e2e--session (cwd name)
  "Create a session called NAME in CWD on the demo provider; return its id."
  (plist-get (harness-call 'session/create :cwd cwd :name name :model "demo:scripted") :id))

(defun harness-redact-e2e--turn (sid script &optional text)
  "Run a turn of session SID in which the demo provider plays SCRIPT; return its result.
SCRIPT is a list of events, or a function of the request that returns
one.  TEXT is what the user says to start the turn."
  (let ((harness-provider-demo-script-override script))
    (harness-test-await (harness-call 'agent/prompt sid (or text "go")) 60)))

(defun harness-redact-e2e--nodes-of (sid kind)
  "Return the nodes of KIND in the transcript of session SID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(defun harness-redact-e2e--summary (result)
  "Return what the tool RESULT node keeps of the report: its `:redaction' meta."
  (plist-get (plist-get result :meta) :redaction))

(defun harness-redact-e2e--sorted (list)
  "Return a sorted copy of LIST, a list of strings."
  (sort (copy-sequence list) #'string<))

(defun harness-redact-e2e--printed (object)
  "Return OBJECT printed as text, its strings as they are."
  (let ((print-circle t) (print-length nil) (print-level nil))
    (prin1-to-string object t)))

(defvar harness-redact-e2e--tapped nil
  "The events that carried a fake secret since the tap was set, (EVENT . COUNT), newest first.")

(defvar harness-redact-e2e--tapped-total 0
  "How many events the tap saw since it was set, with a secret or without.")

(defun harness-redact-e2e--tap (event args)
  "Note EVENT, emitted with ARGS, in `harness-redact-e2e--tapped' when it carries a fake secret."
  (cl-incf harness-redact-e2e--tapped-total)
  (let ((n (harness-redact-e2e--text-count (harness-redact-e2e--printed args))))
    (when (> n 0)
      (push (cons event n) harness-redact-e2e--tapped))))

(defmacro harness-redact-e2e-tapping (&rest body)
  "Run BODY with every event of the bus looked at for the fake secrets.
The events that carry one are noted in `harness-redact-e2e--tapped'."
  (declare (indent 0))
  `(let ((harness-redact-e2e--tapped nil)
         (harness-redact-e2e--tapped-total 0))
     (let ((handle (harness-on '* #'harness-redact-e2e--tap)))
       (unwind-protect (progn ,@body)
         (harness-off handle)))))

;;;; The tool's own call and result

(ert-deftest harness-redact-e2e-the-tools-own-call-and-result-hold-no-secret ()
  "An agent redacts through redact_secret, and nothing it stores or the bus carries holds a secret.
The session looks at the shape of the state file and scans, in one turn
of the agent; then redacts and scans again in another.  The calls name
the file and the path, the results are counts, ids, labels and
fingerprints; the node log, the record and the memory of the redacting
session never held a copy, and every store of the world is clean."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (s (plist-get w :s))
           (f (plist-get w :f))
           (c (plist-get w :c))
           (a (harness-redact-e2e--session (plist-get w :outside) "The redactor"))
           (ref (list :file "terraform.tfstate" :json_path "outputs.creds.value"))
           (reason "A diff printed the keys.")
           (census (harness-redact-e2e--census w))
           (s-log (harness-redact-e2e--read (harness-redact-e2e--log s))))
      (should-not (harness-redact-e2e--empty census))
      (harness-redact-e2e-tapping
        ;; Looking: the shape of the file, then a scan.  Neither changes a store.
        (harness-redact-e2e--turn
         a `((:type tool-call :id "shape-1" :name "redact_secret"
                    :input (:mode "shape" :source (:file "terraform.tfstate")))
             (:type tool-call :id "scan-1" :name "redact_secret"
                    :input (:mode "scan" :source ,ref :scope "all"))
             (:type text :delta "It is in three sessions.")
             (:type done :stop-reason end-turn)))
        (let ((results (harness-redact-e2e--nodes-of a 'tool-result)))
          (should (= 2 (length results)))
          (dolist (r results) (should-not (plist-get r :is-error)))
          ;; The shape is paths and types.
          (should (string-search "outputs.creds.value.secret_key" (plist-get (nth 0 results) :output)))
          (should (string-search "string" (plist-get (nth 0 results) :output)))
          ;; The scan is sessions, ids and counts.
          (let ((summary (harness-redact-e2e--summary (nth 1 results))))
            (should (equal "scan" (plist-get summary :mode)))
            (should (> (plist-get summary :total) 0))
            (should (eq :false (plist-get summary :complete)))
            (should (equal (harness-redact-e2e--sorted (list s f c))
                           (harness-redact-e2e--sorted (plist-get summary :sessions))))))
        (should (equal census (harness-redact-e2e--census w)))
        (should (equal s-log (harness-redact-e2e--read (harness-redact-e2e--log s))))
        ;; Acting: the redaction, then a scan that finds nothing.
        (harness-redact-e2e--turn
         a `((:type tool-call :id "redact-1" :name "redact_secret"
                    :input (:mode "redact" :source ,ref :scope "all" :reason ,reason))
             (:type tool-call :id "scan-2" :name "redact_secret"
                    :input (:mode "scan" :source ,ref :scope "all"))
             (:type text :delta "The keys are out of every store.")
             (:type done :stop-reason end-turn)))
        (let* ((results (harness-redact-e2e--nodes-of a 'tool-result))
               (done (nth 2 results))
               (summary (harness-redact-e2e--summary done)))
          (should (= 4 (length results)))
          (dolist (r results) (should-not (plist-get r :is-error)))
          (should (eq t (plist-get summary :complete)))
          (should (= 0 (plist-get summary :errors)))
          (should (= 0 (plist-get summary :remaining)))
          (should (equal (harness-redact-e2e--sorted (list s f c))
                         (harness-redact-e2e--sorted (plist-get summary :sessions))))
          (should (equal '("outputs.creds.value.access_key" "outputs.creds.value.secret_key")
                         (harness-redact-e2e--sorted
                          (mapcar (lambda (e) (plist-get e :label)) (plist-get summary :secrets)))))
          (dolist (i '(0 1))
            (should (string-search (format "sha256:%s" (harness-redact-e2e--fp i)) (plist-get done :output))))
          (should (string-search "cannot recall what the model provider already received"
                                 (plist-get done :output)))
          ;; The scan after it finds no copy.
          (let ((again (harness-redact-e2e--summary (nth 3 results))))
            (should (= 0 (plist-get again :total)))
            (should-not (plist-get again :sessions))))
        ;; The calls named where the secret is, and nothing else.
        (let ((calls (harness-redact-e2e--nodes-of a 'tool-call)))
          (should (= 4 (length calls)))
          (should (equal (list :mode "redact" :source ref :scope "all" :reason reason)
                         (plist-get (nth 2 calls) :input)))
          (should (equal (list :mode "shape" :source (list :file "terraform.tfstate"))
                         (plist-get (nth 0 calls) :input))))
        ;; The redacting session never held a copy: not in its calls and results,
        ;; its node log, its record, its memory or the index.
        (harness-session-flush)
        (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--memory a))))
        (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log a))))
        (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--record-file a))))
        (should (> (length (harness-redact-e2e--log-ids a)) 8))
        (dolist (sid (list a s f c))
          (harness-redact-e2e--check-replay sid))
        (should-not (harness-redact-e2e--redactions a))
        (should-not (harness-redact-e2e--hints a))
        ;; The sessions it redacted say who asked, and why.
        (dolist (sid (list s f c))
          (let ((record (car (harness-redact-e2e--redactions sid))))
            (should (equal (format "session %s" (substring a 0 8)) (plist-get record :by)))
            (should (equal reason (plist-get record :reason)))))
        ;; Every store of the world is clean.
        (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
        (should-not (harness-redact-e2e--holders w))
        ;; And nothing the bus carried meanwhile held a copy.
        (should (> harness-redact-e2e--tapped-total 20))
        (should-not harness-redact-e2e--tapped)))))

;;;; A running session

(ert-deftest harness-redact-e2e-a-running-session-loses-no-append-and-is-finished-when-its-turn-ends ()
  "A session in a turn is cleaned at once, its provider is reset when the turn ends.
The turn is a stand-in here: `agent/running' says the session runs, and
the end of the turn is announced by hand; the tests that follow run real
turns of the agent.  The node log is rewritten whole, with every node it
had and no torn line; the CLI's log, which a process may be writing, is
left as it is, and so is the provider conversation.  What the turn writes
next -- the secret echoed -- is appended to the new log, and taken out
when the turn ends, as the provider is reset and the CLI's log cleaned."
  (harness-redact-e2e-with
    (let ((running nil))
      (harness-register-method 'agent/running
                               (lambda (&optional sid) (if sid (and (member sid running) t) running)))
      (let* ((w (harness-redact-e2e--world t))
             (s (plist-get w :s))
             (f (plist-get w :f))
             (key harness-redact-e2e--secret-key)
             (id harness-redact-e2e--access-key)
             (ids-before (harness-redact-e2e--log-ids s))
             (cli-before (mapcar #'harness-redact-e2e--read
                                 (list (plist-get w :cli-log) (plist-get w :cli-file)))))
        (push s running)
        (let ((report (harness-redact-e2e--redact w :reason "leaked in a diff")))
          ;; The session waits for its turn; the request says so, and is not done.
          (should (equal (list s) (plist-get report :deferred)))
          (should-not (plist-get report :complete))
          (should-not (plist-get report :errors))
          (should (string-search "Waiting for a running turn" (plist-get report :text)))
          (should (= 0 (harness-redact-e2e--text-count report))))
        ;; Its stores are clean at once: the log, the nodes in memory, the record, the index ...
        (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log s))))
        (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--record-file s))))
        (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--memory s))))
        ;; ... and the log lost no node and is whole: every line is JSON and it ends in a newline,
        ;; and a restart would load the transcript the session holds.
        (let ((ids (harness-redact-e2e--log-ids s)))
          (dolist (node-id ids-before) (should (member node-id ids)))
          (should (> (length ids) (length ids-before))))
        (harness-redact-e2e--check-replay s)
        ;; The CLI's files that a process of the session may be writing are as they were,
        ;; and so is the conversation, with a flag that says why, by label and fingerprint.
        (should (equal cli-before (mapcar #'harness-redact-e2e--read
                                          (list (plist-get w :cli-log) (plist-get w :cli-file)))))
        (should (harness-redact-e2e--provider-state s))
        (let ((flag (plist-get (plist-get (harness-call 'session/get s) :ext) :redaction-pending)))
          (should (equal (harness-redact-e2e--sorted (list (harness-redact-e2e--fp 0) (harness-redact-e2e--fp 1)))
                         (harness-redact-e2e--sorted (mapcar (lambda (k) (plist-get k :fingerprint)) flag))))
          (should (= 0 (harness-redact-e2e--text-count flag))))
        (should (= 1 (length (gethash s harness-redact--pending))))
        (should (equal "deferred" (plist-get (car (harness-redact-e2e--redactions s)) :provider)))
        (should (string-search "once the turn ends" (car (last (harness-redact-e2e--hints s)))))
        ;; The fork does not run: it is done, with its conversation reset.
        (should-not (harness-redact-e2e--provider-state f))
        (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log f))))
        ;; All that is left is what a live process of the session writes into.
        (should (equal (harness-redact-e2e--sorted '("Claude Code log of the conversation"
                                                     "Claude Code file of the conversation"))
                       (harness-redact-e2e--sorted (harness-redact-e2e--full (harness-redact-e2e--census w)))))
        ;; The turn goes on: the model says the secret again, in a new reply that it then extends.
        (let* ((lines-before (length (harness-redact-e2e--log-lines s)))
               (echo (harness-redact-e2e--add
                      s (list :kind 'assistant :content (format "The key is %s." key)))))
          (harness-call 'session/update-node s echo
                        :content (format "The key is %s and the id %s." key id))
          (should (> (harness-redact-e2e--file-count (harness-redact-e2e--log s)) 0))
          (should (= (+ 2 lines-before) (length (harness-redact-e2e--log-lines s))))
          (should (member echo (harness-redact-e2e--log-ids s)))
          ;; The turn ends: what it wrote is taken out, and the conversation starts over.
          (setq running nil)
          (harness-emit 'agent/turn-ended s 'end-turn)
          (should (= 0 (hash-table-count harness-redact--pending)))
          (should-not (plist-get (plist-get (harness-call 'session/get s) :ext) :redaction-pending))
          (should-not (harness-redact-e2e--provider-state s))
          (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log s))))
          (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--memory s))))
          (let ((ids (harness-redact-e2e--log-ids s)))
            (dolist (node-id ids-before) (should (member node-id ids)))
            (should (member echo ids)))
          (harness-redact-e2e--check-replay s)
          (should (string-search (harness-redact-e2e--placeholder 0)
                                 (plist-get (cl-find echo (harness-call 'session/nodes s)
                                                     :key (lambda (n) (plist-get n :id)) :test #'equal)
                                            :content))))
        ;; Two records now, the second saying when, and a hint for each.
        (let ((records (harness-redact-e2e--redactions s)))
          (should (= 2 (length records)))
          (should-not (plist-get (car records) :after-turn))
          (should (plist-get (cadr records) :after-turn))
          (should (equal "reset" (plist-get (cadr records) :provider)))
          (should (equal "leaked in a diff" (plist-get (cadr records) :reason)))
          (should (= 0 (harness-redact-e2e--text-count records))))
        (should (string-search "after its turn ended" (car (last (harness-redact-e2e--hints s)))))
        (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--hints s))))
        ;; The CLI's files are clean now, and every store of the world.
        (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
        (should-not (harness-redact-e2e--holders w))))))

;;;; A turn of the agent that runs while the redaction does

(defun harness-redact-e2e--live-session (w &optional cwd)
  "Create a session on the demo provider that holds the fake secrets, in the world W.
Like a hosted session, it names a conversation of the CLI, whose log is in
the projects directory and holds the secret; its transcript holds them in
a message and in the output of a call, and the search index has read it.
The turn the tests run in it is the agent's own.  The session works in
CWD, the directory of the world by default.  Return (:id ID :cli-log FILE)."
  (let* ((key harness-redact-e2e--secret-key)
         (id harness-redact-e2e--access-key)
         (cli (concat "cli-" (harness-redact-e2e--chars 10)))
         (log (harness-redact-e2e--write
               (expand-file-name (concat cli ".jsonl") (expand-file-name "-home-test-qr/" (plist-get w :projects)))
               (concat (harness-redact-e2e--cli-line "user" (format "the key is %s" key)) "\n")
               3600))
         (l (harness-redact-e2e--session (or cwd (plist-get w :cwd)) "The live one")))
    (harness-redact-e2e--add l (list :kind 'user :content (format "Here is the key: %s" key)))
    (harness-redact-e2e--add l (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run: terraform output"
                                     :input (list :command "terraform output")))
    (harness-redact-e2e--add l (list :kind 'tool-result :call-id "c1" :output (format "access_key = %s" id)))
    (let ((head (harness-redact-e2e--add l (list :kind 'assistant :content "I have it."))))
      (harness-call 'session/set-provider-state l (list :cli-session-id cli))
      (harness-call 'session/set-provider-node l head))
    (harness-session-flush)
    (harness-session-search--sync (harness-session-search--db) l)
    (harness-redact-e2e--quiet-index)
    (list :id l :cli-log log)))

(defun harness-redact-e2e--check-finished (w l)
  "Check that session L, whose turn ended after a redaction waited for it, is clean.
W is the world.  The provider conversation starts over, nothing waits, the
redaction was recorded twice -- during the turn, and after it -- and no
store of the world keeps a copy."
  (should-not (harness-redact-e2e--provider-state l))
  (should-not (plist-get (harness-call 'session/get l) :provider-node))
  (should-not (plist-get (plist-get (harness-call 'session/get l) :ext) :redaction-pending))
  (should (= 0 (hash-table-count harness-redact--pending)))
  (let ((records (harness-redact-e2e--redactions l)))
    (should (= 2 (length records)))
    (should (equal "deferred" (plist-get (car records) :provider)))
    (should-not (plist-get (car records) :after-turn))
    (should (plist-get (cadr records) :after-turn))
    (should (equal "reset" (plist-get (cadr records) :provider)))
    (should (= 0 (harness-redact-e2e--text-count records))))
  (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--memory l))))
  (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--hints l))))
  (harness-redact-e2e--check-replay l)
  (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
  (should-not (harness-redact-e2e--holders w)))

(ert-deftest harness-redact-e2e-a-reply-that-streams-during-the-redaction-ends-clean ()
  "A reply the model is streaming keeps what comes after the redaction, and loses the secret.
The redaction lands between two chunks of the reply.  The turn's own
buffer of the reply holds the secret and writes it back with the next
chunk; the redaction goes over the session again when the turn ends, and
the reply is the text it would have been, with the placeholder where the
secret was."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world t))
           (live (harness-redact-e2e--live-session w))
           (l (plist-get live :id))
           (id harness-redact-e2e--access-key)
           (log-before (harness-redact-e2e--log-ids l))
           (report nil) (inside nil)
           (harness-provider-demo-script-override
            `((:type text :delta ,(format "The id %s is the one." id))
              (:type text :delta " Nothing else to say.")
              (:type done :stop-reason end-turn)))
           ;; The first chunk of the reply has been written when the stream is announced:
           ;; the redaction runs there, the second chunk comes after it.
           (handle (harness-on 'agent/stream
                               (lambda (sid &rest _)
                                 (when (and (equal sid l) (null report))
                                   (should (harness-call 'agent/running l))
                                   (setq report (harness-redact-e2e--redact w :reason "leaked while it streamed"))
                                   (setq inside
                                         (list :log (harness-redact-e2e--file-count (harness-redact-e2e--log l))
                                               :memory (harness-redact-e2e--text-count (harness-redact-e2e--memory l))
                                               :cli (harness-redact-e2e--file-count (plist-get live :cli-log)))))))))
      (unwind-protect (harness-test-await (harness-call 'agent/prompt l "go") 30)
        (harness-off handle))
      ;; The redaction found the session mid-turn: clean at once, its conversation kept for the turn.
      (should (equal (list l) (plist-get report :deferred)))
      (should-not (plist-get report :complete))
      (should (= 0 (plist-get inside :log)))
      (should (= 0 (plist-get inside :memory)))
      (should (> (plist-get inside :cli) 0))
      ;; The turn went on and ended: the reply is whole, the secret is not in it.
      (let ((reply (harness-redact-e2e--last-assistant l)))
        (should (equal (format "The id %s is the one. Nothing else to say." (harness-redact-e2e--placeholder 1))
                       reply)))
      (let ((ids (harness-redact-e2e--log-ids l)))
        (dolist (node-id log-before) (should (member node-id ids))))
      (should (= 0 (harness-redact-e2e--file-count (plist-get live :cli-log))))
      (harness-redact-e2e--check-finished w l))))

(ert-deftest harness-redact-e2e-tool-output-is-masked-while-a-redaction-waits ()
  "While a session's redaction waits for its turn, what a tool prints is masked before it is stored or sent.
A tool prints both secrets after the redaction: the result in the
transcript and the request the model gets next hold placeholders.  The
first request, made before the redaction, held the secret: a redaction
cannot recall what the provider already received."
  (harness-redact-e2e-with
    ;; The tool the test registers goes with its own copy of the registry.
    (let* ((harness-tools (copy-hash-table harness-tools))
           (w (harness-redact-e2e--world t))
           (live (harness-redact-e2e--live-session w))
           (l (plist-get live :id))
           (key harness-redact-e2e--secret-key)
           (id harness-redact-e2e--access-key)
           (gate (harness-make-promise))
           (started nil) (requests nil)
           (harness-provider-demo-script-override
            (lambda (request)
              (push (harness-redact-e2e--printed (plist-get request :messages)) requests)
              '((:type text :delta "Let me run it again.")
                (:type tool-call :id "g1" :name "e2e_gate" :input nil)
                (:type text :delta "Done.")
                (:type done :stop-reason end-turn)))))
      (harness-define-tool "e2e_gate" :label "Gate" :description "Prints once the test opens it." :kind 'read
                           :handler (lambda (_input _ctx) (setq started t) gate))
      (let ((promise (harness-call 'agent/prompt l "go")))
        (harness-test-wait (lambda () started) 10 "the tool to start")
        ;; The redaction lands while the tool runs.
        (let ((report (harness-redact-e2e--redact w :reason "leaked in a diff")))
          (should (equal (list l) (plist-get report :deferred)))
          (should (= 0 (harness-redact-e2e--text-count (harness-redact-e2e--memory l))))
          (should (> (harness-redact-e2e--file-count (plist-get live :cli-log)) 0)))
        ;; The command prints the secrets again.
        (harness-resolve gate (format "terraform output:\naccess_key = %s\nsecret_key = %s\n" id key))
        (harness-test-await promise 30))
      ;; The transcript has the placeholders, and says what was masked, by label and fingerprint.
      (let* ((result (car (last (harness-redact-e2e--nodes-of l 'tool-result))))
             (hits (plist-get (plist-get result :meta) :masked)))
        (should (equal "g1" (plist-get result :call-id)))
        (should (= 0 (harness-redact-e2e--text-count result)))
        (should (string-search (harness-redact-e2e--placeholder 0) (plist-get result :output)))
        (should (string-search (harness-redact-e2e--placeholder 1) (plist-get result :output)))
        (should (equal (harness-redact-e2e--sorted (list (harness-redact-e2e--fp 0) (harness-redact-e2e--fp 1)))
                       (harness-redact-e2e--sorted (mapcar (lambda (h) (plist-get h :fingerprint)) hits)))))
      ;; The model was sent the redacted history and the masked output; the first request,
      ;; made before the redaction, had the secret in the history.
      (should (= 2 (length requests)))
      (should (> (harness-redact-e2e--text-count (car (last requests))) 0))
      (should (= 0 (harness-redact-e2e--text-count (car requests))))
      (should (string-search (harness-redact-e2e--placeholder 1) (car requests)))
      (harness-redact-e2e--check-finished w l)
      (should (= 0 (harness-redact-e2e--file-count (plist-get live :cli-log)))))))

;;;; Scopes narrower than all

(defconst harness-redact-e2e--outside-a-session-scope
  '("search index files" "search index rows" "Copilot events of the session" "Copilot summary of the session"
    "Copilot state no session owns" "spill file no node names" "task record in memory" "task store"
    "state file, JSON lines" "state file, JSON" "state file, text" "node log no session owns"
    "record no session owns")
  "The stores of the world that a request for a session leaves as they are.
They are the other sessions' (the rows of the index, the state of the
Copilot CLI), and what belongs to no session: the tasks, the spill file no
node names, the other files of the state directory and the files of the
sessions directory that no session owns.")

(ert-deftest harness-redact-e2e-a-request-for-one-session-cleans-it-and-its-fork-and-nothing-else ()
  "A request for a session takes the secret out of it and its fork, and leaves the rest as it is.
The other sessions, the files of the state directory, the tasks and the
rows of the index that are the other sessions' are as they were; the
request is complete for its scope, and says that the files of the index
still hold the secret because the rows of those sessions do.  A request
for every session then finishes the job."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (s (plist-get w :s))
           (f (plist-get w :f))
           (c (plist-get w :c))
           (live (harness-redact-e2e--live-session w))
           (g (plist-get live :id))
           (g-log (harness-redact-e2e--read (harness-redact-e2e--log g)))
           (g-cli (harness-redact-e2e--read (plist-get live :cli-log)))
           (g-state (harness-redact-e2e--provider-state g))
           (c-state (harness-redact-e2e--provider-state c)))
      (should-not (harness-redact-e2e--empty (harness-redact-e2e--census w)))
      (should (= 3 (harness-redact-e2e--search-total harness-redact-e2e--access-key)))
      (let ((report (harness-redact-e2e--redact w :scope 'session :sessions (list s))))
        (should (plist-get report :complete))
        (should-not (plist-get report :errors))
        (should-not (plist-get report :remaining))
        (should (equal (harness-redact-e2e--sorted (list s f))
                       (harness-redact-e2e--sorted (mapcar (lambda (e) (plist-get e :id)) (plist-get report :sessions)))))
        ;; The files of the index hold the secret still, in the rows of the session that was not asked
        ;; about: the verification expects that, and says so.
        (let* ((verification (plist-get report :verification))
               (row (cl-find "search index files" (plist-get verification :stores)
                             :key (lambda (r) (plist-get r :store)) :test #'equal)))
          (should (eq t (plist-get verification :ok)))
          (should (= 0 (plist-get verification :unexplained)))
          (should (> (plist-get row :count) 0))
          (should (= (plist-get row :count) (plist-get row :expected))))
        (should (string-search "rows of sessions outside the scope" (plist-get report :text)))
        (should-not (string-search "NOT everything is clean" (plist-get report :text)))
        (should (= 0 (harness-redact-e2e--text-count report))))
      ;; What belongs to the sessions asked about is clean, their fork's too: node logs, records,
      ;; memory, the CLI's conversation and what it saved, the transcripts, the file of a cut output
      ;; and the scratch file; so is the log of the harness.
      (should (equal (harness-redact-e2e--sorted harness-redact-e2e--outside-a-session-scope)
                     (harness-redact-e2e--sorted (harness-redact-e2e--full (harness-redact-e2e--census w)))))
      (dolist (sid (list s f))
        (harness-redact-e2e--check-replay sid)
        (should-not (harness-redact-e2e--provider-state sid)))
      ;; What does not: another session is as it was, with its conversation, and so is the Copilot one.
      (should (equal g-log (harness-redact-e2e--read (harness-redact-e2e--log g))))
      (should (equal g-cli (harness-redact-e2e--read (plist-get live :cli-log))))
      (should (> (harness-redact-e2e--text-count (harness-redact-e2e--memory g)) 0))
      (should (equal g-state (harness-redact-e2e--provider-state g)))
      (should (equal c-state (harness-redact-e2e--provider-state c)))
      (dolist (sid (list g c))
        (should-not (harness-redact-e2e--redactions sid))
        (should-not (harness-redact-e2e--hints sid)))
      (should (= 1 (harness-redact-e2e--search-total harness-redact-e2e--access-key)))
      ;; A list of sessions, named by an id and by the start of one: the other two, and with
      ;; them the last of the rows of the index that held the secret.
      (let ((listed (harness-redact-e2e--redact w :scope 'session :sessions (list (substring g 0 8) c))))
        (should (plist-get listed :complete))
        (should (equal (harness-redact-e2e--sorted (list g c))
                       (harness-redact-e2e--sorted (mapcar (lambda (e) (plist-get e :id)) (plist-get listed :sessions)))))
        (should (= 0 (plist-get (cl-find "search index files" (plist-get (plist-get listed :verification) :stores)
                                         :key (lambda (r) (plist-get r :store)) :test #'equal)
                                :count))))
      (should (equal (harness-redact-e2e--sorted
                      '("Copilot state no session owns" "spill file no node names" "task record in memory"
                        "task store" "state file, JSON lines" "state file, JSON" "state file, text"
                        "node log no session owns" "record no session owns"))
                     (harness-redact-e2e--sorted (harness-redact-e2e--full (harness-redact-e2e--census w)))))
      (should (= 0 (harness-redact-e2e--search-total harness-redact-e2e--access-key)))
      ;; A request for every session finishes the job: what belongs to no session, and the task
      ;; of the first, whose record holds the secret too.
      (let ((all (harness-redact-e2e--redact w)))
        (should (plist-get all :complete))
        (should (equal (list s)
                       (mapcar (lambda (e) (plist-get e :id)) (plist-get all :sessions)))))
      (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
      (should-not (harness-redact-e2e--holders w))
      (should-not (harness-redact-e2e--provider-state g))
      (should-not (harness-redact-e2e--provider-state c)))))

(ert-deftest harness-redact-e2e-a-fork-left-out-keeps-its-conversation-and-its-transcript ()
  "A fork the request leaves out keeps what it has, and its conversation, until it is asked about.
It shares the conversation of the CLI with the session asked about, which
is cleaned; its own transcript is not, so a new conversation made from
that transcript would send the secret again: its conversation is kept,
and its record says so."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (s (plist-get w :s))
           (f (plist-get w :f))
           (f-log (harness-redact-e2e--read (harness-redact-e2e--log f)))
           (f-transcript (harness-redact-e2e--read (nth 2 (plist-get w :transcripts))))
           (f-state (harness-redact-e2e--provider-state f)))
      (should f-state)
      (let ((report (harness-redact-e2e--redact w :scope 'session :sessions (list s) :include-forks :false)))
        (should (plist-get report :complete))
        (should (string-search "forks left out" (plist-get report :scope)))
        (should (string-search "was left as it is" (plist-get report :text)))
        (should (= 0 (harness-redact-e2e--text-count report))))
      ;; The session is clean and starts over; the conversation they share is clean.
      (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log s))))
      (should-not (harness-redact-e2e--provider-state s))
      (should (= 0 (harness-redact-e2e--file-count (plist-get w :cli-log))))
      ;; The fork has its transcript and its conversation, and a record that says why.  Its log
      ;; was not written again; the hint of the record was added to it.
      (should (string-prefix-p f-log (harness-redact-e2e--read (harness-redact-e2e--log f))))
      (should (> (harness-redact-e2e--file-count (harness-redact-e2e--log f)) 0))
      (should (equal f-transcript (harness-redact-e2e--read (nth 2 (plist-get w :transcripts)))))
      (should (equal f-state (harness-redact-e2e--provider-state f)))
      (let ((record (car (harness-redact-e2e--redactions f)))
            (hint (car (last (harness-redact-e2e--hints f)))))
        (should (equal "kept" (plist-get record :provider)))
        (should (string-search "left as it is" hint))
        (should (= 0 (harness-redact-e2e--text-count (list record hint)))))
      ;; Asked about, it is cleaned and starts over.
      (let ((again (harness-redact-e2e--redact w :scope 'session :sessions (list f))))
        (should (plist-get again :complete)))
      (should-not (harness-redact-e2e--provider-state f))
      (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log f))))
      (should (= 0 (harness-redact-e2e--file-count (nth 2 (plist-get w :transcripts)))))
      (harness-redact-e2e--check-replay f))))

(ert-deftest harness-redact-e2e-a-request-for-a-project-cleans-its-sessions-and-tasks-and-no-other ()
  "A request for a project takes the secret out of its sessions and their forks and its tasks.
A session and a task of another project are as they were."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (s (plist-get w :s))
           (f (plist-get w :f))
           (c (plist-get w :c))
           (other (harness-test-temp-dir))
           (live (harness-redact-e2e--live-session w other))
           (g (plist-get live :id))
           (project (harness-tasks--project (plist-get w :cwd)))
           (other-project (harness-tasks--project other))
           (g-log (harness-redact-e2e--read (harness-redact-e2e--log g)))
           (prompt (format "Use %s and %s." harness-redact-e2e--access-key harness-redact-e2e--secret-key)))
      (should-not (equal project other-project))
      ;; A task in each project holds the secret in its prompt.
      (dolist (cell (list (cons "t-in" project) (cons "t-out" other-project)))
        (harness-tasks--put (list :id (car cell) :project (cdr cell) :cwd (cdr cell) :state 'review
                                  :created 2.0 :prompt prompt)))
      (harness-tasks-flush)
      (let ((report (harness-redact-e2e--redact w :scope 'project :project (plist-get w :cwd))))
        (should (plist-get report :complete))
        (should (string-search "project" (plist-get report :scope)))
        (should (equal (harness-redact-e2e--sorted (list s f c))
                       (harness-redact-e2e--sorted (mapcar (lambda (e) (plist-get e :id)) (plist-get report :sessions)))))
        (should (= 0 (harness-redact-e2e--text-count report))))
      ;; The task of the project is clean, the other's is not.
      (should (= 0 (harness-redact-e2e--text-count (gethash "t-in" harness-tasks--table))))
      (should (> (harness-redact-e2e--text-count (gethash "t-out" harness-tasks--table)) 0))
      ;; The session of the other project, with its conversation, is as it was.
      (should (equal g-log (harness-redact-e2e--read (harness-redact-e2e--log g))))
      (should (> (harness-redact-e2e--file-count (plist-get live :cli-log)) 0))
      (should (harness-redact-e2e--provider-state g))
      (should-not (harness-redact-e2e--redactions g))
      ;; The project's sessions, with the Copilot one whose state held the secret.
      (dolist (sid (list s f c))
        (should-not (harness-redact-e2e--provider-state sid)))
      (should (= 0 (harness-redact-e2e--file-count (plist-get w :copilot-events))))
      (should (= 0 (harness-redact-e2e--file-count (harness-redact-e2e--log s))))
      ;; A request for every session takes the rest.
      (should (plist-get (harness-redact-e2e--redact w) :complete))
      (should (= 0 (harness-redact-e2e--text-count (gethash "t-out" harness-tasks--table))))
      (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
      (should-not (harness-redact-e2e--holders w))
      (should (= 0 (harness-redact-e2e--file-count (plist-get live :cli-log)))))))

;;;; A log that someone else may be writing

(ert-deftest harness-redact-e2e-a-conversation-log-nobody-owns-and-just-written-is-left-alone-and-reported ()
  "A log that no session owns and that was written a moment ago is left alone, and the request says so.
A CLI the user started outside the harness may be writing it, and a
rewrite by rename would be lost to it.  Everything else is clean, the
request is not called done, and it names the file; once the file has been
quiet for a while the next request cleans it."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world))
           (outside (harness-redact-e2e--write
                     (expand-file-name "-home-test-elsewhere/cli-outside.jsonl" (plist-get w :projects))
                     (concat (harness-redact-e2e--cli-line "user" (format "the key is %s" harness-redact-e2e--secret-key))
                             "\n"))))
      (let ((report (harness-redact-e2e--redact w)))
        (should-not (plist-get report :complete))
        (should-not (plist-get report :errors))
        (should (cl-some (lambda (line) (and (string-search "cli-outside.jsonl" line)
                                             (string-search "no session of the harness owns it" line)))
                         (plist-get report :remaining)))
        (should (string-search "NOT everything is clean" (plist-get report :text)))
        ;; What was left is explained, not lost: the verification expects it.
        (let ((verification (plist-get report :verification)))
          (should (eq t (plist-get verification :ok)))
          (should (= 0 (plist-get verification :unexplained)))
          (should (> (plist-get verification :explained) 0)))
        (should (= 0 (harness-redact-e2e--text-count report))))
      ;; The file is the only copy left; what the world made is clean.
      (should (> (harness-redact-e2e--file-count outside) 0))
      (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
      (should (equal (list outside) (harness-redact-e2e--holders w)))
      ;; Quiet for an hour, it is cleaned by the next request, which is then done.
      (set-file-times outside (time-subtract (current-time) 3600))
      (let ((again (harness-redact-e2e--redact w)))
        (should (plist-get again :complete))
        (should-not (plist-get again :remaining)))
      (should (= 0 (harness-redact-e2e--file-count outside)))
      (should-not (harness-redact-e2e--holders w)))))

;;;; A copy that something wrote back

(ert-deftest harness-redact-e2e-a-copy-something-wrote-back-is-found-and-the-next-request-takes-it-out ()
  "A request is not done while a copy is in a log it cleaned: the second scan finds it.
Something appends the secret to the node log of a session after it was
cleaned and before the request ends; the report says where it is, and
that the redaction is not done, and a second request takes it out."
  (harness-redact-e2e-with
    (let* ((w (harness-redact-e2e--world t))
           (s (plist-get w :s))
           (echoes 0)
           (handle (harness-on 'session/provider-state-changed
                               (lambda (sid state)
                                 (when (and (equal sid s) (null state) (= echoes 0))
                                   (cl-incf echoes)
                                   (harness-redact-e2e--add
                                    s (list :kind 'assistant
                                            :content (format "The key was %s." harness-redact-e2e--secret-key))))))))
      (let ((report (unwind-protect (harness-redact-e2e--redact w)
                      (harness-off handle))))
        (should (= 1 echoes))
        (should-not (plist-get report :complete))
        (let ((verification (plist-get report :verification)))
          (should (eq :false (plist-get verification :ok)))
          (should (> (plist-get verification :unexplained) 0)))
        (should (cl-some (lambda (line) (string-search "node logs" line)) (plist-get report :remaining)))
        (should (string-search "NOT everything is clean" (plist-get report :text)))
        (should (= 0 (harness-redact-e2e--text-count report))))
      ;; The copy is there, the log is whole, and what holds a copy besides the log and the
      ;; nodes in memory is the search index, which reads the log: no other store has one.
      (should (> (harness-redact-e2e--file-count (harness-redact-e2e--log s)) 0))
      (harness-redact-e2e--check-replay s)
      (let ((full (harness-redact-e2e--full (harness-redact-e2e--census w))))
        (should (member "node log of the session" full))
        (should (member "nodes and record of the session in memory" full))
        (dolist (store full)
          (should (member store '("node log of the session" "nodes and record of the session in memory"
                                  "search index rows" "search index files")))))
      ;; Nothing writes it again: the next request is done.
      (let ((again (harness-redact-e2e--redact w)))
        (should (plist-get again :complete))
        (should (plist-get (plist-get again :verification) :ok)))
      (should-not (harness-redact-e2e--full (harness-redact-e2e--census w)))
      (should-not (harness-redact-e2e--holders w)))))

(provide 'harness-redact-e2e-test)
;;; harness-redact-e2e-test.el ends here
