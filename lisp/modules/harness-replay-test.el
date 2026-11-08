;;; harness-replay-test.el --- Tests for what a session's model was sent  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider is sent a session's whole conversation with every request,
;; and keeps the start of the last one it read in its prompt cache.
;; harness-replay.el keeps two things on disk so that the prefix it
;; cached does not change under it: the responses a session's tool calls
;; were answered with, reasoning items included, which used to be lost
;; at a restart, and the payload of the last request, which the next one
;; is continued from even when the code that renders a transcript
;; changed.  These tests are about those two promises: what is written
;; is what is read back, a restart and a code change keep the prefix, a
;; conversation that changed in what it renders does not, and a
;; redaction and a deletion take the copy with them.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider-responses)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-responses--responses)
(defvar harness-responses--responses-by-session)

(declare-function harness-responses--remember "harness-provider-responses" (items &optional session))
(declare-function harness-responses--remembered "harness-provider-responses" (blocks))
(declare-function harness-responses--session-table "harness-provider-responses" (session create))
(declare-function harness-replay--request "harness-replay" (id))
(declare-function harness-replay--request-name "harness-replay" (id))
(declare-function harness-replay--responses-name "harness-replay" (id))
(declare-function harness-replay--file "harness-replay" (name))
(declare-function harness-session-reload-nodes "harness-session" (id))

(defmacro harness-replay-test-with (&rest body)
  "Load the state modules and the replay module into a fresh bus, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session replay)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory dir))
       ,@body)))

(defmacro harness-replay-test-with-agent (&rest body)
  "As `harness-replay-test-with', with the demo provider and the turn loop."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent replay))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-replay-test-session ()
  "Return the id of a session of a project of its own."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))

