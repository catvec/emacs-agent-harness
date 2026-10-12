;;; harness-redact-hosted-test.el --- Masking in a turn, and a hosted session after a redaction  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The two ends of the defence against a secret in a transcript, run
;; through real turns of the agent on the modules as they are -- the
;; store, session, agent, tools, shell tool, secrets and redaction modules,
;; the demo provider and the Claude Code provider over the fake CLI of
;; test/fixtures/fake-claude.py -- in a throwaway state directory.  Every
;; secret is a fake one, built when the test runs, so that no value that
;; looks real is committed.
;;
;; Prevention.  A source is registered by where its secrets can be read, the
;; outputs of a made-up Terraform state, and a turn of the agent runs the
;; shell tool as the incident did: it diffs the state files, and the output
;; has both keys in it.  What a tool returns is masked before anything keeps
;; it or sends it on:
;;
;; - the result in the transcript, the node log that holds it, the messages
;;   the model is given on its next request and the events the bus carries
;;   hold the placeholder [redacted: LABEL sha256:FINGERPRINT] and not the
;;   value; the harness log does not hold it either, and the registry
;;   kept the reference to the state file and no value of it;
;; - the same command with no source registered leaves the keys in the
;;   transcript, so the test above is one that can fail;
;; - with the default detectors on, as in a harness that comes as it is, the
;;   registry names the keys it knows: a detector does not take the line of
;;   the secret key first;
;; - an output cut and saved whole to a file is masked before it is saved,
;;   so the file holds the placeholders too;
;; - a key that reaches the harness in two chunks of output is masked in the
;;   result as the one text it is;
;; - a hosted loop is sent the masked result: the Claude Code CLI never
;;   gets the value over its tool protocol.
;;
;; Cleaning up.  A session on Claude Code leaks a key into its transcript,
;; into what it told the CLI, into the conversation the CLI keeps and into
;; the CLI's own log.  The key is taken out by reference to the state file it
;; is read from, as the user would, and:
;;
;; - the session has no provider conversation left, and its CLI log, its node
;;   log and its record hold no key;
;; - its next turn starts a new CLI session, not a resumed one, and tells it
;;   the transcript as the harness has it now, the redacted one: the CLI is
;;   spawned without --resume, is sent the placeholders in place of the keys,
;;   answers from what it was sent, and writes nothing into the old
;;   conversation, which it can no longer reach;
;; - without a redaction the same session does resume its CLI session, which
;;   remembers the key, so the check above is one that can fail too;
;; - a session redacted in the middle of a turn is clean at once, in the
;;   parts the turn is not using, and finished when the turn ends: its CLI
;;   log is cleaned then, its conversation dropped, its reply whole, and it
;;   goes on from the redacted transcript as well;
;; - a session on Copilot, the other hosted loop, is cleaned and goes on the
;;   same way: its CLI's events are cleaned, and its next turn asks for a
;;   new Copilot session, not for the old one to be resumed, and opens it
;;   with the redacted transcript.
;;
;; The fake CLI keeps the prompts of its conversation, not the results of its
;; tools, so the user pastes the secret key into the first message as well as
;; the tool printing both keys: the old conversation then holds a key that a
;; resumed session would repeat.  A redaction cannot recall what the model
;; provider already received: the message that carried the key to the CLI
;; the first time still holds it, and so does the conversation the fake CLI
;; kept, which lies outside what the harness can reach.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-redact--pending)
(defvar harness-secrets-mask)
(defvar harness-secrets-sources)
(defvar harness-secrets-detectors)
(defvar harness-tools-max-output-chars)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-provider-claude-program)
(defvar harness-provider-claude-projects-directory)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(defvar harness-provider-claude-api-key)
(defvar harness-provider-claude--api-base)
(defvar harness-provider-copilot-program)
(defvar harness-provider-copilot-state-directory)
(defvar harness-provider-copilot--sessions)
(defvar harness-provider-copilot--catalogue)
(defvar harness-provider-copilot--status)
(defvar harness-provider-copilot--asked)
(defvar harness-provider-copilot--refresh)
(defvar harness-provider-copilot--probe)
(declare-function harness-provider-copilot-close-all "harness-provider-copilot")
(declare-function harness-provider-claude-close "harness-provider-claude")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude--forget-listing "harness-provider-claude")
(declare-function harness-provider-claude-session-process "harness-provider-claude")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-secrets-forget "harness-secrets")
(declare-function harness-session-flush "harness-session")
(declare-function harness-session-nodes "harness-session")
(declare-function harness-session--load-nodes "harness-session")
(declare-function make-harness-session "harness-session")
(declare-function harness-session-plist "harness-session")
(declare-function harness-define-tool "harness-tools")

;;;; The fake secrets

(defvar harness-redact-hosted--access-key nil
  "The fake access key id of the test running, 20 characters.")

(defvar harness-redact-hosted--secret-key nil
  "The fake secret key of the test running: 44 characters, a plus and slashes.")

(defconst harness-redact-hosted--alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  "The characters the fake secrets are made of, besides a slash and a plus.")

(random t)

(defun harness-redact-hosted--chars (n)
  "Return N random letters and digits."
  (apply #'string (cl-loop repeat n
                           collect (aref harness-redact-hosted--alphabet
                                         (random (length harness-redact-hosted--alphabet))))))

