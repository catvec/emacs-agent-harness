;;; harness-provider-claude-redact-test.el --- Taking a secret out of the CLIs' own logs  -*- lexical-binding: t; -*-

;;; Commentary:

;; `provider/claude-redact-logs' cleans the conversation logs of Claude
;; Code (PROJECTS/SLUG/ID.jsonl and what lies under PROJECTS/SLUG/ID/),
;; `provider/copilot-redact-logs' the session state of the Copilot CLI.
;; The logs here are written to temporary directories; the projects
;; directory and the state directory are bound to them, so no test reads
;; the real ones.  Every secret is a fake one, built when the test runs,
;; so that no value that looks real is committed.  A test that fails
;; shows the values it compared; they are made up.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-provider-claude-program)
(defvar harness-provider-claude-projects-directory)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-copilot-program)
(defvar harness-provider-copilot-state-directory)
(defvar harness-provider-copilot--sessions)
(defvar harness-provider-copilot--catalogue)
(declare-function harness-provider-claude-close "harness-provider-claude")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude-log-files "harness-provider-claude")
(declare-function harness-provider-claude--make-session "harness-provider-claude")
(declare-function harness-provider-claude--projects-directory "harness-provider-claude")
(declare-function harness-provider-copilot-close "harness-provider-copilot")
(declare-function harness-provider-copilot-close-all "harness-provider-copilot")
(declare-function harness-provider-copilot--make-session "harness-provider-copilot")
(declare-function harness-provider-copilot--state-directory "harness-provider-copilot")

;;;; Fakes

(defconst harness-provider-claude-redact-test--key
  (concat "FAKEKEY/" (make-string 20 ?z) "+" (make-string 12 ?y))
  "A fake secret key, with a slash that some JSON writers escape.")

(defconst harness-provider-claude-redact-test--id (concat "FAKEID" (make-string 14 ?x))
  "A fake access key id.")

(defconst harness-provider-claude-redact-test--cli-1 "5c1a0001-aaaa-4bbb-8ccc-000000000001"
  "The CLI session whose log, sub-agent log and spilled output hold the secrets.")

(defconst harness-provider-claude-redact-test--cli-2 "5c1a0002-aaaa-4bbb-8ccc-000000000002"
  "A CLI session whose log holds none.")

(defconst harness-provider-claude-redact-test--cli-3 "5c1a0003-aaaa-4bbb-8ccc-000000000003"
  "A CLI session of the other project, whose log holds the id.")

(defconst harness-provider-claude-redact-test--slug-a "-home-someone-project-a"
  "The directory of a project's logs.")

(defconst harness-provider-claude-redact-test--slug-b "-home-someone-project-b"
  "The directory of another project's logs.")

(defun harness-provider-claude-redact-test--secrets ()
  "Return the fake key and id as secrets, labelled."
  (list (harness-redaction-secret harness-provider-claude-redact-test--key "spaces key")
        (harness-redaction-secret harness-provider-claude-redact-test--id "spaces id")))

(defun harness-provider-claude-redact-test--placeholder (index)
  "Return the placeholder of the secret INDEX of the fake secrets."
  (harness-redaction-placeholder (nth index (harness-provider-claude-redact-test--secrets))))

;;;; Files

