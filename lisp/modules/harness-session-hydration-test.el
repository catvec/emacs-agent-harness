;;; harness-session-hydration-test.el --- Hydration of saved session records  -*- lexical-binding: t; -*-

;;; Commentary:

;; A cold boot hydrates a session from its own record and from nothing
;; else: `sessions/ID.json' is the record, and the sidecars of the same
;; session -- its frozen body, the payload of its last request, its
;; responses -- are no record of it, whatever id they name.  The loader
;; used to take any `.json' there for a record and accept the first
;; `:id' it found; `<id>.frozen.json' sorts before `<id>.json', so a
;; boot read the frozen body as the session, skipped the canonical
;; record, and left the session with no head, no project, no working
;; directory and sometimes no model.  A task retry then sent the task's
;; prompt again as a node with no parent -- a second, disconnected chain
;; in the node log -- and saved that incomplete record over the
;; canonical one.
;;
;; These tests are about the two promises that keeps: a cold boot loads
;; the canonical record whatever sidecars stand beside it, and a record
;; it cannot hydrate is refused, left exactly as it is, and refuses to
;; send, append or save until an operator recovers it
;; (`session/recover-hydration').  The retry tests drive a real turn
;; through the demo provider and check what the transport was given.

;;; Code:

(require 'harness-test-helpers)
;; The struct's accessors, so a test can put a session in a state a save
;; has to refuse; the suites that load the modules in a fresh bus still
;; get the module they test from that bus.
(require 'harness-session)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-session--hydration-faults)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--waking)
(defvar harness-tasks--joining)
(defvar harness-tasks--superseding)
(defvar harness-tasks--message-starts)
(defvar harness-tasks--write-up-messages)
(defvar harness-tasks--naming)
(defvar harness-tasks--blocked-at)
(defvar harness-tasks--reply-blocked)
(defvar harness-tasks--lend-timers)
(defvar harness-tasks--holds)
(defvar harness-tasks--hold-timer)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-working-phase)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-context-limit)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-naming-auto)
(defvar harness-replay-frozen-max-bytes)

(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks--naming-pool-new "harness-tasks")
(declare-function harness-tasks--set "harness-tasks")

(defconst harness-session-hydration-test-script
  '((:type text :delta "Done.") (:type done :stop-reason end-turn)))

(defmacro harness-session-hydration-test-with (&rest body)
  "Load the state modules into a fresh bus and temp state dir, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-session--hydration-faults)
     (let ((default-directory dir))
       ,@body)))

(defmacro harness-session-hydration-test-with-agent (&rest body)
  "As the other, with the demo provider, the turn loop and the tasks."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent
                          priority tasks acp replay))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-session--hydration-faults)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks--waking)
     (clrhash harness-tasks--superseding)
     (clrhash harness-tasks--message-starts)
     (clrhash harness-tasks--write-up-messages)
     (clrhash harness-tasks--naming)
     (clrhash harness-tasks--blocked-at)
     (clrhash harness-tasks--reply-blocked)
     (maphash (lambda (_ timer) (cancel-timer timer)) harness-tasks--lend-timers)
     (clrhash harness-tasks--lend-timers)
     (clrhash harness-tasks--holds)
     (when (timerp harness-tasks--hold-timer) (cancel-timer harness-tasks--hold-timer))
     (setq harness-tasks--hold-timer nil)
     (harness-tasks--forget-stores)
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-tasks--naming-pool (harness-tasks--naming-pool-new)
           harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-session-hydration-test-script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification nil)
           (harness-tasks-working-phase nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (unwind-protect (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

;;;; Helpers

(defun harness-session-hydration-test-record-name (id)
  "Return the store name of session ID's canonical record."
  (format "sessions/%s.json" id))

(defun harness-session-hydration-test-journal-name (id)
  "Return the store name of session ID's node log."
  (format "sessions/%s.nodes.jsonl" id))

(defun harness-session-hydration-test-frozen-name (id)
  "Return the store name of session ID's frozen body."
  (format "sessions/%s.frozen.json" id))

(defun harness-session-hydration-test-forget ()
  "Forget every session in memory, as a restart does."
  (harness-session-flush)
  (clrhash harness-sessions))

(defun harness-session-hydration-test-boot ()
  "Load the saved sessions as the start of a harness does."
  (clrhash harness-sessions)
  (harness-session--load-all))

(defun harness-session-hydration-test-sidecars (id)
  "Write the sidecars of session ID a harness writes beside its record.
The frozen body of its last request sorts before the record, which is
what the loader used to read first; a request payload and a responses
log stand beside it.  Each carries the session's own id, as the real
ones do, and none of them is a session record."
  (harness-call 'store/save (harness-session-hydration-test-frozen-name id)
                (list :id id :version 1 :generation 7 :reset nil :at 1.0
                      :model "demo:scripted" :route "demo|scripted"
                      :body (list :kind "object" :fields (harness-json-array nil))))
  (harness-call 'store/append (format "sessions/%s.request.jsonl" id)
                (list :id id :at 1.0 :body (list :messages (harness-json-array nil))))
  (harness-call 'store/append (format "sessions/%s.responses.jsonl" id)
                (list :id id :call-id "c1" :output "a kept response")))

(defun harness-session-hydration-test-damage (id &optional record)
  "Overwrite the record of session ID with an incomplete RECORD.
That is what a retry from a session hydrated off a sidecar saved: no
head, no project, no working directory and no model, its times being
the replacement's, and the worktree the session was made in.  RECORD,
when given, replaces it."
  (harness-call 'store/save (harness-session-hydration-test-record-name id)
                (or record
                    (let ((before (harness-session-hydration-test-record id)))
                      (append (list :id id :kind "main")
                              (and (plist-get before :name) (list :name (plist-get before :name)))
                              (and (plist-get before :worktree) (list :worktree (plist-get before :worktree)))
                              (list :created 1.0 :updated 2.0 :status "inactive"))))))

(defun harness-session-hydration-test-retry-root (id)
  "Write the node a retry from an unhydrated session appended, and return its id.
It has no parent: the session had no head, so the message that should
have continued the transcript started a second chain in the log."
  (harness-call 'store/append (harness-session-hydration-test-journal-name id)
                (list :id "retry-root" :session id :kind "user" :parent nil
                      :content "carry on" :ts 300.0))
  "retry-root")

(defun harness-session-hydration-test-record (id)
  "Return the record of session ID as the store holds it."
  (harness-call 'store/load (harness-session-hydration-test-record-name id)))

(defun harness-session-hydration-test-record-text (id)
  "Return the bytes of session ID's record as the store holds them."
  (harness-read-file (expand-file-name (harness-session-hydration-test-record-name id)
                                       harness-state-directory)))

(defun harness-session-hydration-test-journal-text (id)
  "Return the bytes of session ID's node log as the store holds them."
  (harness-read-file (expand-file-name (harness-session-hydration-test-journal-name id)
                                       harness-state-directory)))

(defun harness-session-hydration-test-recovered-files ()
  "Return the recovery backups in the store, relative names, sorted."
  (sort (cl-remove-if-not (lambda (name) (string-match-p "\\.recovery-[^/]*\\.json\\'" name))
                          (harness-call 'store/list "sessions"))
        #'string<))

(defun harness-session-hydration-test-task (id)
  "Return task ID's view."
  (harness-call 'task/get id))

(defun harness-session-hydration-test-wait (predicate timeout message)
  "Wait until PREDICATE holds, at most TIMEOUT seconds; MESSAGE names it."
  (harness-test-wait predicate timeout message))

(defun harness-session-hydration-test-session-of (task-id)
  "Return the id of task TASK-ID's session."
  (plist-get (harness-session-hydration-test-task task-id) :session))

(defun harness-session-hydration-test-text (message)
  "Return the text of MESSAGE, a request's message, its blocks joined.
A message's content is a string, or the blocks the harness sends: the
text of its text blocks, in order."
  (let ((content (plist-get message :content)))
    (if (stringp content)
        content
      (mapconcat (lambda (block)
                   (or (plist-get block :text) ""))
                 (append content nil) ""))))

(defun harness-session-hydration-test-kinds (id)
  "Return the kinds of session ID's nodes, oldest first."
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

;;;; A cold boot reads the canonical record, whatever stands beside it

(ert-deftest harness-session-hydration-a-boot-reads-the-canonical-record ()
  "A cold boot hydrates the canonical record, not the frozen body beside it.
The frozen body sorts before the record and names the same session: the
boot has to take the record's head, project, working directory, model
and worktree, and the transcript the node log pairs with them."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (created (harness-call 'session/create :cwd cwd :name "Canonical"
                                  :model "demo:scripted" :worktree cwd))
           (id (plist-get created :id))
           (question (harness-call 'session/append id (list :kind 'user :content "the question")))
           (answer (harness-call 'session/append
                                 id (list :kind 'assistant :content "the answer"
                                          :meta (list :model "demo:scripted" :project cwd)))))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-sidecars id)
      (harness-session-hydration-test-boot)
      (let ((s (harness-call 'session/get id)))
        (should (equal "Canonical" (plist-get s :name)))
        (should (equal (plist-get answer :id) (plist-get s :head)))
        (should (equal cwd (plist-get s :cwd)))
        (should (equal (plist-get created :project) (plist-get s :project)))
        (should (equal "demo:scripted" (plist-get s :model)))
        (should (equal cwd (plist-get s :worktree)))
        (should (eq 'inactive (plist-get s :status))))
      (should (equal '(user assistant) (harness-session-hydration-test-kinds id)))
      (should (equal '("the question" "the answer")
                     (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes id))))
      (should (equal (plist-get question :id)
                     (plist-get (car (harness-call 'session/nodes id)) :id)))
      (should (equal "the question"
                     (plist-get (car (harness-call 'session/nodes id)) :content)))
      ;; Nothing was refused, and the record on disk still names the head.
      (should-not (harness-call 'session/hydration-faults))
      (should (equal (plist-get answer :id)
                     (plist-get (harness-session-hydration-test-record id) :head))))))

(ert-deftest harness-session-hydration-a-sidecar-is-never-a-session ()
  "A sidecar with the same id is no session at all when the record is missing.
Nothing is manufactured from it: no session, no fault of another id, and
no record written where the canonical one would be."
  (harness-session-hydration-test-with
    (let ((id "only-a-sidecar"))
      (harness-session-hydration-test-sidecars id)
      (harness-session-hydration-test-boot)
      (should-not (harness-call 'session/exists-p id))
      (should-not (harness-call 'session/hydration-faults))
      (should-not (file-exists-p
                   (expand-file-name (harness-session-hydration-test-record-name id)
                                     harness-state-directory))))))

(ert-deftest harness-session-hydration-a-record-naming-another-session-is-refused ()
  "A record whose `:id' is not the id its name carries is not hydrated.
It is left byte for byte as it was, and its own id is held, so nothing
writes a session over it."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "mine"))
           (id (plist-get s :id))
           (before (harness-session-hydration-test-record-text id)))
      (harness-session-hydration-test-forget)
      (harness-call 'store/save (harness-session-hydration-test-record-name id)
                    (plist-put (harness-session-hydration-test-record id) :id "somebody-else"))
      (harness-session-hydration-test-boot)
      (should-not (harness-call 'session/exists-p id))
      (should (equal (format "its record names session somebody-else")
                     (harness-call 'session/hydration-fault id)))
      ;; Left exactly as the boot found it.
      (should-not (equal before (harness-session-hydration-test-record-text id)))
      (should (equal "somebody-else"
                     (plist-get (harness-session-hydration-test-record id) :id)))
      ;; A session of the id the record names is not made either.
      (should-not (harness-call 'session/exists-p "somebody-else")))))

(ert-deftest harness-session-hydration-a-torn-record-is-refused ()
  "A record that cannot be read as JSON is refused, and left as it is.
Nothing is written over it: the bytes a recovery reads are the bytes
the boot found."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "torn") :id))
           (path (expand-file-name (harness-session-hydration-test-record-name id)
                                   harness-state-directory)))
      (harness-session-hydration-test-forget)
      (with-temp-file path (insert "{\"id\":\"torn\",\"cwd\":"))
      (let ((before (harness-read-file path)))
        (harness-session-hydration-test-boot)
        (should-not (harness-call 'session/exists-p id))
        (should (equal "its record is not a JSON object" (harness-call 'session/hydration-fault id)))
        (should (equal before (harness-read-file path)))))))

(ert-deftest harness-session-hydration-a-faulted-session-refuses-to-save ()
  "A record the boot refused is not written over, and no session is made over it.
A session that did not hydrate is not in memory, so no save of it can
write; a session made with that id is refused, and the record on disk
keeps the bytes a recovery reads."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "damaged") :id))
           (journal (harness-session-hydration-test-journal-name id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-boot)
      (let ((before (harness-session-hydration-test-record-text id)))
        (should (harness-call 'session/hydration-fault id))
        ;; Nothing is in memory to save, and asking for it says why.
        (should-not (gethash id harness-sessions))
        (should-not (harness-session--save id))
        (should (string-match-p "not hydrated" (cadr (should-error (harness-call 'session/get id)))))
        ;; Nor is one made over it.
        (should (string-match-p "not hydrated"
                                (cadr (should-error (harness-call 'session/create :cwd cwd :id id)))))
        (should-not (gethash id harness-sessions))
        (should (equal before (harness-session-hydration-test-record-text id)))
        (should (file-exists-p (expand-file-name journal harness-state-directory)))))))

(ert-deftest harness-session-hydration-a-save-never-writes-what-would-not-load ()
  "A save of a record that would not hydrate again is refused.
A record that names no session, or no working directory, is not
written: the next boot would refuse it, and the record it replaced would
be gone.  The record of a session that hydrates passes the same check."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "saved") :id))
           (before (harness-session-hydration-test-record-text id))
           (record (harness-session-hydration-test-record id)))
      ;; A record that hydrates is written.
      (should-not (harness-session--save-problem record id))
      (harness-session--save id)
      (should (equal record (harness-session-hydration-test-record id)))
      ;; One that does not is refused, and nothing is written.
      (should (string-match-p "names no session"
                              (harness-session--save-problem (plist-put (copy-sequence record)
                                                                        :id "another-id")
                                                             id)))
      (should (string-match-p "no working directory"
                              (harness-session--save-problem (plist-put (copy-sequence record) :cwd nil)
                                                             id)))
      (should (string-match-p "no working directory"
                              (harness-session--save-problem (plist-put (copy-sequence record) :cwd "")
                                                             id)))
      (should (equal before (harness-session-hydration-test-record-text id))))))

(ert-deftest harness-session-hydration-a-node-log-with-two-chains-is-refused ()
  "A record with no head whose log holds nodes refuses the session.
That is the damage a retry from a session hydrated off a sidecar left:
the prompt went in as a node with no parent, after the transcript had
begun, and the record was saved with no head at all.  The session is not
given that node as its transcript; the record is left for a recovery,
and nothing appends to the log."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "two chains"))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-retry-root id)
      (let ((record-before (harness-session-hydration-test-record-text id))
            (journal-before (harness-session-hydration-test-journal-text id)))
        (harness-session-hydration-test-boot)
        (should-not (harness-call 'session/exists-p id))
        (should (string-match-p "its record has no working directory"
                                (harness-call 'session/hydration-fault id)))
        ;; Asking for it says what restores it, and nothing is written.
        (should (string-match-p "not hydrated"
                                (cadr (should-error (harness-call 'session/nodes id)))))
        (should (string-match-p "not hydrated"
                                (cadr (should-error (harness-call 'session/append
                                                                  id (list :kind 'user :content "again"))
                                                    :type 'harness-error))))
        (should (equal record-before (harness-session-hydration-test-record-text id)))
        (should (equal journal-before (harness-session-hydration-test-journal-text id)))))))

(ert-deftest harness-session-hydration-a-headless-record-beside-a-full-log-is-refused ()
  "A record that names no head, though its log holds nodes, refuses the session.
A retry from a session hydrated off a sidecar wrote its prompt as a
node with no parent and saved a record with no head: the transcript it
should have continued is in the log, and nothing may read the session
as if the prompt were its first node."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "headless" :worktree cwd))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"))
      (harness-session-hydration-test-forget)
      ;; The record keeps its shape, and loses its head.
      (harness-call 'store/save (harness-session-hydration-test-record-name id)
                    (plist-put (harness-session-hydration-test-record id) :head nil))
      (harness-session-hydration-test-retry-root id)
      (let ((record-before (harness-session-hydration-test-record-text id))
            (journal-before (harness-session-hydration-test-journal-text id)))
        (harness-session-hydration-test-boot)
        (should (harness-call 'session/exists-p id))
        (should (string-match-p "names no head"
                                (cadr (should-error (harness-call 'session/nodes id)))))
        (should (string-match-p "names no head" (harness-call 'session/hydration-fault id)))
        (should (string-match-p "not hydrated"
                                (cadr (should-error (harness-call 'session/append
                                                                  id (list :kind 'user :content "again"))
                                                    :type 'harness-error))))
        (should (equal record-before (harness-session-hydration-test-record-text id)))
        (should (equal journal-before (harness-session-hydration-test-journal-text id)))))))

(ert-deftest harness-session-hydration-an-extra-chain-beside-a-good-record-is-harmless ()
  "A log with an extra chain whose record names a head on the first chain loads.
The session's transcript is the first chain, whole; the node the other
chain starts at is not part of it, and the record is not refused for
it."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "extra chain"))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-retry-root id)
      (harness-session-hydration-test-boot)
      (should-not (harness-call 'session/hydration-faults))
      (should (equal '(user assistant) (harness-session-hydration-test-kinds id)))
      (should (equal '("the question" "the answer")
                     (mapcar (lambda (n) (plist-get n :content))
                             (harness-call 'session/nodes id))))
      ;; A recovery has nothing to do: the record hydrates.
      (should (string-match-p "hydrates already"
                              (cadr (should-error (harness-call 'session/recover-hydration id))))))))

;;;; A retry continues the transcript the boot hydrated

(ert-deftest harness-session-hydration-a-retry-continues-the-canonical-transcript ()
  "A task retry after a boot with sidecars continues the canonical transcript.
The transport is given the whole history, the retry is the harness's
message parented on the canonical head -- not the task's prompt sent
again as a root -- and the record on disk keeps every field the boot
read: head, project, working directory, model and worktree."
  (harness-session-hydration-test-with-agent
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "Retried"
                                        :model "demo:scripted" :worktree cwd) :id))
           (question (harness-call 'session/append id (list :kind 'user :content "the question")))
           (answer (harness-call 'session/append
                                 id (list :kind 'assistant :content "the answer"
                                          :meta (list :model "demo:scripted" :project cwd))))
           (task (plist-get (harness-call 'task/submit cwd "carry on") :id)))
      ;; The task is given the session the transcript is in, and the
      ;; prompt that opened it, as the task's own work.
      (harness-tasks--set task :session id :started 0 :state 'active
                          :outcome 'error :error "it failed")
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-sidecars id)
      (let ((record-before (harness-session-hydration-test-record-text id))
            (journal-before (harness-session-hydration-test-journal-text id))
            (requests nil))
        (harness-session-hydration-test-boot)
        (should (equal (plist-get answer :id) (plist-get (harness-call 'session/get id) :head)))
        (let ((harness-provider-demo-script-override
               (lambda (request)
                 (push (plist-get request :messages) requests)
                 harness-session-hydration-test-script)))
          (harness-call 'task/retry task)
          (harness-session-hydration-test-wait
           (lambda () (eq 'done (plist-get (harness-session-hydration-test-task task) :state)))
           5 "the retried task to finish"))
        ;; The transport was given the canonical history, oldest first,
        ;; before the retry's message.
        (should requests)
        (let ((messages (car (last requests))))
          (should (>= (length messages) 3))
          (should (equal "the question" (harness-session-hydration-test-text (nth 0 messages))))
          (should (equal "the answer" (harness-session-hydration-test-text (nth 1 messages))))
          (should (string-match-p "stopped early"
                                  (harness-session-hydration-test-text (nth 2 messages)))))
        ;; The retry is a node after the canonical head, not a root.
        (let* ((nodes (harness-call 'session/nodes id))
               (retry (car (last (cl-remove-if-not
                                  (lambda (n) (harness-node-sender n))
                                  nodes)))))
          (should retry)
          (should (equal (harness-sender-system "tasks") (harness-node-sender retry)))
          (should (equal (plist-get answer :id) (plist-get retry :parent)))
          ;; One root, and it is the question the transcript began with.
          (should (equal (list (plist-get question :id))
                         (mapcar (lambda (n) (plist-get n :id))
                                 (cl-remove-if-not (lambda (n) (null (plist-get n :parent))) nodes)))))
        ;; The canonical record keeps every field, and the journal every node.
        (let ((after (harness-session-hydration-test-record id)))
          ;; The head is the retry's node, after the answer: the canonical
          ;; head it continued is still its parent.
          (should (equal (plist-get (car (last (harness-call 'session/nodes id))) :id)
                         (plist-get after :head)))
          (should (equal cwd (plist-get after :cwd)))
          (should (equal (plist-get (harness-call 'session/get id) :project) (plist-get after :project)))
          (should (equal "demo:scripted" (plist-get after :model)))
          (should (equal cwd (plist-get after :worktree))))
        (should-not (equal record-before (harness-session-hydration-test-record-text id)))
        (should (equal journal-before
                       (substring (harness-session-hydration-test-journal-text id)
                                  0 (length journal-before))))))))

(ert-deftest harness-session-hydration-a-faulted-task-refuses-to-retry ()
  "A task whose session did not hydrate refuses to retry, before it sends anything.
Its prompt does not go again as a root of the log, the record keeps the
bytes the boot found, and the refusal says what restores it."
  (harness-session-hydration-test-with-agent
    (let* ((cwd (harness-test-temp-dir))
           (task (plist-get (harness-call 'task/submit cwd "carry on") :id))
           (id (harness-session-hydration-test-session-of task)))
      ;; The submission's own turn ends before the boot this test makes.
      (harness-session-hydration-test-wait
       (lambda () (not (harness-call 'agent/running id))) 5 "the submission's turn to end")
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-boot)
      ;; The task stopped where a retry would carry on from.
      (harness-tasks--set task :started 0 :state 'active :outcome 'error :error "it failed")
      (let ((record-before (harness-session-hydration-test-record-text id))
            (journal-before (harness-session-hydration-test-journal-text id))
            (prompts nil))
        (let ((harness-provider-demo-script-override
               (lambda (request) (push (plist-get request :messages) prompts)
                 harness-session-hydration-test-script)))
          ;; A retry, and a message, both refuse, and neither sends.
          (dolist (call (list (lambda () (harness-call 'task/retry task))
                              (lambda () (harness-call 'task/prompt task "carry on"))))
            (should (string-match-p "not hydrated"
                                    (cadr (should-error (funcall call) :type 'harness-error)))))
          (should-not prompts)
          (should-not (harness-call 'agent/running id))
          (should-not (gethash id harness-agent--turns))
          ;; And the refusal did not become the task's error either.
          ;; The refusal did not become the task's own error: what it
          ;; stopped with is still what it says.
          (should (equal "it failed" (plist-get (harness-session-hydration-test-task task) :error))))
        (should (equal journal-before (harness-session-hydration-test-journal-text id)))
        (should (equal record-before (harness-session-hydration-test-record-text id)))))))

;;;; The replay guard is not weakened

(ert-deftest harness-session-hydration-a-boot-does-not-reset-the-frozen-body ()
  "A boot reads the canonical record and leaves the frozen body alone.
The body is not reset to explain a difference, and the guard still
refuses a request whose prompt component changed with no reset recorded
for it."
  (harness-session-hydration-test-with-agent
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "Guarded"
                                        :model "demo:scripted") :id)))
      (harness-call 'session/append id (list :kind 'user :content "hi"))
      (harness-call 'session/append id (list :kind 'assistant :content "ok"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-sidecars id)
      (let ((before (harness-read-file
                     (expand-file-name (harness-session-hydration-test-frozen-name id)
                                       harness-state-directory))))
        (harness-session-hydration-test-boot)
        (should (equal before
                       (harness-read-file
                        (expand-file-name (harness-session-hydration-test-frozen-name id)
                                          harness-state-directory))))
        ;; The body continues the transcript, so it is sent as it is.
        (let* ((body (list :model "scripted" :messages (list (list :role "user" :content "hi"))))
               (seam (harness-replay-seam (list :model "demo:scripted" :session (list :id id))
                                          "demo:scripted" "demo|scripted" body)))
          (should-not (cdr seam))
          (harness-replay-seam-keep (list :model "demo:scripted" :session (list :id id))
                                    "demo:scripted" "demo|scripted" body))
        ;; A prompt component that changed with no reset recorded for it
        ;; is still refused, and the complaint names it without its text.
        (let ((seam (harness-replay-seam
                     (list :model "demo:scripted" :session (list :id id))
                     "demo:scripted" "demo|scripted"
                     (list :model "scripted"
                           :messages (list (list :role "user" :content "HI"))))))
          (should (cdr seam))
          (should (string-match-p "messages\\[0\\]\\.content" (cdr seam)))
          (should-not (string-match-p "HI" (cdr seam))))))))

;;;; Recovery of a record the boot refused

(ert-deftest harness-session-hydration-recovery-restores-a-task-session ()
  "A task session's damaged record is recovered from its task and transcript.
That is the reported failure: a task's session lost its head, project,
working directory and model.  The task names the directory, the
transcript names the project and the model, and the recovered record
hydrates on the next boot with the task's own history."
  (harness-session-hydration-test-with-agent
    (let* ((cwd (harness-test-temp-dir))
           (task (plist-get (harness-call 'task/submit cwd "the task prompt") :id))
           (id (harness-session-hydration-test-session-of task)))
      (harness-session-hydration-test-wait
       (lambda () (not (harness-call 'agent/running id))) 10 "the task's turn to end")
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-retry-root id)
      (harness-session-hydration-test-boot)
      (should (harness-call 'session/hydration-fault id))
      (let ((plan (harness-call 'session/recover-hydration id (list :dry-run t))))
        ;; The directory comes from the task, the project and the model
        ;; from the transcript, and the session's own chain ends the head.
        (should (equal cwd (plist-get (plist-get plan :record-after) :cwd)))
        (should (equal cwd (plist-get (plist-get plan :record-after) :project)))
        (should (equal "demo:scripted" (plist-get (plist-get plan :record-after) :model)))
        ;; A task's session has no worktree of its own, so the directory
        ;; is the task's and nothing else says otherwise.
        (should (equal '(:created :cwd :model :project)
                       (sort (mapcar (lambda (p) (plist-get p :key)) (plist-get plan :provenance))
                             (lambda (a b) (string< (symbol-name a) (symbol-name b))))))
        (should (equal "its task"
                       (plist-get (cl-find :cwd (plist-get plan :provenance)
                                           :key (lambda (p) (plist-get p :key)))
                                  :source))))
      (harness-call 'session/recover-hydration id)
      (harness-session-hydration-test-boot)
      (should-not (harness-call 'session/hydration-faults))
      (should (equal cwd (plist-get (harness-call 'session/get id) :cwd)))
      ;; The task's prompt and its answer are the transcript again, and
      ;; the retry's root is not.
      (let ((texts (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes id))))
        (should (member "the task prompt" texts))
        (should-not (member "carry on" texts))))))


(ert-deftest harness-session-hydration-recovery-dry-run-changes-nothing ()
  "The dry run reports the plan and writes nothing at all."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd
                            :model "demo:scripted"))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"
                                             :meta (list :model "demo:scripted" :project cwd)))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-retry-root id)
      (harness-session-hydration-test-boot)
      (let ((record-before (harness-session-hydration-test-record-text id))
            (journal-before (harness-session-hydration-test-journal-text id)))
        (let ((plan (harness-call 'session/recover-hydration id (list :dry-run t))))
          (should (plist-get plan :dry-run))
          (should-not (plist-get plan :written))
          (should-not (plist-get plan :audit))
          (should (plist-get plan :head-moved))
          ;; The head goes back to the end of the session's own chain,
          ;; which is the head the record had before the damage.
          (should (equal (plist-get plan :head)
                         (plist-get (nth 0 (plist-get plan :chains)) :head)))
          (should (equal (plist-get (nth 0 (plist-get plan :chains)) :nodes) 2))
          ;; Both chains are reported, and the second is kept apart.
          (should (= 2 (length (plist-get plan :chains))))
          (should (equal "retry-root" (plist-get (nth 1 (plist-get plan :chains)) :root)))
          ;; What the record lost is read from what is left, and said.
          (let ((after (plist-get plan :record-after)))
            (should (equal cwd (plist-get after :cwd)))
            (should (equal cwd (plist-get after :project)))
            (should (equal "demo:scripted" (plist-get after :model)))
            (should (equal "Damaged" (plist-get after :name)))
            (should (equal "inactive" (plist-get after :status))))
          (should (equal '(:created :cwd :model :project :worktree)
                         (sort (mapcar (lambda (p) (plist-get p :key)) (plist-get plan :provenance))
                               (lambda (a b) (string< (symbol-name a) (symbol-name b)))))))
        ;; Nothing was written, and the session is still refused.
        (should (equal record-before (harness-session-hydration-test-record-text id)))
        (should (equal journal-before (harness-session-hydration-test-journal-text id)))
        (should-not (harness-session-hydration-test-recovered-files))
        (should (harness-call 'session/hydration-fault id))))))

(ert-deftest harness-session-hydration-recovery-writes-the-record-and-keeps-both-chains ()
  "A recovery backs up what it replaces, writes the record, and keeps both chains.
The audit holds the record before and after, the chains and the
provenance; the node log and the frozen body keep their bytes; and the
next boot hydrates the session with its own transcript, not the other
chain."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd
                            :model "demo:scripted"))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"
                                             :meta (list :model "demo:scripted" :project cwd)))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-retry-root id)
      (harness-session-hydration-test-sidecars id)
      (harness-session-hydration-test-boot)
      (let ((journal-before (harness-session-hydration-test-journal-text id))
            (frozen-before (harness-read-file
                            (expand-file-name (harness-session-hydration-test-frozen-name id)
                                              harness-state-directory)))
            (damaged (harness-session-hydration-test-record id)))
        (let ((plan (harness-call 'session/recover-hydration id)))
          (should-not (plist-get plan :dry-run))
          (should (file-exists-p (plist-get plan :written)))
          (should (file-exists-p (plist-get plan :audit)))
          ;; The audit keeps the record it replaced, the one it wrote,
          ;; the chains and where each field came from.
          (let* ((audit (harness-call 'store/load
                                      (file-relative-name (plist-get plan :audit)
                                                          harness-state-directory))))
            (should (equal "hydration-recovery" (plist-get audit :kind)))
            (should (equal id (plist-get audit :id)))
            (should (equal damaged (plist-get audit :record-before)))
            (should (equal (harness-session-hydration-test-record id)
                           (plist-get audit :record-after)))
            (should (= 2 (length (plist-get audit :chains))))
            (should (plist-get audit :provenance))
            (should (equal "Unchanged: the guard still refuses a frozen body that does not continue the transcript"
                           (plist-get audit :replay)))))
        ;; The node log and the frozen body are untouched.
        (should (equal journal-before (harness-session-hydration-test-journal-text id)))
        (should (equal frozen-before
                       (harness-read-file
                        (expand-file-name (harness-session-hydration-test-frozen-name id)
                                          harness-state-directory))))
        ;; The next boot hydrates it, with its own transcript.
        (harness-session-hydration-test-boot)
        (should-not (harness-call 'session/hydration-faults))
        (let ((s (harness-call 'session/get id)))
          (should (equal "Damaged" (plist-get s :name)))
          (should (equal cwd (plist-get s :cwd)))
          (should (equal cwd (plist-get s :project)))
          (should (equal "demo:scripted" (plist-get s :model)))
          (should (equal cwd (plist-get s :worktree))))
        (should (equal '(user assistant) (harness-session-hydration-test-kinds id)))
        (should (equal '("the question" "the answer")
                       (mapcar (lambda (n) (plist-get n :content))
                               (harness-call 'session/nodes id))))))))

(ert-deftest harness-session-hydration-recovery-is-idempotent ()
  "A recovery run twice writes once: the second run has nothing to recover.
The record, the journal and the backups are as the first run left them."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-boot)
      (harness-call 'session/recover-hydration id)
      (let ((record (harness-session-hydration-test-record-text id))
            (journal (harness-session-hydration-test-journal-text id))
            (files (harness-session-hydration-test-recovered-files)))
        (should files)
        (should (string-match-p "hydrates already: nothing to recover"
                                (cadr (should-error (harness-call 'session/recover-hydration id)))))
        (should (equal record (harness-session-hydration-test-record-text id)))
        (should (equal journal (harness-session-hydration-test-journal-text id)))
        (should (equal files (harness-session-hydration-test-recovered-files)))))))

(ert-deftest harness-session-hydration-recovery-refuses-what-two-stores-disagree-about ()
  "A recovery refuses a field its stores disagree about, and writes nothing.
The project the transcript names and the one its task works in are two
answers to one question: no recovery picks between them, and the record
it would have replaced is left as it was."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-call 'session/append id (list :kind 'assistant :content "the answer"
                                             :meta (list :project cwd)))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (harness-session-hydration-test-boot)
      (let ((before (harness-session-hydration-test-record-text id)))
        ;; A project the record names, which the transcript does not.
        (harness-call 'store/save (harness-session-hydration-test-record-name id)
                      (plist-put (harness-session-hydration-test-record id)
                                 :project (harness-test-temp-dir)))
        (setq before (harness-session-hydration-test-record-text id))
        (should (string-match-p "ambiguous"
                                (cadr (should-error (harness-call 'session/recover-hydration id)
                                                    :type 'harness-error))))
        (should (equal before (harness-session-hydration-test-record-text id)))
        (should-not (harness-session-hydration-test-recovered-files))
        (should (harness-call 'session/hydration-fault id))))))

(ert-deftest harness-session-hydration-recovery-refuses-a-chain-with-no-head ()
  "A first chain with several ends and no head to choose between them is refused.
A recovery does not pick one: the record named none of them, and a
guess would cut a transcript that is not the session's to lose."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      ;; Two ends of one chain: a node after the first, and another
      ;; after it again, with no head in the record to say which won.
      (harness-call 'store/append (harness-session-hydration-test-journal-name id)
                    (list :id "left" :session id :kind 'assistant :parent nil :content "left" :ts 100.0))
      (harness-call 'store/append (harness-session-hydration-test-journal-name id)
                    (list :id "right" :session id :kind 'assistant :parent nil :content "right" :ts 200.0))
      (harness-session-hydration-test-boot)
      (let ((before (harness-session-hydration-test-record-text id)))
        (should (string-match-p "chains"
                                (cadr (should-error (harness-call 'session/recover-hydration id)
                                                    :type 'harness-error))))
        (should (equal before (harness-session-hydration-test-record-text id)))
        (should-not (harness-session-hydration-test-recovered-files))))))

(ert-deftest harness-session-hydration-recovery-leaves-a-provider-conversation-off-the-chain ()
  "A provider conversation that reached a node of the other chain is dropped.
The record keeps the node its own chain holds, and nothing else: the
session starts a provider conversation from its transcript rather than
resume one that belongs to the session that replaced it."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd))
           (id (plist-get s :id)))
      (harness-call 'session/append id (list :kind 'user :content "the question"))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-retry-root id)
      (harness-session-hydration-test-damage
       id (list :id id :name "Damaged" :kind "main" :worktree cwd
                :created 1.0 :updated 2.0 :status "inactive"
                :provider-node "retry-root" :provider-state (list :cli "the other session")))
      (harness-session-hydration-test-boot)
      (let ((plan (harness-call 'session/recover-hydration id)))
        (should-not (plist-get (plist-get plan :record-after) :provider-node))
        (should-not (plist-get (plist-get plan :record-after) :provider-state))
        (should (plist-get plan :written))))))

(ert-deftest harness-session-hydration-recovery-explicit-head-multiple-retries ()
  "Recover only from the selected ancestry and leave all log bytes alone."
  (harness-session-hydration-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :name "Damaged" :worktree cwd))
           (id (plist-get s :id))
           (root (plist-get (harness-call 'session/append id (list :kind 'user :content "original")) :id))
           (choice (list :original-head "chosen" :head-evidence "Recorded pre-restart head")))
      (harness-session-hydration-test-forget)
      (harness-session-hydration-test-damage id)
      (dolist (node (list (list :id "chosen" :parent root :meta (list :model "demo:scripted"))
                          (list :id "alternate" :parent root :meta (list :model "other:model"))
                          (list :id "retry-1") (list :id "retry-2")))
        (harness-call 'store/append (harness-session-hydration-test-journal-name id)
                      (append node (list :session id :kind "assistant"
                                         :content (plist-get node :id)
                                         :ts (if (equal (plist-get node :id) "alternate") 20 10)))))
      (harness-session-hydration-test-sidecars id)
      (harness-session-hydration-test-boot)
      (should-error (harness-call 'session/recover-hydration id (list :dry-run t)) :type 'harness-error)
      (should-error (harness-call 'session/recover-hydration id
                                  (list :dry-run t :original-head "retry-2" :head-evidence "Wrong tree"))
                    :type 'harness-error)
      (let* ((before (harness-session-hydration-test-record-text id))
             (journal (harness-session-hydration-test-journal-text id))
             (plan (harness-call 'session/recover-hydration id (append '(:dry-run t) choice)))
             (fp (plist-get plan :fingerprint)))
        (should (= 3 (length (plist-get plan :chains))))
        (should (equal "demo:scripted" (plist-get (plist-get plan :record-after) :model)))
        (should (equal before (harness-session-hydration-test-record-text id)))
        (should-not (harness-session-hydration-test-recovered-files))
        (should-error (harness-call 'session/recover-hydration id (append choice '(:expected-fingerprint "wrong")))
                      :type 'harness-error)
        (should-not (harness-session-hydration-test-recovered-files))
        (let* ((applied (harness-call 'session/recover-hydration id
                                      (append choice (list :expected-fingerprint fp))))
               (audit (harness-call 'store/load (file-relative-name (plist-get applied :audit)
                                                                    harness-state-directory))))
          (should (equal fp (plist-get audit :fingerprint)))
          (should (equal "Recorded pre-restart head" (plist-get audit :head-evidence)))
          (should (equal journal (harness-session-hydration-test-journal-text id)))
          (should (equal "inactive" (plist-get (harness-session-hydration-test-record id) :status))))
        (harness-session-hydration-test-boot)
        (should (equal "chosen" (plist-get (harness-call 'session/get id) :head)))
        (should (equal '("original" "chosen")
                       (mapcar (lambda (n) (plist-get n :content))
                               (harness-call 'session/nodes id))))))))

(ert-deftest harness-session-hydration-recovery-task-cwd-is-not-its-worktree ()
  "Verify that a task's base cwd and linked worktree have distinct roles."
  (require 'harness-files)
  (let* ((project (harness-test-temp-dir))
         (outside (harness-test-temp-dir))
         (tree (expand-file-name "linked" outside))
         (default-directory project))
    (should (= 0 (call-process "git" nil nil nil "init" "--quiet")))
    (should (= 0 (call-process "git" nil nil nil "-c" "user.name=Fixture"
                               "-c" "user.email=fixture@example.invalid" "-c" "commit.gpgsign=false"
                               "commit" "--quiet" "--allow-empty" "-m" "Fixture")))
    (should (= 0 (call-process "git" nil nil nil "worktree" "add" "--detach" tree)))
    (should-not (harness-session--recovery-task-cwd
                 (list :cwd project :project project :worktree tree)))
    (should-error (harness-session--recovery-task-cwd
                   (list :cwd project :project project :worktree outside))
                  :type 'harness-error)))

(ert-deftest harness-session-hydration-recovery-head-is-the-node-written-last ()
  "A chain with several ends is recovered at the node the log wrote last.
A session that moved its head back left a branch behind; the transcript
it went on writing is the end the log wrote last, and a hint written
after the last thing the model said is where it went on to.  The rule
reproduces the recorded head of every healthy multi-leaf record, so it
is what a damaged one with the same shape is recovered to."
  (let* ((chain (list :root "a" :nodes '("a" "b" "c" "d") :leaves '("b" "d")))
         (order '("a" "b" "d" "c")))
    ;; "d" was written after "b", and "c" is a branch written last of all:
    ;; the newest node of the chain is the head.
    (should (equal "c" (harness-session--recovery-head nil chain nil order))))
  ;; A record that still names its head keeps it, wherever it is.
  (let ((chain (list :root "a" :nodes '("a" "b" "c") :leaves '("b" "c"))))
    (should (equal "b" (harness-session--recovery-head (list :head "b") chain nil
                                                       '("a" "b" "c")))))
  ;; The several ends without a write order are not guessed at.
  (let ((chain (list :root "a" :nodes '("a" "b" "c") :leaves '("b" "c"))))
    (should-error (harness-session--recovery-head nil chain nil nil) :type 'harness-error)
    ;; An order that names none of the nodes decides nothing.
    (should-error (harness-session--recovery-head nil chain nil '("x" "y")) :type 'harness-error))
  ;; Nor does one that leaves a node unnamed: which it was is not known.
  (should-not (harness-session--recovery-last-written '("a" "b") '("a"))))

(ert-deftest harness-session-hydration-recovery-task-worktree-wins-over-its-cwd ()
  "A task's worktree is where it worked; its cwd is where it was submitted.
A task submitted from one worktree but working in another of its own
names both, and the two are no disagreement: the worktree is the
directory.  Without a worktree, the cwd is."
  (require 'harness-files)
  (let* ((project (harness-test-temp-dir))
         (outside (harness-test-temp-dir))
         (tree (expand-file-name "linked" outside))
         (default-directory project))
    (should (= 0 (call-process "git" nil nil nil "init" "--quiet")))
    (should (= 0 (call-process "git" nil nil nil "-c" "user.name=Fixture"
                               "-c" "user.email=fixture@example.invalid" "-c" "commit.gpgsign=false"
                               "commit" "--quiet" "--allow-empty" "-m" "Fixture")))
    (should (= 0 (call-process "git" nil nil nil "worktree" "add" "--detach" tree)))
    ;; The worktree is the directory, and the cwd does not compete with it.
    (should-not (harness-session--recovery-task-cwd
                 (list :cwd outside :project project :worktree tree)))
    ;; A task with no worktree works in its cwd.
    (should (equal (file-name-as-directory (expand-file-name outside))
                   (harness-session--recovery-task-cwd
                    (list :cwd outside :project project))))))

(ert-deftest harness-session-hydration-recovery-project-names-one-project ()
  "A project's root and a worktree of it are one project, not a disagreement.
A task's session that worked in a worktree names the worktree in its
transcript and the project root in its task, and the recovery reads
that as one project rather than refusing it."
  (require 'harness-files)
  (let* ((project (harness-test-temp-dir))
         (outside (harness-test-temp-dir))
         (tree (expand-file-name "linked" outside))
         (default-directory project))
    (should (= 0 (call-process "git" nil nil nil "init" "--quiet")))
    (should (= 0 (call-process "git" nil nil nil "-c" "user.name=Fixture"
                               "-c" "user.email=fixture@example.invalid" "-c" "commit.gpgsign=false"
                               "commit" "--quiet" "--allow-empty" "-m" "Fixture")))
    (should (= 0 (call-process "git" nil nil nil "worktree" "add" "--detach" tree)))
    (should (harness-session--recovery-same-project
             (file-name-as-directory (expand-file-name project))
             (file-name-as-directory (expand-file-name tree))))
    ;; A directory of another project is another project.
    (should-not (harness-session--recovery-same-project
                 (file-name-as-directory (expand-file-name project))
                 (file-name-as-directory (expand-file-name outside))))))

(ert-deftest harness-session-hydration-recovery-observed-cwd-is-unanimous-or-nothing ()
  "The directory a session's own tool results name is read only when they agree.
A session whose record and task both lost their directory still says
where it ran in the `:cwd' of its tool results; a session that ran in
two directories says no one thing, and nothing is taken from it."
  (let* ((dir (file-name-as-directory (expand-file-name (harness-test-temp-dir))))
         (other (file-name-as-directory (expand-file-name (harness-test-temp-dir)))))
    (should (equal dir
                   (harness-session--recovery-observed-cwd
                    (list (list :kind 'tool-result :meta (list :cwd dir))
                          (list :kind 'tool-result :meta (list :cwd dir))))))
    (should-not (harness-session--recovery-observed-cwd
                 (list (list :kind 'tool-result :meta (list :cwd dir))
                       (list :kind 'tool-result :meta (list :cwd other)))))
    ;; A tool result that names no directory says nothing either way.
    (should (equal dir
                   (harness-session--recovery-observed-cwd
                    (list (list :kind 'tool-result :meta nil)
                          (list :kind 'tool-result :meta (list :cwd dir))))))
    ;; A directory that is gone is no directory.
    (should-not (harness-session--recovery-observed-cwd
                 (list (list :kind 'tool-result
                             :meta (list :cwd (expand-file-name "gone" dir))))))))

(provide 'harness-session-hydration-test)
;;; harness-session-hydration-test.el ends here
