;;; harness-redact-files-test.el --- Tests for redacting files, buffers and logging it  -*- lexical-binding: t; -*-

;;; Commentary:

;; Besides the node logs, records, search index, provider logs and task
;; records (harness-redact-test.el), `secrets/redact' takes a secret out of
;; the transcript files that compaction and handoff write, the files that
;; hold cut tool outputs whole, the temporary directories of the
;; sessions, the other files of the state directory and the log buffers;
;; scans the same scope and stores again when it is done; and adds a line
;; to redactions.jsonl, which `secrets/log' reads.
;; These tests drive the engine with the real session module, in a state
;; directory and project directories of their own.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  A test that fails shows values it
;; compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-sessions)
(defvar harness-redact--pending)
(defvar harness-redact--store-functions)
(defvar harness-redact--sweep-limit)
(declare-function harness-redact-run-dry-p "harness-redact" (run))

(defconst harness-redact-files-test--key (concat "FAKE/key+" (make-string 24 ?k) "\"q")
  "A fake secret key, with a slash and a quote for JSON to escape.")

(defconst harness-redact-files-test--id (concat "FAKEID" (make-string 14 ?x))
  "A fake access key id.")

(defvar harness-redact-files-test--running nil
  "The ids of the sessions the stand-in `agent/running' says run a turn.")

(defun harness-redact-files-test--secrets ()
  "Return the fake key and id as secrets."
  (list (harness-redaction-secret harness-redact-files-test--key "spaces.secret_key")
        (harness-redaction-secret harness-redact-files-test--id "spaces.access_key")))

(defun harness-redact-files-test--fp (index)
  "Return the fingerprint of the fake secret number INDEX, 0 the key and 1 the id."
  (plist-get (nth index (harness-redact-files-test--secrets)) :fingerprint))

(defun harness-redact-files-test--marker (index)
  "Return the placeholder that stands for the fake secret number INDEX."
  (harness-redaction-placeholder (nth index (harness-redact-files-test--secrets))))

(defmacro harness-redact-files-test-with (&rest body)
  "Run BODY with the session modules and the engine in a fresh state directory.
The variable DIR is the state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session secrets redact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-redact--pending)
     (let ((default-directory dir)
           (harness-redact-files-test--running nil))
       (harness-register-method 'agent/running
                                (lambda (&optional sid)
                                  (and sid (member sid harness-redact-files-test--running) t)))
       ,@body)))

(defun harness-redact-files-test--write (file text &optional mode)
  "Write TEXT to FILE, making its directory; MODE, when given, is its modes."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert text)))
  (when mode (set-file-modes file mode))
  file)

(defun harness-redact-files-test--write-bytes (file text)
  "Write TEXT to FILE as bytes, NUL bytes among them."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'binary))
    (write-region (encode-coding-string text 'utf-8) nil file nil 'silent))
  file)

(defun harness-redact-files-test--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redact-files-test--count (file)
  "Return how many times the fake secrets occur in the bytes of FILE."
  (harness-redaction-file-count file (harness-redact-files-test--secrets)))

(defun harness-redact-files-test--holds-p (&rest objects)
  "Non-nil when any of OBJECTS, printed, holds a fake secret, as is or as JSON."
  (cl-some (lambda (object)
             (or (string-search harness-redact-files-test--key (prin1-to-string object t))
                 (string-search harness-redact-files-test--id (prin1-to-string object t))
                 (> (harness-redaction-count (prin1-to-string object t) (harness-redact-files-test--secrets)) 0)
                 (> (harness-redaction-count (prin1-to-string object) (harness-redact-files-test--secrets)) 0)))
           objects))