(defconst harness-redact-hosted--cli-words
  "die\\|hang\\|ignore\\|recall\\|compacting\\|paragraphs"
  "Words the fake CLI reacts to wherever a prompt holds them.
See test/fixtures/fake-claude.py.  A fake secret that is part of a prompt
must not hold one by chance.")

(defun harness-redact-hosted--made (make)
  "Return what MAKE makes, the first time it holds no word of the fake CLI."
  (let ((value (funcall make)))
    (while (string-match-p harness-redact-hosted--cli-words value)
      (setq value (funcall make)))
    value))

(defun harness-redact-hosted--make-access-key ()
  "Return a fake access key id of 20 characters."
  (harness-redact-hosted--made
   (lambda () (concat "FAKEACC" (harness-redact-hosted--chars 13)))))

(defun harness-redact-hosted--make-secret-key ()
  "Return a fake secret key of 44 characters, with slashes and a plus in it."
  (harness-redact-hosted--made
   (lambda () (concat "sK/" (harness-redact-hosted--chars 18) "+" (harness-redact-hosted--chars 17) "/"
                      (harness-redact-hosted--chars 4)))))

(defun harness-redact-hosted--secrets ()
  "Return the fake key and id as secrets, the longest first.
That is the order a resolution has them in.  They are labelled as the
JSON path of the state file labels them."
  (list (harness-redaction-secret harness-redact-hosted--secret-key "outputs.spaces_keys.value.secret_key")
        (harness-redaction-secret harness-redact-hosted--access-key "outputs.spaces_keys.value.access_key")))

(defun harness-redact-hosted--fp (index)
  "Return the fingerprint of fake secret number INDEX: 0 the key, 1 the id."
  (plist-get (nth index (harness-redact-hosted--secrets)) :fingerprint))

(defun harness-redact-hosted--label (index)
  "Return the label of fake secret number INDEX: 0 the key, 1 the id."
  (plist-get (nth index (harness-redact-hosted--secrets)) :label))

(defun harness-redact-hosted--placeholder (index)
  "Return the placeholder of fake secret number INDEX: 0 the key, 1 the id."
  (harness-redaction-placeholder (nth index (harness-redact-hosted--secrets))))

;;;; Counting

(defun harness-redact-hosted--printed (object)
  "Return OBJECT printed as text, its strings as they are."
  (let ((print-circle t) (print-length nil) (print-level nil))
    (prin1-to-string object t)))

(defun harness-redact-hosted--text-count (object)
  "Return how many times the fake secrets occur in OBJECT, printed.
A string is taken as it is.  They are found as they are and as JSON
writes them."
  (harness-redaction-count (if (stringp object) object (harness-redact-hosted--printed object))
                           (harness-redact-hosted--secrets)))

(defun harness-redact-hosted--file-count (file)
  "Return how many times the fake secrets occur in the bytes of FILE.
A missing file has none."
  (if (file-regular-p file)
      (harness-redaction-file-count file (harness-redact-hosted--secrets))
    0))

(defun harness-redact-hosted--tree-count (root)
  "Return how many times the fake secrets occur in every file under ROOT."
  (if (file-directory-p root)
      (cl-loop for file in (directory-files-recursively root "")
               sum (harness-redact-hosted--file-count file))
    0))

(defun harness-redact-hosted--tree-holders (root)
  "Return the files under ROOT that hold a fake secret, relative to it."
  (and (file-directory-p root)
       (cl-loop for file in (directory-files-recursively root "")
                when (> (harness-redact-hosted--file-count file) 0)
                collect (file-relative-name file root))))

(defun harness-redact-hosted--occurrences (needle text)
  "Return how many times the string NEEDLE occurs in TEXT."
  (let ((n 0) (pos 0))
    (while (setq pos (string-search needle text pos))
      (cl-incf n)
      (setq pos (+ pos (length needle))))
    n))

(defun harness-redact-hosted--sorted (list)
  "Return a sorted copy of LIST, a list of strings."
  (sort (copy-sequence list) #'string<))

;;;; Files

(defun harness-redact-hosted--write (file text)
  "Write TEXT to FILE, making its directory; return FILE."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert text)))
  file)

(defun harness-redact-hosted--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redact-hosted--state-text (serial)
  "Return a made-up Terraform state at SERIAL, with the fake keys as an output.
The keys are under outputs.spaces_keys.value, beside a type and a region
that are no secrets, and a few lines below the serial, so that a diff of
two serials shows them as context."
  (format (concat "{\n  \"version\": 4,\n  \"serial\": %d,\n  \"outputs\": {\n"
                  "    \"spaces_keys\": {\n      \"value\": {\n"
                  "        \"access_key\": \"%s\",\n        \"secret_key\": \"%s\"\n      },\n"
                  "      \"type\": [\n        \"object\",\n        {\n"
                  "          \"access_key\": \"string\",\n          \"secret_key\": \"string\"\n"
                  "        }\n      ],\n      \"sensitive\": true\n    },\n"
                  "    \"region\": {\n      \"value\": \"nyc3\",\n      \"type\": \"string\"\n    }\n"
                  "  }\n}\n")
          serial harness-redact-hosted--access-key harness-redact-hosted--secret-key))

(defun harness-redact-hosted--project (dir)
  "Write the Terraform states of a project in DIR; return the current one.
There is a backup at serial 41 and the state at serial 42, as Terraform
leaves them."
  (harness-redact-hosted--write (expand-file-name "terraform.tfstate.backup" dir)
                                (harness-redact-hosted--state-text 41))
  (harness-redact-hosted--write (expand-file-name "terraform.tfstate" dir)
                                (harness-redact-hosted--state-text 42)))

(defun harness-redact-hosted--reference (state-file)
  "Return the reference to the fake keys in STATE-FILE.
It names the strings under the output."
  (list :file state-file :json-path "outputs.spaces_keys.value"))

(defun harness-redact-hosted--output-text ()
  "Return what `terraform output -json' prints for the fake keys."
  (format "{\n  \"access_key\": \"%s\",\n  \"secret_key\": \"%s\"\n}"
          harness-redact-hosted--access-key harness-redact-hosted--secret-key))

;;;; The stack

(defvar harness-redact-hosted--store nil
  "The directory where the fake CLI keeps its conversations in this test.")

(defvar harness-redact-hosted--argv-file nil
  "The file where each process of the fake CLI writes its arguments.")

(defvar harness-redact-hosted--input-file nil
  "The file where each process of the fake CLI logs the user messages it gets.")

(defmacro harness-redact-hosted-with (&rest body)
  "Run BODY on the stack a session runs on, in a fresh state directory.
It has fake secrets.  Sessions on a Claude model run on the fake CLI,
which keeps its conversations in `harness-redact-hosted--store', writes
its arguments to `harness-redact-hosted--argv-file' and logs the user
messages it gets to `harness-redact-hosted--input-file'; the CLI's own
logs are in a directory of the test's
\(`harness-provider-claude-projects-directory'), never the user's.
Masking is on, with no source and no detector; everything is allowed.
BODY has the tools it defines to itself."
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
     (dolist (m '(store project config provider-demo tools tools-shell session agent secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-redact--pending)
     (harness-secrets-forget)
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let* ((harness-redact-hosted--access-key (harness-redact-hosted--make-access-key))
            (harness-redact-hosted--secret-key (harness-redact-hosted--make-secret-key))
            (harness-redact-hosted--store (harness-test-temp-dir))
            (harness-redact-hosted--argv-file
             (expand-file-name "argv.json" (harness-test-temp-dir)))
            (harness-redact-hosted--input-file
             (expand-file-name "input.jsonl" (harness-test-temp-dir)))
            ;; The tools a test registers go with its own copy of the registry.
            (harness-tools (copy-hash-table harness-tools))
            (harness-secrets-mask t)
            (harness-secrets-sources nil)
            (harness-secrets-detectors nil)
            (harness-provider-claude-projects-directory (harness-test-temp-dir))
            (harness-provider-demo--delay 0.005)
            (harness-provider-demo-script-override nil)
            (default-directory dir)
            (process-environment
             (append (list (concat "HARNESS_FAKE_CLAUDE_STORE=" harness-redact-hosted--store)
                           (concat "HARNESS_FAKE_CLAUDE_ARGV=" harness-redact-hosted--argv-file)
                           (concat "HARNESS_FAKE_CLAUDE_INPUT=" harness-redact-hosted--input-file))
                     process-environment)))
       (unwind-protect (progn ,@body)
         (harness-provider-claude-close-all)))))

;;;; Sessions and turns

