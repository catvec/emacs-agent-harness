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
;; The adapter-level tests drive the real chat-completions transport
;; through a recording fake of their own.
(require 'harness-provider-openai)

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

(ert-deftest harness-replay-a-picture-is-kept-as-the-tool-returned-it ()
  "A request that holds a picture's bytes is kept like any other request.
The bytes are the ones the tool returned, because the copy `harness-images.el'
keeps names the picture by the digest of them: a file that changed under the
conversation cannot change the prefix, so there is nothing to render again."
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
      (should (harness-call 'replay/save-request request))
      (should (file-exists-p (harness-replay-test--payload-file id)))
      ;; What is kept is what was sent: the picture's bytes are in it, and
      ;; the next request that sends the same picture continues from it.
      (let ((kept (harness-replay--request id)))
        (should (harness-replay--image-data-p (plist-get kept :messages)))))))

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

;;; The frozen body, for harness-replay-test.el.

(defun harness-replay-test--body (messages &rest over)
  "Return a chat-completions body of MESSAGES, with OVER merged in."
  (let ((body (list :model "m" :messages messages :stream t
                    :stream_options (list :include_usage t))))
    (cl-loop for (key value) on over by #'cddr
             do (setq body (plist-put body key value)))
    body))

(defun harness-replay-test--seam (id messages &rest over)
  "Return (BODY . COMPLAINT) for MESSAGES as session ID's next request."
  (harness-replay-seam (list :model "m" :session (list :id id)) "m" "route"
                       (apply #'harness-replay-test--body messages over)))

(defun harness-replay-test--keep (id messages &rest over)
  "Keep MESSAGES as what session ID's request sent."
  (harness-replay-seam-keep (list :model "m" :session (list :id id)) "m" "route"
                            (apply #'harness-replay-test--body messages over)))

(defun harness-replay-test--message (text &optional role)
  "Return one message of TEXT from ROLE, a user's by default."
  (list :role (or role "user") :content text))

(ert-deftest harness-replay-the-frozen-body-is-what-was-sent ()
  "The body the seam returns is the bytes a transport would have sent.
It is not a re-encoding of equal data: it is the adapter's own fields, in the
adapter's own order, so a provider that read them reads the same bytes."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (body (harness-replay-test--body (list (harness-replay-test--message "hi"))
                                            :max_tokens 40))
           (seam (harness-replay-seam (list :model "m" :session (list :id id))
                                      "m" "route" body)))
      (should-not (cdr seam))
      (should (equal (car seam)
                     (decode-coding-string (harness-json-encode body) 'utf-8))))))

(ert-deftest harness-replay-an-appended-message-changes-nothing-before-it ()
  "A second request that adds a message sends the first one's bytes as they were.
The whole body is rebuilt by the adapter with every step; what goes out keeps
the bytes of every field and item the provider already read."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (second (append first (list (harness-replay-test--message "yo" "assistant")))))
      (harness-replay-test--keep id first)
      (let ((seam (harness-replay-test--seam id second)))
        (should-not (cdr seam))
        (should (equal (car seam)
                       (decode-coding-string
                        (harness-json-encode (harness-replay-test--body second))
                        'utf-8)))))))

(ert-deftest harness-replay-a-change-with-no-recorded-reset-is-refused ()
  "A prompt component that changed with nothing to explain it is refused.
The complaint names the field and the index, never the text."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (changed (list (harness-replay-test--message "HI"))))
      (harness-replay-test--keep id first)
      (let ((seam (harness-replay-test--seam id changed)))
        (should (cdr seam))
        (should (string-match-p "messages\\[0\\]\\.content" (cdr seam)))
        (should-not (string-match-p "HI" (cdr seam)))))))

(ert-deftest harness-replay-a-recorded-reset-explains-the-change ()
  "A reset recorded for the reason that changed empties the frozen body."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (changed (list (harness-replay-test--message "HI"))))
      (harness-replay-test--keep id first)
      (should (cdr (harness-replay-test--seam id changed)))
      (harness-call 'replay/frozen-reset id 'redaction)
      (should-not (cdr (harness-replay-test--seam id changed)))
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "redaction"))
      (should (= 2 (plist-get (harness-call 'replay/frozen-status id) :generation))))))

(ert-deftest harness-replay-settling-a-prompt-explains-the-change-it-makes ()
  "A session that settles a system prompt after it sent one records a reset.
That is a session from before prompts were settled at all: its record
says nil, so the request it sends next is built from a prompt no earlier
request sent, and the boundary check would refuse it as a change nothing
explained.  Settling it is a change the harness knows, so it is recorded
in advance and the next request goes out instead of being refused."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (settled (list (harness-replay-test--message "hi" "assistant")
                          (harness-replay-test--message "there"))))
      ;; A request went out before the session settled a prompt.
      (harness-replay-test--keep id first)
      (should-not (plist-get (harness-call 'session/get id) :system))
      ;; The settle is what the fix announces.  Its change is exactly what
      ;; the boundary check refuses when nothing records it, which is the
      ;; stranded session's failure: the prompt the next request is built
      ;; from is not the one the frozen body kept.
      (should (cdr (harness-replay-test--seam id settled :system "You are a test.")))
      (harness-call 'session/set-system id "You are a test.")
      ;; The reset is recorded, so the same body is sent, not refused.
      (should (equal "system" (plist-get (harness-call 'replay/frozen-status id) :reset)))
      (should (= 0 (plist-get (harness-call 'replay/frozen-status id) :bytes)))
      (let ((seam (harness-replay-test--seam id settled :system "You are a test.")))
        (should-not (cdr seam))))))

(ert-deftest harness-replay-settling-a-tool-schema-explains-the-change-it-makes ()
  "A session that settles a tool schema after it sent a request records a reset.
The schema follows the prompt in a request, and a provider's cache reads
it, so a session that settles one it did not send before has changed what
it sends, and the change is recorded rather than refused."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (tool (list :type "function" :function (list :name "a" :description "d"))))
      (harness-replay-test--keep id messages)
      (should-not (plist-get (harness-call 'session/get id) :tool-schema))
      (harness-call 'session/set-tool-schema id (list "a"))
      (should (equal "tools" (plist-get (harness-call 'replay/frozen-status id) :reset)))
      (let ((seam (harness-replay-test--seam id messages :tools (list tool))))
        (should-not (cdr seam))))))

(ert-deftest harness-replay-a-first-request-settling-a-prompt-records-nothing ()
  "A session settling a prompt at its first request records no reset.
Nothing was sent before it, so there is no frozen body to stop applying,
and settling announces nothing: its first request is the first thing
frozen."
  (harness-replay-test-with
    (let ((id (harness-replay-test-session)))
      (should-not (harness-call 'replay/frozen-status id))
      (harness-call 'session/set-system id "You are a test.")
      (harness-call 'session/set-tool-schema id (list "a"))
      (should-not (harness-call 'replay/frozen-status id)))))

(ert-deftest harness-replay-the-tool-schema-is-a-component-of-its-own ()
  "A tool list that moved is refused, and an added tool is not a change of the old.
The tool a session settled is compared as a component of its own: a tool
whose *name* changed, or one the kept body had and the new one does not,
is the list moving with nothing recorded, and nothing is sent.  An added
tool appends, as an array may, and continues the kept body."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (tool (list :type "function" :function (list :name "a" :description "d")))
           (renamed (list :type "function" :function (list :name "b" :description "d")))
           (added (list :type "function" :function (list :name "c" :description "e")))
           (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep id messages :tools (list tool))
      (let ((changed (harness-replay-test--seam id messages :tools (list renamed))))
        (should (string-match-p "tools\\[0\\]" (cdr changed))))
      (should (string-match-p "tools"
                              (cdr (harness-replay-test--seam id messages :tools nil))))
      (should-not (cdr (harness-replay-test--seam id messages :tools (list tool added)))))))

(ert-deftest harness-replay-a-metadata-field-is-not-a-prompt-change ()
  "A per-request metadata field is encoded fresh, never refused.
The invariant is the prompt the model is given, not the whole body:
`max_tokens', `stream_options' and `include' are how a request was
transported, and a provider's cache does not read them.  Freezing
them would stop a turn for a change the cache never cared about."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep id messages)
      ;; A budget the first request did not carry: sent, not refused.
      (let ((seam (harness-replay-test--seam id messages :max_tokens 40)))
        (should-not (cdr seam))
        (should (string-match-p "\"max_tokens\":40" (car seam))))
      ;; The prompt itself is still the frozen bytes.
      (should (equal (car (harness-replay-test--seam id messages))
                     (decode-coding-string
                      (harness-json-encode (harness-replay-test--body messages))
                      'utf-8))))))

(ert-deftest harness-replay-a-prompt-field-changed-is-still-refused ()
  "A field that is the prompt is still refused when it changes.
The metadata allowance does not weaken the prompt invariant: a
changed system prompt, tool schema or message is a mutation with no
recorded reset, and nothing is sent."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep id messages)
      (should (cdr (harness-replay-test--seam
                    id (list (harness-replay-test--message "HI"))))))))
(ert-deftest harness-replay-a-body-kept-for-another-model-is-not-continued ()
  "A body kept for one model or route is not spliced into another's."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (request (list :model "m" :session (list :id id)))
           (body (harness-replay-test--body messages)))
      (harness-replay-test--keep id messages)
      (should-not (cdr (harness-replay-seam request "other" "route" body)))
      (should-not (cdr (harness-replay-seam request "m" "elsewhere" body)))
      ;; The model and route it was kept for still continue.
      (should-not (cdr (harness-replay-seam request "m" "route" body))))))

(ert-deftest harness-replay-a-session-with-no-frozen-body-is-sent-as-built ()
  "A first request, and one that names no session, go out exactly as built."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (body (harness-replay-test--body messages))
           (plain (decode-coding-string (harness-json-encode body) 'utf-8)))
      ;; The first request's body is the adapter's own bytes, in its
      ;; own field order, and a request that names no session is too.
      (should (equal (car (harness-replay-test--seam id messages)) plain))
      (should (equal (car (harness-replay-seam (list :model "m") "m" "route" body))
                     plain)))))

(ert-deftest harness-replay-a-large-body-is-not-kept ()
  "A body over the limit is not kept, and a `too-large' reset says so."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           ;; The prompt alone must exceed the limit: a message big enough
           ;; that the frozen bytes are over it.
           (harness-replay-frozen-max-bytes 64))
      (harness-replay-test--keep id (list (harness-replay-test--message (make-string 200 ?x))))
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "too-large"))
      (should (= 0 (plist-get (harness-call 'replay/frozen-status id) :bytes))))))

(ert-deftest harness-replay-a-store-that-cannot-write-keeps-nothing ()
  "A body that cannot be written is not a body, and the next request is built fresh."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      (cl-letf (((symbol-function 'harness-write-file-atomically)
                 (lambda (&rest _) (error "disk full"))))
        (should-not (harness-replay-test--keep id messages)))
      (should-not (file-exists-p (harness-replay--file (harness-replay--frozen-name id))))
      (should-not (cdr (harness-replay-test--seam id messages))))))

(ert-deftest harness-replay-a-compaction-records-its-reset ()
  "A compaction empties the frozen body and says why."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep id messages)
      (harness-emit 'compaction/done id nil)
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "compaction"))
      (should-not (cdr (harness-replay-test--seam
                        id (list (harness-replay-test--message "other"))))))))