(defun harness-redact-files-test--session (name cwd &rest args)
  "Create a session called NAME working in CWD, with ARGS more keys; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd cwd :name name args) :id))

(defun harness-redact-files-test--ref (&optional file)
  "Return the reference to the fake secrets in FILE (a new file by default)."
  (list :file (or file
                  (let ((f (expand-file-name "source.json" (harness-test-temp-dir))))
                    (harness-redact-files-test--write
                     f (harness-json-encode-text
                        (list :outputs (list :keys (list :value (list :access_key harness-redact-files-test--id
                                                                      :secret_key harness-redact-files-test--key)))
                              :other "unrelated")))
                    f))
        :json-path "outputs.keys.value" :label "spaces"))

(defun harness-redact-files-test--call (&rest params)
  "Call `secrets/redact' with the plist PARAMS; return its report."
  (harness-call 'secrets/redact params))

(defun harness-redact-files-test--store (report name)
  "Return the store called NAME that the REPORT lists."
  (cl-find name (plist-get report :stores) :key (lambda (s) (plist-get s :store)) :test #'equal))

(defun harness-redact-files-test--entry (report sid)
  "Return what the REPORT says of session SID."
  (cl-find sid (plist-get report :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal))

(defun harness-redact-files-test--file-entry (store file)
  "Return the entry of FILE among the files of STORE, a store of a report."
  (cl-find (file-truename file) (plist-get store :files)
           :key (lambda (f) (file-truename (plist-get f :file))) :test #'equal))

(defun harness-redact-files-test--redactions (sid)
  "Return the redaction records in the `ext' of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :redactions))

(defun harness-redact-files-test--dirty-text ()
  "Return text, as a transcript file has it, with the key twice and the id once."
  (format "# Conversation\n\n- [tool bash] echo\n- [result] key: %s\n  id: %s\n- [assistant] the key again: %s\nEnd.\n"
          harness-redact-files-test--key harness-redact-files-test--id harness-redact-files-test--key))

;;;; Transcript files

(ert-deftest harness-redact-files-takes-the-secret-out-of-transcript-files ()
  "The files named for a session, and those its nodes name, are cleaned; others are left."
  (harness-redact-files-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (harness-redact-files-test--session "worker" cwd))
           (c (harness-redact-files-test--session "asker" (harness-test-temp-dir)))
           (own (expand-file-name (format ".harness/transcripts/%s-20261010T120000.md" (substring a 0 8)) cwd))
           (named (expand-file-name ".harness/handoff/zzzzzzzz-20261010T130000.md" cwd))
           (strange (expand-file-name ".harness/transcripts/qqqqqqqq-20261010T140000.md" cwd))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write own text #o640)
      (harness-redact-files-test--write named text)
      (harness-redact-files-test--write strange text)
      ;; A compaction of the session named the second, whose prefix is another session's.
      (harness-call 'session/append a (list :kind 'compaction
                                            :content (format "The conversation so far was compacted into a file, to keep the context small: %s (7 lines, the whole conversation, oldest first).  You start without it." named)
                                            :meta (list :file named)))
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                   :sessions (list a))))
        (let ((store (harness-redact-files-test--store scan "transcript files")))
          (should (= 2 (plist-get store :scanned)))
          (should (= 6 (plist-get store :count)))
          (should (harness-redact-files-test--file-entry store own))
          (should (harness-redact-files-test--file-entry store named))
          (should-not (harness-redact-files-test--file-entry store strange))
          (should (eq 'found (plist-get (harness-redact-files-test--file-entry store own) :status))))
        (let ((entry (harness-redact-files-test--entry scan a)))
          (should (= 6 (plist-get entry :transcripts)))
          (should (= 0 (plist-get entry :log))))
        (should (string-search "Transcript files: 2 files looked at, 6 occurrences in 2 files."
                               (plist-get scan :text)))
        (should-not (harness-redact-files-test--holds-p scan))
        ;; A scan changes no file.
        (should (equal text (harness-redact-files-test--read own)))
        (should (equal text (harness-redact-files-test--read named))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list a) :mode 'redact :reason "leaked in a diff"
                                                     :origin (list :kind 'session :id c))))
        (should (plist-get report :complete))
        (dolist (file (list own named))
          (should (= 0 (harness-redact-files-test--count file)))
          (should (string-search (harness-redact-files-test--marker 0) (harness-redact-files-test--read file)))
          (should (string-search (harness-redact-files-test--marker 1) (harness-redact-files-test--read file))))
        ;; Only the secret changed: the rest of the text, and the modes, are as they were.
        (should (equal (car (harness-redaction-string text (harness-redact-files-test--secrets)))
                       (harness-redact-files-test--read own)))
        (should (= #o640 (file-modes own)))
        ;; A transcript that is neither named for the session nor named by it is not its own.
        (should (equal text (harness-redact-files-test--read strange)))
        ;; The record in the session says which files, and how many occurrences.
        (let ((record (car (harness-redact-files-test--redactions a))))
          (should (member (file-truename own) (plist-get record :files)))
          (should (member (file-truename named) (plist-get record :files)))
          (should (= 6 (plist-get (plist-get record :counts) :transcripts)))
          (should-not (harness-redact-files-test--holds-p record)))
        (should (cl-some (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                          (string-search "6 occurrences in transcript files"
                                                         (plist-get n :content))))
                         (harness-call 'session/nodes a)))
        (should (equal "transcript files" (plist-get (harness-redact-files-test--store report "transcript files") :store)))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-a-session-owns-only-the-transcripts-a-note-names ()
  "A path a tool printed is no transcript the session wrote; the note of a compaction or a handoff is.
The report of a scan lists the transcript files it found, and the session
that asked reads it: its node log then holds their paths, but it is not
their owner, and a redaction must not credit it with their occurrences,
nor record in it that its transcript files were cleaned.  A handoff note
names its file in its `:handoff', as a compaction does in its `:meta'."
  (harness-redact-files-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (harness-redact-files-test--session "worker" cwd))
           (reader (harness-redact-files-test--session "reader" (harness-test-temp-dir)))
           (listed (expand-file-name (format ".harness/transcripts/%s-20261010T120000.md" (substring a 0 8)) cwd))
           (handed (expand-file-name ".harness/handoff/zzzzzzzz-20261010T130000.md" cwd))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write listed text)
      (harness-redact-files-test--write handed text)
      ;; The reader ran a command and read a report that listed the first file ...
      (harness-call 'session/append reader (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run"
                                                 :input (list :command "ls .harness/transcripts")))
      (harness-call 'session/append reader (list :kind 'tool-result :call-id "c1"
                                                 :output (format "Transcript files:\n  %s: 6 occurrences, found\n" listed)))
      (let* ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                    :sessions (list reader)))
             (store (harness-redact-files-test--store scan "transcript files")))
        ;; ... which makes it the owner of nothing.
        (should (= 0 (plist-get store :scanned)))
        (should-not (harness-redact-files-test--file-entry store listed))
        (should-not (harness-redact-files-test--entry scan reader)))
      ;; A handoff note in the reader's transcript names the second file: that is its own.
      (harness-call 'session/append reader (list :kind 'user
                                                 :content (format "This conversation was handed over to you. Read %s first." handed)
                                                 :meta (list :handoff (list :mode "transcript" :file handed))))
      (let* ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                    :sessions (list reader)))
             (store (harness-redact-files-test--store scan "transcript files")))
        (should (= 1 (plist-get store :scanned)))
        (should (harness-redact-files-test--file-entry store handed))
        (should-not (harness-redact-files-test--file-entry store listed))
        (should (= 3 (plist-get (harness-redact-files-test--entry scan reader) :transcripts))))
      ;; The redaction cleans the one it owns and records only that.
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list reader) :mode 'redact :reason "leaked")))
        (should (= 0 (harness-redact-files-test--count handed)))
        (should (= 3 (harness-redact-files-test--count listed)))
        (let ((record (car (harness-redact-files-test--redactions reader))))
          (should (equal (list (file-truename handed)) (plist-get record :files)))
          (should (= 3 (plist-get (plist-get record :counts) :transcripts))))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-leaves-the-transcripts-of-a-session-on-another-host ()
  "A session on another host has its transcript files there: they are not looked at, and it is said."
  (harness-redact-files-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (harness-redact-files-test--session "remote" cwd :host "devbox"))
           (b (harness-redact-files-test--session "local" (harness-test-temp-dir)))
           (file (expand-file-name (format ".harness/transcripts/%s-20261010T120000.md" (substring a 0 8)) cwd))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write file text)
      (dolist (mode '(scan redact))
        (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                       :sessions (list a b) :mode mode)))
          (let ((store (harness-redact-files-test--store report "transcript files")))
            (should (= 0 (plist-get store :scanned)))
            (should (equal (list a) (plist-get store :skipped-sessions))))
          (should (string-search "Transcript files of 1 session on another host were not looked at"
                                 (plist-get report :text)))
          (should (string-search (substring a 0 8) (plist-get report :text)))
          (when (eq mode 'redact)
            ;; What was not looked at may hold it: the redaction is not complete.
            (should-not (plist-get report :complete))
            (should (cl-some (lambda (s) (string-search "on another host" s)) (plist-get report :remaining))))
          (should (equal text (harness-redact-files-test--read file))))))))

;;;; Spill files

(defun harness-redact-files-test--spill-note (path)
  "Return the end of a cut tool output that was saved whole to PATH."
  (format "head of the output\n\n[Output truncated: 99 characters, 3 lines. The full output was saved to %s. Read it in ranges with read_file (offset/limit), or narrow the request.]"
          path))