(defun harness-replay-test-request (id &rest over)
  "Return the request a step of session ID would make, with OVER merged in.
It is what `harness-agent-step-request' makes of a session, without the
turn: the same model, system prompt, messages and tools."
  (let ((session (harness-call 'session/get id)))
    (list :model (or (plist-get over :model) (plist-get session :model))
          :session session
          :system (or (plist-get over :system) "You are a test.")
          :messages (harness-call 'session/messages id)
          :tools (plist-get over :tools)
          :thinking (plist-get over :thinking))))

(defun harness-replay-test--payload-file (id)
  "Return the absolute name of the payload kept for session ID."
  (harness-replay--file (harness-replay--request-name id)))

(defun harness-replay-test--responses-file (id)
  "Return the absolute name of the responses kept for session ID."
  (harness-replay--file (harness-replay--responses-name id)))

(defun harness-replay-test--edit-payload (id edit)
  "Call EDIT with session ID's kept payload and write the result back.
It stands for a change of the code that renders a request: the same
nodes, rendered to other messages."
  (let ((new (funcall edit (harness-replay--request id))))
    (harness-write-file-atomically (harness-replay-test--payload-file id)
                                   (harness-json-encode new))
    new))

(defun harness-replay-test--call-items (n)
  "Return the output items of a response that called tool number N."
  (list (list :type "reasoning" :id (format "rs_%d" n)
              :summary (vector (list :type "summary_text" :text (format "thinking %d" n)))
              :encrypted_content (format "E-%d" n))
        (list :type "function_call" :id (format "fc_%d" n)
              :call_id (format "call_%d" n) :name "echo"
              :arguments "{\"value\":\"a\"}")
        (list :type "function_call" :id (format "fc_%db" n)
              :call_id (format "call_%db" n) :name "echo"
              :arguments "{\"value\":\"b\"}")))

(defun harness-replay-test--blocks (n)
  "Return an assistant message that made the calls of response N."
  (list (list :type "tool_use" :id (format "call_%d" n) :name "echo" :input (list :value "a"))
        (list :type "tool_use" :id (format "call_%db" n) :name "echo" :input (list :value "b"))))

;;;; The responses

(ert-deftest harness-replay-a-response-is-read-back-after-a-restart ()
  "A response remembered before a restart is replayed after it.
The message it made is sent back as the response delivered it, its
reasoning items included, though the table that held them is gone."
  (harness-replay-test-with
    (let ((harness-responses--responses (make-hash-table :test 'equal))
          (harness-responses--responses-by-session (make-hash-table :test 'equal))
          (id "restarted"))
      (harness-responses--remember (harness-replay-test--call-items 1) (list :id id))
      (should (file-exists-p (harness-replay-test--responses-file id)))
      ;; The restart: the table in memory goes, the disk stays.
      (remhash id harness-responses--responses-by-session)
      (let ((harness-responses--current-session (list :id id))
            (harness-responses--current-tables nil))
        (let ((items (harness-responses--remembered (harness-replay-test--blocks 1))))
          (should items)
          (should (equal "E-1" (plist-get (car items) :encrypted_content)))
          (should (equal '("call_1" "call_1b")
                         (delq nil (mapcar (lambda (item) (and (equal (plist-get item :type)
                                                                      "function_call")
                                                               (plist-get item :call_id)))
                                           items))))))
      ;; A session with nothing kept for it has nothing to replay.
      (let ((harness-responses--current-session (list :id "elsewhere"))
            (harness-responses--current-tables nil))
        (should-not (harness-responses--remembered (harness-replay-test--blocks 1)))))))

(ert-deftest harness-replay-a-fork-reads-its-parents-responses-from-disk ()
  "A fork replays the calls its parent made before a restart.
The parent's table is not in memory, but its responses are on disk
under its own id, and the fork's history is the parent's."
  (harness-replay-test-with
    (let ((harness-responses--responses (make-hash-table :test 'equal))
          (harness-responses--responses-by-session (make-hash-table :test 'equal))
          (parent (harness-replay-test-session))
          (fork (harness-replay-test-session)))
      (harness-responses--remember (harness-replay-test--call-items 1)
                                   (harness-call 'session/get parent))
      (remhash parent harness-responses--responses-by-session)
      (let ((harness-responses--current-session (list :id fork :parent-id parent))
            (harness-responses--current-tables nil))
        (should (harness-responses--remembered (harness-replay-test--blocks 1)))))))

(ert-deftest harness-replay-only-the-newest-responses-are-kept ()
  "The disk keeps the newest responses, and a restart reads back those.
A response is cut from the file when the limit is passed, so a restart
cannot replay one the running harness had already dropped."
  (harness-replay-test-with
    (let ((harness-responses--responses (make-hash-table :test 'equal))
          (harness-responses--responses-by-session (make-hash-table :test 'equal))
          (harness-replay-responses-limit 2)
          (id "many"))
      (dotimes (n 4)
        (harness-responses--remember (harness-replay-test--call-items (1+ n)) (list :id id)))
      (should (= 2 (length (harness-call 'replay/responses id))))
      (remhash id harness-responses--responses-by-session)
      (let ((harness-responses--current-session (list :id id))
            (harness-responses--current-tables nil))
        (should-not (harness-responses--remembered (harness-replay-test--blocks 1)))
        (should (harness-responses--remembered (harness-replay-test--blocks 4)))))))

;;;; The payload of the last request

(ert-deftest harness-replay-a-request-continues-from-the-one-before ()
  "The next request sends the last one as it was, plus the new messages.
The nodes added since render as `session/messages' makes them, and the
two together are the whole conversation as a fresh rendering has it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (let ((first (harness-replay-test-request id)))
        (should (harness-call 'replay/save-request first))
        (should (equal (plist-get first :messages)
                       (plist-get (harness-replay--request id) :messages)))
        (harness-call 'session/append id (list :kind 'assistant :content "hi there"))
        (let* ((second (harness-replay-test-request id))
               (prefix (harness-call 'replay/prefix second)))
          (should prefix)
          (should (equal (plist-get prefix :messages) (plist-get first :messages)))
          (should (equal (append (plist-get prefix :messages) (plist-get prefix :suffix))
                         (plist-get second :messages))))))))

(ert-deftest harness-replay-a-payload-is-written-back-as-it-was ()
  "A payload read back is the JSON it was kept as, to the last byte.
An empty object, an empty array, false and text outside ASCII survive
the round trip; the harness's own reading of JSON would make null of
the first two, and the request would not be the one the provider
cached."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (list :role 'user
                                 :content (list (list :type "text"
                                                      :text "héllo — 日本語 \"quoted\"")
                                                (list :type "tool_use" :id "call_1"
                                                      :name "echo" :input :empty)
                                                (list :type "tool_result" :tool_use_id "call_1"
                                                      :content "done" :is_error nil)
                                                (list :type "text" :text "x"
                                                      :annotations [] :seen :false :on t)))))
           (request (list :model "demo:scripted" :session (harness-call 'session/get id)
                          :system "s" :messages messages :tools nil :thinking nil)))
      (harness-call 'session/append id (list :kind 'user :content "hi"))
      (should (harness-call 'replay/save-request request))
      (let ((kept (plist-get (harness-replay--request id) :messages)))
        (should (equal (harness-json-encode messages) (harness-json-encode kept)))
        ;; And the shapes are the harness's: the role is a symbol again,
        ;; an empty object `:empty', an empty array a vector.
        (should (eq (plist-get (car kept) :role) 'user))
        (should (eq (plist-get (nth 1 (plist-get (car kept) :content)) :input) :empty))
        (should (equal [] (plist-get (nth 3 (plist-get (car kept) :content)) :annotations)))))))

(ert-deftest harness-replay-a-restart-sends-the-payload-it-kept ()
  "A request made after a restart starts with the payload, not a rendering.
The transcript is read again from the node log, and the messages of the
last request are still what they were."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (let ((first (harness-replay-test-request id)))
        (harness-call 'replay/save-request first)
        (harness-session-reload-nodes id)
        (let ((prefix (harness-call 'replay/prefix (harness-replay-test-request id))))
          (should prefix)
          (should (equal (plist-get prefix :messages) (plist-get first :messages)))
          (should-not (plist-get prefix :suffix)))))))

(ert-deftest harness-replay-a-code-change-keeps-the-prefix ()
  "A change of the rendering code does not change a message already sent.
The nodes are the same; what rendering makes of them is not, and the
request still starts with the payload the provider has cached."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (secret "STAND-IN-OLD"))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      ;; A call nobody answered: its message holds a stand-in result, which
      ;; is where a change of the rendering code shows.  The user message
      ;; after it leaves the request ending where a step's does.
      (harness-call 'session/append id (list :kind 'tool-call :tool "echo"
                                             :call-id "call_1" :input (list :value "a")))
      (harness-call 'session/append id (list :kind 'user :content "and then?"))
      (let ((harness-session-missing-result-output secret))
        (harness-call 'replay/save-request (harness-replay-test-request id)))
      (harness-call 'session/append id (list :kind 'assistant :content "done"))
      (let* ((harness-session-missing-result-output "STAND-IN-NEW")
             (request (harness-replay-test-request id))
             (prefix (harness-call 'replay/prefix request))
             (rendered (harness-json-encode-text (plist-get request :messages))))
        ;; The change is a real one: rendering again shows it.
        (should (string-match-p "STAND-IN-NEW" rendered))
        (should-not (string-match-p "STAND-IN-OLD" rendered))
        ;; And the request is the payload as it was, with only what the
        ;; new node adds rendered.
        (should prefix)
        (should (string-match-p "STAND-IN-OLD" (harness-json-encode-text (plist-get prefix :messages))))
        (should (equal (append (plist-get prefix :messages) (plist-get prefix :suffix))
                       (let ((harness-session-missing-result-output secret))
                         (harness-call 'session/messages id))))))))

(ert-deftest harness-replay-a-node-that-renders-differently-starts-again ()
  "A node changed in what it renders gives another digest, and a fresh render.
The conversation is not the one the payload was made of any more."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (let* ((node (car (harness-call 'session/nodes id)))
             (other (harness-replay-test-request id)))
        (harness-call 'session/update-node id (plist-get node :id) :content "hello again")
        (should-not (harness-call 'replay/prefix other))))))

(ert-deftest harness-replay-another-prompt-or-tool-set-starts-again ()
  "A change of the system prompt, the tools or the model is rendered afresh.
Those are what the model is told, not how the conversation is rendered:
the payload is no prefix of the request that would be sent."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (should (harness-call 'replay/prefix (harness-replay-test-request id)))
      (should-not (harness-call 'replay/prefix (harness-replay-test-request id :system "Another.")))
      (should-not (harness-call 'replay/prefix
                                (harness-replay-test-request
                                 id :tools (list (list :name "echo" :description "say")))))
      (should-not (harness-call 'replay/prefix (harness-replay-test-request id :model "other:model")))
      (should-not (harness-call 'replay/prefix (harness-replay-test-request id :thinking 'high))))))

(ert-deftest harness-replay-a-compaction-drops-the-payload ()
  "A compaction replaces the conversation, and the payload goes with it.
What it would be continued into is the summary, not the messages it
holds, and it would be a second copy of the transcript it just cut."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (should (file-exists-p (harness-replay-test--payload-file id)))
      (harness-emit 'compaction/done id nil)
      (should-not (file-exists-p (harness-replay-test--payload-file id)))
      (should-not (harness-call 'replay/prefix (harness-replay-test-request id))))))

(ert-deftest harness-replay-a-picture-is-not-kept ()
  "A request that holds a picture's bytes is rendered again with every step.
The images a conversation carries are cut by its length, so a kept one
would hold pictures a later request drops, and the bytes are not the
transcript's to keep twice."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (request nil))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (setq request (harness-replay-test-request id))
      (setq request (plist-put request :messages
                               (list (list :role 'user
                                           :content (list (list :type "text" :text "look")
                                                          (list :type "image" :mime "image/png"
                                                                :data "iVBORw0KGgo="))))))
      (should-not (harness-call 'replay/save-request request))
      (should-not (file-exists-p (harness-replay-test--payload-file id))))))

;;;; Redaction and deletion

(ert-deftest harness-replay-a-redaction-cleans-what-the-provider-was-sent ()
  "A secret goes out of the responses, and the last request with it.
The responses are cleaned in place -- dropping them would send the
messages that made them without their reasoning items -- and the
payload is dropped, which costs no cache: the next request is rendered
from the redacted transcript anyway."
  (harness-replay-test-with
    (let* ((secret "FAKE-replay-secret-1234567890")
           (secrets (list (harness-redaction-secret secret "test.replay")))
           (id (harness-replay-test-session))
           (harness-responses--responses (make-hash-table :test 'equal))
           (harness-responses--responses-by-session (make-hash-table :test 'equal)))
      (harness-call 'session/append id (list :kind 'user :content (format "the key is %s" secret)))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (harness-call 'replay/remember-response
                    id (list (list :type "reasoning" :id "rs_1" :summary []
                                   :encrypted_content (format "thought about %s" secret))
                             (list :type "function_call" :id "fc_1" :call_id "call_1"
                                   :name "echo" :arguments "{}")))
      ;; A table in memory holds the same copy, and must go too.
      (harness-responses--session-table (list :id id) t)
      (should (file-exists-p (harness-replay-test--payload-file id)))
      (let ((result (harness-call 'session/redact-text id secrets nil)))
        (should (> (plist-get result :payload-count) 0))
        (should (member (harness-replay-test--responses-file id) (plist-get result :payload-files)))
        (should (member (harness-replay-test--payload-file id) (plist-get result :payload-files))))
      (should-not (file-exists-p (harness-replay-test--payload-file id)))
      (should (= 0 (harness-redaction-file-count
                    (harness-replay-test--responses-file id) secrets)))
      (should (file-exists-p (harness-replay-test--responses-file id)))
      ;; The table in memory is the copy the next request would replay.
      (should-not (gethash id harness-responses--responses-by-session)))))

(ert-deftest harness-replay-a-scan-counts-the-copies-too ()
  "A dry run finds the secret in what the provider was sent, and changes nothing."
  (harness-replay-test-with
    (let* ((secret "FAKE-replay-secret-1234567890")
           (secrets (list (harness-redaction-secret secret "test.replay")))
           (id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content (format "the key is %s" secret)))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (let ((result (harness-call 'session/redact-text id secrets t)))
        (should (> (plist-get result :payload-count) 0))
        (should (plist-get result :hit)))
      (should (file-exists-p (harness-replay-test--payload-file id))))))

(ert-deftest harness-replay-deleting-a-session-deletes-its-payload ()
  "A deleted session takes what was kept for it with it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (harness-responses--responses (make-hash-table :test 'equal))
           (harness-responses--responses-by-session (make-hash-table :test 'equal)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (harness-call 'replay/save-request (harness-replay-test-request id))
      (harness-call 'replay/remember-response id (harness-replay-test--call-items 1))
      (should (file-exists-p (harness-replay-test--payload-file id)))
      (should (file-exists-p (harness-replay-test--responses-file id)))
      (harness-call 'session/delete id)
      (should-not (file-exists-p (harness-replay-test--payload-file id)))
      (should-not (file-exists-p (harness-replay-test--responses-file id))))))

;;;; The session's own rendering, which the payload leans on

(ert-deftest harness-replay-the-messages-after-a-node-are-the-tail ()
  "The messages after a node are the tail of the whole rendering.
That is what a request continues with, and it is only those: the
message that ends before it stays as it was sent."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (harness-call 'session/append id (list :kind 'user :content "hello"))))
      (harness-call 'session/append id (list :kind 'assistant :content "hi there"))
      (harness-call 'session/append id (list :kind 'user :content "again"))
      (harness-call 'session/append id (list :kind 'assistant :content "yes"))
      (let* ((whole (harness-call 'session/messages id))
             (from (harness-call 'session/messages-from id (plist-get first :id))))
        (should (plist-get from :ok))
        (should (equal (nthcdr 1 whole) (plist-get from :messages))))
      ;; A user message that follows a user-side one renders as part of it,
      ;; so the messages after the node alone would not be the whole tail.
      (let* ((other (harness-replay-test-session))
             (said (harness-call 'session/append other (list :kind 'user :content "one"))))
        (harness-call 'session/append other (list :kind 'user :content "two"))
        (let ((from (harness-call 'session/messages-from other (plist-get said :id))))
          (should-not (plist-get from :ok))
          (should (stringp (plist-get from :why))))))))

(ert-deftest harness-replay-a-tail-is-what-a-request-up-to-there-ends-with ()
  "Wherever a request can be cut, its messages and the tail make the whole.
The property a kept payload leans on, over every node of a transcript
with answers, calls and what came after them: the messages up to the
node, then the messages after it, are the messages of the whole."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (last nil))
      (harness-call 'session/append id (list :kind 'user :content "a"))
      (harness-call 'session/append id (list :kind 'assistant :content "b"))
      (harness-call 'session/append id (list :kind 'tool-call :tool "echo"
                                             :call-id "call_1" :input (list :value "a")))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "call_1" :output "one"))
      (harness-call 'session/append id (list :kind 'hint :content "a note"))
      (harness-call 'session/append id (list :kind 'user :content "c"))
      (harness-call 'session/append id (list :kind 'assistant :content "d"))
      (setq last (plist-get (car (last (harness-call 'session/nodes id))) :id))
      (let ((whole (harness-call 'session/messages id))
            (nodes (harness-call 'session/nodes id)))
        (dolist (node nodes)
          (let ((from (harness-call 'session/messages-from id (plist-get node :id)))
                (cut (plist-get node :id)))
            (when (plist-get from :ok)
              (harness-call 'session/set-head id cut)
              (let ((prefix (harness-call 'session/messages id)))
                (harness-call 'session/set-head id last)
                (should (equal (append prefix (plist-get from :messages)) whole))))))))))

(ert-deftest harness-replay-the-digest-follows-what-rendering-reads ()
  "The digest of a transcript changes with what a request shows, and not with the rest.
The usage a step is given is kept on its node, and a request never
shows it: a digest that followed it would cost the cache for nothing."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session)))
      (harness-call 'session/append id (list :kind 'user :content "hello"))
      (let* ((digest (plist-get (harness-call 'session/render-state id) :digest))
             (nodes (plist-get (harness-call 'session/render-state id) :nodes)))
        (should (equal digest (harness-call 'session/render-digest id nodes)))
        ;; The usage of a step is not what rendering reads.
        (harness-call 'session/update-node id (car nodes) :meta (list :usage (list :input 10)))
        (should (equal digest (harness-call 'session/render-digest id nodes)))
        ;; The blocks a message is sent as, when it has them, are.
        (harness-call 'session/update-node id (car nodes)
                      :blocks (list (list :type "text" :text "as blocks")))
        (should-not (equal digest (harness-call 'session/render-digest id nodes)))
        ;; What it shows is.
        (harness-call 'session/update-node id (car nodes) :blocks nil :content "hello again")
        (should-not (equal digest (harness-call 'session/render-digest id nodes)))
        ;; A digest of ids that no longer start the transcript is none.
        (should-not (harness-call 'session/render-digest id (list "not-a-node")))))))

;;;; The turn loop

(defun harness-replay-test--watch-requests ()
  "Return a vector holding the newest request of the turns after this call.
`provider/request-started' reports each as the provider got it; it is
kept without its `:on-event', as `harness-agent-last-request' has one."
  (let ((seen (vector nil)))
    (harness-on 'provider/request-started
                (lambda (_pid request)
                  (aset seen 0 (harness-plist-remove request :on-event))))
    seen))

(ert-deftest harness-replay-a-step-keeps-what-it-sent ()
  "A step keeps the request it sent, and the next one is continued from it.
What is kept is the messages as the provider was given them, which is
what the provider cached."
  (harness-replay-test-with-agent
    (let ((seen (harness-replay-test--watch-requests))
          (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                       :model "demo:scripted") :id)))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (let ((sent (plist-get (aref seen 0) :messages)))
        (should sent)
        (should (file-exists-p (harness-replay-test--payload-file id)))
        (should (equal (plist-get (harness-replay--request id) :messages) sent)))
      ;; The next turn starts with the payload, not with a rendering of it.
      (harness-replay-test--edit-payload
       id (lambda (payload)
            (setcar (plist-get payload :messages)
                    (list :role 'user
                          :content (list (list :type "text" :text "KEPT BY THE PAYLOAD"))))
            payload))
      (harness-await (harness-call 'agent/prompt id "again"))
      (let ((messages (plist-get (aref seen 0) :messages)))
        (should (equal (plist-get (car messages) :content)
                       (list (list :type "text" :text "KEPT BY THE PAYLOAD"))))))))

(ert-deftest harness-replay-a-hosted-loop-is-not-sent-a-payload ()
  "A provider that holds the conversation is sent the newest message only.
Continuing a payload there would send the whole conversation again, so
nothing is kept for it either."
  (harness-replay-test-with-agent
    (harness-define-provider 'replay-hosted
      :label "Hosted"
      :complete
      (lambda (request)
        (let ((on-event (plist-get request :on-event)))
          (harness-run-soon
           (lambda ()
             (funcall on-event '(:type text :delta "hi"))
             (funcall on-event '(:type done :stop-reason end-turn))))
          (list :cancel #'ignore)))
      :capabilities '(:hosted-loop t))
    (unwind-protect
        (let ((seen (harness-replay-test--watch-requests))
              (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                           :model "replay-hosted:loop") :id)))
          (harness-await (harness-call 'agent/prompt id "hello"))
          (should (aref seen 0))
          (should (<= (length (plist-get (aref seen 0) :messages)) 1))
          (should-not (file-exists-p (harness-replay-test--payload-file id))))
      (harness-provider-unregister 'replay-hosted))))

(provide 'harness-replay-test)
;;; harness-replay-test.el ends here