(ert-deftest harness-replay-a-redaction-drops-the-frozen-body ()
  "A redaction takes the body kept for the session with the secret in it."
  (harness-replay-test-with
    (let* ((secret "FAKE-replay-frozen-secret-1234567890")
           (secrets (list (harness-redaction-secret secret "test.frozen")))
           (id (harness-replay-test-session))
           (file (harness-replay--file (harness-replay--frozen-name id))))
      (harness-replay-test--keep id (list (harness-replay-test--message
                                           (format "the key is %s" secret))))
      (should (file-exists-p file))
      (harness-call 'replay/redact id secrets nil)
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "redaction"))
      (should (= 0 (harness-redaction-file-count file secrets))))))

(ert-deftest harness-replay-a-deleted-session-takes-its-frozen-body ()
  "Deleting a session deletes the body kept for it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (file (harness-replay--file (harness-replay--frozen-name id))))
      (harness-replay-test--keep id (list (harness-replay-test--message "hi")))
      (should (file-exists-p file))
      (harness-call 'replay/forget id)
      (should-not (file-exists-p file)))))

(ert-deftest harness-replay-a-frozen-body-survives-a-restart ()
  "A body kept before a restart is spliced into the request after it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (second (append first (list (harness-replay-test--message "yo" "assistant")))))
      (harness-replay-test--keep id first)
      (let ((seam (harness-replay-test--seam id second)))
        (should-not (cdr seam))
        (should (equal (car seam)
                       (decode-coding-string
                        (harness-json-encode (harness-replay-test--body second))
                        'utf-8)))))))


;;; Adapter-level frozen-body tests.

(defvar harness-replay-test--requests nil
  "Requests the adapter made, newest first: (:url :json :args).")

(defun harness-replay-test--fake-request (url &rest args)
  "Record a request to URL with ARGS and answer it with one streamed reply."
  (let ((handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                          :on-chunk (plist-get args :on-chunk)
                                          :started (float-time))))
    (push (list :url url :json (plist-get args :json)
                :body (plist-get args :body) :args args)
          harness-replay-test--requests)
    (harness-run-soon
     (lambda ()
       (unless (harness-http-handle-cancelled handle)
         (when (plist-get args :on-headers) (funcall (plist-get args :on-headers) 200 nil))
         (when (plist-get args :on-chunk)
           (funcall (plist-get args :on-chunk)
                    (concat "data: "
                            (harness-json-encode
                             (list :id "gen-1" :model "m"
                                   :choices (vector (list :index 0
                                                          :delta (list :content "ok")))))
                            "\n\ndata: "
                            (harness-json-encode
                             (list :id "gen-1" :model "m"
                                   :choices (vector (list :index 0 :delta :empty
                                                          :finish_reason "stop"))
                                   :usage (list :prompt_tokens 10 :completion_tokens 1)))
                            "\n\n")))
         (when (plist-get args :callback)
           (funcall (plist-get args :callback) 200 nil "" nil)))))
    handle))

(defmacro harness-replay-test--with-openai (&rest body)
  "Run BODY with the replay and OpenAI modules loaded, and a fake transport."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-openai replay))
       (harness-test-load-module m))
     (let ((harness-replay-test--requests nil)
           (auth-sources nil))
       (cl-letf (((symbol-function 'harness-http-request)
                  #'harness-replay-test--fake-request))
         ,@body))))

(defconst harness-replay-test--endpoint
  '(:id replay-probe :label "Replay probe" :base-url "https://probe.example/v1"
    :api-key "sk-test-not-a-real-key")
  "An OpenAI-compatible endpoint the fake transport answers for.")

(defun harness-replay-test--run (sid messages)
  "Send MESSAGES as session SID's request through the real adapter.
Return the events the request emitted, oldest first."
  (let ((events nil))
    (harness-openai--complete
     harness-replay-test--endpoint
     (list :model "replay-probe:m" :session (list :id sid)
           :messages messages
           :on-event (lambda (e) (push e events))))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                       5 "done event")
    (nreverse events)))


(ert-deftest harness-replay-a-session-setting-records-its-own-reset ()
  "A model, a thinking level, a system prompt or a tool set the session
changed is a recorded reset, so the next request is built fresh instead of
being refused at the boundary.  The first setting a body cannot survive
names the reason."
  (harness-replay-test-with
    (let ((id (harness-replay-test-session)))
      (dolist (case '(((:model "other") . model)
                      ((:thinking "high") . model)
                      ((:system "a new prompt") . system)
                      ((:tools ("a")) . tools)
                      ((:account "acct-2") . route)))
        (ert-info ((format "%S" (car case)))
          (should (equal (harness-replay-reset-on-change id (car case)) (cdr case)))
          ;; The record keeps the reason as a tag, which is its name.
          (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                         (format "%s" (cdr case))))))
      ;; A setting no body depends on is no reset at all.
      (let ((before (plist-get (harness-call 'replay/frozen-status id) :generation)))
        (should-not (harness-replay-reset-on-change id '(:title "renamed")))
        (should (= before (plist-get (harness-call 'replay/frozen-status id) :generation)))))))

(ert-deftest harness-replay-a-pruned-picture-records-its-reset ()
  "Pictures cut from a history are a recorded reset, not a silent rebuild.
The event is what `harness-agent-history-images' emits when it drops them."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (pruned (list (harness-replay-test--message "look, without the picture"))))
      (harness-replay-test--keep id first)
      (should (cdr (harness-replay-test--seam id pruned)))
      (harness-emit 'agent/images-pruned id 4 2)
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "images-pruned"))
      (should-not (cdr (harness-replay-test--seam id pruned))))))

(ert-deftest harness-replay-a-compaction-is-not-a-refusal ()
  "The request after a compaction is sent, not refused: the reset explains it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (before (list (harness-replay-test--message "hi")))
           (after (list (harness-replay-test--message "summary of hi"))))
      (harness-replay-test--keep id before)
      (should (cdr (harness-replay-test--seam id after)))
      (harness-emit 'compaction/done id nil)
      (should-not (cdr (harness-replay-test--seam id after))))))

(ert-deftest harness-replay-two-sessions-do-not-share-a-frozen-body ()
  "One session's body is never spliced into another's, even on one route."
  (harness-replay-test-with
    (let* ((one (harness-replay-test-session))
           (two (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (changed (list (harness-replay-test--message "something else"))))
      (harness-replay-test--keep one messages)
      (should-not (cdr (harness-replay-test--seam two changed)))
      (should-not (file-exists-p (harness-replay-test--payload-file two))))))

;;; The prefix decision, content-free.

(ert-deftest harness-replay-a-decision-says-what-it-did-with-the-prefix ()
  "Every request says, without any prompt text, whether it continued a
kept prefix, built a fresh one, or found the kept one diverged.  That is
what makes a later cache miss diagnosable: the record says how many bytes
were re-sent and how many were new, never what they said."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (second (append first (list (harness-replay-test--message "yo" "assistant"))))
           (records nil))
      (harness-on 'replay/prefix (lambda (sid info) (push (cons sid info) records)))
      ;; A first request has nothing to continue.
      (harness-replay-test--seam id first)
      (should (eq (plist-get (cdar records) :decision) 'fresh))
      (harness-replay-test--keep id first)
      ;; A second, appending one continues it.
      (setq records nil)
      (harness-replay-test--seam id second)
      (let ((info (cdar records)))
        (should (eq (plist-get info :decision) 'spliced))
        (should (> (plist-get info :prefix-bytes) 0))
        (should (> (plist-get info :appended-bytes) 0))
        ;; Content-free: no message text, no digest, in the record.
        (should-not (string-match-p "hi" (format "%S" info)))
        (should-not (plist-get info :digest)))
      ;; A changed prompt diverges, and names only the field and index.
      (setq records nil)
      (let ((seam (harness-replay-test--seam
                   id (list (harness-replay-test--message "HI")))))
        (should (cdr seam)))
      (let ((info (cdar records)))
        (should (eq (plist-get info :decision) 'diverged))
        (should (equal (plist-get info :divergence) "messages[0].content"))
        (should-not (string-match-p "HI" (format "%S" info)))))))

(ert-deftest harness-replay-a-metadata-change-is-still-spliced ()
  "A metadata field changing does not turn a continued prompt into a
fresh one: the decision stays `spliced', and the count of metadata
fields says how many went out fresh."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (records nil))
      (harness-replay-test--keep id messages)
      (harness-on 'replay/prefix (lambda (_sid info) (push info records)))
      ;; The body's own metadata fields (`stream', `stream_options') count,
      ;; and so does the one this request adds.
      (harness-replay-test--seam id messages)
      (let ((without (plist-get (car records) :metadata)))
        (setq records nil)
        (harness-replay-test--seam id messages :max_tokens 40)
        (should (eq (plist-get (car records) :decision) 'spliced))
        (should (= (1+ without) (plist-get (car records) :metadata)))))))

(ert-deftest harness-replay-an-unchanged-prefix-is-not-a-cache-hit ()
  "The module says what it sent, never that the provider cached it.
A decision of `spliced' is a claim about the bytes the harness sent;
eviction, retention and routing are the provider's, so nothing in the
record says a hit happened.  A provider that missed on identical bytes
is a `cache/reuse' fact, and it is not turned into a reset or a
re-render here."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (records nil))
      (harness-replay-test--keep id messages)
      (harness-on 'replay/prefix (lambda (_sid info) (push info records)))
      (harness-replay-test--seam id messages)
      (should (eq (plist-get (car records) :decision) 'spliced))
      ;; Nothing in the record claims a hit or a miss.
      (should-not (plist-member (car records) :hit))
      (should-not (plist-member (car records) :cache-read))
      ;; A miss the provider reports does not disturb the frozen body.
      (let ((before (plist-get (harness-call 'replay/frozen-status id) :generation)))
        (harness-emit 'cache/reuse id (list :ratio 0.0 :previous 40000
                                            :cache-read 0 :wasted 40000
                                            :context 40000 :model "m"))
        (should (= before (plist-get (harness-call 'replay/frozen-status id)
                                      :generation)))
        (should-not (cdr (harness-replay-test--seam id messages)))))))
(ert-deftest harness-replay-a-miss-on-identical-bytes-is-the-providers ()
  "A provider miss after a spliced prefix is recorded as the provider's,
and nothing about the request changes for it: no reset, no re-render, no
retry.  That is the bounded response -- the harness does not turn a
provider miss into client drift by reacting to it."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep id messages)
      ;; A request that continues the kept prefix.
      (harness-replay-test--seam id messages)
      (should (harness-replay-miss-after-identical-prefix-p id))
      (let ((generation (plist-get (harness-call 'replay/frozen-status id)
                                    :generation))
            (bytes (plist-get (harness-call 'replay/frozen-status id) :bytes)))
        ;; The provider says it read nothing.
        (should (eq 'provider
                    (harness-call 'replay/miss-note id
                                  (list :ratio 0.0 :previous 40000
                                        :cache-read 0 :wasted 40000))))
        ;; Nothing was reset, and the next request still splices.
        (should (= generation (plist-get (harness-call 'replay/frozen-status id)
                                          :generation)))
        (should (= bytes (plist-get (harness-call 'replay/frozen-status id) :bytes)))
        (should-not (cdr (harness-replay-test--seam id messages)))))))

(ert-deftest harness-replay-a-miss-with-no-identical-prefix-is-unexplained ()
  "A session whose last request built a fresh prompt has no identical
prefix for a miss to be read against, and the miss is reported as
unexplained rather than blamed on the provider."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi"))))
      ;; Nothing kept: the request was built fresh.
      (harness-replay-test--seam id messages)
      (should-not (harness-replay-miss-after-identical-prefix-p id))
      (should (eq 'unexplained
                  (harness-call 'replay/miss-note id
                                (list :ratio 0.0 :previous 40000
                                      :cache-read 0 :wasted 40000)))))))
(ert-deftest harness-replay-two-sessions-interleaved-keep-their-own-bytes ()
  "Two conversations whose requests interleave each continue from their
own frozen body.  A session's body is keyed by its id, so a request of
one session between two requests of another neither splices into it nor
is refused by it."
  (harness-replay-test-with
    (let* ((one (harness-replay-test-session))
           (two (harness-replay-test-session))
           (one-first (list (harness-replay-test--message "one hi")))
           (two-first (list (harness-replay-test--message "two hi")))
           (one-second (append one-first (list (harness-replay-test--message "yo" "assistant"))))
           (two-second (append two-first (list (harness-replay-test--message "hey" "assistant")))))
      ;; Each session sends once, then both send again, interleaved.
      (harness-replay-test--keep one one-first)
      (harness-replay-test--keep two two-first)
      (let ((one-seam (harness-replay-test--seam one one-second))
            (two-seam (harness-replay-test--seam two two-second)))
        (should-not (cdr one-seam))
        (should-not (cdr two-seam))
        ;; Each is its own conversation, in its own bytes.
        (should (equal (car one-seam)
                       (decode-coding-string
                        (harness-json-encode (harness-replay-test--body one-second))
                        'utf-8)))
        (should (equal (car two-seam)
                       (decode-coding-string
                        (harness-json-encode (harness-replay-test--body two-second))
                        'utf-8)))
        (should-not (equal (car one-seam) (car two-seam)))))
    ;; And a reset of one says nothing about the other.
    (let ((three (harness-replay-test-session))
          (four (harness-replay-test-session))
          (messages (list (harness-replay-test--message "hi"))))
      (harness-replay-test--keep three messages)
      (harness-replay-test--keep four messages)
      (harness-call 'replay/frozen-reset three 'compaction)
      (should (= 0 (plist-get (harness-call 'replay/frozen-status three) :bytes)))
      (should (> (plist-get (harness-call 'replay/frozen-status four) :bytes) 0)))))
(ert-deftest harness-replay-a-body-sent-twice-is-sent-the-same-bytes ()
  "Sending the same conversation again keeps every byte, and keeps it again.
A retry is the same request, not a second body: the bytes of the second send
are the bytes of the first."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (first (car (harness-replay-test--seam id messages))))
      (harness-replay-test--keep id messages)
      (let ((second (car (harness-replay-test--seam id messages))))
        (should (equal first second))
        ;; Keeping it again is idempotent: the bytes do not drift.
        (harness-replay-test--keep id messages)
        (should (equal first (car (harness-replay-test--seam id messages))))))))

(ert-deftest harness-replay-reasoning-and-tool-items-go-back-as-they-came ()
  "A remembered reasoning item and its tool call are part of the prefix.
The provider's own item, with its encrypted reasoning, goes out again byte
for byte, so the chain of thought it stored is not lost."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (reasoning (list :type "reasoning" :id "rs_1"
                            :summary (vector)
                            :encrypted_content "ENCRYPTED-1"))
           (call (list :type "function_call" :id "fc_1" :call_id "call_1"
                       :name "echo" :arguments "{\"value\":\"a\"}"))
           (first (list (harness-replay-test--message "look")))
           (second (append first (list reasoning call))))
      (harness-replay-test--keep id first)
      (let ((seam (harness-replay-test--seam id second)))
        (should-not (cdr seam))
        (should (equal (car seam)
                       (decode-coding-string
                        (harness-json-encode (harness-replay-test--body second))
                        'utf-8)))
        ;; The item is in the body that goes out, its own bytes included.
        (should (string-match-p "ENCRYPTED-1" (car seam)))
        (should (string-match-p "call_1" (car seam)))))))

(ert-deftest harness-replay-a-mutation-stops-before-the-transport ()
  "A prompt component that changed under the adapter is never sent.
The complaint reaches the caller as a failed step, and the transport is not
called at all: no HTTP request is made for a body the harness cannot explain."
  (harness-replay-test--with-openai
    (let* ((sid "replay-probe-mutation")
           (first (list (list :role "user" :content "hi"))))
      (harness-replay-test--run sid first)
      (should (= 1 (length harness-replay-test--requests)))
      ;; The next request rebuilds the same conversation differently.
      (let ((harness-replay-test--requests nil)
            (events nil))
        ;; The adapter rebuilds the same conversation with another text:
        ;; the shape is unchanged, so the divergence is a component.
        ;; The adapter rebuilds the same body, field for field, with
        ;; another message text: the divergence is that component.
        (cl-letf (((symbol-function 'harness-openai--body)
                   (lambda (_endpoint name _request)
                     (list :model name
                           :messages (list (list :role "user" :content "CHANGED"))
                           :stream t
                           :stream_options (list :include_usage t)))))
          (setq events (harness-replay-test--run sid first)))
        (should (= 0 (length harness-replay-test--requests)))
        (should (equal (mapcar (lambda (e) (plist-get e :type)) events) '(start done)))
        (should (equal (plist-get (car (last events)) :stop-reason) 'error))
        (should (string-match-p "messages\\[0\\]\\.content"
                                (plist-get (car (last events)) :error)))))))

(ert-deftest harness-replay-the-sent-body-is-the-kept-one ()
  "What the transport is given is the bytes of the frozen body, field for field.
A second step of the same conversation sends the first step's messages as they
were, and only what it adds is new."
  (harness-replay-test--with-openai
    (let* ((sid "replay-probe-append")
           (hi (list :role "user" :content "hi"))
           (ok (list :role "assistant" :content "ok"))
           (model (format "%s:m" (plist-get harness-replay-test--endpoint :id))))
      (harness-replay-test--run sid (list hi))
      (harness-replay-test--run sid (list hi ok))
      (let* ((sent (mapcar (lambda (r) (plist-get r :body))
                           (reverse harness-replay-test--requests)))
             (bodies (mapcar (lambda (s) (decode-coding-string s 'utf-8)) sent)))
        (should (= 2 (length bodies)))
        ;; Both requests are the adapter's own body, and the message the
        ;; first one sent is the first message of the second, unchanged.
        (should (equal (nth 0 bodies)
                       (decode-coding-string
                        (harness-json-encode
                         (harness-openai--body
                          harness-replay-test--endpoint "m"
                          (list :messages (list hi))))
                        'utf-8)))
        (should (equal (nth 1 bodies)
                       (decode-coding-string
                        (harness-json-encode
                         (harness-openai--body
                          harness-replay-test--endpoint "m"
                          (list :messages (list hi ok))))
                        'utf-8)))))))


(ert-deftest harness-replay-unicode-persisted-prefix-keeps-exact-wire-bytes ()
  "Nested JSON survives disk as text, and reaches HTTP as the same UTF-8."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (request (list :session (list :id id)))
           (body '(:model "m" :messages [(:role "system" :content "Unicode → café 日本語 🐈")
                                        (:role "user" :content "Résumé: é; \"quote\"\nline")]
                          :tools [(:type "function" :function
                                  (:name "read" :description "Lisez → 文件"
                                         :parameters (:type "object" :properties
                                                            (:日本語 (:type "string")))))]))
           (text (harness-replay--piece-text (harness-replay--piece body))))
      (should (equal (encode-coding-string text 'utf-8 t) (harness-json-encode body)))
      ;; Exercise the actual curl body-file writer, not just our encoding.
      (let ((file (harness-http--write-body text nil)))
        (unwind-protect
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally file)
              (should (equal (buffer-string) (harness-json-encode body))))
          (delete-file file)))
      (harness-replay-seam-keep request "m" "route" body)
      (should (= (plist-get (harness-call 'replay/frozen-status id) :bytes)
                 (length (harness-json-encode body))))
      ;; Every call reads the persisted record again, not an in-memory piece.
      (dotimes (_ 3)
        (let* ((decision (harness-call 'replay/frozen-splice id "m" "route" body))
               (seam (harness-replay-seam request "m" "route" body)))
          (should (plist-get decision :spliced))
          (should-not (cdr seam))
          (should (equal (encode-coding-string (car seam) 'utf-8 t)
                         (harness-json-encode body)))
          (harness-replay-seam-keep request "m" "route" body)))
      (let ((changed (copy-tree body t)))
        (setf (plist-get (aref (plist-get changed :messages) 0) :content)
              "Unicode → café 日本語 🐕")
        (should (string-match-p "messages\\[0\\]\\.content"
                                (cdr (harness-replay-seam request "m" "route" changed))))))))

(defmacro harness-replay-test-with-system-transition (&rest body)
  "Run BODY with a frozen chat and a changed real system-prompt filter."
  (declare (indent 0))
  `(harness-replay-test-with-agent
     (let* ((id (harness-replay-test-session))
            (old "Instructions → café 日本語")
            (current (concat old "\nMemory: known new index line 🐈"))
            (request (list :session (list :id id)))
            (wire (list :model "m" :messages
                        (vector (list :role "system" :content old)
                                (list :role "user" :content "history → unchanged"))
                        :tools [(:type "function" :function (:name "read"))])))
       (harness-add-filter 'agent/system-prompt (lambda (_prompt _session) current) 999)
       (harness-replay-seam-keep request "m" "route" wire)
       (let* ((before (harness-replay--frozen-read id))
              (status (harness-call 'session/system-transition-status id))
              (generation (plist-get status :generation))
              (old-hash (plist-get status :old-sha256))
              (new-hash (plist-get status :new-sha256)))
         ,@body))))

(ert-deftest harness-replay-system-transition-preserves-other-frozen-components ()
  (harness-replay-test-with-system-transition
    (should (equal old-hash (secure-hash 'sha256 (encode-coding-string old 'utf-8-unix))))
    (should (equal new-hash (secure-hash 'sha256 (encode-coding-string current 'utf-8-unix))))
    (should (= 6 (length status)))
    (let* ((result (harness-call 'session/transition-system id generation old-hash new-hash))
           (after (harness-replay--frozen-read id))
           (expected (copy-tree before t)))
      (setf (plist-get (harness-replay--system-piece expected) :bytes)
            (harness-json-encode-text current))
      (should (equal (plist-get after :body) (plist-get expected :body)))
      (should (= (plist-get result :generation) (1+ generation)))
      (should (equal (plist-get after :reset) "system"))
      (should (equal (plist-get after :at) (plist-get before :at)))
      (should (equal (plist-get (plist-get after :transition) :kind)
                     "system-transition-approved"))
      (setf (plist-get (aref (plist-get wire :messages) 0) :content) current)
      (let ((seam (harness-replay-seam request "m" "route" wire)))
        (should-not (cdr seam))
        (should (equal (encode-coding-string (car seam) 'utf-8-unix)
                       (harness-json-encode wire))))
      (harness-replay-seam-keep request "m" "route" wire)
      (should (equal (plist-get (harness-replay--frozen-read id) :transition)
                     (plist-get after :transition)))
      ;; Approval of system text cannot approve any unrelated divergence.
      (dolist (field '(history tools model system))
        (let ((changed (copy-tree wire t)))
          (pcase field
            ('history (setf (plist-get (aref (plist-get changed :messages) 1) :content) "CHANGED"))
            ('tools (setq changed (plist-put changed :tools [])))
            ('model (setq changed (plist-put changed :model "other")))
            ('system (setf (plist-get (aref (plist-get changed :messages) 0) :content) "unapproved")))
          (should (cdr (harness-replay-seam request "m" "route" changed)))))
      (should (cdr (harness-replay-seam request "other-model" "other-route"
                                       (plist-put (copy-tree wire t) :model "other")))))))

(ert-deftest harness-replay-system-transition-refuses-stale-or-unapproved-state ()
  (harness-replay-test-with-system-transition
    (dolist (args (list (list (1+ generation) old-hash new-hash)
                       (list generation "wrong" new-hash)
                       (list generation old-hash "wrong")))
      (should-error (apply #'harness-call 'session/transition-system id args))
      (should (equal before (harness-replay--frozen-read id))))
    (puthash id t harness-agent--turns)
    (should-error (harness-call 'session/transition-system id generation old-hash new-hash))
    (remhash id harness-agent--turns)
    (should (equal before (harness-replay--frozen-read id)))
    (setq current (concat current " unexpected extra change"))
    (should-error (harness-call 'session/transition-system id generation old-hash new-hash))
    (should (equal before (harness-replay--frozen-read id)))))

(ert-deftest harness-replay-system-transition-rechecks-after-prompt-generation ()
  (harness-replay-test-with-system-transition
    (harness-add-filter 'agent/system-prompt
                        (lambda (prompt _session) (puthash id t harness-agent--turns) prompt) 1000)
    (should-error (harness-call 'session/transition-system id generation old-hash new-hash))
    (should (equal before (harness-replay--frozen-read id)))))

(ert-deftest harness-replay-system-transition-refuses-unsupported-and-failed-write ()
  (harness-replay-test-with-system-transition
    (cl-letf (((symbol-function 'harness-replay--frozen-write) (lambda (&rest _) nil)))
      (should-error (harness-call 'session/transition-system id generation old-hash new-hash)))
    (should (equal before (harness-replay--frozen-read id)))
    (setf (plist-get (aref (plist-get wire :messages) 0) :role) "user")
    (harness-replay-seam-keep request "m" "route" wire)
    (should-error (harness-call 'session/system-transition-status id))
    (should-error (harness-call 'session/transition-system id generation old-hash new-hash))))

;;; What may become the prefix the session continues

(ert-deftest harness-replay-a-one-off-call-is-not-the-conversations-prefix ()
  "An auto-name or a judge names the session but is not its conversation.
Its body carries another system prompt and another message list, so it may
neither be spliced into the session's frozen body nor become it: spliced, it
would rewrite the bytes the next step has to continue; kept, it would leave
that step diverging from a body it never sent.  It goes out as its adapter
built it, and the conversation's next step still splices."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (session (list :id id))
           (ask (lambda (messages &optional extra)
                  (append (list :model "m" :system "S" :messages messages :stream t)
                          extra)))
           (hi (harness-replay-test--message "hi")))
      ;; The conversation's own first step.
      (let ((first (harness-replay-seam (list :model "m" :session session) "m" "route"
                                        (funcall ask (list hi)))))
        (should-not (cdr first))
        (harness-replay-seam-keep (list :model "m" :session session) "m" "route"
                                  (funcall ask (list hi))))
      ;; A one-off call for the same session.
      (let* ((body (funcall ask (list (harness-replay-test--message "opening"))))
             (seam (harness-replay-seam (list :model "m" :session session :ephemeral t)
                                        "m" "route" body)))
        (should-not (cdr seam))
        (should (equal (car seam)
                       (decode-coding-string (harness-json-encode body) 'utf-8)))
        (harness-replay-seam-keep (list :model "m" :session session :ephemeral t)
                                  "m" "route" body))
      ;; The conversation goes on, and is still continued from its own body.
      (let ((next (harness-replay-seam
                   (list :model "m" :session session) "m" "route"
                   (funcall ask (list hi (harness-replay-test--message "yo" "assistant"))))))
        (should-not (cdr next))
        (should (string-match-p "hi" (car next)))))))

(ert-deftest harness-replay-a-cache-refresh-reads-without-becoming-the-prefix ()
  "A refresh sends the conversation plus one message it does not hold.
It splices, which is what reads the cache, and it must not be kept: the next
real step would diverge at the message the transcript never had."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (session (list :id id))
           (ask (lambda (messages &optional extra)
                  (append (list :model "m" :system "S" :messages messages :stream t)
                          extra)))
           (hi (harness-replay-test--message "hi"))
           (ping (harness-replay-test--message "reply with just: ok")))
      (let ((first (harness-replay-seam (list :model "m" :session session) "m" "route"
                                        (funcall ask (list hi)))))
        (should-not (cdr first))
        (harness-replay-seam-keep (list :model "m" :session session) "m" "route"
                                  (funcall ask (list hi))))
      (let* ((body (funcall ask (list hi ping) (list :cache-refresh t)))
             (refresh (harness-replay-seam (list :model "m" :session session :cache-refresh t)
                                           "m" "route" body)))
        (should-not (cdr refresh))
        (harness-replay-seam-keep (list :model "m" :session session :cache-refresh t)
                                  "m" "route" body))
      (let ((next (harness-replay-seam
                   (list :model "m" :session session) "m" "route"
                   (funcall ask (list hi (harness-replay-test--message "yo" "assistant"))))))
        (should-not (cdr next))
        (should-not (string-match-p "reply with just" (car next)))))))

(ert-deftest harness-replay-a-read-only-request-reads-without-becoming-the-prefix ()
  "A request flagged `:replay-read-only' splices and is never kept.
A compaction summary made from the prompt cache appends its instruction
after the conversation's last message: re-sending the frozen bytes is
what reads the cache, so it splices, but keeping it would make the
conversation's next step diverge at a message the transcript never had.
The flag is the request's own, not `:cache-refresh' and not
`:ephemeral': a read-only request is still a conversation's request."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (session (list :id id))
           (ask (lambda (messages &optional extra)
                  (append (list :model "m" :system "S" :messages messages :stream t)
                          extra)))
           (hi (harness-replay-test--message "hi"))
           (ask-message (harness-replay-test--message "summarise it")))
      (let ((first (harness-replay-seam (list :model "m" :session session) "m" "route"
                                        (funcall ask (list hi)))))
        (should-not (cdr first))
        (harness-replay-seam-keep (list :model "m" :session session) "m" "route"
                                  (funcall ask (list hi))))
      (let* ((request (list :model "m" :session session :replay-read-only t))
             (body (funcall ask (list hi ask-message))))
        (should (harness-replay-read-only-p request))
        (should (harness-replay-conversation-p request))
        (should-not (harness-replay-keeps-prefix-p request))
        (let ((seam (harness-replay-seam request "m" "route" body)))
          (should-not (cdr seam))
          (should (string-match-p "hi" (car seam))))
        (harness-replay-seam-keep request "m" "route" body))
      ;; The conversation goes on from what it sent, not from the summary.
      (let ((next (harness-replay-seam
                   (list :model "m" :session session) "m" "route"
                   (funcall ask (list hi (harness-replay-test--message "yo" "assistant"))))))
        (should-not (cdr next))
        (should-not (string-match-p "summarise it" (car next))))
      ;; A plain request is still kept.
      (should (harness-replay-keeps-prefix-p (list :model "m" :session session))))))

(ert-deftest harness-replay-the-module-defines-its-handlers-and-inits-once ()
  "Loading the module defines its handlers, and init only subscribes.
The handlers used to be defined inside init, which left them undefined until
the module was initialised and gave init a docstring of their own."
  (harness-replay-test-with
    (should (fboundp 'harness-replay--on-prefix))
    (should (fboundp 'harness-replay--on-reuse))
    (should (functionp (symbol-function 'harness-replay--init)))
    (should (string-prefix-p "Subscribe" (documentation 'harness-replay--init)))))

(ert-deftest harness-replay-a-prompt-field-that-is-gone-is-recorded-not-refused ()
  "A prompt field the request no longer sends at all records a reset.
A session whose thinking level went nil stops sending the `reasoning'
field the provider already read, and one whose tool list emptied stops
sending `tools'.  No setting announces either, so the boundary check saw
a body whose field count changed, named it `body', and refused it -- and
because the frozen body is only rewritten by a request that is sent, the
refusal repeated for every request the session made, forever.  A field
that is gone is recorded as the reset it is; a field whose bytes changed
is still refused, since that is a rebuild nothing accounts for."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (with-reasoning (harness-replay-test--body messages :reasoning '(:effort "max"))))
      (harness-replay-seam-keep (list :model "m" :session (list :id id))
                                "m" "route" with-reasoning)
      (should (> (plist-get (harness-call 'replay/frozen-status id) :bytes) 0))
      ;; The request without the field: sent, not refused.
      (let ((seam (harness-replay-test--seam id messages)))
        (should-not (cdr seam))
        (should-not (string-match-p "reasoning" (car seam))))
      ;; And it says why the body stopped applying.
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "field-dropped"))
      ;; A field whose bytes changed is still a mutation: nothing is sent.
      (harness-replay-test--keep id messages)
      (should (cdr (harness-replay-test--seam
                    id (list (harness-replay-test--message "HI"))))))))

(ert-deftest harness-replay-a-changed-effort-is-recorded-not-refused-forever ()
  "A reasoning effort that changed for a reason no setting announces recovers.
A model's listing can name the reasoning efforts it takes only after a
session's first request went out (`harness-openai--effort'), which maps
the same thinking level onto another effort: the body then no longer
continues the one the provider read, and no setting announced it.  The
boundary check refused the request -- and because a frozen body is only
rewritten by a request that is sent, it refused every request the
session made afterwards, forever.  The change is recorded as the reset
it is and the request goes out built fresh, as a prompt field that is
gone already did."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (first (harness-replay-test--body messages :reasoning '(:effort "max")))
           (changed (harness-replay-test--body messages :reasoning '(:effort "high")))
           (request (list :model "m" :session (list :id id))))
      (harness-replay-seam-keep request "m" "route" first)
      (should (> (plist-get (harness-call 'replay/frozen-status id) :bytes) 0))
      ;; The request goes out, built fresh: nothing is refused.
      (let ((seam (harness-replay-seam request "m" "route" changed)))
        (should-not (cdr seam))
        (should (equal (decode-coding-string (car seam) 'utf-8)
                       (decode-coding-string (harness-json-encode changed) 'utf-8))))
      ;; And it says why the body stopped applying.
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "diverged"))
      ;; The request after it continues the body this one kept, so the
      ;; session is not stranded on a refusal.
      (harness-replay-seam-keep request "m" "route" changed)
      (let ((next (harness-replay-seam request "m" "route" changed)))
        (should-not (cdr next))
        (should (equal (decode-coding-string (car next) 'utf-8)
                       (decode-coding-string (harness-json-encode changed) 'utf-8)))))))

(ert-deftest harness-replay-a-changed-tool-name-is-still-refused ()
  "A tool name that changed with nothing recorded is still a refusal.
A session settles the tool *names* it sends (`session/set-tool-schema'),
and the one way that list moves mid-session -- the schema cleared so the
supervisor's mode can be re-decided -- records its own `tools' reset.  A
tool list that moved with neither the schema cleared nor a reset recorded
is a rebuild the harness cannot account for, and nothing is sent.  The
definition exception does not reach it: it covers a definition changing
while the names the session settled stayed the same."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (tool (list :type "function" :function (list :name "a" :description "d")))
           (changed (list :type "function" :function (list :name "b" :description "d"))))
      (harness-replay-test--keep id messages :tools (list tool))
      (let ((seam (harness-replay-test--seam id messages :tools (list changed))))
        (should (cdr seam))
        (should (string-match-p "tools\\[0\\]" (cdr seam)))))))

(ert-deftest harness-replay-a-changed-tool-definition-recovers ()
  "A tool whose definition the harness changed records a reset, not a refusal.
A session settles the tool *names* it sends, and their definitions are
read from the registry with every request.  So a release that edits one --
a description, a property, a renamed parameter -- rewrites the schema the
provider already read, and no setting announces it, because the names did
not change.  Left to the refusal it stopped every request the session made
afterwards, since a frozen body is only rewritten by a request that is
sent: this is what wedged the soundcore session at
`tools[46].function.parameters.properties' when `history.undo' gained two
properties under a running session."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (request (list :model "m" :session (list :id id)))
           (tool (lambda (properties)
                   (list :type "function"
                         :function (list :name "history.undo" :description "Undo board edit"
                                         :parameters (list :type "object"
                                                           :properties properties
                                                           :required (list "board"))))))
           (before (funcall tool (list :board (list :type "string"))))
           (after (funcall tool (list :board (list :type "string" :description "The board id.")
                                      :revision (list :type "number")))))
      (harness-replay-test--keep id messages :tools (list before))
      (should (> (plist-get (harness-call 'replay/frozen-status id) :bytes) 0))
      ;; The request goes out, built fresh: nothing is refused.
      (let ((seam (harness-replay-test--seam id messages :tools (list after))))
        (should-not (cdr seam))
        (should (string-match-p "\\\"revision\\\"" (car seam))))
      ;; And it says why the body stopped applying.
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "tool-definition"))
      ;; The request after it continues the body this one kept, so the
      ;; session is not stranded on a refusal.
      (harness-replay-test--keep id messages :tools (list after))
      (let ((next (harness-replay-test--seam id messages :tools (list after))))
        (should-not (cdr next))
        (should (string-match-p "\\\"revision\\\"" (car next)))))))

(ert-deftest harness-replay-a-tool-added-is-not-a-definition-change ()
  "A tool the kept body did not have appends, and diverges nowhere.
The list is the session's to settle, and `session/set-tool-schema'
announces a change of it; the definition exception is not needed for an
added tool, which continues the kept body as an array may."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (read (list :type "function" :function (list :name "read" :description "Read")))
           (write (list :type "function" :function (list :name "write" :description "Write"))))
      (harness-replay-test--keep id messages :tools (list read))
      (let ((seam (harness-replay-test--seam id messages :tools (list read write))))
        (should-not (cdr seam))
        (should (string-match-p "\\\"write\\\"" (car seam)))))))

(ert-deftest harness-replay-a-tool-dropped-is-still-refused ()
  "A tool the kept body sent and the new one does not is the list moving.
That is `session/set-tool-schema''s to announce with a `tools' reset, so
the definition exception stays out of it and nothing is sent."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (read (list :type "function" :function (list :name "read" :description "Read")))
           (write (list :type "function" :function (list :name "write" :description "Write"))))
      (harness-replay-test--keep id messages :tools (list read write))
      (let ((seam (harness-replay-test--seam id messages :tools (list read))))
        (should (cdr seam))
        (should (string-match-p "tools" (cdr seam)))))))

(ert-deftest harness-replay-a-responses-tool-definition-recovers ()
  "The Responses route's tools are found where that route keeps them.
They come in as an `additional_tools' item of `input', so a definition
changing there diverges at \"input[0].tools[0]...\" and not at \"tools\"."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (request (list :model "m" :session (list :id id)))
           (body (lambda (description)
                   (list :model "m" :store :false :stream t :messages messages
                         :input (vector (list :type "additional_tools" :role "developer"
                                              :tools (vector
                                                      (list :type "function" :name "history.undo"
                                                            :description description
                                                            :strict :false
                                                            :parameters (list :type "object")))))))))
      (harness-replay-seam-keep request "m" "route" (funcall body "Undo"))
      (let ((seam (harness-replay-seam request "m" "route" (funcall body "Undo an edit"))))
        (should-not (cdr seam))
        (should (string-match-p "Undo an edit" (car seam))))
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset)
                     "tool-definition")))))

(ert-deftest harness-replay-a-changed-message-is-still-refused-for-good ()
  "The envelope's exception never reaches the conversation.
A message whose text changed is a rebuild of the transcript: it is
refused, and stays refused until something records why, because a
session that sent different words than it holds is a defect and not a
change it can go on from."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (first (list (harness-replay-test--message "hi")))
           (changed (list (harness-replay-test--message "HI"))))
      (harness-replay-test--keep id first)
      (dotimes (_ 3)
        (let ((seam (harness-replay-test--seam id changed)))
          (should (cdr seam))
          (should (string-match-p "messages\\[0\\]\\.content" (cdr seam))))))))

(ert-deftest harness-replay-clearing-a-settled-schema-explains-the-change ()
  "Clearing a settled tool schema records the reset it makes.
`session/set-tool-schema' with nil forgets the list so the next request
settles a new one -- the supervisor's judge does it to make its mode
decision real -- and that rewrites the tool schema the provider already
read.  It announced nothing, so the boundary check refused the next
request for a change with no recorded reset, and every request after it:
a frozen body is only rewritten by a request that is sent.  The clear
now announces itself, so the reset is recorded and the request after it
is built fresh."
  (harness-replay-test-with
    (let* ((id (harness-replay-test-session))
           (messages (list (harness-replay-test--message "hi")))
           (before (harness-replay-test--body
                    messages
                    :tools (vector (list :type "function"
                                         :function (list :name "read" :description "Read")))))
           (after (harness-replay-test--body
                   messages
                   :tools (vector (list :type "function"
                                        :function (list :name "read" :description "Read"))
                                  (list :type "function"
                                        :function (list :name "write" :description "Write"))))))
      (harness-replay-seam-keep (list :model "m" :session (list :id id))
                                "m" "route" before)
      ;; The session settled the schema it first sent, as `tools/settle' does.
      (harness-call 'session/set-tool-schema id '("read"))
      (should (equal (plist-get (harness-call 'session/get id) :tool-schema) '("read")))
      (harness-call 'session/set-tool-schema id nil)
      (should-not (plist-get (harness-call 'session/get id) :tool-schema))
      (should (equal (plist-get (harness-call 'replay/frozen-status id) :reset) "tools"))
      ;; The next request, with the schema settled again, goes out.
      (let ((seam (harness-replay-seam (list :model "m" :session (list :id id))
                                       "m" "route" after)))
        (should-not (cdr seam))
        (should (string-match-p "write" (car seam))))
      (harness-replay-seam-keep (list :model "m" :session (list :id id))
                                "m" "route" after)
      (should (> (plist-get (harness-call 'replay/frozen-status id) :bytes) 0)))))

(provide 'harness-replay-test)
;;; harness-replay-test.el ends here