(ert-deftest harness-redact-files-takes-the-secret-out-of-spill-files ()
  "The file a cut output was saved to is cleaned when the node says so, though the log is clean."
  (harness-redact-files-test-with
    (let* ((outputs (expand-file-name "outputs" harness-state-directory))
           (spill (expand-file-name "call_1.txt" outputs))
           (loose (expand-file-name "nested/call_2.txt" outputs))
           (outside (expand-file-name "elsewhere.txt" (harness-test-temp-dir)))
           (text (harness-redact-files-test--dirty-text))
           (a (harness-redact-files-test--session "worker" (harness-test-temp-dir)))
           (b (harness-redact-files-test--session "other" (harness-test-temp-dir))))
      (harness-redact-files-test--write spill text)
      (harness-redact-files-test--write loose text)
      (harness-redact-files-test--write outside text)
      ;; The cut output in the log is clean: the secret was past the cut.
      (harness-call 'session/append a (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run" :input (list :command "terraform output")))
      (harness-call 'session/append a (list :kind 'tool-result :call-id "c1"
                                            :output (harness-redact-files-test--spill-note spill)
                                            :meta (list :truncated (list :path spill :chars 99))))
      ;; Another session names a path outside the outputs directory.
      (harness-call 'session/append b (list :kind 'tool-result :call-id "c9"
                                            :output (harness-redact-files-test--spill-note outside)))
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                   :sessions (list a b))))
        (let ((store (harness-redact-files-test--store scan "spill files")))
          (should (= 1 (plist-get store :scanned)))
          (should (= 3 (plist-get store :count)))
          (should (harness-redact-files-test--file-entry store spill)))
        (should (= 3 (plist-get (harness-redact-files-test--entry scan a) :spill)))
        (should (string-search "outside the outputs directory, not touched" (plist-get scan :text)))
        (should (= 3 (harness-redact-files-test--count spill))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list a b) :mode 'redact)))
        (should (= 0 (harness-redact-files-test--count spill)))
        (should (string-search (harness-redact-files-test--marker 0) (harness-redact-files-test--read spill)))
        ;; The session scope does not reach a file nothing names, or a path outside.
        (should (equal text (harness-redact-files-test--read loose)))
        (should (equal text (harness-redact-files-test--read outside)))
        (should (member (file-truename spill) (plist-get (car (harness-redact-files-test--redactions a)) :files)))
        (should-not (harness-redact-files-test--redactions b))
        (should-not (harness-redact-files-test--holds-p report)))
      ;; The scope all takes every file under the outputs directory.
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact)))
        (should (= 0 (harness-redact-files-test--count loose)))
        (should (string-search (harness-redact-files-test--marker 1) (harness-redact-files-test--read loose)))
        (should (equal text (harness-redact-files-test--read outside)))
        (should (= 3 (plist-get (harness-redact-files-test--store report "spill files") :count)))))))

(ert-deftest harness-redact-files-counts-a-binary-spill-file-and-follows-no-link ()
  "A binary file is counted and left; a link to a file is not followed."
  (harness-redact-files-test-with
    (let* ((outputs (expand-file-name "outputs" harness-state-directory))
           (blob (expand-file-name "shot.bin" outputs))
           (target (expand-file-name "real.txt" (harness-test-temp-dir)))
           (link (expand-file-name "linked.txt" outputs))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write-bytes blob (concat "PNG\0\0" harness-redact-files-test--key "\0"))
      (harness-redact-files-test--write target text)
      (make-directory outputs t)
      (make-symbolic-link target link)
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact)))
        (let* ((store (harness-redact-files-test--store report "spill files"))
               (entry (harness-redact-files-test--file-entry store blob)))
          (should (eq 'not-redacted (plist-get entry :status)))
          (should (= 1 (plist-get entry :count)))
          (should (equal "a binary file" (plist-get entry :error)))
          (should (cl-some (lambda (s) (and (string-search "found, not redacted" s) (string-search "shot.bin" s)))
                           (plist-get store :left))))
        (should (= 1 (harness-redact-files-test--count blob)))
        ;; What it could not clean is said, and the redaction is not complete.
        (should-not (plist-get report :complete))
        (should (cl-some (lambda (s) (string-search "shot.bin: found, not redacted (a binary file)" s))
                         (plist-get report :remaining)))
        (should (string-search "Links are never followed: 1 spill file skipped." (plist-get report :text)))
        (should (equal text (harness-redact-files-test--read target)))
        (should-not (harness-redact-files-test--holds-p report))))))

;;;; Session temp files

(defun harness-redact-files-test--age (file)
  "Make FILE look as if it was written an hour ago."
  (set-file-times file (time-subtract (current-time) 3600)))

