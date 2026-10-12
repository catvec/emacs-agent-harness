;;; harness-session-redact-test.el --- Tests for redacting the text of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; `session/redact-text' takes a secret out of the node log, the nodes in
;; memory and the record of a session; `session/reset-provider' drops the
;; provider conversation that may hold it too; `session/family-ids' names
;; the sessions a redaction has to reach together with its session.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  A test that fails shows values it
;; compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-providers)
(defvar harness-sessions)

(defconst harness-session-redact-test--key
  (concat "FAKE/secret+" (make-string 24 ?k) "\"q")
  "A fake secret key, with a slash and a quote for JSON to escape.")

(defconst harness-session-redact-test--id (concat "FAKEID" (make-string 14 ?x))
  "A fake access key id.")

(defun harness-session-redact-test--secrets ()
  "Return the fake key and id as secrets, labelled."
  (list (harness-redaction-secret harness-session-redact-test--key "spaces key" "a test")
        (harness-redaction-secret harness-session-redact-test--id "spaces id")))

(defun harness-session-redact-test--placeholder (index)
  "Return the placeholder of the fake secret number INDEX, 0 the key and 1 the id."
  (harness-redaction-placeholder (nth index (harness-session-redact-test--secrets))))

(defmacro harness-session-redact-test-with (&rest body)
  "Load the state modules into a fresh bus and temp state dir, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory dir))
       ,@body)))

(defmacro harness-session-redact-test-with-cut-provider (&rest body)
  "Run BODY with the provider `test-cut', which can fork at a checkpoint.