(defun harness-redact-hosted--session (cwd model name)
  "Create a session called NAME in CWD on MODEL; return its id."
  (plist-get (harness-call 'session/create :cwd cwd :model model :name name) :id))

(defun harness-redact-hosted--demo-session (cwd name)
  "Create a session called NAME in CWD on the demo provider; return its id."
  (harness-redact-hosted--session cwd "demo:scripted" name))

(defun harness-redact-hosted--claude-session (cwd name)
  "Create a session called NAME in CWD on a Claude model; return its id."
  (harness-redact-hosted--session cwd "claude:claude-fable-5-1" name))

(defun harness-redact-hosted--turn (sid text)
  "Run a turn of session SID in which the user says TEXT; return its result."
  (let ((result (harness-test-await (harness-call 'agent/prompt sid text) 60)))
    (should (eq 'end-turn (plist-get result :stop-reason)))
    result))

(defun harness-redact-hosted--nodes-of (sid kind)
  "Return the nodes of KIND in the transcript of session SID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(defun harness-redact-hosted--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))

(defun harness-redact-hosted--record-file (sid)
  "Return the file name of the record of session SID."
  (expand-file-name (format "sessions/%s.json" sid) harness-state-directory))

(defun harness-redact-hosted--memory (sid)
  "Return everything the harness holds in memory about session SID, printed.
That is every node it has loaded, on its path or not, and its record."
  (let ((s (gethash sid harness-sessions)) nodes)
    (maphash (lambda (_ node) (push node nodes)) (harness-session-nodes s))
    (harness-redact-hosted--printed (list nodes (harness-session-plist s)))))

(defun harness-redact-hosted--replayed-ids (sid)
  "Return the ids of the nodes a restart would load for session SID.
The harness's own loader reads the node log into a session that has
nothing else, as `harness-session--load-all' does."
  (let ((s (make-harness-session :id sid)))
    (harness-session--load-nodes s)
    (hash-table-keys (harness-session-nodes s))))

(defun harness-redact-hosted--provider-state (sid)
  "Return the provider state in the record of session SID."
  (plist-get (harness-call 'session/get sid) :provider-state))

(defun harness-redact-hosted--cli-id (sid)
  "Return the CLI session in the provider state of session SID."
  (plist-get (harness-redact-hosted--provider-state sid) :cli-session-id))

(defun harness-redact-hosted--last-reply (sid)
  "Return the text of the last reply in the transcript of session SID."
  (plist-get (cl-find 'assistant (harness-call 'session/nodes sid)
                      :key (lambda (n) (plist-get n :kind)) :from-end t)
             :content))

(defun harness-redact-hosted--hints (sid)
  "Return the text of the hints in the transcript of session SID, oldest first."
  (cl-loop for n in (harness-call 'session/nodes sid)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(defun harness-redact-hosted--redactions (sid)
  "Return the redaction records in the `ext' of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :redactions))

(defun harness-redact-hosted--clean-p (sid)
  "Non-nil when nothing of session SID holds a fake secret.
That is its node log, its record, its memory and its nodes."
  (harness-session-flush)
  (and (= 0 (harness-redact-hosted--file-count (harness-redact-hosted--log sid)))
       (= 0 (harness-redact-hosted--file-count (harness-redact-hosted--record-file sid)))
       (= 0 (harness-redact-hosted--text-count (harness-redact-hosted--memory sid)))
       (= 0 (harness-redact-hosted--text-count (harness-call 'session/nodes sid)))))

;;;; The bus

(defvar harness-redact-hosted--tapped nil
  "The events that carried a fake secret since the tap was set.
Each is (EVENT . COUNT), the newest first.")

(defvar harness-redact-hosted--tapped-total 0
  "How many events the tap saw since it was set, with a secret or without.")

(defun harness-redact-hosted--tap (event args)
  "Note EVENT, emitted with ARGS, in `harness-redact-hosted--tapped'.
It is noted when it carries a fake secret."
  (cl-incf harness-redact-hosted--tapped-total)
  (let ((n (harness-redact-hosted--text-count (harness-redact-hosted--printed args))))
    (when (> n 0)
      (push (cons event n) harness-redact-hosted--tapped))))

(defmacro harness-redact-hosted-tapping (&rest body)
  "Run BODY with every event of the bus looked at for the fake secrets.
The events that carry one are noted in `harness-redact-hosted--tapped'."
  (declare (indent 0))
  `(let ((harness-redact-hosted--tapped nil)
         (harness-redact-hosted--tapped-total 0))
     (let ((handle (harness-on '* #'harness-redact-hosted--tap)))
       (unwind-protect (progn ,@body)
         (harness-off handle)))))

(defun harness-redact-hosted--quietly (thunk least)
  "Call THUNK with every event of the bus looked at; return its value.
Fail when an event carried a fake secret, or when fewer than LEAST events
went by: a tap that saw almost nothing proves almost nothing."
  (harness-redact-hosted-tapping
    (prog1 (funcall thunk)
      (should (>= harness-redact-hosted--tapped-total least))
      (should-not harness-redact-hosted--tapped))))

;;;; What a hosted provider is sent

(defun harness-redact-hosted--define-echo (handler)
  "Make `echo' a harness tool, answered by HANDLER.
HANDLER is a function of the input and the context.  The fake CLI calls
it, as mcp__harness__echo, when a message says \"call echo\"."
  (harness-define-tool "echo" :label "Echo" :description "Echo TEXT back." :kind 'read
                       :schema '(:type "object" :properties (:text (:type "string")))
                       :handler handler))

(defvar harness-redact-hosted--sent nil
  "What the Claude provider wrote to its CLI since the spy was set.
Each message is JSON text, the newest first.")

(defun harness-redact-hosted--spy (_entry object)
  "Note OBJECT, a message the Claude provider is about to write to its CLI."
  (push (condition-case nil (harness-json-encode-text object) (error "")) harness-redact-hosted--sent))

(defmacro harness-redact-hosted-spying (&rest body)
  "Run BODY with each message written to a CLI noted.
They are noted in `harness-redact-hosted--sent'."
  (declare (indent 0))
  `(let ((harness-redact-hosted--sent nil))
     (advice-add 'harness-provider-claude--send :before #'harness-redact-hosted--spy)
     (unwind-protect (progn ,@body)
       (advice-remove 'harness-provider-claude--send #'harness-redact-hosted--spy))))

;;;; Masking: a turn that runs the shell tool

(defun harness-redact-hosted--shell-turn (sid command)
  "Run a turn of session SID in which the demo model runs the shell COMMAND.
The model says what it will do, runs COMMAND with the bash tool as call
diff-1, and answers.  Return the messages each request was given,
printed, oldest first: the second holds the result of the call."
  (let* ((requests nil)
         (harness-provider-demo-script-override
          (lambda (request)
            (push (harness-redact-hosted--printed (plist-get request :messages)) requests)
            `((:type text :delta "I will look at what changed.")
              (:type tool-call :id "diff-1" :name "bash" :input (:command ,command))
              (:type text :delta "Only the serial moved.")
              (:type done :stop-reason end-turn)))))
    (harness-redact-hosted--turn sid "What changed between the two Terraform states?")
    (nreverse requests)))

(defconst harness-redact-hosted--diff-command
  "diff -U 40 terraform.tfstate.backup terraform.tfstate; true"
  "The command that prints the keys the way the incident's diff did.
They are lines of context.")

(defun harness-redact-hosted--result (sid)
  "Return the node of the result of the shell call of session SID."
  (let ((results (harness-redact-hosted--nodes-of sid 'tool-result)))
    (should (= 1 (length results)))
    (should (equal "diff-1" (plist-get (car results) :call-id)))
    (car results)))

(ert-deftest harness-redact-hosted-masking-catches-a-registered-value-in-shell-output-before-it-is-recorded ()
  "A registered value that a shell command prints is a placeholder everywhere.
Everything that keeps the output or sends it on has the placeholder.
The outputs of the Terraform state are the source, registered the way the
user adds one.  The command diffs the state files and so prints both keys.
The result in the transcript, the node log, the messages the model is given
back, the events of the bus and the log of the harness hold the
placeholders, with the fingerprints the registry shows, and not a value; and
nothing in the state directory does, the registry's own file included: it
holds the reference to the state file, never what it names."
  (harness-redact-hosted-with
    (let* ((cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--project cwd))
           (added (harness-call 'secrets/add-source (harness-redact-hosted--reference state-file)))
           (sid (harness-redact-hosted--demo-session cwd "Step qr: cut over"))
           (requests nil))
      ;; The registry knows the two values by fingerprint.
      (should (= 2 (plist-get added :values)))
      (should (equal (harness-redact-hosted--sorted
                      (list (harness-redact-hosted--fp 0) (harness-redact-hosted--fp 1)))
                     (harness-redact-hosted--sorted (plist-get added :fingerprints))))
      (harness-redact-hosted-tapping
        (setq requests (harness-redact-hosted--shell-turn sid harness-redact-hosted--diff-command))
        (should (> harness-redact-hosted--tapped-total 20))
        (should-not harness-redact-hosted--tapped))
      ;; The result in the transcript is the output with the placeholders in the keys' places.
      (let* ((result (harness-redact-hosted--result sid))
             (output (plist-get result :output))
             (hits (plist-get (plist-get result :meta) :masked)))
        (should-not (plist-get result :is-error))
        (should (string-search "\"serial\": 42" output))
        (should (string-search (harness-redact-hosted--placeholder 0) output))
        (should (string-search (harness-redact-hosted--placeholder 1) output))
        (should (= 0 (harness-redact-hosted--text-count result)))
        ;; It says what it masked, by label and fingerprint, and how often.
        (should (equal (harness-redact-hosted--sorted
                        (list (harness-redact-hosted--fp 0) (harness-redact-hosted--fp 1)))
                       (harness-redact-hosted--sorted
                        (mapcar (lambda (h) (plist-get h :fingerprint)) hits))))
        (should (equal (harness-redact-hosted--sorted
                        (list (harness-redact-hosted--label 0) (harness-redact-hosted--label 1)))
                       (harness-redact-hosted--sorted
                        (mapcar (lambda (h) (plist-get h :label)) hits))))
        (dolist (h hits) (should (>= (plist-get h :count) 1))))
      ;; The node log holds the placeholders, and nowhere a value.
      (should (string-search (harness-redact-hosted--placeholder 0)
                             (harness-redact-hosted--read (harness-redact-hosted--log sid))))
      (should (harness-redact-hosted--clean-p sid))
      ;; The model was given the output masked, on the request after the call.
      (should (= 2 (length requests)))
      (should (= 0 (harness-redact-hosted--text-count requests)))
      (should (string-search (harness-redact-hosted--placeholder 0) (nth 1 requests)))
      (should (string-search (harness-redact-hosted--placeholder 1) (nth 1 requests)))
      (should-not (string-search "[redacted: " (nth 0 requests)))
      ;; The harness did not log it, and the registry stored no value.
      (should (= 0 (harness-redact-hosted--text-count
                    (with-current-buffer (get-buffer-create harness-log-buffer-name) (buffer-string)))))
      (should (file-regular-p (expand-file-name "secret-sources.json" harness-state-directory)))
      (should (string-search "terraform.tfstate"
                             (harness-redact-hosted--read
                              (expand-file-name "secret-sources.json" harness-state-directory))))
      (should-not (harness-redact-hosted--tree-holders harness-state-directory))
      ;; The files the secrets were read from still hold them: they are the project's.
      (should (> (harness-redact-hosted--file-count state-file) 0)))))

(ert-deftest harness-redact-hosted-the-same-command-leaves-the-keys-in-the-transcript-without-a-source ()
  "With no source registered, the output of the command keeps the keys.
So the test above is one that can fail.  Detectors are off here too, so
nothing but the registry could have masked them."
  (harness-redact-hosted-with
    (let* ((cwd (harness-test-temp-dir))
           (_ (harness-redact-hosted--project cwd))
           (sid (harness-redact-hosted--demo-session cwd "Step qr: cut over"))
           (requests (harness-redact-hosted--shell-turn sid harness-redact-hosted--diff-command))
           (result (harness-redact-hosted--result sid)))
      (should (string-search harness-redact-hosted--access-key (plist-get result :output)))
      (should (string-search harness-redact-hosted--secret-key (plist-get result :output)))
      (should-not (plist-get (plist-get result :meta) :masked))
      (should-not (string-search "[redacted: " (plist-get result :output)))
      (should (> (harness-redact-hosted--file-count (harness-redact-hosted--log sid)) 0))
      (should (> (harness-redact-hosted--text-count (nth 1 requests)) 0))
      (should-not (harness-redact-hosted--clean-p sid)))))

(ert-deftest harness-redact-hosted-an-output-saved-whole-is-masked-before-it-is-saved ()
  "The file an oversized output is saved to holds placeholders, not keys.
The command prints the state, a long run of filler and the state again;
the node keeps the beginning and the path of the file the whole is saved
to.  Masking runs ahead of the size guard, so what the guard saves and
what it cuts are the masked text: each key is masked twice, once in the
part the node keeps and once in the part only the file has."
  (harness-redact-hosted-with
    (let* ((harness-tools-max-output-chars 2000)
           (cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--project cwd))
           (sid (harness-redact-hosted--demo-session cwd "Step qr: cut over"))
           (command "cat terraform.tfstate; head -c 3000 /dev/zero | tr '\\0' x; echo; cat terraform.tfstate"))
      (harness-call 'secrets/add-source (harness-redact-hosted--reference state-file))
      (let* ((requests (harness-redact-hosted--shell-turn sid command))
             (result (harness-redact-hosted--result sid))
             (truncated (plist-get (plist-get result :meta) :truncated))
             (spill (plist-get truncated :path))
             (hits (plist-get (plist-get result :meta) :masked)))
        ;; The output was cut, and the whole was saved under the state directory.
        (should (string-search "[Output truncated:" (plist-get result :output)))
        (should (equal (expand-file-name "outputs/diff-1.txt" harness-state-directory) spill))
        (should (file-regular-p spill))
        (should (> (plist-get truncated :chars) harness-tools-max-output-chars))
        ;; What the node keeps and what the file holds are masked.
        (should (= 0 (harness-redact-hosted--text-count result)))
        (should (string-search (harness-redact-hosted--placeholder 0) (plist-get result :output)))
        (should (= 0 (harness-redact-hosted--file-count spill)))
        (dolist (i '(0 1))
          (should (= 2 (harness-redact-hosted--occurrences (harness-redact-hosted--placeholder i)
                                                           (harness-redact-hosted--read spill)))))
        (should (equal '(2 2) (mapcar (lambda (h) (plist-get h :count)) hits)))
        ;; The model was given the cut output, masked.
        (should (= 0 (harness-redact-hosted--text-count requests)))
        (should (string-search "[Output truncated:" (nth 1 requests)))
        (should (harness-redact-hosted--clean-p sid))
        (should-not (harness-redact-hosted--tree-holders harness-state-directory))))))

(ert-deftest harness-redact-hosted-the-registry-names-a-key-before-a-detector-does ()
  "With the default detectors on, a registered key is named by its source.
The detectors are on in a harness as it comes.  The line of the secret
key, \"secret_key\": \"...\", is one they know, and the access key id is
not (a plain id has no format to find).  The registry goes first: both
keys are masked as the outputs of the state file, no detector's name is
in the result, and it holds no value."
  (harness-redact-hosted-with
    (let* ((harness-secrets-detectors 'default)
           (cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--project cwd))
           (sid (harness-redact-hosted--demo-session cwd "Step qr: cut over")))
      (harness-call 'secrets/add-source (harness-redact-hosted--reference state-file))
      (let* ((requests (harness-redact-hosted--shell-turn sid harness-redact-hosted--diff-command))
             (result (harness-redact-hosted--result sid))
             (hits (plist-get (plist-get result :meta) :masked)))
        (should (string-search (harness-redact-hosted--placeholder 0) (plist-get result :output)))
        (should (string-search (harness-redact-hosted--placeholder 1) (plist-get result :output)))
        (should (equal (harness-redact-hosted--sorted
                        (list (harness-redact-hosted--label 0) (harness-redact-hosted--label 1)))
                       (harness-redact-hosted--sorted
                        (mapcar (lambda (h) (plist-get h :label)) hits))))
        (should-not (string-search "secret-assignment" (plist-get result :output)))
        (should (= 0 (harness-redact-hosted--text-count requests)))
        (should (harness-redact-hosted--clean-p sid))
        (should-not (harness-redact-hosted--tree-holders harness-state-directory))))))

(ert-deftest harness-redact-hosted-a-key-split-across-chunks-of-output-is-masked-in-the-result ()
  "Whatever chunks a command's output arrives in, its result is masked whole.
The command prints the secret key in two pieces, a moment apart, so that
the shell tool's output reaches the harness in two chunks with the key cut
between them.  The result is masked as the one text it is, and holds the
placeholder and not the key.  The progress text, which is only shown, is
masked a chunk at a time: no event holds the whole key, though one may show
half of it."
  (harness-redact-hosted-with
    (let* ((cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--project cwd))
           (key harness-redact-hosted--secret-key)
           (half (/ (length key) 2))
           (command "printf '%s' \"$(cat part1)\"; sleep 0.4; printf '%s\\n' \"$(cat part2)\"")
           (sid (harness-redact-hosted--demo-session cwd "Step qr: cut over")))
      (harness-redact-hosted--write (expand-file-name "part1" cwd) (substring key 0 half))
      (harness-redact-hosted--write (expand-file-name "part2" cwd) (substring key half))
      (harness-call 'secrets/add-source (harness-redact-hosted--reference state-file))
      (let ((requests (harness-redact-hosted--quietly
                       (lambda () (harness-redact-hosted--shell-turn sid command)) 10))
            (result (harness-redact-hosted--result sid)))
        (should (equal (format "%s\nexit 0" (harness-redact-hosted--placeholder 0))
                       (plist-get result :output)))
        (should (= 0 (harness-redact-hosted--text-count requests)))
        (should (harness-redact-hosted--clean-p sid))))))

;;;; Masking: a hosted loop

(ert-deftest harness-redact-hosted-a-hosted-loop-is-sent-the-masked-result ()
  "The Claude Code CLI is sent the masked result of a tool.
The source is a setting, as in an init file.  The harness tool the CLI
calls prints both keys.  What goes back to the CLI over its tool protocol,
the node of the result and the node log hold the placeholders and not a
value, and neither does anything else the provider wrote to the CLI."
  (harness-redact-hosted-with
    (let* ((cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--project cwd))
           (harness-secrets-sources (list (harness-redact-hosted--reference state-file)))
           (sid (harness-redact-hosted--claude-session cwd "Step qr: cut over")))
      (harness-redact-hosted--define-echo (lambda (_input _ctx) (harness-redact-hosted--output-text)))
      (harness-redact-hosted-spying
        (harness-redact-hosted-tapping
          (harness-redact-hosted--turn sid "please call echo")
          (should-not harness-redact-hosted--tapped))
        ;; The CLI called the tool and was sent its result, with the placeholders in it.
        (let ((replies (cl-remove-if-not (lambda (m) (string-search "mcp_response" m))
                                         harness-redact-hosted--sent)))
          (should replies)
          (should (cl-some (lambda (m) (string-search (harness-redact-hosted--placeholder 0) m)) replies))
          (should (cl-some (lambda (m) (string-search (harness-redact-hosted--placeholder 1) m)) replies)))
        (should (> (length harness-redact-hosted--sent) 3))
        (should (= 0 (harness-redact-hosted--text-count harness-redact-hosted--sent))))
      (let ((result (car (harness-redact-hosted--nodes-of sid 'tool-result))))
        (should (string-search (harness-redact-hosted--placeholder 0) (plist-get result :output)))
        (should (= 2 (length (plist-get (plist-get result :meta) :masked)))))
      (should (harness-redact-hosted--clean-p sid))
      (should (= 0 (harness-redact-hosted--tree-count harness-redact-hosted--store)))
      (should-not (harness-redact-hosted--tree-holders harness-state-directory)))))

;;;; A hosted session after a redaction

(defun harness-redact-hosted--inputs ()
  "Return the user messages the fake CLI logged, oldest first.
Each is a plist: the CLI session it went to (`:session'), the one that
process resumed (`:resumed', nil for a new one), whether it was forked
\(`:forked') and the message's text (`:text')."
  (and (file-exists-p harness-redact-hosted--input-file)
       (mapcar #'harness-json-parse
               (split-string (harness-read-file harness-redact-hosted--input-file) "\n" t))))

(defun harness-redact-hosted--argv ()
  "Return the arguments of the CLI process that started last, or nil."
  (and (file-exists-p harness-redact-hosted--argv-file)
       (plist-get (harness-json-parse (harness-read-file harness-redact-hosted--argv-file)) :argv)))

(defun harness-redact-hosted--cli-line (type content)
  "Return a line of a CLI conversation log.
The TYPE, user or assistant, said CONTENT."
  (harness-json-encode-text
   (list :type type :uuid (concat "uuid-" (harness-redact-hosted--chars 6))
         :message (list :role type :content content))))

(defun harness-redact-hosted--cli-log (cli prompt)
  "Write the log of the CLI session CLI after a turn of PROMPT; return the file.
The Claude Code CLI keeps the conversation in PROJECTS/SLUG/CLI.jsonl:
the prompt, the call of the tool, the result it was sent, which has the
keys in it, and the reply.  The fake CLI keeps no such log, so the test
writes the one the real CLI would have."
  (harness-redact-hosted--write
   (expand-file-name (format "-home-test-project/%s.jsonl" cli) harness-provider-claude-projects-directory)
   (concat
    (mapconcat
     #'identity
     (list (harness-redact-hosted--cli-line "user" prompt)
           (harness-redact-hosted--cli-line
            "assistant" (list (list :type "tool_use" :id "toolu_fake_1" :name "mcp__harness__echo"
                                    :input (list :text "ping"))))
           (harness-redact-hosted--cli-line
            "user" (list (list :type "tool_result" :tool_use_id "toolu_fake_1"
                               :content (list (list :type "text" :text (harness-redact-hosted--output-text))))))
           (harness-redact-hosted--cli-line "assistant" (list (list :type "text" :text "hello"))))
     "\n")
    "\n")))

(defun harness-redact-hosted--leaky-session (cwd &optional model)
  "Make a session in CWD on the fake CLI whose first turn leaked the keys.
It runs on MODEL, a Claude model by default.  Return a plist with the
session (`:sid'), its CLI session (`:cli', that of Claude Code) and the
prompt of the turn (`:prompt').  The user pasted the secret key into
the message, which also tells the CLI to call `echo'; the tool prints
both keys.  Call this with masking off, as it was when the incident
happened.  The tool prints the keys once: the transcript still says to
call it, so a later turn of a new CLI session calls it again, and then it
prints nothing, which keeps the second turn of a test from leaking anew."
  (let ((calls 0)
        (prompt (format "please call echo, and keep the key %s in mind" harness-redact-hosted--secret-key)))
    (harness-redact-hosted--define-echo
     (lambda (_input _ctx)
       (if (= 1 (cl-incf calls)) (harness-redact-hosted--output-text) "nothing more to print")))
    (let ((sid (harness-redact-hosted--session cwd (or model "claude:claude-fable-5-1") "Step qr: cut over")))
      (harness-redact-hosted--turn sid prompt)
      (list :sid sid :cli (harness-redact-hosted--cli-id sid) :prompt prompt))))

(ert-deftest harness-redact-hosted-a-hosted-loop-session-continues-from-the-redacted-transcript ()
  "After a redaction a Claude Code session carries on in a new CLI session.
The new one is made from the session's redacted transcript.  Masking is
off, so the first turn leaks: the user pastes the secret key, the CLI
calls a tool that prints both, and the keys are in the transcript, in the
conversation the CLI kept, in what it was sent and in its log.  The user
redacts by the state file the keys are read from, naming the session.
Then the session has no provider conversation, no live CLI process and no
copy of a key in its log, its record, its memory or the CLI's log.  The
next turn, \"recall\", is not a resumed one: the new CLI process is spawned
without --resume and gets, with the message, the transcript as it is now,
the placeholders where the keys were.  The CLI answers from what it was
sent, the reply and every node the turn wrote hold no key, and the old
conversation, which the harness cannot reach, is neither resumed nor
written to."
  (harness-redact-hosted-with
    (let* ((harness-secrets-mask nil)
           (cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--write
                        (expand-file-name "terraform.tfstate" (harness-test-temp-dir))
                        (harness-redact-hosted--state-text 42)))
           (leak (harness-redact-hosted--leaky-session cwd))
           (s (plist-get leak :sid))
           (cli (plist-get leak :cli))
           (proc (harness-provider-claude-session-process (gethash s harness-provider-claude--sessions)))
           (cli-log (harness-redact-hosted--cli-log cli (plist-get leak :prompt)))
           (chain (expand-file-name (concat cli ".json") harness-redact-hosted--store))
           (chain-before (harness-redact-hosted--read chain)))
      ;; The first turn left the keys everywhere a session keeps or tells them.
      (should (string-prefix-p "fake-" cli))
      (should (process-live-p proc))
      (should (equal (list cli) (list (plist-get (car (harness-redact-hosted--inputs)) :session))))
      (should (> (harness-redact-hosted--file-count (harness-redact-hosted--log s)) 0))
      (should (> (harness-redact-hosted--text-count (harness-redact-hosted--memory s)) 0))
      (should (> (harness-redact-hosted--file-count cli-log) 0))
      (should (> (harness-redact-hosted--file-count chain) 0))
      (should (> (harness-redact-hosted--text-count (plist-get (car (harness-redact-hosted--inputs)) :text)) 0))
      (should-not (harness-redact-hosted--clean-p s))
      ;; The user takes them out of the session, by reference to the state file.
      (let* ((report (harness-redact-hosted--quietly
                      (lambda ()
                        (harness-call 'secrets/redact
                                      (list :source (harness-redact-hosted--reference state-file)
                                            :scope 'session :sessions (list s) :mode 'redact
                                            :origin '(:kind user)
                                            :reason "The echo tool printed the Spaces keys.")))
                      3))
             (entry (car (plist-get report :sessions))))
        (should (eq t (plist-get report :complete)))
        (should (equal (list s) (mapcar (lambda (e) (plist-get e :id)) (plist-get report :sessions))))
        (should (>= (plist-get entry :claude) 1))
        (should (equal "reset" (format "%s" (plist-get entry :provider))))
        (should (= 0 (harness-redact-hosted--text-count report))))
      ;; Nothing of the old conversation is left in the session, and nothing runs in it.
      (should-not (harness-redact-hosted--provider-state s))
      (should-not (process-live-p proc))
      (should (= 0 (harness-redact-hosted--file-count cli-log)))
      (should (string-search (harness-redact-hosted--placeholder 0) (harness-redact-hosted--read cli-log)))
      (should (string-search "hello" (harness-redact-hosted--read cli-log)))
      (should (harness-redact-hosted--clean-p s))
      (should-not (cl-find-if (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes s)))
      (let ((record (car (harness-redact-hosted--redactions s)))
            (hint (car (last (harness-redact-hosted--hints s)))))
        (should (equal "user" (plist-get record :by)))
        (should (equal "reset" (plist-get record :provider)))
        (should (member cli-log (plist-get record :files)))
        (should (string-search "starts over from the redacted transcript" hint))
        (should (string-search (harness-redact-hosted--fp 0) hint)))
      ;; What the model provider and the CLI already held is out of the harness's reach.
      (should (> (harness-redact-hosted--file-count chain) 0))
      ;; Turn 2: a new CLI process, spawned to start a session, is told the redacted transcript.
      (delete-file harness-redact-hosted--argv-file)
      (harness-redact-hosted--quietly (lambda () (harness-redact-hosted--turn s "recall")) 10)
      (let* ((argv (harness-redact-hosted--argv))
             (inputs (harness-redact-hosted--inputs))
             (row (car (last inputs)))
             (text (plist-get row :text))
             (reply (harness-redact-hosted--last-reply s)))
        (should argv)
        (should-not (member "--resume" argv))
        (should-not (member "--fork-session" argv))
        (should (= 2 (length inputs)))
        (should-not (plist-get row :resumed))
        (should-not (harness-json-true-p (plist-get row :forked)))
        (should (string-prefix-p "fake-" (plist-get row :session)))
        (should-not (equal cli (plist-get row :session)))
        (should (equal (plist-get row :session) (harness-redact-hosted--cli-id s)))
        ;; It was sent the transcript with placeholders and the new message after it.
        (should (string-prefix-p "This conversation continues an earlier one" text))
        (should (string-suffix-p "recall" text))
        (should (string-search (harness-redact-hosted--placeholder 0) text))
        (should (string-search (harness-redact-hosted--placeholder 1) text))
        (should (= 0 (harness-redact-hosted--text-count text)))
        ;; It answered from that, and what it said holds no key.
        (should (string-prefix-p "I remember: " reply))
        (should (string-search (harness-redact-hosted--placeholder 0) reply))
        (should (= 0 (harness-redact-hosted--text-count reply))))
      ;; The old conversation was not written to, and the session no longer points at it:
      ;; no node of its log or memory, nor its provider state or node, names the CLI
      ;; session.  (The record of the redaction does name the log it cleaned, which is
      ;; called after the CLI session.)
      (should (equal chain-before (harness-redact-hosted--read chain)))
      (should-not (string-search cli (harness-redact-hosted--read (harness-redact-hosted--log s))))
      (should-not (string-search cli (harness-redact-hosted--printed (harness-call 'session/nodes s))))
      (let ((session (harness-call 'session/get s)))
        (should-not (string-search cli (harness-redact-hosted--printed
                                        (list (plist-get session :provider-state)
                                              (plist-get session :provider-node))))))
      ;; The whole session, and every place the harness and the CLI keep text, is clean.
      (should (harness-redact-hosted--clean-p s))
      (should (>= (length (harness-redact-hosted--nodes-of s 'user)) 2))
      (should-not (harness-redact-hosted--tree-holders harness-state-directory))
      (should-not (harness-redact-hosted--tree-holders harness-provider-claude-projects-directory)))))

(ert-deftest harness-redact-hosted-a-session-redacted-during-a-turn-is-finished-when-the-turn-ends ()
  "A hosted session redacted in the middle of a turn loses nothing and ends clean.
The turn is held in the middle of its reply.  The redaction cleans what
the session can be cleaned of at once -- its log, its memory, its record --
and waits for the end of the turn for the rest: the CLI is writing to its
log and holds the conversation, so neither can be taken from under it.  The
turn goes on and its reply is whole.  Once it ends the CLI log is clean, the
provider conversation is dropped, the session says so in a second record,
and its next turn starts a new CLI session from the redacted transcript."
  (harness-redact-hosted-with
    (let* ((harness-secrets-mask nil)
           (gate (expand-file-name "gate" (harness-test-temp-dir)))
           (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_GATE=" gate) process-environment))
           (cwd (harness-test-temp-dir))
           (state-file (harness-redact-hosted--write
                        (expand-file-name "terraform.tfstate" (harness-test-temp-dir))
                        (harness-redact-hosted--state-text 42)))
           (leak (harness-redact-hosted--leaky-session cwd))
           (s (plist-get leak :sid))
           (cli (plist-get leak :cli))
           (proc (harness-provider-claude-session-process (gethash s harness-provider-claude--sessions)))
           (cli-log (harness-redact-hosted--cli-log cli (plist-get leak :prompt)))
           (promise (harness-call 'agent/prompt s "slow-text")))
      ;; The second turn runs, and is held after the first piece of its reply.
      (harness-test-wait (lambda () (harness-call 'agent/running s)) 30 "the turn to run")
      (harness-test-wait (lambda () (equal "Hel" (harness-redact-hosted--last-reply s))) 30
                         "the reply to begin")
      (let* ((report (harness-redact-hosted--quietly
                      (lambda ()
                        (harness-call 'secrets/redact
                                      (list :source (harness-redact-hosted--reference state-file)
                                            :scope 'session :sessions (list s) :mode 'redact
                                            :origin '(:kind user) :reason "Found while it ran.")))
                      3))
             (entry (car (plist-get report :sessions)))
             (pending (plist-get (plist-get (harness-call 'session/get s) :ext) :redaction-pending)))
        ;; It says the session waits, and what is left for the end of its turn.
        (should (equal (list s) (plist-get report :deferred)))
        (should-not (plist-get report :complete))
        (should (plist-get entry :running))
        (should (equal "deferred" (format "%s" (plist-get entry :provider))))
        (should (cl-some (lambda (line) (string-search "provider's log" line)) (plist-get report :remaining)))
        (should (= 0 (harness-redact-hosted--text-count report)))
        ;; The session is clean at once, and what waits is named by label and fingerprint.
        (should (harness-redact-hosted--clean-p s))
        (should (equal (harness-redact-hosted--sorted
                        (list (harness-redact-hosted--fp 0) (harness-redact-hosted--fp 1)))
                       (harness-redact-hosted--sorted
                        (mapcar (lambda (p) (plist-get p :fingerprint)) pending))))
        (should (= 0 (harness-redact-hosted--text-count pending))))
      ;; What belongs to the running turn is left alone: its conversation, its process, its log.
      (should (equal cli (harness-redact-hosted--cli-id s)))
      (should (process-live-p proc))
      (should (> (harness-redact-hosted--file-count cli-log) 0))
      (should (equal "Hel" (harness-redact-hosted--last-reply s)))
      ;; The turn goes on to its end, the reply whole.
      (write-region "" nil (concat gate ".1") nil 'silent)
      (should (eq 'end-turn (plist-get (harness-test-await promise 30) :stop-reason)))
      (harness-test-wait (lambda () (null (harness-redact-hosted--provider-state s))) 30
                         "the provider conversation to be dropped")
      (should (equal "Hello" (harness-redact-hosted--last-reply s)))
      ;; Then the rest is done: the CLI log is clean, its process gone, the flag cleared.
      (should-not (process-live-p proc))
      (should (= 0 (harness-redact-hosted--file-count cli-log)))
      (should-not (plist-get (plist-get (harness-call 'session/get s) :ext) :redaction-pending))
      (should (harness-redact-hosted--clean-p s))
      (should-not (cl-find-if (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes s)))
      (let ((records (harness-redact-hosted--redactions s))
            (hints (harness-redact-hosted--hints s)))
        (should (equal '("deferred" "reset") (mapcar (lambda (r) (plist-get r :provider)) records)))
        (should-not (plist-get (nth 0 records) :after-turn))
        (should (eq t (plist-get (nth 1 records) :after-turn)))
        (should (member cli-log (plist-get (nth 1 records) :files)))
        (should (= 2 (length hints)))
        (should (string-search "after its turn ended" (nth 1 hints))))
      ;; Nothing was lost or torn: a restart would load the nodes the session holds.
      (should (equal (harness-redact-hosted--sorted (harness-redact-hosted--replayed-ids s))
                     (harness-redact-hosted--sorted
                      (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes s)))))
      ;; The next turn starts a new CLI session from the redacted transcript.
      (delete-file harness-redact-hosted--argv-file)
      (harness-redact-hosted--turn s "recall")
      (let* ((argv (harness-redact-hosted--argv))
             (row (car (last (harness-redact-hosted--inputs))))
             (text (plist-get row :text)))
        (should argv)
        (should-not (member "--resume" argv))
        (should-not (plist-get row :resumed))
        (should-not (equal cli (plist-get row :session)))
        (should (string-prefix-p "This conversation continues an earlier one" text))
        (should (string-search (harness-redact-hosted--placeholder 0) text))
        (should (string-search (harness-redact-hosted--placeholder 1) text))
        (should (= 0 (harness-redact-hosted--text-count text))))
      ;; (The fake CLI answers by the words of what it is sent, "slow-text" before "recall",
      ;; and the history holds the former: its reply says nothing of the history.)
      (should (harness-redact-hosted--clean-p s))
      (should-not (harness-redact-hosted--tree-holders harness-state-directory))
      (should-not (harness-redact-hosted--tree-holders harness-provider-claude-projects-directory)))))

(defun harness-redact-hosted--load-copilot ()
  "Load the Copilot provider over its fake CLI, with nothing of earlier tests."
  (harness-test-load-module 'provider-copilot)
  (setq harness-provider-copilot-program (harness-test-fixture "fake-copilot.py"))
  (harness-provider-copilot-close-all)
  (clrhash harness-provider-copilot--sessions)
  (clrhash harness-provider-copilot--catalogue)
  (setq harness-provider-copilot--status nil
        harness-provider-copilot--asked nil
        harness-provider-copilot--refresh nil
        harness-provider-copilot--probe nil))

(defun harness-redact-hosted--copilot-requests (log method)
  "Return the params of the requests of METHOD the fake Copilot CLI logged in LOG."
  (and (file-exists-p log)
       (cl-loop for line in (split-string (harness-read-file log) "\n" t)
                for entry = (harness-json-parse line)
                when (equal (plist-get entry :method) method)
                collect (or (plist-get entry :params) :empty))))

(ert-deftest harness-redact-hosted-a-copilot-session-continues-from-the-redacted-transcript ()
  "The other hosted loop does not resume its conversation after a redaction either.
A session on Copilot leaks the keys as the one on Claude Code does.  The
Copilot CLI keeps the events of the session in a directory of its own; the
redaction cleans them, and drops the session's Copilot session.  Its next
turn asks the CLI for a new session, not to resume the old one, and the
first message of that session is the transcript with the placeholders in
the keys' places."
  (harness-redact-hosted-with
    (harness-redact-hosted--load-copilot)
    (unwind-protect
        (let* ((harness-secrets-mask nil)
               (harness-provider-copilot-state-directory (harness-test-temp-dir))
               (log (expand-file-name "copilot.jsonl" (harness-test-temp-dir)))
               (process-environment (cons (concat "HARNESS_FAKE_COPILOT_LOG=" log) process-environment))
               (state-file (harness-redact-hosted--write
                            (expand-file-name "terraform.tfstate" (harness-test-temp-dir))
                            (harness-redact-hosted--state-text 42)))
               (leak (harness-redact-hosted--leaky-session (harness-test-temp-dir) "copilot:gpt-5.4"))
               (s (plist-get leak :sid))
               (old (plist-get (harness-redact-hosted--provider-state s) :copilot-session-id))
               (events (expand-file-name (format "%s/events.jsonl" old)
                                         harness-provider-copilot-state-directory)))
          ;; The CLI keeps the events of the session: what was said and what the tool returned.
          (harness-redact-hosted--write
           events
           (concat (harness-json-encode-text
                    (list :type "user.message" :data (list :content (plist-get leak :prompt))))
                   "\n"
                   (harness-json-encode-text
                    (list :type "tool.execution_complete"
                          :data (list :result (harness-redact-hosted--output-text))))
                   "\n"))
          (should (stringp old))
          (should (> (harness-redact-hosted--file-count events) 0))
          (should (= 1 (length (harness-redact-hosted--copilot-requests log "session.create"))))
          (should-not (harness-redact-hosted--clean-p s))
          (let* ((report (harness-call 'secrets/redact
                                       (list :source (harness-redact-hosted--reference state-file)
                                             :scope 'session :sessions (list s) :mode 'redact
                                             :origin '(:kind user) :reason "Found in a diff.")))
                 (entry (car (plist-get report :sessions))))
            (should (eq t (plist-get report :complete)))
            (should (>= (plist-get entry :copilot) 1))
            (should (equal "reset" (format "%s" (plist-get entry :provider)))))
          (should-not (harness-redact-hosted--provider-state s))
          (should (= 0 (harness-redact-hosted--file-count events)))
          (should (string-search (harness-redact-hosted--placeholder 0)
                                 (harness-redact-hosted--read events)))
          (should (harness-redact-hosted--clean-p s))
          ;; The next turn creates a Copilot session; it resumes none.
          (harness-redact-hosted--turn s "and now?")
          (let* ((creates (harness-redact-hosted--copilot-requests log "session.create"))
                 (sends (harness-redact-hosted--copilot-requests log "session.send"))
                 (prompt (plist-get (car (last sends)) :prompt))
                 (new (plist-get (harness-redact-hosted--provider-state s) :copilot-session-id)))
            (should (= 2 (length creates)))
            (should-not (harness-redact-hosted--copilot-requests log "session.resume"))
            (should (stringp new))
            (should-not (equal old new))
            (should (equal new (plist-get (car (last creates)) :sessionId)))
            (should (string-prefix-p "This conversation continues an earlier one" prompt))
            (should (string-suffix-p "and now?" prompt))
            (should (string-search (harness-redact-hosted--placeholder 0) prompt))
            (should (string-search (harness-redact-hosted--placeholder 1) prompt))
            (should (= 0 (harness-redact-hosted--text-count prompt))))
          (should (harness-redact-hosted--clean-p s))
          (should-not (harness-redact-hosted--tree-holders harness-state-directory))
          (should-not (harness-redact-hosted--tree-holders harness-provider-copilot-state-directory)))
      (harness-provider-copilot-close-all))))

(ert-deftest harness-redact-hosted-without-a-redaction-the-session-resumes-its-cli-conversation ()
  "Without a redaction the same session resumes its CLI session.
The CLI session remembers the key.  The CLI process goes, as it does when
Emacs restarts; the next turn is spawned with --resume on the CLI session
the provider state names, and the CLI, which kept the conversation,
repeats the message that held the key.  So the new CLI session of the
test above is the redaction's doing."
  (harness-redact-hosted-with
    (let* ((harness-secrets-mask nil)
           (leak (harness-redact-hosted--leaky-session (harness-test-temp-dir)))
           (s (plist-get leak :sid))
           (cli (plist-get leak :cli)))
      (harness-provider-claude-close s)
      (delete-file harness-redact-hosted--argv-file)
      (harness-redact-hosted--turn s "recall")
      (let ((argv (harness-redact-hosted--argv))
            (row (car (last (harness-redact-hosted--inputs)))))
        (should (equal cli (cadr (member "--resume" argv))))
        (should (equal cli (plist-get row :resumed)))
        (should (equal cli (plist-get row :session)))
        (should (equal "recall" (plist-get row :text))))
      (should (equal cli (harness-redact-hosted--cli-id s)))
      (should (string-search harness-redact-hosted--secret-key (harness-redact-hosted--last-reply s)))
      (should-not (harness-redact-hosted--clean-p s)))))

(provide 'harness-redact-hosted-test)
;;; harness-redact-hosted-test.el ends here