(ert-deftest harness-redact-files-takes-the-secret-out-of-session-temp-files ()
  "What a session left in its temporary directory is cleaned, and no other session's."
  (harness-redact-files-test-with
    (let* ((a (harness-redact-files-test--session "w" (harness-test-temp-dir)))
           (b (harness-redact-files-test--session "other" (harness-test-temp-dir)))
           (dir-a (harness-call 'session/tmp-dir a))
           (dir-b (harness-call 'session/tmp-dir b))
           (out (expand-file-name "out.txt" dir-a))
           (nested (expand-file-name "shots/log.txt" dir-a))
           (theirs (expand-file-name "out.txt" dir-b))
           (away (expand-file-name "away.txt" (harness-test-temp-dir)))
           (link (expand-file-name "linked.txt" dir-a))
           (text (harness-redact-files-test--dirty-text)))
      (should dir-a)
      (harness-redact-files-test--write out text)
      (harness-redact-files-test--write nested text)
      (harness-redact-files-test--write theirs text)
      (harness-redact-files-test--write away text)
      (dolist (file (list out nested theirs)) (harness-redact-files-test--age file))
      (make-symbolic-link away link)
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                   :sessions (list a) :include-forks :false)))
        (let ((store (harness-redact-files-test--store scan "session temp files")))
          (should (= 2 (plist-get store :scanned)))
          (should (= 6 (plist-get store :count)))
          (should (harness-redact-files-test--file-entry store out))
          (should (harness-redact-files-test--file-entry store nested))
          (should-not (harness-redact-files-test--file-entry store theirs)))
        (should (= 6 (plist-get (harness-redact-files-test--entry scan a) :temp)))
        (should (string-search "Links are never followed: 1 file skipped." (plist-get scan :text)))
        (should (equal text (harness-redact-files-test--read out))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list a) :include-forks :false :mode 'redact)))
        (should (= 0 (harness-redact-files-test--count out)))
        (should (= 0 (harness-redact-files-test--count nested)))
        (should (string-search (harness-redact-files-test--marker 0) (harness-redact-files-test--read out)))
        ;; Another session's scratch files, and the file a link leads to, are not touched.
        (should (equal text (harness-redact-files-test--read theirs)))
        (should (equal text (harness-redact-files-test--read away)))
        (should (= 6 (plist-get (plist-get (car (harness-redact-files-test--redactions a)) :counts) :temp)))
        (should (member (file-truename out) (plist-get (car (harness-redact-files-test--redactions a)) :files)))
        (should (cl-some (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                          (string-search "6 occurrences in session temp files"
                                                         (plist-get n :content))))
                         (harness-call 'session/nodes a)))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-leaves-a-scratch-file-that-was-just-written ()
  "A file a process may be writing is not replaced under it: it is counted, left, and said."
  (harness-redact-files-test-with
    (let* ((a (harness-redact-files-test--session "w" (harness-test-temp-dir)))
           (dir-a (harness-call 'session/tmp-dir a))
           (old (expand-file-name "old.txt" dir-a))
           (fresh (expand-file-name "fresh.log" dir-a))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write old text)
      (harness-redact-files-test--age old)
      (harness-redact-files-test--write fresh text)
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                      :sessions (list a) :include-forks :false :mode 'redact))
             (store (harness-redact-files-test--store report "session temp files"))
             (entry (harness-redact-files-test--file-entry store fresh)))
        (should (eq 'busy (plist-get entry :status)))
        (should (= 3 (plist-get entry :count)))
        (should (eq 'redacted (plist-get (harness-redact-files-test--file-entry store old) :status)))
        ;; Untouched, and the report says it holds the secret still.
        (should (equal text (harness-redact-files-test--read fresh)))
        (should (= 0 (harness-redact-files-test--count old)))
        (should-not (plist-get report :complete))
        (should (cl-some (lambda (s) (string-search "fresh.log: left alone, found" s)) (plist-get report :remaining)))
        ;; The scan after it expects that: the file is named, not a failure of the redaction.
        (let ((verification (plist-get report :verification)))
          (should (= 3 (plist-get verification :total)))
          (should (= 0 (plist-get verification :unexplained)))
          (should (eq t (plist-get verification :ok))))
        ;; Once it has been left alone for a while, the redaction takes it.
        (harness-redact-files-test--age fresh)
        (let ((again (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                      :sessions (list a) :include-forks :false :mode 'redact)))
          (should (= 0 (harness-redact-files-test--count fresh)))
          (should (plist-get again :complete)))))))

;;;; State files

(ert-deftest harness-redact-files-sweeps-the-session-files-that-no-session-owns ()
  "A node log and a record of a session that was not loaded hold a copy too.
The record is torn, so the session was never loaded: its files are no
session's to the first store.  The scope all sweeps them, as text where
they do not parse; a scope of sessions leaves them; the files of a loaded
session are left to the first store."
  (harness-redact-files-test-with
    (let* ((a (harness-redact-files-test--session "loaded" (harness-test-temp-dir)))
           (orphan "0badbeef-0000-4000-8000-000000000000")
           (log (expand-file-name (format "sessions/%s.nodes.jsonl" orphan) dir))
           (record (expand-file-name (format "sessions/%s.json" orphan) dir))
           (own-log (expand-file-name (format "sessions/%s.nodes.jsonl" a) dir)))
      (harness-call 'session/append a (list :kind 'user :content "nothing secret"))
      (harness-redact-files-test--write
       log (concat (harness-json-encode-text
                    (list :id "n1" :kind "user" :content (format "use %s" harness-redact-files-test--key)))
                   "\n"))
      (harness-redact-files-test--write
       record (format "{\"id\":\"%s\",\"name\":\"torn %s\",\n" orphan harness-redact-files-test--id))
      ;; A request for sessions does not look in the state directory.
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                   :sessions (list a))))
        (should-not (harness-redact-files-test--store scan "state files")))
      (should (= 1 (harness-redact-files-test--count log)))
      ;; The scope all finds both, and not the files of the session that is loaded.
      (let* ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all))
             (store (harness-redact-files-test--store scan "state files")))
        (should (harness-redact-files-test--file-entry store log))
        (should (harness-redact-files-test--file-entry store record))
        (should-not (harness-redact-files-test--file-entry store own-log))
        (should (= 2 (plist-get store :count))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact :reason "leaked")))
        (should (plist-get report :complete))
        (should (plist-get (plist-get report :verification) :ok))
        (should-not (harness-redact-files-test--holds-p report)))
      (should (= 0 (harness-redact-files-test--count log)))
      (should (= 0 (harness-redact-files-test--count record)))
      ;; The text around the secret is as it was.
      (should (string-search (harness-redact-files-test--marker 1) (harness-redact-files-test--read record)))
      (should (string-prefix-p "{\"id\":\"0badbeef" (harness-redact-files-test--read record)))
      (should (equal (list :id "n1" :kind "user" :content (format "use %s" (harness-redact-files-test--marker 0)))
                     (harness-json-parse (car (split-string (harness-redact-files-test--read log) "\n" t))))))))

(ert-deftest harness-redact-files-sweeps-the-state-directory-for-the-scope-all ()
  "JSON, JSON lines and text files are cleaned, a database is counted, others are left."
  (harness-redact-files-test-with
    (let* ((key harness-redact-files-test--key)
           (json (expand-file-name "pet.json" dir))
           (jsonl (expand-file-name "insights/permissions-2026-10.jsonl" dir))
           (el (expand-file-name "server-config.el" dir))
           (db (expand-file-name "usage.db" dir))
           (elc (expand-file-name "elc/x.elc" dir))
           (rec (expand-file-name "recordings/r.txt" dir))
           (link (expand-file-name "linked.json" dir))
           (away (expand-file-name "away.json" (harness-test-temp-dir)))
           (line-1 "{\"tool\":\"bash\",\"n\":1}")
           (line-3 "{\"tool\":\"read_file\",\"list\":[1,2,3]}")
           (a (harness-redact-files-test--session "w" (harness-test-temp-dir))))
      (ignore a)
      (harness-redact-files-test--write json (harness-json-encode-text
                                              (list :name "pet" :said (list "hello" (format "the key %s" key)) :n 1.5)))
      (harness-redact-files-test--write jsonl (concat line-1 "\n"
                                                      (harness-json-encode-text (list :tool "bash" :note key))
                                                      "\n" line-3 "\n"))
      (harness-redact-files-test--write el (format "(customize-set-variable 'harness-x '((:literal \"%s\")))\n"
                                                   harness-redact-files-test--id))
      (harness-redact-files-test--write-bytes db (concat "SQLite format 3\0" (make-string 64 ?x) key "\0"))
      (harness-redact-files-test--write elc (concat "compiled " key))
      (harness-redact-files-test--write rec (concat "recorded " key))
      (harness-redact-files-test--write away (harness-json-encode-text (list :key key)))
      (make-symbolic-link away link)
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all)))
        (let ((store (harness-redact-files-test--store scan "state files")))
          (should (= 4 (plist-get store :count)))
          (should (cl-every (lambda (f) (harness-redact-files-test--file-entry store f)) (list json jsonl el db)))
          ;; Left out, whatever they hold: compiled code, recordings, links.
          (should-not (cl-some (lambda (f) (harness-redact-files-test--file-entry store f)) (list elc rec link away))))
        (should-not (harness-redact-files-test--holds-p scan))
        (should (= 1 (harness-redact-files-test--count json)))
        (should (= 1 (harness-redact-files-test--count el))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact)))
        (let ((store (harness-redact-files-test--store report "state files")))
          (should (eq 'redacted (plist-get (harness-redact-files-test--file-entry store json) :status)))
          (should (eq 'redacted (plist-get (harness-redact-files-test--file-entry store jsonl) :status)))
          (should (eq 'redacted (plist-get (harness-redact-files-test--file-entry store el) :status)))
          (let ((entry (harness-redact-files-test--file-entry store db)))
            (should (eq 'not-redacted (plist-get entry :status)))
            (should (equal "a SQLite database" (plist-get entry :error)))
            (should (= 1 (plist-get entry :count)))))
        ;; The document: the same, but for the string that held the key.
        (let ((doc (harness-json-parse (harness-redact-files-test--read json))))
          (should (equal "pet" (plist-get doc :name)))
          (should (= 1.5 (plist-get doc :n)))
          (should (equal "hello" (car (plist-get doc :said))))
          (should (equal (format "the key %s" (harness-redact-files-test--marker 0))
                         (cadr (plist-get doc :said)))))
        ;; The lines: the ones without the key byte for byte, the one with it cleaned.
        (let ((lines (split-string (harness-redact-files-test--read jsonl) "\n" t)))
          (should (= 3 (length lines)))
          (should (equal line-1 (nth 0 lines)))
          (should (equal line-3 (nth 2 lines)))
          (should (equal (harness-redact-files-test--marker 0)
                         (plist-get (harness-json-parse (nth 1 lines)) :note))))
        (should (string-search (harness-redact-files-test--marker 1) (harness-redact-files-test--read el)))
        ;; A module that keeps one of them in memory may write it again.
        (should (string-search "may write it again" (plist-get report :text)))
        ;; A database cannot be rewritten as text: counted, left, and said.
        (should (= 1 (harness-redact-files-test--count db)))
        (should (cl-some (lambda (s) (string-search "usage.db: found, not redacted (a SQLite database)" s))
                         (plist-get report :remaining)))
        (should-not (plist-get report :complete))
        ;; Left alone: compiled code, recordings, and a link (and so the file it leads to).
        (should (= 1 (harness-redact-files-test--count elc)))
        (should (= 1 (harness-redact-files-test--count rec)))
        (should (= 1 (harness-redact-files-test--count away)))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-says-which-directories-it-could-not-look-in ()
  "A directory that cannot be listed is named and left unclean; the rest is swept."
  (skip-unless (/= 0 (user-uid)))
  (harness-redact-files-test-with
    (let* ((locked (expand-file-name "outputs/locked" dir))
           (loose (expand-file-name "outputs/loose.txt" dir))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write (expand-file-name "inside.txt" locked) text)
      (harness-redact-files-test--write loose text)
      (set-file-modes locked #o000)
      (unwind-protect
          (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                         :mode 'redact)))
            (should (= 0 (harness-redact-files-test--count loose)))
            (let ((store (harness-redact-files-test--store report "spill files")))
              (should (equal (list (file-truename locked)) (mapcar #'file-truename (plist-get store :unreadable)))))
            (should-not (plist-get report :complete))
            (should (cl-some (lambda (s) (string-search "locked: could not be looked in" s))
                             (plist-get report :remaining)))
            (should (string-search "1 directory could not be looked in" (plist-get report :text))))
        (set-file-modes locked #o700)))))

(ert-deftest harness-redact-files-leaves-the-state-directory-to-the-scope-all ()
  "A scope of sessions, or of a project, leaves the state files and the outputs alone."
  (harness-redact-files-test-with
    (let* ((json (expand-file-name "pet.json" dir))
           (loose (expand-file-name "outputs/loose.txt" dir))
           (a (harness-redact-files-test--session "w" (harness-test-temp-dir)))
           (text (harness-redact-files-test--dirty-text)))
      (harness-redact-files-test--write json (harness-json-encode-text (list :said harness-redact-files-test--key)))
      (harness-redact-files-test--write loose text)
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list a) :mode 'redact)))
        (should-not (harness-redact-files-test--store report "state files"))
        (should (= 1 (harness-redact-files-test--count json)))
        (should (equal text (harness-redact-files-test--read loose)))))))

(ert-deftest harness-redact-files-counts-a-file-over-the-limit-without-reading-it ()
  "A file over the limit is counted by its bytes and left, and the report says why."
  (harness-redact-files-test-with
    (let ((big (expand-file-name "notes.txt" dir))
          (harness-redact--sweep-limit 100))
      (harness-redact-files-test--write big (concat (make-string 200 ?.) harness-redact-files-test--id "\n"))
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                      :mode 'redact))
             (entry (harness-redact-files-test--file-entry (harness-redact-files-test--store report "state files") big)))
        (should (eq 'not-redacted (plist-get entry :status)))
        (should (= 1 (plist-get entry :count)))
        (should (string-search "larger than 100 B" (plist-get entry :error)))
        (should (= 1 (harness-redact-files-test--count big)))
        (should (cl-some (lambda (s) (string-search "notes.txt: found, not redacted (larger than 100 B)" s))
                         (plist-get report :remaining)))))))

(ert-deftest harness-redact-files-leaves-the-file-the-secret-was-read-from ()
  "A reference to a file among those swept does not have the file rewritten."
  (harness-redact-files-test-with
    (let ((source (expand-file-name "tf-state.json" dir)))
      (harness-redact-files-test--write
       source (harness-json-encode-text
               (list :outputs (list :keys (list :value (list :access_key harness-redact-files-test--id
                                                             :secret_key harness-redact-files-test--key))))))
      (let* ((before (harness-redact-files-test--read source))
             (report (harness-redact-files-test--call :source (harness-redact-files-test--ref source) :scope 'all
                                                      :mode 'redact)))
        (should (equal before (harness-redact-files-test--read source)))
        (should (plist-get (harness-redact-files-test--store report "state files") :source-kept))
        (should (string-search "The file the secret was read from is left as it is." (plist-get report :text)))))))

;;;; Log buffers

(defmacro harness-redact-files-test-with-buffers (&rest body)
  "Run BODY with log buffers that hold the fake key, and a buffer that is no log.
BODY sees LOG, CHAT (both log buffers), OTHER (a buffer the engine leaves
alone) and VISITING (one whose name starts alike and visits a file)."
  (declare (indent 0))
  `(let ((log (get-buffer-create "*harness-log*"))
         (chat (get-buffer-create "*harness: Step qr: a chat*"))
         (other (get-buffer-create "*something else*"))
         (visiting (get-buffer-create "*harness-visiting*")))
     (unwind-protect
         (progn
           (with-current-buffer log
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (insert (format "12:00:00.000 INFO  a line that quotes %s\n" harness-redact-files-test--key))))
           (with-current-buffer chat
             (insert (format "message: %s and %s" harness-redact-files-test--key harness-redact-files-test--id))
             (add-text-properties 1 5 '(face bold)))
           (with-current-buffer other (insert harness-redact-files-test--key))
           (with-current-buffer visiting
             (insert harness-redact-files-test--key)
             (setq buffer-file-name (expand-file-name "visited.txt" temporary-file-directory)))
           ,@body)
       (dolist (buffer (list chat other))
         (kill-buffer buffer))
       (with-current-buffer visiting (set-buffer-modified-p nil) (setq buffer-file-name nil))
       (kill-buffer visiting)
       ;; The log is the harness's own: only what the test put in it goes.
       (with-current-buffer log
         (let ((inhibit-read-only t))
           (erase-buffer))))))

(ert-deftest harness-redact-files-takes-the-secret-out-of-log-buffers ()
  "A scan counts the log buffers; a redaction cleans them and no other buffer."
  (harness-redact-files-test-with
    (harness-redact-files-test-with-buffers
      (let ((scan (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all)))
        (let ((store (harness-redact-files-test--store scan "log buffers")))
          (should (= 3 (plist-get store :count)))
          (should (equal '("*harness-log*" "*harness: Step qr: a chat*")
                         (sort (mapcar (lambda (b) (plist-get b :buffer)) (plist-get store :buffers)) #'string<))))
        (should (string-search "Log buffers:" (plist-get scan :text)))
        (should-not (harness-redact-files-test--holds-p scan))
        (should (string-search harness-redact-files-test--key (with-current-buffer log (buffer-string)))))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact)))
        (dolist (buffer (list log chat))
          (should-not (harness-redact-files-test--holds-p (with-current-buffer buffer (buffer-string)))))
        (should (string-search (harness-redact-files-test--marker 0) (with-current-buffer log (buffer-string))))
        (should (string-search (format "message: %s and %s" (harness-redact-files-test--marker 0)
                                       (harness-redact-files-test--marker 1))
                               (with-current-buffer chat (buffer-string))))
        ;; The text properties stay on the text that stays.
        (should (eq 'bold (get-text-property 1 'face chat)))
        ;; Another buffer, and one that visits a file, are not logs.
        (should (string-search harness-redact-files-test--key (with-current-buffer other (buffer-string))))
        (should (string-search harness-redact-files-test--key (with-current-buffer visiting (buffer-string))))
        (should (= 3 (plist-get (harness-redact-files-test--store report "log buffers") :count)))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-cleans-the-log-buffers-for-every-scope ()
  "A log holds a secret whichever sessions were asked about."
  (harness-redact-files-test-with
    (harness-redact-files-test-with-buffers
      (let ((a (harness-redact-files-test--session "w" (harness-test-temp-dir))))
        (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                         :sessions (list a) :mode 'redact)
        (should-not (harness-redact-files-test--holds-p (with-current-buffer log (buffer-string))))))))

;;;; The verification

(ert-deftest harness-redact-files-verifies-with-a-second-scan ()
  "A redaction scans again, store by store, and says that nothing is left."
  (harness-redact-files-test-with
    (let ((a (harness-redact-files-test--session "dirty" (harness-test-temp-dir))))
      (harness-call 'session/append a (list :kind 'user :content (format "use %s" harness-redact-files-test--key)))
      (harness-redact-files-test--write (expand-file-name "pet.json" dir)
                                        (harness-json-encode-text (list :said harness-redact-files-test--id)))
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                      :mode 'redact))
             (verification (plist-get report :verification))
             (rows (plist-get verification :stores)))
        (should (eq t (plist-get verification :ok)))
        (should (= 0 (plist-get verification :total)))
        (should (= 0 (plist-get verification :unexplained)))
        (should (member "node logs" (mapcar (lambda (r) (plist-get r :store)) rows)))
        (should (member "state files" (mapcar (lambda (r) (plist-get r :store)) rows)))
        (should (cl-every (lambda (r) (= 0 (plist-get r :count))) rows))
        (should (string-search "Verification" (plist-get report :text)))
        (should (string-search "nothing is left" (plist-get report :text)))
        (should (plist-get report :complete))
        (should-not (plist-get report :remaining))
        ;; It is part of the report, which a client reads as JSON.
        (should (stringp (harness-json-encode-text report))))
      ;; A scan has none: nothing was done to check.
      (should-not (plist-get (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all)
                             :verification)))))

(ert-deftest harness-redact-files-counts-the-secret-in-the-files-of-the-search-index ()
  "The verification counts raw occurrences in search.db, its log and its shared memory."
  (harness-redact-files-test-with
    (let ((db (expand-file-name "search.db" dir))
          (wal (expand-file-name "search.db-wal" dir))
          (shm (expand-file-name "search.db-shm" dir))
          (a (harness-redact-files-test--session "w" (harness-test-temp-dir))))
      (ignore a)
      (harness-redact-files-test--write-bytes db (concat "SQLite format 3\0" (make-string 32 ?x) "\0"))
      (harness-redact-files-test--write-bytes wal (concat "wal\0" harness-redact-files-test--key "\0"
                                                          harness-redact-files-test--id "\0"
                                                          harness-redact-files-test--id))
      (harness-redact-files-test--write-bytes shm (make-string 16 ?y))
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                      :mode 'redact))
             (verification (plist-get report :verification))
             (row (cl-find "search index files" (plist-get verification :stores)
                           :key (lambda (r) (plist-get r :store)) :test #'equal)))
        ;; The three files, the secrets counted in each.
        (should (equal '("search.db" "search.db-shm" "search.db-wal")
                       (sort (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file))) (plist-get row :files))
                             #'string<)))
        (should (= 3 (plist-get row :count)))
        (should (= 3 (plist-get (cl-find wal (plist-get row :files) :key (lambda (f) (plist-get f :file))
                                         :test #'equal)
                                :count)))
        (should (= 0 (plist-get (cl-find db (plist-get row :files) :key (lambda (f) (plist-get f :file))
                                         :test #'equal)
                                :count)))
        ;; Nothing explains them: the redaction is not complete, and says where.
        (should (eq :false (plist-get verification :ok)))
        (should (= 3 (plist-get verification :unexplained)))
        (should-not (plist-get report :complete))
        (should (cl-some (lambda (s) (string-search "search index files: 3 occurrences left" s))
                         (plist-get report :remaining)))
        (should (string-search "search.db-wal 3 occurrences" (plist-get report :text)))
        ;; The sweep leaves the index to the search module.
        (should (= 3 (harness-redact-files-test--count wal)))
        (should-not (harness-redact-files-test--holds-p report))))))

(ert-deftest harness-redact-files-expects-what-a-binary-file-holds ()
  "A binary file that was found is expected in the verification: it is not a failure of the scan."
  (harness-redact-files-test-with
    (let ((db (expand-file-name "usage.db" dir)))
      (harness-redact-files-test--write-bytes db (concat "SQLite format 3\0" harness-redact-files-test--key))
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                      :mode 'redact))
             (verification (plist-get report :verification))
             (row (cl-find "state files" (plist-get verification :stores)
                           :key (lambda (r) (plist-get r :store)) :test #'equal)))
        (should (= 1 (plist-get row :count)))
        (should (= 1 (plist-get row :expected)))
        (should (= 1 (plist-get verification :total)))
        (should (= 0 (plist-get verification :unexplained)))
        (should (eq t (plist-get verification :ok)))
        (should (string-search "In files that were left alone (deferred, busy, binary or too large; listed above): 1."
                               (plist-get report :text)))
        ;; Not complete all the same: the file is named under what remains.
        (should-not (plist-get report :complete))
        (should (cl-some (lambda (s) (string-search "usage.db" s)) (plist-get report :remaining)))))))

(ert-deftest harness-redact-files-finds-what-something-wrote-back ()
  "A copy that appears after a store was cleaned is found by the second scan."
  (harness-redact-files-test-with
    (let* ((late (expand-file-name "late.txt" dir))
           (calls 0)
           (harness-redact--store-functions
            (append harness-redact--store-functions
                    (list (lambda (run)
                            (cl-incf calls)
                            ;; A module that writes its own state again, after the sweep.
                            (unless (harness-redact-run-dry-p run)
                              (harness-redact-files-test--write late harness-redact-files-test--key)))))))
      (let* ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                      :mode 'redact))
             (verification (plist-get report :verification)))
        (should (= 2 calls))
        (should (eq :false (plist-get verification :ok)))
        (should (= 1 (plist-get verification :unexplained)))
        (should (cl-some (lambda (s) (string-search "state files: 1 occurrence left, found by the verification" s))
                         (plist-get report :remaining)))
        (should (string-search "NOT everything is clean" (plist-get report :text)))
        (should (string-search "Not explained by that" (plist-get report :text)))
        (should-not (plist-get report :complete))))))

(ert-deftest harness-redact-files-verifies-the-conversations-it-reset ()
  "The second scan looks in the provider conversations of the first, though the sessions forgot them."
  (harness-redact-files-test-with
    (let* ((a (harness-redact-files-test--session "dirty" (harness-test-temp-dir)))
           (seen nil))
      (harness-call 'session/append a (list :kind 'user :content (format "use %s" harness-redact-files-test--key)))
      (harness-call 'session/append a (list :kind 'tool-call :tool "bash" :call-id "c1" :title "Run"
                                            :input (list :command "echo")
                                            :checkpoint '(:cli-session-id "cli-1" :uuid "u-1")))
      (harness-call 'session/set-provider-state a (list :cli-session-id "cli-1"))
      (harness-register-method 'provider/claude-redact-logs
                               (lambda (_secrets &optional ids dry)
                                 (push (list ids dry) seen)
                                 (list :directory "/claude/" :count 0 :scanned 1 :files nil)))
      (harness-register-method 'provider/copilot-redact-logs
                               (lambda (&rest _) (list :directory "/copilot/" :count 0 :scanned 0 :files nil)))
      (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                       :sessions (list a) :mode 'redact)
      ;; The session no longer names the conversation, and the second scan asks for it all the same.
      (should-not (plist-get (harness-call 'session/get a) :provider-state))
      (should (equal '((("cli-1") nil) (("cli-1") t)) (reverse seen))))))

;;;; The log of redactions

(ert-deftest harness-redact-files-logs-each-redaction-without-a-value ()
  "A redaction adds a line to redactions.jsonl; a scan adds none, and no line holds a value."
  (harness-redact-files-test-with
    (let* ((log (expand-file-name "redactions.jsonl" dir))
           (cwd (harness-test-temp-dir))
           (a (harness-redact-files-test--session (concat "named " harness-redact-files-test--key) cwd))
           (c (harness-redact-files-test--session "asker" (harness-test-temp-dir)))
           (transcript (expand-file-name (format ".harness/transcripts/%s-20261010T120000.md" (substring a 0 8)) cwd)))
      (harness-call 'session/append a (list :kind 'user :content (format "use %s" harness-redact-files-test--key)))
      (harness-redact-files-test--write transcript (harness-redact-files-test--dirty-text))
      (should-not (file-exists-p log))
      (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all)
      (should-not (file-exists-p log))
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all
                                                     :mode 'redact :reason "leaked in a diff"
                                                     :origin (list :kind 'session :id c))))
        (should (file-exists-p log))
        (let* ((lines (split-string (harness-redact-files-test--read log) "\n" t))
               (line (harness-json-parse (car lines))))
          (should (= 1 (length lines)))
          (should (numberp (plist-get line :ts)))
          (should (stringp (plist-get line :time)))
          (should (equal "session" (plist-get (plist-get line :origin) :kind)))
          (should (equal c (plist-get (plist-get line :origin) :id)))
          (should (equal "leaked in a diff" (plist-get line :reason)))
          (should (equal "redact" (plist-get line :mode)))
          (should (equal "all" (plist-get line :scope-kind)))
          (should (string-search "all sessions" (plist-get line :scope)))
          (should (equal '("spaces.secret_key" "spaces.access_key")
                         (mapcar (lambda (s) (plist-get s :label)) (plist-get line :secrets))))
          (should (equal (list (harness-redact-files-test--fp 0) (harness-redact-files-test--fp 1))
                         (mapcar (lambda (s) (plist-get s :fingerprint)) (plist-get line :secrets))))
          (should (string-search "source.json" (plist-get (car (plist-get line :secrets)) :source)))
          (should (equal (plist-get report :total) (plist-get line :total)))
          (should (equal '("node logs" "nodes in memory" "session records")
                         (mapcar (lambda (r) (plist-get r :store)) (seq-take (plist-get line :totals) 3))))
          (should (member "transcript files" (mapcar (lambda (r) (plist-get r :store)) (plist-get line :totals))))
          (should (equal (list a) (plist-get line :sessions)))
          (should (member (file-truename transcript) (plist-get line :files)))
          (should (member (expand-file-name (format "sessions/%s.nodes.jsonl" a) dir) (plist-get line :files)))
          (should (eq t (plist-get line :complete)))
          (should (eq t (plist-get (plist-get line :verification) :ok)))
          (should (= 0 (plist-get (plist-get line :verification) :total)))))
      ;; The name of the session held the key, the reason may: no byte of the log does.
      (should (= 0 (harness-redact-files-test--count log)))
      ;; Another redaction is another line.
      (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                       :sessions (list a) :mode 'redact)
      (let ((lines (split-string (harness-redact-files-test--read log) "\n" t)))
        (should (= 2 (length lines)))
        (should (equal "user" (plist-get (plist-get (harness-json-parse (cadr lines)) :origin) :kind)))
        (should (equal "session" (plist-get (harness-json-parse (cadr lines)) :scope-kind))))
      (should (= 0 (harness-redact-files-test--count log))))))

(ert-deftest harness-redact-files-keeps-a-reason-that-holds-the-secret-out-of-the-log ()
  "A reason or a label that holds a value is replaced before it is kept anywhere."
  (harness-redact-files-test-with
    (let ((log (expand-file-name "redactions.jsonl" dir))
          (a (harness-redact-files-test--session "w" (harness-test-temp-dir))))
      (ignore a)
      (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all :mode 'redact
                                       :label harness-redact-files-test--id
                                       :reason (format "the key %s leaked" harness-redact-files-test--key))
      (should (= 0 (harness-redact-files-test--count log)))
      (should (string-search "withheld" (plist-get (car (harness-call 'secrets/log)) :reason))))))

(ert-deftest harness-redact-files-logs-a-run-that-found-nothing-and-one-that-went-on-after-a-turn ()
  "A redaction that found nothing is a line too, and so is the one a running turn waited for."
  (harness-redact-files-test-with
    (let* ((a (harness-redact-files-test--session "running" (harness-test-temp-dir))))
      (harness-call 'session/append a (list :kind 'user :content (format "use %s" harness-redact-files-test--key)))
      (push a harness-redact-files-test--running)
      (let ((report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'session
                                                     :sessions (list a) :mode 'redact)))
        (should (equal (list a) (plist-get report :deferred))))
      (let ((first (car (harness-call 'secrets/log))))
        (should (equal (list a) (plist-get first :deferred)))
        (should (eq :false (plist-get first :complete)))
        (should-not (plist-get first :after-turn)))
      (setq harness-redact-files-test--running nil)
      (harness-emit 'agent/turn-ended a 'end-turn)
      (let ((runs (harness-call 'secrets/log)))
        (should (= 2 (length runs)))
        (should (eq t (plist-get (car runs) :after-turn)))
        (should (string-search "session" (plist-get (car runs) :scope-kind)))
        (should (eq t (plist-get (car runs) :complete)))))))

(ert-deftest harness-redact-files-reads-the-log-of-redactions-back ()
  "`secrets/log' gives the last runs, newest first, up to the limit."
  (harness-redact-files-test-with
    (should-not (harness-call 'secrets/log))
    (let ((a (harness-redact-files-test--session "w" (harness-test-temp-dir))))
      (ignore a)
      (dolist (reason '("first" "second" "third"))
        (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all :mode 'redact
                                         :reason reason))
      (should (equal '("third" "second" "first")
                     (mapcar (lambda (r) (plist-get r :reason)) (harness-call 'secrets/log))))
      (should (equal '("third" "second")
                     (mapcar (lambda (r) (plist-get r :reason)) (harness-call 'secrets/log 2))))
      (should (equal '("third") (mapcar (lambda (r) (plist-get r :reason)) (harness-call 'secrets/log "1"))))
      (should (equal 3 (length (harness-call 'secrets/log 100))))
      (let ((runs (harness-call 'secrets/log)))
        (should (cl-every #'numberp (mapcar (lambda (r) (plist-get r :ts)) runs)))
        (should (apply #'>= (mapcar (lambda (r) (plist-get r :ts)) runs)))
        (should-not (harness-redact-files-test--holds-p runs)))
      (dolist (bad '(0 -1 "many" :x))
        (should-error (harness-call 'secrets/log bad) :type 'harness-error)))))

;;;; Nothing changed by a scan

(ert-deftest harness-redact-files-scan-changes-no-file-and-no-buffer ()
  "A scan counts the files and the buffers and changes none."
  (harness-redact-files-test-with
    (harness-redact-files-test-with-buffers
      (let* ((cwd (harness-test-temp-dir))
             (a (harness-redact-files-test--session "w" cwd))
             (files (list (expand-file-name (format ".harness/transcripts/%s-20261010T120000.md" (substring a 0 8)) cwd)
                          (expand-file-name "outputs/loose.txt" dir)
                          (expand-file-name "pet.json" dir)
                          (expand-file-name "jobs.jsonl" dir)))
             (before nil))
        (dolist (f files)
          (harness-redact-files-test--write f (concat (harness-redact-files-test--dirty-text) "\n")))
        (setq before (mapcar #'harness-redact-files-test--read files))
        (let ((buffers (mapcar (lambda (b) (with-current-buffer b (buffer-string))) (list log chat other visiting)))
              (report (harness-redact-files-test--call :source (harness-redact-files-test--ref) :scope 'all)))
          (should (equal before (mapcar #'harness-redact-files-test--read files)))
          (should (equal buffers (mapcar (lambda (b) (with-current-buffer b (buffer-string))) (list log chat other visiting))))
          (should (= 12 (apply #'+ (mapcar (lambda (name) (or (plist-get (harness-redact-files-test--store report name) :count) 0))
                                           '("transcript files" "spill files" "state files")))))
          (should-not (file-exists-p (expand-file-name "redactions.jsonl" dir)))
          (should-not (plist-get report :verification)))))))

(provide 'harness-redact-files-test)
;;; harness-redact-files-test.el ends here