Its fork of a whole state is (:whole CLI-SESSION-ID), of a checkpoint
\(:cut CHECKPOINT), and of no state nothing."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (harness-define-provider 'test-cut :complete #'ignore
                                  :fork (lambda (_model st &optional checkpoint)
                                          (harness-resolved
                                           (cond (checkpoint (list :cut checkpoint))
                                                 ((plist-get st :cli-session-id)
                                                  (list :whole (plist-get st :cli-session-id)))))))
         ,@body)
     (remhash 'test-cut harness-providers)))

(defun harness-session-redact-test--read (file)
  "Return the content of FILE, read as UTF-8 with no conversion of line ends."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-session-redact-test--log (id)
  "Return the file name of the node log of session ID."
  (expand-file-name (harness-session--nodes-name id) harness-state-directory))

(defun harness-session-redact-test--record (id)
  "Return the file name of the record of session ID."
  (expand-file-name (harness-session--meta-name id) harness-state-directory))

(defun harness-session-redact-test--count (file)
  "Return how many times the fake secrets occur in FILE, as bytes."
  (harness-redaction-file-count file (harness-session-redact-test--secrets)))

(defun harness-session-redact-test--holds-p (object value)
  "Non-nil when OBJECT, printed either way, holds the string VALUE.
A string prints with its quotes and backslashes escaped by `prin1' and
as it is without: a value with a quote in it hides from a search of the
first, so both are searched."
  (and (or (string-search value (prin1-to-string object t))
           (string-search (substring (prin1-to-string value) 1 -1) (prin1-to-string object)))
       t))

(defun harness-session-redact-test--holds-any-p (object)
  "Non-nil when OBJECT, nodes or a result or a record, holds a fake secret."
  (or (harness-session-redact-test--holds-p object harness-session-redact-test--key)
      (harness-session-redact-test--holds-p object harness-session-redact-test--id)))

(defun harness-session-redact-test--reload ()
  "Write every record, forget the sessions in memory and load them from disk."
  (harness-session-flush)
  (clrhash harness-sessions)
  (harness-session--load-all))

(defun harness-session-redact-test--populate ()
  "Make a session whose transcript and record hold the fake secrets.
The key is in a user message, a thinking node, a tool call's input and
title, a tool result's output (with the id), a hint, the text block of a
user message, the final text of a reply that an update line wrote, and
the record's name, queue, todos, plan and ext: nine copies in the log
\(and in memory), five in the record.  Other nodes hold none.  Return a
plist of the session's `:id' and the ids of the nodes by name."
  (let* ((key harness-session-redact-test--key)
         (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :name (concat "named " key))
                        :id))
         (add (lambda (node) (plist-get (harness-call 'session/append id node) :id)))
         (user (funcall add (list :kind 'user :content (format "Use the key %s please" key))))
         (clean (funcall add '(:kind assistant :content "Understood, nothing secret here.")))
         (thinking (funcall add (list :kind 'thinking :content (format "The key is %s" key)
                                      :meta '(:signature "sig"))))
         (call (funcall add (list :kind 'tool-call :tool "bash" :call-id "c1"
                                  :input (list :command (format "echo %s" key))
                                  :title (format "Run: echo %s" key)
                                  :checkpoint '(:cli-session-id "cli-1" :uuid "u-1"))))
         (result (funcall add (list :kind 'tool-result :call-id "c1"
                                    :output (format "AccessKeyId: %s\nSecret: %s\n"
                                                    harness-session-redact-test--id key)
                                    :meta '(:duration 0.5 :truncated (:path "/spill/c1.txt" :chars 99999)))))
         (hint (progn (harness-call 'session/hint id (format "note: %s" key))
                      (plist-get (car (last (harness-call 'session/nodes id))) :id)))
         (blocks (funcall add (list :kind 'user :content "see the attachment"
                                    :blocks (list (list :type "text" :text (format "block %s" key))))))
         (call2 (funcall add '(:kind tool-call :tool "bash" :call-id "c2" :input (:command "ls")
                               :title "Run: ls")))
         (result2 (funcall add (list :kind 'tool-result :call-id "c2" :meta '(:duration 0.1)
                                     :output (concat "files\n\n[Output truncated: 99999 characters, 1 lines."
                                                     " The full output was saved to /spill/c2.txt."
                                                     " Read it in ranges with read_file (offset/limit),"
                                                     " or narrow the request.]"))))
         (streamed (funcall add '(:kind assistant :content "draft"))))
    ;; The final text of the reply comes as an update line.
    (harness-call 'session/update-node id streamed :content (format "final answer with %s" key))
    (harness-call 'session/queue id (format "queued %s" key))
    (harness-call 'session/set-todos id (list (list :content (format "todo %s" key) :status "pending")))
    (harness-call 'session/set-plan id (format "plan %s" key))
    (harness-call 'session/set-ext id :notes (format "ext %s" key))
    (harness-call 'session/set-provider-state id '(:cli-session-id "cli-1" :model "m"))
    (harness-call 'session/set-provider-node id streamed)
    (list :id id :user user :clean clean :thinking thinking :call call :result result :hint hint
          :blocks blocks :call2 call2 :result2 result2 :streamed streamed)))

;;;; What is found

(ert-deftest harness-session-redact-dry-run-finds-everything-and-changes-nothing ()
  "A dry run counts and names, in every copy, and leaves all of them as they were."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (secrets (harness-session-redact-test--secrets))
           (log (harness-session-redact-test--log id))
           (record (harness-session-redact-test--record id)))
      (harness-session-flush)
      (let ((log-before (harness-session-redact-test--read log))
            (record-before (harness-session-redact-test--read record))
            (inode (file-attribute-inode-number (file-attributes log)))
            (nodes-before (harness-call 'session/nodes id))
            (session-before (harness-call 'session/get id)))
        ;; The copies are there to find, in the log and in the record.
        (should (= 9 (harness-session-redact-test--count log)))
        (should (= 5 (harness-session-redact-test--count record)))
        (should (harness-session-redact-test--holds-any-p nodes-before))
        (let ((result (harness-call 'session/redact-text id secrets t)))
          (should (equal id (plist-get result :id)))
          (should (eq t (plist-get result :hit)))
          (should (= 9 (plist-get result :log-count)))
          (should (= 9 (plist-get result :memory-count)))
          (should (= 5 (plist-get result :record-count)))
          ;; Memory overlaps the log: the stores are the log and the record.
          (should (= 14 (plist-get result :count)))
          (should (equal (mapcar (lambda (k) (plist-get ids k))
                                 '(:user :thinking :call :result :hint :blocks :streamed))
                         (plist-get result :nodes)))
          (should (equal '(assistant hint thinking tool-call tool-result user) (plist-get result :kinds)))
          (should (equal '(:blocks :content :input :output :title) (plist-get result :fields)))
          (should (equal '(:name :queue :todos :plan :ext) (plist-get result :record-fields)))
          (should (equal log (plist-get result :file)))
          (should-not (plist-get result :running))
          ;; What else holds copies: the files of cut outputs, found from
          ;; the meta and from the note the cut output ends with, the
          ;; checkpoints and the state of the provider conversation.
          (should (equal '("/spill/c1.txt" "/spill/c2.txt") (plist-get result :spill-files)))
          (should (equal '((:cli-session-id "cli-1" :uuid "u-1")) (plist-get result :checkpoints)))
          (should (equal '(:cli-session-id "cli-1" :model "m") (plist-get result :provider-state)))
          ;; The result names where and how many, never what.
          (should-not (harness-session-redact-test--holds-any-p result)))
        ;; Nothing changed, anywhere.
        (should (equal log-before (harness-session-redact-test--read log)))
        (should (equal record-before (harness-session-redact-test--read record)))
        (should (equal inode (file-attribute-inode-number (file-attributes log))))
        (should (equal nodes-before (harness-call 'session/nodes id)))
        (should (equal session-before (harness-call 'session/get id)))))))

(ert-deftest harness-session-redact-finds-a-secret-in-an-update-line-and-in-blocks ()
  "The final text of a reply and the text blocks of a message are fields too."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (log (harness-session-redact-test--read (harness-session-redact-test--log id))))
      (harness-session-flush)
      ;; The reply's draft holds nothing; only its update line does.
      (should (string-match-p "\"content\":\"draft\"" log))
      (should (string-match-p "_op\":\"update\"" log))
      (let ((result (harness-call 'session/redact-text id (harness-session-redact-test--secrets) t)))
        (should (member (plist-get ids :streamed) (plist-get result :nodes)))
        (should (member (plist-get ids :blocks) (plist-get result :nodes)))
        (should (memq :blocks (plist-get result :fields)))))))

(ert-deftest harness-session-redact-finds-nothing-where-there-is-nothing ()
  "A session without the secret is counted, not touched: its log is not even rewritten."
  (harness-session-redact-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name "plain") :id))
           (log (harness-session-redact-test--log id)))
      (harness-call 'session/append id '(:kind user :content "hello"))
      (harness-call 'session/append id '(:kind assistant :content "hi"))
      (harness-session-flush)
      (let ((text (harness-session-redact-test--read log))
            (attrs (file-attributes log 'integer)))
        (dolist (dry-run '(t nil))
          (let ((result (harness-call 'session/redact-text id (harness-session-redact-test--secrets) dry-run)))
            (should-not (plist-get result :hit))
            (should (= 0 (plist-get result :count)))
            (should (= 0 (plist-get result :log-count)))
            (should (= 0 (plist-get result :memory-count)))
            (should (= 0 (plist-get result :record-count)))
            (should-not (plist-get result :nodes))
            (should-not (plist-get result :file))
            (should-not (plist-member result :spill-files))))
        (should (equal text (harness-session-redact-test--read log)))
        (should (equal (file-attribute-inode-number attrs)
                       (file-attribute-inode-number (file-attributes log 'integer))))
        (should (equal (file-attribute-modification-time attrs)
                       (file-attribute-modification-time (file-attributes log 'integer))))
        ;; No secrets, nothing to look for.
        (should (= 0 (plist-get (harness-call 'session/redact-text id nil) :count)))
        ;; The log is counted by its bytes: it is not read as lines unless it holds a secret.
        (let ((calls 0)
              (parse (symbol-function 'harness-redaction-file)))
          (cl-letf (((symbol-function 'harness-redaction-file)
                     (lambda (&rest args) (cl-incf calls) (apply parse args))))
            (harness-call 'session/redact-text id (harness-session-redact-test--secrets))
            (should (= 0 calls))
            (harness-call 'session/append id (list :kind 'user :content harness-session-redact-test--id))
            (harness-call 'session/redact-text id (harness-session-redact-test--secrets) t)
            (should (= 1 calls))))))))

;;;; Taking it out

(ert-deftest harness-session-redact-leaves-no-copy-in-any-store ()
  "The log, the nodes in memory and the record hold no secret afterwards, only placeholders."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (secrets (harness-session-redact-test--secrets))
           (key-marker (harness-session-redact-test--placeholder 0))
           (id-marker (harness-session-redact-test--placeholder 1))
           (log (harness-session-redact-test--log id))
           (record (harness-session-redact-test--record id))
           (changed nil))
      (harness-session-flush)
      (let ((log-before (harness-session-redact-test--read log))
            (updated (plist-get (harness-call 'session/get id) :updated))
            (inode (file-attribute-inode-number (file-attributes log))))
        (should (= 9 (harness-session-redact-test--count log)))
        (should (= 5 (harness-session-redact-test--count record)))
        (harness-on 'session/changed (lambda (sid plist) (push (cons sid plist) changed)))
        (let ((result (harness-call 'session/redact-text id secrets)))
          (should (= 9 (plist-get result :log-count)))
          (should (= 9 (plist-get result :memory-count)))
          (should (= 5 (plist-get result :record-count)))
          (should (= 14 (plist-get result :count)))
          (should-not (harness-session-redact-test--holds-any-p result)))
        ;; The node log: no secret in any spelling, the placeholders in its place.
        (let ((log-after (harness-session-redact-test--read log)))
          (should (= 0 (harness-session-redact-test--count log)))
          (should (= 0 (harness-redaction-count log-after secrets)))
          (should (string-search key-marker log-after))
          (should (string-search id-marker log-after))
          (should-not (equal inode (file-attribute-inode-number (file-attributes log))))
          ;; Every line that held no secret is as it was, byte for byte.
          (let ((old (split-string log-before "\n"))
                (new (split-string log-after "\n"))
                (kept 0))
            (should (= (length old) (length new)))
            (cl-loop for o in old for n in new
                     do (if (> (harness-redaction-count o secrets) 0)
                            (progn (should-not (equal o n))
                                   (should (string-search "[redacted: " n)))
                          (should (equal o n))
                          (cl-incf kept)))
            (should (>= kept 5))))
        ;; The nodes in memory.
        (let ((nodes (harness-call 'session/nodes id)))
          (should-not (harness-session-redact-test--holds-any-p nodes))
          (should (harness-session-redact-test--holds-p nodes key-marker))
          (should (harness-session-redact-test--holds-p nodes id-marker))
          (should (equal (format "Use the key %s please" key-marker)
                         (plist-get (harness-call 'session/node id (plist-get ids :user)) :content)))
          (should (equal (format "final answer with %s" key-marker)
                         (plist-get (harness-call 'session/node id (plist-get ids :streamed)) :content)))
          ;; What did not hold a secret is the same node.
          (should (equal "Understood, nothing secret here."
                         (plist-get (harness-call 'session/node id (plist-get ids :clean)) :content))))
        ;; The record, written at once: the file is clean before anything else saves it.
        (should (= 0 (harness-session-redact-test--count record)))
        (let ((session (harness-call 'session/get id)))
          (should-not (harness-session-redact-test--holds-any-p session))
          (should (equal (concat "named " key-marker) (plist-get session :name)))
          (should (equal (format "plan %s" key-marker) (plist-get session :plan)))
          (should (equal (format "todo %s" key-marker) (plist-get (car (plist-get session :todos)) :content)))
          (should (equal (format "queued %s" key-marker) (plist-get (car (plist-get session :queue)) :text)))
          (should (equal (format "ext %s" key-marker) (plist-get (plist-get session :ext) :notes)))
          ;; It is the same session, in its place in the list.
          (should (equal updated (plist-get session :updated)))
          (should (equal '(:cli-session-id "cli-1" :model "m") (plist-get session :provider-state))))
        ;; The change was announced, with the record as it is now.
        (should (= 1 (length changed)))
        (should (equal id (car (car changed))))
        (should (equal (concat "named " key-marker) (plist-get (cdr (car changed)) :name)))
        ;; A second run finds nothing.
        (let ((again (harness-call 'session/redact-text id secrets)))
          (should-not (plist-get again :hit))
          (should (= 0 (plist-get again :count))))
        ;; Loaded again from disk: the same.
        (harness-session-redact-test--reload)
        (let ((nodes (harness-call 'session/nodes id))
              (session (harness-call 'session/get id)))
          (should-not (harness-session-redact-test--holds-any-p nodes))
          (should-not (harness-session-redact-test--holds-any-p session))
          (should (equal (format "Use the key %s please" key-marker)
                         (plist-get (harness-call 'session/node id (plist-get ids :user)) :content)))
          (should (equal (format "final answer with %s" key-marker)
                         (plist-get (harness-call 'session/node id (plist-get ids :streamed)) :content)))
          (should (equal (concat "named " key-marker) (plist-get session :name))))))))

(ert-deftest harness-session-redact-keeps-appending-to-the-log-after-it-was-replaced ()
  "The log is replaced whole, and what the session writes next lands in the new file."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (before (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id))))
      (harness-call 'session/redact-text id (harness-session-redact-test--secrets))
      (let ((after (plist-get (harness-call 'session/append id '(:kind user :content "and then?")) :id)))
        (harness-call 'session/update-node id after :content "and then, please?")
        (harness-session-redact-test--reload)
        (should (equal (append before (list after))
                       (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id))))
        (should (equal "and then, please?"
                       (plist-get (harness-call 'session/node id after) :content)))
        (should (= 0 (harness-session-redact-test--count (harness-session-redact-test--log id))))))))

(ert-deftest harness-session-redact-cleans-memory-that-was-never-written ()
  "A reply that is still streaming has its text in memory only; that is cleaned too."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (key harness-session-redact-test--key)
           (marker (harness-session-redact-test--placeholder 0))
           (stream (plist-get (harness-call 'session/append id '(:kind assistant :content "streaming")) :id))
           (log (harness-session-redact-test--log id)))
      ;; A transient update is announced and never written.
      (harness-call 'session/update-node id stream :content (concat "partial " key) :transient t)
      (should (string-search key (plist-get (harness-call 'session/node id stream) :content)))
      (should-not (string-search "partial" (harness-session-redact-test--read log)))
      (let ((dry (harness-call 'session/redact-text id (harness-session-redact-test--secrets) t)))
        (should (= 10 (plist-get dry :memory-count)))
        (should (= 9 (plist-get dry :log-count)))
        (should (member stream (plist-get dry :nodes)))
        (should (string-search key (plist-get (harness-call 'session/node id stream) :content))))
      (let ((result (harness-call 'session/redact-text id (harness-session-redact-test--secrets))))
        (should (= 10 (plist-get result :memory-count)))
        (should (= 9 (plist-get result :log-count)))
        (should (equal (concat "partial " marker)
                       (plist-get (harness-call 'session/node id stream) :content)))
        (should-not (harness-session-redact-test--holds-any-p (harness-call 'session/nodes id)))))))

(ert-deftest harness-session-redact-cleans-a-session-that-is-not-loaded ()
  "A session as a restart leaves it, its nodes still on disk, is cleaned and left unloaded.
Its nodes are read to name the kinds, the spill files and the checkpoints,
and let go again: looking through hundreds of sessions does not load them."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (secrets (harness-session-redact-test--secrets))
           (log (harness-session-redact-test--log id)))
      (harness-session-redact-test--reload)
      (let ((s (gethash id harness-sessions)))
        (should-not (harness-session-loaded s))
        (let ((log-before (harness-session-redact-test--read log))
              (dry (harness-call 'session/redact-text id secrets t)))
          (should (= 9 (plist-get dry :log-count)))
          (should (= 0 (plist-get dry :memory-count)))
          (should (= 5 (plist-get dry :record-count)))
          (should (equal '(assistant hint thinking tool-call tool-result user) (plist-get dry :kinds)))
          (should (equal '("/spill/c1.txt" "/spill/c2.txt") (plist-get dry :spill-files)))
          (should (equal '((:cli-session-id "cli-1" :uuid "u-1")) (plist-get dry :checkpoints)))
          (should-not (harness-session-loaded s))
          (should (= 0 (hash-table-count (harness-session-nodes s))))
          (should (equal log-before (harness-session-redact-test--read log))))
        (let ((result (harness-call 'session/redact-text id secrets)))
          (should (= 9 (plist-get result :log-count)))
          (should (= 0 (plist-get result :memory-count)))
          (should (= 5 (plist-get result :record-count)))
          (should (= 7 (length (plist-get result :nodes))))
          (should-not (harness-session-loaded s))
          (should (= 0 (hash-table-count (harness-session-nodes s)))))
        (should (= 0 (harness-session-redact-test--count log)))
        (should (= 0 (harness-session-redact-test--count (harness-session-redact-test--record id))))
        ;; Opened later, it is the cleaned transcript.
        (let ((nodes (harness-call 'session/nodes id)))
          (should-not (harness-session-redact-test--holds-any-p nodes))
          (should (harness-session-redact-test--holds-p nodes (harness-session-redact-test--placeholder 0))))))))

;;;; The record

(ert-deftest harness-session-redact-cleans-every-text-slot-of-the-record ()
  "The name, the queue, the requests waiting, the todos, the plan, the ext and a move."
  (harness-session-redact-test-with
    (let* ((key harness-session-redact-test--key)
           (marker (harness-session-redact-test--placeholder 0))
           (secrets (harness-session-redact-test--secrets))
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (s (gethash id harness-sessions))
           (record (harness-session-redact-test--record id)))
      (harness-call 'session/update id :name (format "name %s" key) :silent t)
      (harness-call 'session/queue id (format "queued %s" key))
      (harness-call 'session/pending-add id (list :kind 'question
                                                  :payload (list :question (format "Is %s right?" key))))
      (harness-call 'session/set-todos id (list (list :content (format "todo %s" key))))
      (harness-call 'session/set-plan id (format "plan %s" key))
      (harness-call 'session/set-ext id :plans (list (list :id "p1" :steps (list (list :result (format "got %s" key))))))
      ;; A move waiting for the turn to end: no method of the module sets one without a turn.
      (aset s (cl-struct-slot-offset 'harness-session 'move)
            (list :cwd (format "/tmp/%s/" key) :project "/tmp/"))
      (harness-session-flush)
      (should (= 7 (harness-session-redact-test--count record)))
      (let ((dry (harness-call 'session/redact-text id secrets t)))
        (should (= 7 (plist-get dry :record-count)))
        (should (= 7 (plist-get dry :count)))
        (should (= 0 (plist-get dry :log-count)))
        (should (equal '(:name :queue :pending :todos :plan :ext :move) (plist-get dry :record-fields)))
        (should-not (plist-get dry :file))
        (should (= 7 (harness-session-redact-test--count record))))
      (let ((result (harness-call 'session/redact-text id secrets)))
        (should (= 7 (plist-get result :record-count)))
        (should (equal '(:name :queue :pending :todos :plan :ext :move) (plist-get result :record-fields))))
      (should (= 0 (harness-session-redact-test--count record)))
      (should-not (harness-session-redact-test--holds-any-p (harness-session-plist s)))
      (should (equal (format "name %s" marker) (harness-session-name s)))
      (should (equal (format "Is %s right?" marker)
                     (plist-get (plist-get (car (harness-session-pending s)) :payload) :question)))
      (should (equal (format "/tmp/%s/" marker) (plist-get (harness-session-move s) :cwd)))
      (should (equal (format "got %s" marker)
                     (plist-get (car (plist-get (car (plist-get (harness-session-ext s) :plans)) :steps)) :result)))
      ;; Still blocked on the question: it is the same request.
      (should (eq 'blocked (harness-session-status s))))))

;;;; Awkward logs

(ert-deftest harness-session-redact-handles-lines-that-are-not-json ()
  "A line cut short by a crash is cleaned as text; lines without a secret stay as they are."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (secrets (harness-session-redact-test--secrets))
           (log (harness-session-redact-test--log id))
           (escaped (string-replace "\"" "\\\"" harness-session-redact-test--key))
           (cut (format "{\"id\":\"n-cut\",\"kind\":\"user\",\"content\":\"cut off %s" escaped))
           (junk "this is not json at all")
           (clean-cut "{\"id\":\"n-cut-clean\",\"kind\":\"user\",\"content\":\"cut off"))
      (harness-session-flush)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (concat cut "\n" junk "\n" clean-cut "\n") nil log 'append 'silent))
      (should (= 10 (harness-session-redact-test--count log)))
      (let ((dry (harness-call 'session/redact-text id secrets t)))
        (should (= 10 (plist-get dry :log-count)))
        ;; Not a node it could name.
        (should-not (member "n-cut" (plist-get dry :nodes))))
      (let ((result (harness-call 'session/redact-text id secrets))
            (lines (split-string (harness-session-redact-test--read log) "\n")))
        (should (= 10 (plist-get result :log-count)))
        (should (= 0 (harness-session-redact-test--count log)))
        ;; The last three lines and the final newline.
        (should (equal (list (format "{\"id\":\"n-cut\",\"kind\":\"user\",\"content\":\"cut off %s"
                                     (harness-session-redact-test--placeholder 0))
                             junk clean-cut "")
                       (last lines 4))))
      ;; The session loads as it did, the broken lines skipped.
      (harness-session-redact-test--reload)
      (should (equal 10 (length (harness-call 'session/nodes id)))))))

(ert-deftest harness-session-redact-refuses-a-log-that-is-not-text ()
  "A log with a NUL byte cannot be cleaned: say so, and leave it."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (log (harness-session-redact-test--log id)))
      (harness-session-flush)
      (let ((text (harness-session-redact-test--read log))
            (coding-system-for-write 'no-conversion))
        (write-region (concat "\0" (string-to-unibyte (encode-coding-string text 'utf-8))) nil log nil 'silent)
        (let ((before (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally log) (buffer-string))))
          ;; Counted all the same, but nothing to clean.
          (should (= 9 (plist-get (harness-call 'session/redact-text id (harness-session-redact-test--secrets) t)
                                  :log-count)))
          (let ((err (should-error (harness-call 'session/redact-text id (harness-session-redact-test--secrets))
                                   :type 'harness-error)))
            (should-not (harness-session-redact-test--holds-any-p err)))
          (should (equal before (with-temp-buffer (set-buffer-multibyte nil)
                                                  (insert-file-contents-literally log)
                                                  (buffer-string)))))))))

(ert-deftest harness-session-redact-reports-a-running-session ()
  "A session running a turn is cleaned all the same, and says it is running."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id)))
      (should-not (plist-get (harness-call 'session/redact-text id (harness-session-redact-test--secrets) t)
                             :running))
      (harness-register-method 'agent/running (lambda (&optional _sid) t))
      (let ((result (harness-call 'session/redact-text id (harness-session-redact-test--secrets))))
        (should (eq t (plist-get result :running)))
        (should (= 9 (plist-get result :log-count))))
      (should (= 0 (harness-session-redact-test--count (harness-session-redact-test--log id)))))))

(ert-deftest harness-session-redact-an-unknown-session-is-an-error ()
  (harness-session-redact-test-with
    (should-error (harness-call 'session/redact-text "no-such-session" (harness-session-redact-test--secrets))
                  :type 'harness-error)
    (should-error (harness-call 'session/reset-provider "no-such-session") :type 'harness-error)
    (should-error (harness-call 'session/family-ids "no-such-session") :type 'harness-error)))

;;;; A hosted provider's conversation

(ert-deftest harness-session-redact-leaves-a-transcript-a-new-conversation-starts-from ()
  "What a provider with no conversation of its own is sent has no secret in it.
After the redaction and the reset, the session has no provider state and
nothing to cut its conversation at, and the transcript a hosted
provider's new conversation opens with -- `session/messages' as
`harness-provider-history-text' renders it -- holds the placeholders."
  (harness-session-redact-test-with
    (let* ((ids (harness-session-redact-test--populate))
           (id (plist-get ids :id))
           (marker (harness-session-redact-test--placeholder 0))
           (history (lambda ()
                      (harness-provider-history-text
                       (car (harness-provider-split-history (harness-call 'session/messages id)))))))
      ;; Before: the conversation a new provider would open with has the secret.
      (should (> (harness-redaction-count (funcall history) (harness-session-redact-test--secrets)) 0))
      (harness-call 'session/redact-text id (harness-session-redact-test--secrets))
      (should (equal '(:checkpoints 1) (harness-call 'session/reset-provider id)))
      (let ((text (funcall history)))
        (should (stringp text))
        (should (= 0 (harness-redaction-count text (harness-session-redact-test--secrets))))
        (should-not (harness-session-redact-test--holds-any-p text))
        (should (string-search marker text))
        (should (string-search (harness-session-redact-test--placeholder 1) text))
        ;; The conversation goes on after the last reply, where it stood.
        (should (string-search "final answer with [redacted: " text)))
      (should-not (harness-session-redact-test--holds-any-p (harness-call 'session/messages id)))
      (should-not (plist-get (harness-call 'session/get id) :provider-state))
      (should-not (harness-call 'session/provider-state id))
      (should (equal '(:mode current) (harness-call 'session/provider-continuation id))))))

(defun harness-session-redact-test--hosted ()
  "Make a session on a hosted provider's conversation; return the ids of its nodes.
Two exchanges, each reply with a checkpoint: the first as the node was
written, the second as an update line, which is how the agent writes
them.  The conversation is S and reached the second reply.  Return
\(U1 A1 U2 A2)."
  (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-cut:m") :id))
         (ids (mapcar (lambda (n) (plist-get (harness-call 'session/append id n) :id))
                      '((:kind user :content "q1")
                        (:kind assistant :content "a1" :checkpoint (:cli-session-id "S" :uuid "c1"))
                        (:kind user :content "q2") (:kind assistant :content "a2")))))
    (harness-call 'session/update-node id (nth 3 ids) :checkpoint '(:cli-session-id "S" :uuid "c2"))
    (harness-call 'session/set-provider-state id '(:cli-session-id "S"))
    (harness-call 'session/set-provider-node id (nth 3 ids))
    (cons id ids)))

(ert-deftest harness-session-reset-provider-forgets-the-conversation-and-its-checkpoints ()
  "The provider state, the node it reached and every checkpoint go, in memory and on disk."
  (harness-session-redact-test-with
    (harness-session-redact-test-with-cut-provider
      (pcase-let* ((`(,id ,_u1 ,a1 ,u2 ,a2) (harness-session-redact-test--hosted))
                   (log (harness-session-redact-test--log id))
                   (events nil))
        (harness-on 'session/provider-state-changed (lambda (sid state) (push (list sid state) events)))
        (harness-session-flush)
        ;; Before: a fork at an earlier node holds the conversation cut at a checkpoint.
        (let* ((early (harness-test-await (harness-call 'session/fork id :node u2)))
               (state (plist-get early :provider-state)))
          (should (equal '(:cut (:cli-session-id "S" :uuid "c1") :provider "test-cut") state)))
        (should (equal (list :mode 'checkpoint :checkpoint '(:cli-session-id "S" :uuid "c1") :node a1)
                       (harness-call 'session/provider-continuation id u2)))
        (let ((log-before (harness-session-redact-test--read log)))
          (should (= 2 (cl-count-if (lambda (l) (string-search "checkpoint" l)) (split-string log-before "\n"))))
          (should (equal '(:checkpoints 2) (harness-call 'session/reset-provider id)))
          ;; The state and the node it reached.
          (let ((session (harness-call 'session/get id)))
            (should-not (plist-get session :provider-state))
            (should-not (plist-get session :provider-node))
            (should (equal a2 (plist-get session :head))))
          (should (equal (list (list id nil)) events))
          ;; The checkpoints in memory ...
          (should-not (cl-some (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes id)))
          ;; ... and in the log, where only the lines that had one changed.
          (let ((log-after (harness-session-redact-test--read log)))
            (should-not (string-search "checkpoint" log-after))
            (let ((old (split-string log-before "\n")) (new (split-string log-after "\n")))
              (should (= (length old) (length new)))
              (cl-loop for o in old for n in new
                       do (if (string-search "checkpoint" o)
                              (should-not (equal o n))
                            (should (equal o n)))))))
        ;; The record was written at once.
        (should-not (plist-get (harness-call 'store/load (harness-session--meta-name id)) :provider-state))
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        ;; A head off the conversation has nothing to cut at: a new one.
        (should (equal '(:mode fresh) (harness-call 'session/provider-continuation id u2)))
        (should (equal '(:mode fresh) (harness-call 'session/provider-continuation id a1)))
        ;; A fork at an earlier node starts afresh, with no conversation to resume ...
        (let ((early (harness-test-await (harness-call 'session/fork id :node u2))))
          (should-not (plist-get early :provider-state))
          (should (equal u2 (plist-get early :fork-node))))
        ;; ... and so does one at the head.
        (should-not (plist-get (harness-test-await (harness-call 'session/fork id)) :provider-state))
        ;; Loaded again from disk: the same.
        (harness-session-redact-test--reload)
        (should-not (cl-some (lambda (n) (plist-get n :checkpoint)) (harness-call 'session/nodes id)))
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        ;; Nothing is left to reset: the answer is none, and the provider is told all the same.
        (setq events nil)
        (should (equal '(:checkpoints 0) (harness-call 'session/reset-provider id)))
        (should (equal (list (list id nil)) events))))))

(ert-deftest harness-session-reset-provider-refuses-while-a-turn-runs ()
  "A running turn is writing to the conversation: nothing changes."
  (harness-session-redact-test-with
    (harness-session-redact-test-with-cut-provider
      (pcase-let* ((`(,id . ,_) (harness-session-redact-test--hosted))
                   (log (harness-session-redact-test--log id))
                   (text (harness-session-redact-test--read log))
                   (session (harness-call 'session/get id)))
        (harness-register-method 'agent/running (lambda (&optional _sid) t))
        (should-error (harness-call 'session/reset-provider id) :type 'harness-error)
        (should (equal session (harness-call 'session/get id)))
        (should (equal text (harness-session-redact-test--read log)))
        (harness-register-method 'agent/running (lambda (&optional _sid) nil))
        (should (equal '(:checkpoints 2) (harness-call 'session/reset-provider id)))))))

(ert-deftest harness-session-reset-provider-keeps-the-lines-that-are-not-nodes ()
  "A line that is no node, or one that cannot be written the same again, stays."
  (harness-session-redact-test-with
    (harness-session-redact-test-with-cut-provider
      (pcase-let* ((`(,id . ,_) (harness-session-redact-test--hosted))
                   (log (harness-session-redact-test--log id))
                   (note "{\"id\":\"n-note\",\"kind\":\"hint\",\"content\":\"a checkpoint is a note\"}")
                   (junk "checkpoint { not json")
                   (no-id "{\"checkpoint\":{\"cli-session-id\":\"S\"}}"))
        (harness-session-flush)
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (concat note "\n" junk "\n" no-id "\n") nil log 'append 'silent))
        (should (equal '(:checkpoints 2) (harness-call 'session/reset-provider id)))
        (let ((lines (split-string (harness-session-redact-test--read log) "\n")))
          (should (equal (list note junk no-id "") (last lines 4))))))))

;;;; The sessions a redaction reaches

(ert-deftest harness-session-family-ids-reaches-forks-of-forks-and-side-conversations ()
  "The session itself first, then every session its parent chain reaches, whatever the kind."
  (harness-session-redact-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (plist-get (harness-call 'session/create :cwd cwd :name "root" :model "demo:scripted") :id))
           (other (plist-get (harness-call 'session/create :cwd cwd :name "other") :id)))
      (harness-call 'session/append a '(:kind user :content "q1"))
      (harness-call 'session/append other '(:kind user :content "elsewhere"))
      (let* ((b (plist-get (harness-test-await (harness-call 'session/fork a :kind 'fork)) :id))
             (c (plist-get (harness-test-await (harness-call 'session/fork b :kind 'fork)) :id))
             (d (plist-get (harness-test-await (harness-call 'session/fork c :kind 'subagent)) :id))
             (e (plist-get (harness-call 'session/btw a "side") :id))
             (f (plist-get (harness-test-await (harness-call 'session/fork other :kind 'fork)) :id))
             (sorted (lambda (ids) (sort (copy-sequence ids) #'string<))))
        (let ((family (harness-call 'session/family-ids a)))
          (should (equal a (car family)))
          (should (equal (funcall sorted (list a b c d e)) (funcall sorted family)))
          (should (= 5 (length family))))
        (let ((family (harness-call 'session/family-ids b)))
          (should (equal b (car family)))
          (should (equal (funcall sorted (list b c d)) (funcall sorted family))))
        (should (equal (list d) (harness-call 'session/family-ids d)))
        (should (equal (list f) (cdr (harness-call 'session/family-ids other))))
        (should (equal other (car (harness-call 'session/family-ids other))))
        ;; Oldest first after the session.
        (should (equal (list a b c d e) (harness-call 'session/family-ids a)))
        ;; A fork whose parent went is out of reach of its grandparent: only records held count.
        (harness-call 'session/delete b)
        (should (equal (funcall sorted (list a e)) (funcall sorted (harness-call 'session/family-ids a))))
        (should (equal (list c d) (harness-call 'session/family-ids c)))))))

(ert-deftest harness-session-family-ids-survives-a-loop-of-parents ()
  "Records that name each other as parent do not hang the walk."
  (harness-session-redact-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (plist-get (harness-call 'session/create :cwd cwd :id "loop-a" :parent-id "loop-b") :id))
           (b (plist-get (harness-call 'session/create :cwd cwd :id "loop-b" :parent-id "loop-a") :id)))
      (should (equal (list a b) (harness-call 'session/family-ids a)))
      (should (equal (list b a) (harness-call 'session/family-ids b)))
      ;; A session that is its own parent is not its own descendant.
      (let ((c (plist-get (harness-call 'session/create :cwd cwd :id "loop-c" :parent-id "loop-c") :id)))
        (should (equal (list c) (harness-call 'session/family-ids c)))))))

(ert-deftest harness-session-redacted-event-is-declared ()
  "The engine emits `session/redacted'; the session module documents it."
  (harness-session-redact-test-with
    (should (string-match-p "never the secret" (or (alist-get 'session/redacted (harness-events)) "")))))

(provide 'harness-session-redact-test)
;;; harness-session-redact-test.el ends here