(defun harness-provider-claude-redact-test--json (object)
  "Return OBJECT, an alist, as a line of JSON text."
  (let ((json (json-serialize object)))
    (if (multibyte-string-p json) json (decode-coding-string json 'utf-8-unix))))

(defun harness-provider-claude-redact-test--write (root name text &optional recent)
  "Write TEXT to the file NAME under ROOT; return its path.
The file is made an hour old, unless RECENT is non-nil: a file the CLI
may be writing is a case of its own."
  (let ((file (expand-file-name name root))
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region text nil file nil 'silent)
    (unless recent
      (set-file-times file (time-subtract (current-time) 3600)))
    file))

(defun harness-provider-claude-redact-test--lines (&rest lines)
  "Return LINES as the text of a JSON lines file."
  (concat (mapconcat #'identity lines "\n") "\n"))

(defun harness-provider-claude-redact-test--read (file)
  "Return the content of FILE, read as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-provider-claude-redact-test--bytes (file)
  "Return the bytes of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun harness-provider-claude-redact-test--file-lines (file)
  "Return the lines of FILE."
  (split-string (harness-provider-claude-redact-test--read file) "\n" t))

(defun harness-provider-claude-redact-test--count (file)
  "Return how many times the fake secrets occur in FILE, JSON escapes included."
  (harness-redaction-file-count file (harness-provider-claude-redact-test--secrets)))

(defun harness-provider-claude-redact-test--holds-p (object value)
  "Non-nil when OBJECT, printed either way, holds the string VALUE.
A string prints with its quotes and backslashes escaped by `prin1' and
as it is without: a value with a quote in it hides from a search of the
first, so both are searched."
  (and (or (string-search value (prin1-to-string object t))
           (string-search (substring (prin1-to-string value) 1 -1) (prin1-to-string object)))
       t))

(defun harness-provider-claude-redact-test--layout (root)
  "Write the logs of the fixture under ROOT; return a plist naming its files.
Session 1 has a log with the fake secrets in its entries (a user
message, a tool result with a toolUseResult object, a line that escapes
its slashes) beside lines that hold none, a sub-agent's log and an
output the CLI spilled to a file, in the directory of the session; the
project's memory holds the key.  Session 3 has a log with the id, and
session 2 one with no secret at all."
  (let* ((key harness-provider-claude-redact-test--key)
         (id harness-provider-claude-redact-test--id)
         (cli-1 harness-provider-claude-redact-test--cli-1)
         (cli-2 harness-provider-claude-redact-test--cli-2)
         (cli-3 harness-provider-claude-redact-test--cli-3)
         (a harness-provider-claude-redact-test--slug-a)
         (b harness-provider-claude-redact-test--slug-b)
         (json #'harness-provider-claude-redact-test--json)
         (write #'harness-provider-claude-redact-test--write)
         (lines #'harness-provider-claude-redact-test--lines))
    (list
     :main
     (funcall
      write root (format "%s/%s.jsonl" a cli-1)
      (funcall
       lines
       ;; Written by a program with its own spacing and escapes: kept byte for byte.
       "{\"type\":\"summary\",  \"summary\":\"caf\\u00e9 \\/ fine\", \"n\": 1.50, \"leafUuid\":\"x\"}"
       (funcall json `((type . "user") (uuid . "u-1") (sessionId . ,cli-1)
                       (message . ((role . "user")
                                   (content . ,(format "set the key to %s, please" key))))))
       (funcall json `((type . "user") (uuid . "u-2") (sessionId . ,cli-1)
                       (message . ((role . "user")
                                   (content . [((type . "tool_result") (tool_use_id . "toolu_1")
                                                (content . ,(format "ID=%s KEY=%s" id key)))])))
                       (toolUseResult . ((stdout . ,(format "ID=%s\nKEY=%s\n" id key))
                                         (stderr . "") (interrupted . :false)))))
       ;; A writer that escapes slashes.
       (format "{\"type\":\"user\",\"uuid\":\"u-3\",\"message\":{\"role\":\"user\",\"content\":\"token=%s\"}}"
               (string-replace "/" "\\/" key))
       (funcall json `((type . "assistant") (uuid . "u-4") (sessionId . ,cli-1)
                       (message . ((role . "assistant") (content . "Done."))) (costUSD . 0.25)))
       (funcall json `((type . "user") (uuid . "u-5") (sessionId . ,cli-1)
                       (message . ((role . "user") (content . ,(format "AWS_ACCESS_KEY_ID=%s" id))))))))
     :sub
     (funcall write root (format "%s/%s/subagents/agent-1.jsonl" a cli-1)
              (funcall lines
                       (funcall json `((type . "user") (uuid . "s-1")
                                       (message . ((role . "user") (content . "go")))))
                       (funcall json `((type . "user") (uuid . "s-2")
                                       (toolUseResult . ((stdout . ,(format "KEY=%s" key)) (stderr . "")))))))
     :spill
     (funcall write root (format "%s/%s/tool-results/toolu_1.txt" a cli-1)
              (format "aws secret key: %s\nregion ams3\n" key))
     :memory
     (funcall write root (format "%s/memory/MEMORY.md" a)
              (format "# Notes\n- the key is %s\n" key))
     :other
     (funcall write root (format "%s/%s.jsonl" b cli-3)
              (funcall lines
                       (funcall json `((type . "user") (uuid . "o-1")
                                       (message . ((role . "user") (content . ,(format "id %s" id))))))))
     :clean
     (funcall write root (format "%s/%s.jsonl" b cli-2)
              (funcall lines
                       (funcall json `((type . "user") (uuid . "c-1")
                                       (message . ((role . "user") (content . "nothing to see")))))
                       "{\"type\":\"assistant\",\"uuid\":\"c-2\",\"n\":  2.0}")))))

(defun harness-provider-claude-redact-test--all (files)
  "Return the paths in the plist FILES, sorted."
  (sort (cl-loop for (_ file) on files by #'cddr collect file) #'string<))

;;;; Setup

(defun harness-provider-claude-redact-test--setup ()
  "Load the session module and the Claude Code provider on a clean bus.
Their code is compiled once for the whole run, not once for each test."
  (let ((harness-state-directory harness-test-state-root))
    (harness-test-reset-bus)
    (dolist (m '(provider provider-claude store project session))
      (harness-test-load-module m)))
  ;; Nothing a test does may start the user's own `claude'.
  (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
  (harness-provider-claude-close-all)
  (clrhash harness-provider-claude--sessions)
  (clrhash harness-sessions))

(defmacro harness-provider-claude-redact-test--with-logs (&rest body)
  "Run BODY with the Claude Code provider and a projects directory of its own.
BODY sees ROOT, the projects directory, and CWD, a directory for sessions."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-provider-claude-redact-test--setup)
     (let* ((root (harness-test-temp-dir))
            (cwd (harness-test-temp-dir))
            (harness-provider-claude-projects-directory root))
       (unwind-protect (progn ,@body)
         (harness-provider-claude-close-all)
         (ignore-errors (delete-directory root t))
         (ignore-errors (delete-directory cwd t))))))

(defun harness-provider-claude-redact-test--session (sid cli cwd &rest state)
  "Make session SID, whose provider state names the CLI session CLI, in CWD.
STATE adds keys to the state."
  (harness-call 'session/create :id sid :cwd cwd :model "claude:claude-fable-5-1")
  (harness-call 'session/set-provider-state sid
                (append (list :cli-session-id cli :provider "claude") state))
  sid)

(defun harness-provider-claude-redact-test--live (sid cli &rest slots)
  "Give SID a CLI process record in the CLI session CLI.
SLOTS are more slots of the record, as the keywords of its constructor."
  (puthash sid (apply #'harness-provider-claude--make-session :id sid :cli-session-id cli slots)
           harness-provider-claude--sessions))

(defun harness-provider-claude-redact-test--running (&rest sids)
  "Have the agent say that the sessions SIDS run a turn, and no others."
  (harness-register-method 'agent/running
                           (lambda (&optional sid) (and sid (member sid sids) t))))

(defun harness-provider-claude-redact-test--entry (result file)
  "Return the entry of FILE in RESULT, the answer of a redaction, or nil."
  (cl-find file (plist-get result :files) :key (lambda (e) (plist-get e :file)) :test #'equal))

;;;; Where the logs are

(ert-deftest harness-provider-claude-projects-directory-follows-the-setting-and-the-environment ()
  "Unset, it is `projects' in CLAUDE_CONFIG_DIR or, without it, in ~/.claude."
  (harness-provider-claude-redact-test--with-logs
    (let ((harness-provider-claude-projects-directory nil))
      (let ((process-environment (cons "CLAUDE_CONFIG_DIR=/somewhere/claude-config" process-environment)))
        (should (equal "/somewhere/claude-config/projects/"
                       (harness-provider-claude--projects-directory))))
      ;; A name without a value unsets the variable; an empty one counts as unset.
      (dolist (entry '("CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR="))
        (let ((process-environment (cons entry process-environment)))
          (should (equal (file-name-as-directory (expand-file-name "~/.claude/projects"))
                         (harness-provider-claude--projects-directory)))))
      ;; The setting wins, and a blank one is none: it would name this directory.
      (let ((harness-provider-claude-projects-directory "/elsewhere/logs")
            (process-environment (cons "CLAUDE_CONFIG_DIR=/somewhere/claude-config" process-environment)))
        (should (equal "/elsewhere/logs/" (harness-provider-claude--projects-directory))))
      (dolist (blank '("" "  "))
        (let ((harness-provider-claude-projects-directory blank)
              (process-environment (cons "CLAUDE_CONFIG_DIR=/somewhere/claude-config" process-environment)))
          (should (equal "/somewhere/claude-config/projects/"
                         (harness-provider-claude--projects-directory))))))))

(ert-deftest harness-provider-claude-log-files-names-the-files-of-a-cli-session ()
  "A session's files are its log in any project and all that lies under its directory."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (cli-1 harness-provider-claude-redact-test--cli-1)
           (cli-3 harness-provider-claude-redact-test--cli-3)
           (session-1 (sort (list (plist-get files :main) (plist-get files :sub)
                                  (plist-get files :spill))
                            #'string<)))
      (should (equal session-1 (harness-provider-claude-log-files (list cli-1))))
      (should (equal session-1 (harness-provider-claude-log-files cli-1)))
      (should (equal session-1 (harness-provider-claude-log-files (vector cli-1))))
      (should (equal (list (plist-get files :other)) (harness-provider-claude-log-files (list cli-3))))
      (should (equal (sort (append session-1 (list (plist-get files :other))) #'string<)
                     (harness-provider-claude-log-files (list cli-3 cli-1 cli-3))))
      ;; t is every file, the project's memory and a session with nothing to find too.
      (should (equal (harness-provider-claude-redact-test--all files)
                     (harness-provider-claude-log-files t)))
      ;; An id of no session, and what is no id at all, name nothing.
      (should-not (harness-provider-claude-log-files (list "no-such-session")))
      (should-not (harness-provider-claude-log-files
                   (list ".." "." "" nil 7 (format "../%s/%s"
                                                   harness-provider-claude-redact-test--slug-b cli-3)
                         (format "%s/%s" harness-provider-claude-redact-test--slug-b cli-3))))
      (should-not (harness-provider-claude-log-files nil))
      (should-not (harness-provider-claude-log-files :false))
      ;; Without the directory there is nothing, and no error.
      (let ((harness-provider-claude-projects-directory (expand-file-name "missing" root)))
        (should-not (harness-provider-claude-log-files t))
        (should-not (harness-provider-claude-log-files (list cli-1)))))))

;;;; A scan counts and changes nothing

(ert-deftest harness-provider-claude-redact-logs-dry-run-counts-and-changes-nothing ()
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (before (mapcar (lambda (f) (cons f (harness-provider-claude-redact-test--bytes f)))
                           (harness-provider-claude-redact-test--all files)))
           (times (mapcar (lambda (f) (cons f (file-attribute-modification-time (file-attributes f))))
                          (harness-provider-claude-redact-test--all files)))
           (closed nil))
      (harness-provider-claude-redact-test--session
       "s-one" harness-provider-claude-redact-test--cli-1 cwd)
      (harness-provider-claude-redact-test--live "s-one" harness-provider-claude-redact-test--cli-1)
      (cl-letf (((symbol-function 'harness-provider-claude-close)
                 (lambda (sid) (push sid closed) t)))
        (let ((result (harness-call 'provider/claude-redact-logs
                                    (harness-provider-claude-redact-test--secrets) t t)))
          (should (equal (file-name-as-directory root) (plist-get result :directory)))
          (should (= 6 (plist-get result :scanned)))
          ;; The key and the id, here and there: 7 in the log, then 1 in each other file.
          (should (equal (+ 7 1 1 1 1) (plist-get result :count)))
          (should (equal 5 (length (plist-get result :files))))
          (dolist (entry (plist-get result :files))
            (should (eq 'found (plist-get entry :status))))
          (let ((main (harness-provider-claude-redact-test--entry result (plist-get files :main))))
            (should (= 7 (plist-get main :count)))
            (should (equal harness-provider-claude-redact-test--cli-1 (plist-get main :cli-session)))
            (should (equal '("s-one") (plist-get main :owners))))
          ;; The project's memory belongs to no CLI session; the log of the session with nothing is not listed.
          (let ((memory (harness-provider-claude-redact-test--entry result (plist-get files :memory))))
            (should-not (plist-get memory :cli-session))
            (should-not (plist-get memory :owners)))
          (should-not (harness-provider-claude-redact-test--entry result (plist-get files :clean)))
          (should-not (harness-provider-claude-redact-test--holds-p
                       result harness-provider-claude-redact-test--key))
          (should-not (harness-provider-claude-redact-test--holds-p
                       result harness-provider-claude-redact-test--id))))
      ;; Nothing was closed, written or touched.
      (should-not closed)
      (should (gethash "s-one" harness-provider-claude--sessions))
      (dolist (cell before)
        (should (equal (cdr cell) (harness-provider-claude-redact-test--bytes (car cell)))))
      (dolist (cell times)
        (should (time-equal-p (cdr cell)
                              (file-attribute-modification-time (file-attributes (car cell)))))))))

;;;; Redacting

(ert-deftest harness-provider-claude-redact-logs-leaves-no-copy-and-keeps-the-other-lines ()
  "No file holds a needle afterwards, each line is still JSON and the lines without one are the same bytes."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (key harness-provider-claude-redact-test--key)
           (id harness-provider-claude-redact-test--id)
           (jsonl (list (plist-get files :main) (plist-get files :sub) (plist-get files :other)))
           (old (mapcar #'harness-provider-claude-redact-test--file-lines jsonl))
           (clean-bytes (harness-provider-claude-redact-test--bytes (plist-get files :clean)))
           (result (harness-call 'provider/claude-redact-logs secrets t)))
      (should (equal (+ 7 1 1 1 1) (plist-get result :count)))
      (should (= 5 (length (plist-get result :files))))
      (dolist (entry (plist-get result :files))
        (should (eq 'redacted (plist-get entry :status)))
        (should (> (plist-get entry :count) 0)))
      ;; Not one copy is left, in any file, in any spelling.
      (dolist (file (harness-provider-claude-log-files t))
        (should (= 0 (harness-provider-claude-redact-test--count file)))
        (let ((text (harness-provider-claude-redact-test--read file)))
          (should-not (string-search key text))
          (should-not (string-search (string-replace "/" "\\/" key) text))
          (should-not (string-search id text))))
      ;; A line the secrets were not in is the very bytes it was.
      (cl-loop for file in jsonl
               for before in old
               for after = (harness-provider-claude-redact-test--file-lines file)
               do (should (= (length before) (length after)))
               (cl-loop for b in before for a in after
                        do (if (or (string-search key b) (string-search id b)
                                   (string-search (string-replace "/" "\\/" key) b))
                               (progn (should-not (equal a b))
                                      (should (json-parse-string a))
                                      (should (string-search "[redacted: spaces " a)))
                             (should (equal a b)))))
      ;; The first and the fifth line of the main log, written with a spacing and an
      ;; escape a rewrite would change, are as they were.
      (should (equal (nth 0 (car old)) (nth 0 (harness-provider-claude-redact-test--file-lines (car jsonl)))))
      (should (equal (nth 4 (car old)) (nth 4 (harness-provider-claude-redact-test--file-lines (car jsonl)))))
      ;; The placeholders say which secret was here, and where.
      (let ((entries (harness-provider-claude-redact-test--file-lines (car jsonl))))
        (should (string-search (harness-provider-claude-redact-test--placeholder 0) (nth 1 entries)))
        (should (string-search (harness-provider-claude-redact-test--placeholder 0) (nth 3 entries)))
        (should (string-search (harness-provider-claude-redact-test--placeholder 1) (nth 5 entries)))
        (let* ((u2 (json-parse-string (nth 2 entries) :object-type 'alist))
               (stdout (alist-get 'stdout (alist-get 'toolUseResult u2))))
          (should (equal (format "ID=%s\nKEY=%s\n"
                                 (harness-provider-claude-redact-test--placeholder 1)
                                 (harness-provider-claude-redact-test--placeholder 0))
                         stdout))))
      ;; A text file is cleaned as text, and the file with nothing in it is not rewritten.
      (should (equal (format "aws secret key: %s\nregion ams3\n"
                             (harness-provider-claude-redact-test--placeholder 0))
                     (harness-provider-claude-redact-test--read (plist-get files :spill))))
      (should (equal clean-bytes (harness-provider-claude-redact-test--bytes (plist-get files :clean))))
      ;; The answer holds counts, names and statuses, never a value.
      (should-not (harness-provider-claude-redact-test--holds-p result key))
      (should-not (harness-provider-claude-redact-test--holds-p result id))
      ;; Once clean, a second run finds nothing.
      (let ((again (harness-call 'provider/claude-redact-logs secrets t)))
        (should (= 0 (plist-get again :count)))
        (should-not (plist-get again :files))
        (should (= 6 (plist-get again :scanned)))))))

(ert-deftest harness-provider-claude-redact-logs-writes-json-as-json ()
  "A placeholder that JSON must escape, a label with quotes, leaves valid JSON behind.
Text put into a JSON string as it stands would end the string early: the
files are read as the JSON they are, a line at a time or whole."
  (harness-provider-claude-redact-test--with-logs
    (let* ((key harness-provider-claude-redact-test--key)
           (secrets (list (harness-redaction-secret key "the \"prod\" key\\")))
           (placeholder (harness-redaction-placeholder (car secrets)))
           (log (harness-provider-claude-redact-test--write
                 root (format "%s/%s.jsonl" harness-provider-claude-redact-test--slug-a
                              harness-provider-claude-redact-test--cli-1)
                 (harness-provider-claude-redact-test--lines
                  (harness-provider-claude-redact-test--json
                   `((type . "user") (message . ((content . ,(format "the key is %s, ok" key)))))))))
           (index (harness-provider-claude-redact-test--write
                   root (format "%s/sessions-index.json" harness-provider-claude-redact-test--slug-a)
                   (format "{\n  \"entries\": [\n    {\"note\": \"%s\", \"n\": 2}\n  ]\n}\n" key))))
      (should (string-search "\"" placeholder))
      (let ((result (harness-call 'provider/claude-redact-logs secrets t)))
        (should (equal '(redacted redacted)
                       (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (let ((line (json-parse-string (car (harness-provider-claude-redact-test--file-lines log))
                                     :object-type 'alist)))
        (should (equal (format "the key is %s, ok" placeholder)
                       (alist-get 'content (alist-get 'message line)))))
      (let* ((document (json-parse-string (harness-provider-claude-redact-test--read index)
                                          :object-type 'alist :array-type 'list))
             (entry (car (alist-get 'entries document))))
        (should (equal placeholder (alist-get 'note entry)))
        (should (equal 2 (alist-get 'n entry))))
      (dolist (file (list log index))
        (should (= 0 (harness-redaction-file-count file secrets)))))))

(ert-deftest harness-provider-claude-redact-logs-only-looks-in-the-sessions-asked-for ()
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (result (harness-call 'provider/claude-redact-logs secrets
                                 (list harness-provider-claude-redact-test--cli-1))))
      (should (= 3 (plist-get result :scanned)))
      (should (equal (sort (list (plist-get files :main) (plist-get files :sub) (plist-get files :spill))
                           #'string<)
                     (sort (mapcar (lambda (e) (plist-get e :file)) (plist-get result :files)) #'string<)))
      ;; The rest still holds its copy.
      (should (> (harness-provider-claude-redact-test--count (plist-get files :other)) 0))
      (should (> (harness-provider-claude-redact-test--count (plist-get files :memory)) 0))
      (dolist (name '(:main :sub :spill))
        (should (= 0 (harness-provider-claude-redact-test--count (plist-get files name))))))))

(ert-deftest harness-provider-claude-redact-logs-cleans-a-line-that-is-no-json ()
  "The last line of a log the CLI was writing when it stopped is cut off in the middle."
  (harness-provider-claude-redact-test--with-logs
    (let* ((key harness-provider-claude-redact-test--key)
           (file (harness-provider-claude-redact-test--write
                  root (format "%s/%s.jsonl" harness-provider-claude-redact-test--slug-a
                               harness-provider-claude-redact-test--cli-1)
                  (concat "{\"type\":\"user\",\"uuid\":\"a\"}\n"
                          (format "{\"type\":\"user\",\"message\":{\"content\":\"half a line with %s" key))))
           (result (harness-call 'provider/claude-redact-logs
                                 (harness-provider-claude-redact-test--secrets) t)))
      (should (equal '(redacted) (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files))))
      (should (equal (concat "{\"type\":\"user\",\"uuid\":\"a\"}\n"
                             "{\"type\":\"user\",\"message\":{\"content\":\"half a line with "
                             (harness-provider-claude-redact-test--placeholder 0))
                     (harness-provider-claude-redact-test--read file)))
      (should (= 0 (harness-provider-claude-redact-test--count file))))))

(ert-deftest harness-provider-claude-redact-logs-counts-a-binary-file-and-leaves-it ()
  (harness-provider-claude-redact-test--with-logs
    (let* ((binary (concat "\0\0" harness-provider-claude-redact-test--key "\0"))
           (file (let ((coding-system-for-write 'no-conversion)
                       (path (expand-file-name "-proj/image.bin" root)))
                   (make-directory (file-name-directory path) t)
                   (write-region (string-to-unibyte binary) nil path nil 'silent)
                   (set-file-times path (time-subtract (current-time) 3600))
                   path))
           (result (harness-call 'provider/claude-redact-logs
                                 (harness-provider-claude-redact-test--secrets) t)))
      (should (= 1 (plist-get result :count)))
      (should (eq 'binary (plist-get (car (plist-get result :files)) :status)))
      (should (equal (string-to-unibyte binary) (harness-provider-claude-redact-test--bytes file))))))

(ert-deftest harness-provider-claude-redact-logs-reports-an-error-without-its-data ()
  "A file that fails is listed with what went wrong, but not with what the error quoted."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (key harness-provider-claude-redact-test--key)
           (real (symbol-function 'harness-redaction-file)))
      (cl-letf (((symbol-function 'harness-redaction-file)
                 (lambda (path secrets &rest options)
                   (if (equal path (plist-get files :spill))
                       (signal 'wrong-type-argument (list 'stringp key))
                     (apply real path secrets options)))))
        (let* ((result (harness-call 'provider/claude-redact-logs
                                     (harness-provider-claude-redact-test--secrets) t))
               (entry (harness-provider-claude-redact-test--entry result (plist-get files :spill))))
          (should (eq 'error (plist-get entry :status)))
          (should (equal "wrong-type-argument" (plist-get entry :error)))
          ;; The other files went on being cleaned.
          (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :main))))
          (should-not (harness-provider-claude-redact-test--holds-p result key))
          (should-not (harness-provider-claude-redact-test--holds-p result harness-provider-claude-redact-test--id)))))))

(ert-deftest harness-provider-claude-redact-logs-needs-secrets-and-a-directory ()
  (harness-provider-claude-redact-test--with-logs
    (let ((files (harness-provider-claude-redact-test--layout root))
          (bytes nil))
      (setq bytes (harness-provider-claude-redact-test--bytes (plist-get files :main)))
      ;; No secret: nothing is looked at.
      (let ((result (harness-call 'provider/claude-redact-logs nil t)))
        (should (= 0 (plist-get result :count)))
        (should (= 0 (plist-get result :scanned)))
        (should-not (plist-get result :files)))
      ;; A secret with no value has no needle either.
      (should (= 0 (plist-get (harness-call 'provider/claude-redact-logs
                                            (list (list :value "" :label "none")) t)
                              :count)))
      (should (equal bytes (harness-provider-claude-redact-test--bytes (plist-get files :main))))
      ;; No directory: no files, no error.
      (let ((harness-provider-claude-projects-directory (expand-file-name "missing" root)))
        (should (equal (list :directory (expand-file-name "missing/" root) :count 0 :scanned 0 :files nil)
                       (harness-call 'provider/claude-redact-logs
                                     (harness-provider-claude-redact-test--secrets) t)))))))

;;;; Sessions that own a log

(ert-deftest harness-provider-claude-redact-logs-defers-a-log-whose-owner-runs-a-turn ()
  "A running session may be writing its log: the file stays as it is until the turn is over."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (cli-1 harness-provider-claude-redact-test--cli-1)
           (main-bytes (harness-provider-claude-redact-test--bytes (plist-get files :main)))
           (sub-bytes (harness-provider-claude-redact-test--bytes (plist-get files :sub)))
           (closed nil))
      (harness-provider-claude-redact-test--session "s-one" cli-1 cwd)
      (harness-provider-claude-redact-test--live "s-one" cli-1)
      (harness-provider-claude-redact-test--running "s-one")
      (cl-letf* ((orig (symbol-function 'harness-provider-claude-close))
                 ((symbol-function 'harness-provider-claude-close)
                  (lambda (sid) (push sid closed) (funcall orig sid))))
        (let ((result (harness-call 'provider/claude-redact-logs secrets t)))
          ;; Every file of the session waits; the others are cleaned.
          (should (= 5 (length (plist-get result :files))))
          (dolist (name '(:main :sub :spill))
            (should (eq 'deferred (plist-get (harness-provider-claude-redact-test--entry
                                              result (plist-get files name))
                                             :status))))
          (dolist (name '(:memory :other))
            (should (eq 'redacted (plist-get (harness-provider-claude-redact-test--entry
                                              result (plist-get files name))
                                             :status))))))
      (should (equal main-bytes (harness-provider-claude-redact-test--bytes (plist-get files :main))))
      (should (equal sub-bytes (harness-provider-claude-redact-test--bytes (plist-get files :sub))))
      (should (> (harness-provider-claude-redact-test--count (plist-get files :spill)) 0))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :other))))
      ;; Its process was left running: it is not asked to stop in the middle of a turn.
      (should-not closed)
      (should (gethash "s-one" harness-provider-claude--sessions))
      ;; Once the turn is over, the same call cleans what waited, and closes
      ;; the process once, however many files the session has.
      (harness-provider-claude-redact-test--running)
      (cl-letf* ((orig (symbol-function 'harness-provider-claude-close))
                 ((symbol-function 'harness-provider-claude-close)
                  (lambda (sid) (push sid closed) (funcall orig sid))))
        (let ((result (harness-call 'provider/claude-redact-logs secrets t)))
          (dolist (entry (plist-get result :files))
            (should (eq 'redacted (plist-get entry :status))))
          (should (= 3 (length (plist-get result :files))))))
      (should (equal '("s-one") closed))
      (should-not (gethash "s-one" harness-provider-claude--sessions))
      (dolist (file (harness-provider-claude-log-files t))
        (should (= 0 (harness-provider-claude-redact-test--count file)))))))

(ert-deftest harness-provider-claude-redact-logs-defers-a-log-whose-process-has-a-turn-in-flight ()
  "A process with a turn running says so itself, with no agent to ask."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (cli-1 harness-provider-claude-redact-test--cli-1))
      (harness-provider-claude-redact-test--live "s-one" cli-1 :active t)
      (should-not (harness-method-exists-p 'agent/running))
      (let ((result (harness-call 'provider/claude-redact-logs
                                  (harness-provider-claude-redact-test--secrets) (list cli-1))))
        (should (equal '(deferred deferred deferred)
                       (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (should (> (harness-provider-claude-redact-test--count (plist-get files :main)) 0)))))

(ert-deftest harness-provider-claude-redact-logs-closes-the-owners-process-before-the-rewrite ()
  "A process left running would go on writing into the file that is replaced."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (cli-1 harness-provider-claude-redact-test--cli-1)
           (closed nil))
      (harness-provider-claude-redact-test--session "s-one" cli-1 cwd)
      (harness-provider-claude-redact-test--live "s-one" cli-1)
      (cl-letf* ((orig (symbol-function 'harness-provider-claude-close))
                 ((symbol-function 'harness-provider-claude-close)
                  (lambda (sid)
                    ;; What the file held when the process was told to go.
                    (push (list sid (harness-provider-claude-redact-test--count (plist-get files :main)))
                          closed)
                    (funcall orig sid))))
        (harness-call 'provider/claude-redact-logs secrets (list cli-1)))
      (setq closed (reverse closed))
      (should (equal "s-one" (car (car closed))))
      (should (> (cadr (car closed)) 0))
      (should-not (gethash "s-one" harness-provider-claude--sessions))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :main)))))))

(ert-deftest harness-provider-claude-redact-logs-stops-a-live-process-of-the-owner ()
  "Not a spy: a process that is up, in the CLI session the file belongs to, is gone afterwards."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (cli-1 harness-provider-claude-redact-test--cli-1)
           (other (start-process "idle-cli" nil "sleep" "300"))
           (process (start-process "idle-cli" nil "sleep" "300")))
      (unwind-protect
          (progn
            (set-process-query-on-exit-flag process nil)
            (set-process-query-on-exit-flag other nil)
            (harness-provider-claude-redact-test--session "s-one" cli-1 cwd)
            (harness-provider-claude-redact-test--live "s-one" cli-1 :process process)
            ;; A process in another CLI session is none of its business.
            (harness-provider-claude-redact-test--live
             "s-two" harness-provider-claude-redact-test--cli-2 :process other)
            (should (process-live-p process))
            (harness-call 'provider/claude-redact-logs
                          (harness-provider-claude-redact-test--secrets) (list cli-1))
            (should-not (process-live-p process))
            (should-not (gethash "s-one" harness-provider-claude--sessions))
            (should (process-live-p other))
            (should (gethash "s-two" harness-provider-claude--sessions))
            (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :main)))))
        (ignore-errors (delete-process process))
        (ignore-errors (delete-process other))))))

(ert-deftest harness-provider-claude-redact-logs-owners-are-the-sessions-holding-the-cli-session ()
  "A session holds a CLI session by its provider state, or by a process in it; a side request does not."
  (harness-provider-claude-redact-test--with-logs
    (let* ((files (harness-provider-claude-redact-test--layout root))
           (cli-1 harness-provider-claude-redact-test--cli-1)
           (cli-2 harness-provider-claude-redact-test--cli-2))
      ;; One by its state, a fork whose first turn will fork the CLI session,
      ;; one with a process in it and a state of another CLI session, a side request.
      (harness-provider-claude-redact-test--session "s-state" cli-1 cwd)
      (harness-provider-claude-redact-test--session "s-fork" cli-1 cwd :fork-pending t)
      (harness-provider-claude-redact-test--session "s-elsewhere" cli-2 cwd)
      (harness-provider-claude-redact-test--live "s-live" cli-1)
      (harness-provider-claude-redact-test--live "s-state#side-1" cli-1)
      (let* ((result (harness-call 'provider/claude-redact-logs
                                   (harness-provider-claude-redact-test--secrets) (list cli-1) t))
             (main (harness-provider-claude-redact-test--entry result (plist-get files :main))))
        (should (equal '("s-fork" "s-live" "s-state") (sort (copy-sequence (plist-get main :owners)) #'string<)))
        (should (equal cli-1 (plist-get main :cli-session))))
      ;; The memory of the project belongs to no session.
      (let ((memory (harness-provider-claude-redact-test--entry
                     (harness-call 'provider/claude-redact-logs
                                   (harness-provider-claude-redact-test--secrets) t t)
                     (plist-get files :memory))))
        (should-not (plist-get memory :owners))))))

;;;; Files that someone else may be writing

(ert-deftest harness-provider-claude-redact-logs-leaves-a-recent-log-nobody-here-owns ()
  "A `claude' started outside the harness may be writing it: it waits, and is cleaned once quiet."
  (harness-provider-claude-redact-test--with-logs
    (let* ((secrets (harness-provider-claude-redact-test--secrets))
           (file (harness-provider-claude-redact-test--write
                  root (format "%s/%s.jsonl" harness-provider-claude-redact-test--slug-a
                               harness-provider-claude-redact-test--cli-3)
                  (harness-provider-claude-redact-test--lines
                   (harness-provider-claude-redact-test--json
                    `((type . "user") (message . ((content . ,harness-provider-claude-redact-test--key))))))
                  t))
           (bytes (harness-provider-claude-redact-test--bytes file)))
      (let ((result (harness-call 'provider/claude-redact-logs secrets t)))
        (should (equal '(busy) (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files))))
        (should (= 1 (plist-get result :count))))
      (should (equal bytes (harness-provider-claude-redact-test--bytes file)))
      ;; A dry run says the same.
      (should (eq 'busy (plist-get (car (plist-get (harness-call 'provider/claude-redact-logs secrets t t)
                                                   :files))
                                   :status)))
      ;; A minute and a little later it is cleaned.
      (set-file-times file (time-subtract (current-time) 90))
      (should (eq 'redacted (plist-get (car (plist-get (harness-call 'provider/claude-redact-logs secrets t)
                                                       :files))
                                       :status)))
      (should (= 0 (harness-provider-claude-redact-test--count file))))))

(ert-deftest harness-provider-claude-redact-logs-cleans-a-recent-log-of-an-idle-owner ()
  "The owner's process is closed first, so a log written a moment ago is its own and safe to rewrite."
  (harness-provider-claude-redact-test--with-logs
    (let* ((cli-1 harness-provider-claude-redact-test--cli-1)
           (file (harness-provider-claude-redact-test--write
                  root (format "%s/%s.jsonl" harness-provider-claude-redact-test--slug-a cli-1)
                  (harness-provider-claude-redact-test--lines
                   (harness-provider-claude-redact-test--json
                    `((type . "user") (message . ((content . ,harness-provider-claude-redact-test--key))))))
                  t)))
      (harness-provider-claude-redact-test--session "s-one" cli-1 cwd)
      (harness-provider-claude-redact-test--live "s-one" cli-1)
      (let ((result (harness-call 'provider/claude-redact-logs
                                  (harness-provider-claude-redact-test--secrets) t)))
        (should (equal '(redacted) (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (should-not (gethash "s-one" harness-provider-claude--sessions))
      (should (= 0 (harness-provider-claude-redact-test--count file))))))

(ert-deftest harness-provider-claude-redact-logs-leaves-a-log-that-keeps-changing ()
  "A file that changes under the library's hands on every try is somebody else's."
  (harness-provider-claude-redact-test--with-logs
    (let* ((cli-3 harness-provider-claude-redact-test--cli-3)
           (file (harness-provider-claude-redact-test--write
                  root (format "%s/%s.jsonl" harness-provider-claude-redact-test--slug-b cli-3)
                  (harness-provider-claude-redact-test--lines
                   (harness-provider-claude-redact-test--json
                    `((type . "user") (message . ((content . ,harness-provider-claude-redact-test--id))))))))
           (real (symbol-function 'harness-redaction-rewrite-file)))
      (harness-provider-claude-redact-test--session "s-one" cli-3 cwd)
      ;; Each time the library is about to replace the file, a writer has appended to it.
      (cl-letf (((symbol-function 'harness-redaction-rewrite-file)
                 (lambda (path text &optional expect)
                   (let ((coding-system-for-write 'utf-8-unix))
                     (write-region "{\"type\":\"user\"}\n" nil path 'append 'silent))
                   (funcall real path text expect))))
        (let ((result (harness-call 'provider/claude-redact-logs
                                    (harness-provider-claude-redact-test--secrets) t)))
          (should (equal '(busy) (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files))))))
      (should (> (harness-provider-claude-redact-test--count file) 0)))))

;;;; The Copilot CLI

(defconst harness-provider-claude-redact-test--copilot-a "c0b11ca0-aaaa-4bbb-8ccc-00000000000a"
  "A Copilot session whose state holds the fake key.")

(defconst harness-provider-claude-redact-test--copilot-b "c0b11ca0-aaaa-4bbb-8ccc-00000000000b"
  "A Copilot session whose state holds the fake id.")

(defconst harness-provider-claude-redact-test--copilot-c "c0b11ca0-aaaa-4bbb-8ccc-00000000000c"
  "A Copilot session whose state holds nothing.")

(defun harness-provider-claude-redact-test--copilot-setup ()
  "Load the session module and the Copilot provider on a clean bus."
  (let ((harness-state-directory harness-test-state-root))
    (harness-test-reset-bus)
    (dolist (m '(provider provider-copilot store project session))
      (harness-test-load-module m)))
  ;; Nothing a test does may start the user's own `copilot'.
  (setq harness-provider-copilot-program (harness-test-fixture "fake-copilot.py"))
  (harness-provider-copilot-close-all)
  (clrhash harness-provider-copilot--sessions)
  (clrhash harness-provider-copilot--catalogue)
  (clrhash harness-sessions))

(defmacro harness-provider-claude-redact-test--with-copilot (&rest body)
  "Run BODY with the Copilot provider and a state directory of its own.
BODY sees ROOT, the state directory, and CWD, a directory for sessions."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-provider-claude-redact-test--copilot-setup)
     (let* ((root (harness-test-temp-dir))
            (cwd (harness-test-temp-dir))
            (harness-provider-copilot-state-directory root))
       (unwind-protect (progn ,@body)
         (harness-provider-copilot-close-all)
         (ignore-errors (delete-directory root t))
         (ignore-errors (delete-directory cwd t))))))

(defun harness-provider-claude-redact-test--copilot-layout (root)
  "Write the Copilot state of the fixture under ROOT; return its files, named.
The plist names them: the events of the sessions A, B and C, and the
summary of A."
  (let ((key harness-provider-claude-redact-test--key)
        (id harness-provider-claude-redact-test--id)
        (a harness-provider-claude-redact-test--copilot-a)
        (b harness-provider-claude-redact-test--copilot-b)
        (c harness-provider-claude-redact-test--copilot-c))
    (list :events-a (harness-provider-claude-redact-test--write
                     root (format "%s/events.jsonl" a)
                     (harness-provider-claude-redact-test--lines
                      "{\"type\":\"session.start\",  \"data\":{\"n\": 1.50}}"
                      (harness-provider-claude-redact-test--json
                       `((type . "tool.execution_complete")
                         (data . ((result . ((content . ,(format "KEY=%s" key))))))))))
          :summary-a (harness-provider-claude-redact-test--write
                      root (format "%s/workspace.yaml" a) (format "summary: leaked %s\n" key))
          :events-b (harness-provider-claude-redact-test--write
                     root (format "%s/events.jsonl" b)
                     (harness-provider-claude-redact-test--lines
                      (harness-provider-claude-redact-test--json
                       `((type . "user.message") (data . ((content . ,(format "id %s" id))))))))
          :events-c (harness-provider-claude-redact-test--write
                     root (format "%s/events.jsonl" c)
                     (harness-provider-claude-redact-test--lines "{\"type\":\"session.start\"}")))))

(defun harness-provider-claude-redact-test--copilot-session (sid copilot cwd)
  "Make session SID in CWD, whose provider state names Copilot session COPILOT."
  (harness-call 'session/create :id sid :cwd cwd :model "copilot:claude-sonnet-5")
  (harness-call 'session/set-provider-state sid
                (list :copilot-session-id copilot :provider "copilot"))
  sid)

(ert-deftest harness-provider-copilot-redact-logs-takes-the-secret-out-of-a-sessions-state ()
  (harness-provider-claude-redact-test--with-copilot
    (let* ((files (harness-provider-claude-redact-test--copilot-layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (a harness-provider-claude-redact-test--copilot-a)
           (b harness-provider-claude-redact-test--copilot-b)
           (old-events (harness-provider-claude-redact-test--file-lines (plist-get files :events-a))))
      ;; Only the files whose path holds the session id are looked at.
      (let ((scan (harness-call 'provider/copilot-redact-logs secrets (list a) t)))
        (should (equal (file-name-as-directory root) (plist-get scan :directory)))
        (should (= 2 (plist-get scan :scanned)))
        (should (= 2 (plist-get scan :count)))
        (should (equal '(found found) (mapcar (lambda (e) (plist-get e :status)) (plist-get scan :files))))
        (should (equal (list a a) (mapcar (lambda (e) (plist-get e :cli-session)) (plist-get scan :files))))
        (should (= 1 (harness-provider-claude-redact-test--count (plist-get files :summary-a)))))
      (let ((result (harness-call 'provider/copilot-redact-logs secrets (list a))))
        (should (= 2 (plist-get result :count)))
        (should (equal '(redacted redacted)
                       (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files))))
        (should-not (harness-provider-claude-redact-test--holds-p
                     result harness-provider-claude-redact-test--key)))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :events-a))))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :summary-a))))
      ;; The id in the other session's state is still there, and the line without a secret is as it was.
      (should (> (harness-provider-claude-redact-test--count (plist-get files :events-b)) 0))
      (should (equal (car old-events)
                     (car (harness-provider-claude-redact-test--file-lines (plist-get files :events-a)))))
      (should (equal (format "summary: leaked %s\n" (harness-provider-claude-redact-test--placeholder 0))
                     (harness-provider-claude-redact-test--read (plist-get files :summary-a))))
      ;; t is every session's.
      (let ((result (harness-call 'provider/copilot-redact-logs secrets t)))
        (should (= 4 (plist-get result :scanned)))
        (should (= 1 (plist-get result :count)))
        (should (equal (list b) (mapcar (lambda (e) (plist-get e :cli-session)) (plist-get result :files)))))
      (dolist (file (harness-provider-claude-redact-test--all files))
        (should (= 0 (harness-provider-claude-redact-test--count file)))))))

(ert-deftest harness-provider-copilot-redact-logs-leaves-a-running-sessions-state-and-closes-an-idle-ones ()
  (harness-provider-claude-redact-test--with-copilot
    (let* ((files (harness-provider-claude-redact-test--copilot-layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (a harness-provider-claude-redact-test--copilot-a)
           (b harness-provider-claude-redact-test--copilot-b)
           (a-bytes (harness-provider-claude-redact-test--bytes (plist-get files :events-a)))
           (closed nil))
      (harness-provider-claude-redact-test--copilot-session "s-a" a cwd)
      (harness-provider-claude-redact-test--copilot-session "s-b" b cwd)
      (puthash "s-a" (harness-provider-copilot--make-session :id "s-a" :main a)
               harness-provider-copilot--sessions)
      (puthash "s-b" (harness-provider-copilot--make-session :id "s-b" :main b)
               harness-provider-copilot--sessions)
      (harness-register-method 'agent/running (lambda (&optional sid) (and (equal sid "s-a") t)))
      (cl-letf* ((orig (symbol-function 'harness-provider-copilot-close))
                 ((symbol-function 'harness-provider-copilot-close)
                  (lambda (sid)
                    (push (list sid (harness-provider-claude-redact-test--count (plist-get files :events-b)))
                          closed)
                    (funcall orig sid))))
        (let ((result (harness-call 'provider/copilot-redact-logs secrets t)))
          (let ((entry (harness-provider-claude-redact-test--entry result (plist-get files :events-a))))
            (should (eq 'deferred (plist-get entry :status)))
            (should (equal '("s-a") (plist-get entry :owners))))
          (let ((entry (harness-provider-claude-redact-test--entry result (plist-get files :events-b))))
            (should (eq 'redacted (plist-get entry :status)))
            (should (equal '("s-b") (plist-get entry :owners)))))
        ;; The idle one's process went first, the running one's was left alone.
        (should (equal "s-b" (car (car closed))))
        (should (> (cadr (car closed)) 0))
        (should-not (assoc "s-a" closed)))
      (should (equal a-bytes (harness-provider-claude-redact-test--bytes (plist-get files :events-a))))
      (should (gethash "s-a" harness-provider-copilot--sessions))
      (should-not (gethash "s-b" harness-provider-copilot--sessions))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :events-b))))
      ;; A turn in flight in its process defers it as well, with no agent to ask: in the
      ;; conversation, or in a throwaway session beside it, which closing the process would end.
      (harness-unregister-method 'agent/running)
      (dolist (busy (list (list a) (list "a-side-request-session")))
        (puthash "s-a" (harness-provider-copilot--make-session :id "s-a" :main a :busy busy)
                 harness-provider-copilot--sessions)
        (let ((result (harness-call 'provider/copilot-redact-logs secrets (list a))))
          (should (equal '(deferred deferred)
                         (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files))))))
      (puthash "s-a" (harness-provider-copilot--make-session :id "s-a" :main a)
               harness-provider-copilot--sessions)
      (let ((result (harness-call 'provider/copilot-redact-logs secrets (list a))))
        (should (equal '(redacted redacted)
                       (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :events-a)))))))

(ert-deftest harness-provider-copilot-redact-logs-owners-are-the-sessions-holding-the-copilot-session ()
  "A session holds a Copilot session by its provider state, or by a process with it open."
  (harness-provider-claude-redact-test--with-copilot
    (let* ((files (harness-provider-claude-redact-test--copilot-layout root))
           (secrets (harness-provider-claude-redact-test--secrets))
           (a harness-provider-claude-redact-test--copilot-a)
           (b harness-provider-claude-redact-test--copilot-b))
      (harness-provider-claude-redact-test--copilot-session "s-state" a cwd)
      (harness-provider-claude-redact-test--copilot-session "s-elsewhere" b cwd)
      ;; One by its main conversation, one by a session it has open (a throwaway fork, say).
      (puthash "s-live" (harness-provider-copilot--make-session :id "s-live" :main a)
               harness-provider-copilot--sessions)
      (puthash "s-open" (harness-provider-copilot--make-session :id "s-open" :opened (list (cons a "key")))
               harness-provider-copilot--sessions)
      (let* ((result (harness-call 'provider/copilot-redact-logs secrets (list a) t))
             (entry (harness-provider-claude-redact-test--entry result (plist-get files :events-a))))
        (should (equal '("s-live" "s-open" "s-state")
                       (sort (copy-sequence (plist-get entry :owners)) #'string<))))
      ;; The session that only the provider state ties to it is enough to hold it back,
      (harness-register-method 'agent/running (lambda (&optional sid) (and (equal sid "s-state") t)))
      (let ((result (harness-call 'provider/copilot-redact-logs secrets (list a))))
        (should (equal '(deferred deferred)
                       (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (should (> (harness-provider-claude-redact-test--count (plist-get files :events-a)) 0))
      (should (gethash "s-live" harness-provider-copilot--sessions))
      ;; and when it is idle, the processes that hold the session open are closed.
      (harness-register-method 'agent/running (lambda (&optional _sid) nil))
      (harness-call 'provider/copilot-redact-logs secrets (list a))
      (should-not (gethash "s-live" harness-provider-copilot--sessions))
      (should-not (gethash "s-open" harness-provider-copilot--sessions))
      (should (= 0 (harness-provider-claude-redact-test--count (plist-get files :events-a)))))))

(ert-deftest harness-provider-copilot-redact-logs-leaves-a-recent-file-and-a-missing-directory ()
  (harness-provider-claude-redact-test--with-copilot
    (let* ((secrets (harness-provider-claude-redact-test--secrets))
           (c harness-provider-claude-redact-test--copilot-c)
           (file (harness-provider-claude-redact-test--write
                  root (format "%s/events.jsonl" c)
                  (harness-provider-claude-redact-test--lines
                   (harness-provider-claude-redact-test--json
                    `((type . "user.message")
                      (data . ((content . ,harness-provider-claude-redact-test--key))))))
                  t))
           (bytes (harness-provider-claude-redact-test--bytes file)))
      (let ((result (harness-call 'provider/copilot-redact-logs secrets t)))
        (should (equal '(busy) (mapcar (lambda (e) (plist-get e :status)) (plist-get result :files)))))
      (should (equal bytes (harness-provider-claude-redact-test--bytes file)))
      ;; No ids, no files.
      (should (= 0 (plist-get (harness-call 'provider/copilot-redact-logs secrets nil) :scanned)))
      (should (= 0 (plist-get (harness-call 'provider/copilot-redact-logs secrets (list "")) :scanned)))
      ;; No directory.
      (let ((harness-provider-copilot-state-directory (expand-file-name "missing" root)))
        (should (equal (list :directory (expand-file-name "missing/" root) :count 0 :scanned 0 :files nil)
                       (harness-call 'provider/copilot-redact-logs secrets t)))))))

(ert-deftest harness-provider-copilot-state-directory-follows-the-setting-and-the-environment ()
  (harness-provider-claude-redact-test--with-copilot
    (let ((harness-provider-copilot-state-directory nil))
      (let ((process-environment (cons "COPILOT_HOME=/somewhere/copilot-home" process-environment)))
        (should (equal "/somewhere/copilot-home/session-state/"
                       (harness-provider-copilot--state-directory))))
      (let ((process-environment (cons "COPILOT_HOME" process-environment)))
        (should (equal (file-name-as-directory (expand-file-name "~/.copilot/session-state"))
                       (harness-provider-copilot--state-directory))))
      (let ((harness-provider-copilot-state-directory "/elsewhere/state"))
        (should (equal "/elsewhere/state/" (harness-provider-copilot--state-directory)))))))

(provide 'harness-provider-claude-redact-test)
;;; harness-provider-claude-redact-test.el ends here
