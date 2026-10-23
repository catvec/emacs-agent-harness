;;; harness-linking.el --- Links to sessions, messages, tool calls and threads, written out in full  -*- lexical-binding: t; -*-

;;; Commentary:

;; An agent points at things in its own words with links: a session, a
;; message or a tool call in one, a task, a thread of a task's review
;; (lisp/harness-links.el says how they are written).  The user's Emacs
;; opens them on a click (ui-linking).  This module is the harness's half:
;; it finds what a link names, writes it out in full where the agent wrote
;; it, and teaches agents to write them.
;;
;; WHAT A LINK NAMES.  `link/resolve' (`harness-linking-resolve') takes a
;; link and the session whose text holds it, and answers with the thing,
;; as the ids it is known by -- the session, the node of the message or
;; of the call, the task, the thread -- the link written out in full
;; (`:url'), and words for it (`:label'); or with `:error', a sentence
;; that says what was looked for and found no one.
;;
;; - A session is named as the session tools name one: by its id, a
;;   unique start of it, or its name, in any case.  An internal session,
;;   the record of a model call the harness made on its own, answers only
;;   when no other does.
;; - A message or a call is named by the id of its node, a call also by
;;   the id its provider gave it; where the link names no session, it is
;;   one of the session the text is in.  It may also be named by a HANDLE,
;;   which means something only there, among the nodes before the text
;;   (the model never sees its own ids): for a call, `last' (the newest),
;;   `#3' (the third newest), `bash#2' (the second newest of the tool
;;   bash) and the name of a tool alone (its newest call), the calls
;;   hand_in made left out, as hand_in's tool_call does; for a message,
;;   `last' (the newest assistant message), `first' (the first user
;;   message), `#3' (the third newest of either), `user#1' and
;;   `assistant#2'.
;; - A thread is named by its id or a unique start of it, in the review of
;;   the task the link names, else the task of the session it names, else
;;   the task of the session the text is in.  A task is named by its id
;;   or a unique start of it.  What a review keeps, and what a task is,
;;   the modules that keep them answer (`review/find-thread', `task/get').
;;
;; WRITING THEM OUT.  `link/canonicalize' (`harness-linking-canonicalize')
;; changes the links of a text to the form `link/resolve' gives them: a
;; name, a prefix or a handle becomes the ids it stood for, so a link
;; never means something else later, when the session has moved on or a
;; session is renamed.  A link already in that form is left as it is, so
;; doing it twice changes nothing more.  A link that names nothing is left
;; as it was written and reported, one sentence each; a bare link becomes
;; a Markdown link that reads as what it names, an autolink keeps its
;; form.  What a Markdown renderer shows as code is not touched.  The
;; tools that carry the words of an agent do this before the words go on
;; (`harness-tools-written'): hand_in, review_comment, session_send,
;; ask_user, plan, spawn_agent, task_submit and task_control, in the
;; session of the agent that wrote them and before the call that wrote
;; them; and so does the turn for each assistant message it finishes,
;; before the message (`harness-agent--finalize').  Where a call has a
;; result the agent reads, the links that named nothing are said in it.
;;
;; TEACHING.  The system prompt gets a Links section after Planning
;; (`harness-linking-prompt-section'): the syntax, where an agent finds
;; the ids and the handles for its own calls and messages.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-links)

(defconst harness-linking-prompt-section
  "## Links
The user reads your messages in Emacs, where a link to something in the harness opens it when clicked. Point at things instead of describing where they are: write Markdown links with the scheme harness: (the text is yours), or <harness:...>, which reads as what it names.
- [text](harness:session/ID) -- a session. ID is its id, a unique start of one, or its exact name; session_info, session_list and spawn_agent give ids.
- [text](harness:session/ID/message/NODE) -- a message of that session. NODE is the id in the [assistant n-...] tags of session_read, session_search and session_history.
- [text](harness:call/last) -- a tool call of this session: last is the newest, #3 the third newest, bash#2 the second newest bash call, or give a node id. For another session's: harness:session/ID/call/NODE.
- [text](harness:message/last) -- a message of this session: last is your newest, first the first user message, #2, user#1, assistant#2, or a node id.
- [text](harness:thread/ID) -- a thread of your task's review, the id in [thread ...]; harness:task/TASK/thread/ID for another task's; harness:task/ID is a task.
Use them to point at evidence (\"all tests pass: [the run](harness:call/bash)\"), at the sessions you report on or ask for something, and at the threads you answer. They work in your messages, in the texts of hand_in, review_comment, ask_user and plan, and in what you send to other sessions. last, #3 and the like mean what they mean when you write them: the harness writes them out as ids. A link that names nothing is left as you wrote it (the result of a call that carries it says so); check the ids. Inside backquotes or a fenced block a link is plain text."
  "The Links section of the system prompt.
It is added after the Planning section (`harness-linking--system-prompt'),
and says what `harness-linking-resolve' accepts.")

;;;; Finding what a link names

(defun harness-linking--miss (format-string &rest args)
  "Give up resolving with the sentence FORMAT-STRING makes of ARGS.
`harness-linking-resolve' catches it and answers with it as `:error'."
  (throw 'harness-linking--miss (apply #'format format-string args)))

(defun harness-linking--short (id)
  "Return the first eight characters of ID."
  (if (stringp id) (substring id 0 (min 8 (length id))) ""))

(defun harness-linking--line (text &optional width)
  "Return the first line of TEXT cut to WIDTH (60) characters, blanks squeezed."
  (harness-truncate-end
   (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or (harness-first-line (or text "")) "")))
   (or width 60)))

(defun harness-linking--session-name (id)
  "Return the name of session ID, or nil when it has none."
  (let ((name (plist-get (ignore-errors (harness-call 'session/get id)) :name)))
    (and (stringp name) (not (string-blank-p name)) name)))

(defun harness-linking--session (ref)
  "Return the id of the session REF names.
REF is an id, a unique id prefix or a unique name.  An internal session
answers to a prefix or a name only when no other session does: many are
named after the same job, and a prefix of another session's id is not
meant for them.  Give up with a sentence when REF names none, or several."
  (let ((ref (string-trim (format "%s" (or ref "")))))
    (when (string-empty-p ref) (harness-linking--miss "A link to a session needs its id or its name"))
    (if (harness-call 'session/exists-p ref)
        ref
      (let* ((all (harness-call 'session/list))
             (match (lambda (sessions)
                      (or (cl-remove-if-not (lambda (s) (string-prefix-p ref (plist-get s :id))) sessions)
                          (cl-remove-if-not (lambda (s) (equal (downcase ref) (downcase (or (plist-get s :name) ""))))
                                            sessions))))
             (hits (or (funcall match (cl-remove-if (lambda (s) (eq (plist-get s :kind) 'internal)) all))
                       (funcall match all))))
        (pcase (length hits)
          (1 (plist-get (car hits) :id))
          (0 (harness-linking--miss "No session matches %s; session_list finds ids" ref))
          (_ (harness-linking--miss "%s matches %d sessions (%s); give more of the id"
                                    ref (length hits)
                                    (mapconcat (lambda (s) (harness-linking--short (plist-get s :id)))
                                               hits ", "))))))))

(defun harness-linking--here (link session)
  "Return the id of the session LINK is in: the one it names, else SESSION.
Give up with a sentence when the link names none and no session holds
the text."
  (cond ((plist-get link :session) (harness-linking--session (plist-get link :session)))
        ((and (stringp session) (harness-call 'session/exists-p session)) session)
        (t (harness-linking--miss
            "This link names no session, and no session holds the text it is in: write harness:session/ID/%s/..."
            (if (eq (plist-get link :kind) 'call) "call" "message")))))

(defun harness-linking--before (nodes before)
  "Return the nodes of NODES, oldest first, that come before BEFORE.
BEFORE is the id of a node, or the id of a tool call the provider gave
it; it names the node whose text the link is in, which is not one of
those a handle can mean.  All of NODES when BEFORE names none of them."
  (let ((at (and (stringp before)
                 (or (cl-position before nodes :key (lambda (n) (plist-get n :id)) :test #'equal)
                     (cl-position-if (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                      (equal (plist-get n :call-id) before)))
                                     nodes :from-end t)))))
    (if at (seq-take nodes at) nodes)))

(defun harness-linking--pick (items handle name-of)
  "Return the item of ITEMS, newest first, that HANDLE names, or nil.
HANDLE is what `harness-links-parse-handle' returns; the name it may
hold is compared, in any case, with what NAME-OF gives for an item."
  (if (plist-get handle :first)
      (car (last items))
    (let* ((name (plist-get handle :name))
           (items (if name
                      (cl-remove-if-not (lambda (item) (equal (downcase name) (downcase (or (funcall name-of item) ""))))
                                        items)
                    items)))
      (nth (1- (plist-get handle :nth)) items))))

;;;;; Tool calls

(defun harness-linking--call-title (node)
  "Return words for the tool call NODE: its title, else its tool and what it runs."
  (let* ((title (plist-get node :title))
         (input (plist-get node :input))
         (command (and (listp input) (plist-get input :command))))
    (cond ((and (stringp title) (not (string-blank-p title))) (harness-linking--line title 80))
          ((stringp command) (format "%s: %s" (or (plist-get node :tool) "tool") (harness-linking--line command)))
          (t (format "%s" (or (plist-get node :tool) "tool call"))))))

(defun harness-linking--other-session-hint (ref kind)
  "Return a sentence for a miss on REF, in a link of KIND, if REF is a node id.
An agent that copies a node id from another session's transcript and
leaves the session out is told how to name it; nil for anything else."
  (and (string-match-p "\\`n-[a-z0-9]+\\'" ref)
       (format "; a node of another session is linked with its session: harness:session/ID/%s/%s"
               kind ref)))

(defun harness-linking--calls-list (calls)
  "Return the sentence that lists the recent ones of CALLS, newest first."
  (if (null calls)
      "there are none"
    (cl-loop for node in (seq-take calls 8) for i from 1
             concat (format "%s#%d %s (%s)" (if (> i 1) ", " "") i
                            (plist-get node :id) (harness-linking--call-title node)))))

(defun harness-linking--call-node (sid ref before)
  "Return the tool-call node of session SID that REF names.
REF is the id of a call's node or of its result's, the id its provider
gave it, a handle or the name of a tool; handles count the calls before
BEFORE (see `harness-linking--before'), hand_in's own left out, newest
first.  Give up with a sentence that lists the recent calls when REF
names none."
  (let* ((ref (string-trim (format "%s" (or ref ""))))
         (nodes (harness-call 'session/nodes sid))
         (calls (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'tool-call)) nodes))
         (usable (cl-remove-if (lambda (n) (equal "hand_in" (plist-get n :tool)))
                               (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'tool-call))
                                                 (harness-linking--before nodes before))))
         (newest (reverse usable))
         (handle (harness-links-parse-handle ref))
         (by-tool (lambda (name) (cl-find-if (lambda (n) (equal (downcase name) (downcase (or (plist-get n :tool) ""))))
                                             newest))))
    (when (string-empty-p ref) (harness-linking--miss "A link to a tool call needs its id, or a handle such as last or bash#2"))
    (or
     ;; An exact id: the node of a call, the id its provider gave it, or
     ;; the node of its result.
     (cl-find ref calls :key (lambda (n) (plist-get n :id)) :test #'equal)
     (cl-find ref calls :key (lambda (n) (plist-get n :call-id)) :test #'equal :from-end t)
     (let ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                (equal (plist-get n :id) ref)))
                               nodes)))
       (and result (cl-find (plist-get result :call-id) calls :key (lambda (n) (plist-get n :call-id))
                            :test #'equal :from-end t)))
     (let ((node (ignore-errors (harness-call 'session/node sid ref))))
       (and node (eq (plist-get node :kind) 'tool-call) node))
     (and handle (harness-linking--pick newest handle (lambda (n) (plist-get n :tool))))
     (and (not handle) (funcall by-tool ref))
     (harness-linking--miss "No tool call matches %s in %s; the calls before this one are: %s%s"
                            ref (harness-linking--where sid) (harness-linking--calls-list newest)
                            (or (harness-linking--other-session-hint ref "call") "")))))

;;;;; Messages

(defun harness-linking--message-p (node)
  "Non-nil when NODE is a message: something the user or the agent said."
  (and (memq (plist-get node :kind) '(user assistant))
       (let ((content (plist-get node :content)))
         (and (stringp content) (not (string-blank-p content))))))

(defun harness-linking--message-line (node index)
  "Return NODE, the INDEXth newest message, as one entry of a list."
  (format "#%d %s (%s: %s)" index (plist-get node :id) (plist-get node :kind)
          (harness-linking--line (plist-get node :content) 40)))

(defun harness-linking--message-node (sid ref before)
  "Return the node of session SID that REF names, a message or any other.
REF is the id of a node, or a handle: `last', the newest assistant
message; `first', the first user message; `#3', the third newest message
of either kind; `user#1' and `assistant#2', the nth newest of that kind;
`user' and `assistant', the newest of it.  The messages counted are
those before BEFORE (see `harness-linking--before').  Give up with a
sentence that lists the recent ones when REF names none."
  (let* ((ref (string-trim (format "%s" (or ref ""))))
         (word (downcase ref))
         (nodes (harness-call 'session/nodes sid))
         (messages (cl-remove-if-not #'harness-linking--message-p (harness-linking--before nodes before)))
         (newest (reverse messages)))
    (when (string-empty-p ref) (harness-linking--miss "A link to a message needs its id, or a handle such as last or first"))
    (or
     (ignore-errors (harness-call 'session/node sid ref))
     (cond
      ((member word '("last" "newest" "latest")) (cl-find 'assistant newest :key (lambda (n) (plist-get n :kind))))
      ((member word '("first" "oldest")) (cl-find 'user messages :key (lambda (n) (plist-get n :kind))))
      ((member word '("user" "assistant")) (cl-find (intern word) newest :key (lambda (n) (plist-get n :kind))))
      (t (when-let* ((handle (harness-links-parse-handle ref)))
           (harness-linking--pick newest handle (lambda (n) (symbol-name (plist-get n :kind)))))))
     (harness-linking--miss "No message matches %s in %s; the messages before this one are: %s%s"
                            ref (harness-linking--where sid)
                            (if newest
                                (mapconcat (lambda (i) (harness-linking--message-line (nth (1- i) newest) i))
                                           (number-sequence 1 (min 6 (length newest))) ", ")
                              "there are none")
                            (or (harness-linking--other-session-hint ref "message") "")))))

(defun harness-linking--where (sid)
  "Return how a sentence names session SID: its name, else the start of its id."
  (or (harness-linking--session-name sid) (format "session %s" (harness-linking--short sid))))

;;;;; Tasks and threads

(defun harness-linking--task (ref)
  "Return the task REF names, a task id or a unique start of one.
Give up with a sentence when the tasks module is not loaded or REF names none."
  (unless (harness-method-exists-p 'task/get)
    (harness-linking--miss "Tasks are not available in this harness (the tasks module is not loaded)"))
  (let ((ref (string-trim (format "%s" (or ref "")))))
    (when (string-empty-p ref) (harness-linking--miss "A link to a task needs its id"))
    (or (condition-case nil (harness-call 'task/get ref) (error nil))
        (and (>= (length ref) 3)
             (let ((hits (cl-remove-if-not (lambda (task) (string-prefix-p ref (plist-get task :id)))
                                           (harness-call 'task/list))))
               (when (cdr hits)
                 (harness-linking--miss "%s starts the ids of %d tasks (%s); give more of it"
                                        ref (length hits)
                                        (mapconcat (lambda (task) (plist-get task :id)) hits ", ")))
               (car hits)))
        (harness-linking--miss "No task matches %s" ref))))

(defun harness-linking--task-name (task)
  "Return what to call TASK: its name, else the start of its prompt."
  (let ((name (plist-get task :name)))
    (if (and (stringp name) (not (string-blank-p name)))
        name
      (harness-linking--line (or (plist-get task :prompt) (plist-get task :id)) 60))))

(defun harness-linking--task-of (link session)
  "Return the task whose review LINK, a thread link, is about.
That is the task the link names, else the task of the session it names,
else the task of SESSION, the session the text is in."
  (cond
   ((plist-get link :task) (harness-linking--task (plist-get link :task)))
   (t (let ((sid (cond ((plist-get link :session) (harness-linking--session (plist-get link :session)))
                       ((and (stringp session) (harness-call 'session/exists-p session)) session))))
        (unless sid
          (harness-linking--miss "This link names no task, and no session holds the text it is in: write harness:task/ID/thread/ID"))
        (or (and (harness-method-exists-p 'task/for-session) (harness-call 'task/for-session sid))
            (harness-linking--miss "%s is no task's, so it has no review with threads: write harness:task/ID/thread/ID"
                                   (harness-linking--where sid)))))))

;;;; The answer

(defun harness-linking--session-result (sid)
  "Return the answer for session SID."
  (let ((name (harness-linking--session-name sid)))
    (append (list :kind "session" :url (harness-links-session-url sid)
                  :label (or name (format "session %s" (harness-linking--short sid)))
                  :session sid)
            (and name (list :session-name name)))))

(defun harness-linking--node-result (kind sid node label)
  "Return the answer for NODE of session SID, for a link of KIND, in words LABEL.
KIND is `message' or `call'."
  (let ((name (harness-linking--session-name sid))
        (id (plist-get node :id)))
    (append (list :kind (symbol-name kind)
                  :url (if (eq kind 'call) (harness-links-call-url sid id) (harness-links-message-url sid id))
                  :label label
                  :session sid
                  :node id)
            (and (eq kind 'call) (plist-get node :call-id) (list :call-id (plist-get node :call-id)))
            (and (eq kind 'call) (plist-get node :tool) (list :tool (plist-get node :tool)))
            (and name (list :session-name name)))))

(defun harness-linking--task-result (task)
  "Return the answer for TASK."
  (let* ((id (plist-get task :id))
         (sid (plist-get task :session))
         (sid (and (stringp sid) (not (string-empty-p sid)) sid))
         (name (harness-linking--task-name task)))
    (append (list :kind "task" :url (harness-links-task-url id) :label (format "task %s" name)
                  :task id :task-name name)
            (and sid (list :session sid))
            (and sid (harness-linking--session-name sid) (list :session-name (harness-linking--session-name sid))))))

(defun harness-linking--thread-result (task thread)
  "Return the answer for THREAD, what `review/find-thread' says, of TASK."
  (let* ((id (plist-get task :id))
         (sid (plist-get task :session))
         (sid (and (stringp sid) (not (string-empty-p sid)) sid)))
    (append (list :kind "thread"
                  :url (harness-links-thread-url id (plist-get thread :id))
                  :label (format "thread %s on %s" (plist-get thread :id) (or (plist-get thread :where) "the change"))
                  :task id :task-name (harness-linking--task-name task)
                  :thread (plist-get thread :id))
            (and (plist-get thread :status) (list :status (plist-get thread :status)))
            (and sid (list :session sid))
            (and sid (harness-linking--session-name sid) (list :session-name (harness-linking--session-name sid))))))

(defun harness-linking--resolve (link session before)
  "Return the answer for LINK, parsed, written in SESSION before the node BEFORE.
Give up with a sentence when it names nothing."
  (pcase (plist-get link :kind)
    ('session (harness-linking--session-result (harness-linking--session (plist-get link :session))))
    ('call (let* ((sid (harness-linking--here link session))
                  (node (harness-linking--call-node sid (plist-get link :call) before)))
             (harness-linking--node-result 'call sid node (harness-linking--call-title node))))
    ('message (let* ((sid (harness-linking--here link session))
                     (node (harness-linking--message-node sid (plist-get link :message) before))
                     (name (harness-linking--session-name sid)))
                (harness-linking--node-result
                 'message sid node
                 (harness-links-label (list :kind 'message :message (plist-get node :id)) name))))
    ('task (harness-linking--task-result (harness-linking--task (plist-get link :task))))
    ('thread (let ((task (harness-linking--task-of link session)))
               (unless (harness-method-exists-p 'review/find-thread)
                 (harness-linking--miss "Review threads are not available in this harness"))
               (let ((thread (harness-call 'review/find-thread (plist-get task :id) (plist-get link :thread))))
                 (unless thread
                   (harness-linking--miss "No thread %s in the review of the task %s"
                                          (plist-get link :thread) (harness-linking--task-name task)))
                 (harness-linking--thread-result task thread))))
    (kind (harness-linking--miss "%S is no kind of link" kind))))

(cl-defun harness-linking-resolve (url &key session before)
  "Return what the harness link URL names, or why it names nothing.
SESSION is the session whose text holds the link, which a link that
names no session is in; BEFORE is the id of the node, or of the provider's
call, that wrote it, for the handles that count the nodes before it.

The answer is a plist.  When the link names something it has `:kind',
one of \"session\", \"message\", \"call\", \"thread\" and \"task\"; `:url',
the link written out in full, from ids alone; `:label', words for it; and
what it is by its ids: `:session' and `:session-name', `:node' (the
message's, or the call's node), `:call-id', `:tool', `:task' and
`:task-name', `:thread' and `:status'.  When it names nothing the
answer is `:error' alone, a sentence."
  (let ((answer (catch 'harness-linking--miss
                  (condition-case err
                      (let ((link (harness-links-parse url)))
                        (unless link
                          (harness-linking--miss "%s is no link to a session, a message, a tool call, a task or a thread"
                                                 (harness-truncate-end (format "%s" url) 80)))
                        (harness-linking--resolve link session before))
                    (error (harness-log 'warn "linking: resolving %s failed: %s" url (harness-error-message err))
                           (format "Resolving %s failed: %s" (harness-truncate-end (format "%s" url) 80)
                                   (harness-error-short-message err)))))))
    (if (stringp answer) (list :error answer) answer)))

;;;; Writing them out

(cl-defun harness-linking-canonicalize (text &key session before)
  "Return (TEXT . PROBLEMS): TEXT with its harness links written out in full.
SESSION and BEFORE are as for `harness-linking-resolve'.  Each link a
Markdown renderer shows as a link (`harness-links-scan') becomes the URL
`harness-linking-resolve' gives for it, which leaves a link that has it
already as it is; a bare one becomes a Markdown link with words for what
it names.  A link that names nothing stays as written, and PROBLEMS,
which is nil when there are none, says so in a sentence for each: the
link, then why.  Never signals: a text it cannot work on comes back as
it is."
  (if (not (and (stringp text) (string-match-p "harness:" text)))
      (cons text nil)
    (let ((problems nil))
      (condition-case err
          (let ((new (harness-links-rewrite
                      text
                      (lambda (link)
                        (let* ((url (plist-get link :url))
                               (answer (harness-linking-resolve url :session session :before before)))
                          (if (plist-get answer :error)
                              (progn (push (format "%s: %s" (harness-truncate-end url 80)
                                                   (harness-truncate-end (plist-get answer :error) 300))
                                           problems)
                                     nil)
                            (let ((canonical (plist-get answer :url)))
                              (if (eq (plist-get link :form) 'bare)
                                  (harness-links-markdown (plist-get answer :label) canonical)
                                (and (not (equal canonical url)) canonical)))))))))
            (cons new (nreverse (delete-dups problems))))
        (error (harness-log 'warn "linking: writing out the links of a text failed: %s" (harness-error-message err))
               (cons text nil))))))

;;;; Methods

(harness-defmethod link/resolve (url &optional session)
  "Return what the harness link URL names, or why it names nothing.
SESSION is the session whose text holds the link: a link that names no
session is in it, and a handle such as `last' or `bash#2' counts its
nodes.  The answer is a plist: `:kind', one of \"session\", \"message\",
\"call\", \"thread\" and \"task\"; `:url', the link written out in full,
from ids alone; `:label', words for it; and its ids: `:session' and
`:session-name', `:node' (the message's, or the call's node), `:call-id',
`:task' and `:task-name', `:thread'.  A link that names nothing has
`:error' alone, a sentence for the user to read.  The UI follows a link
with it, and a client that shows one asks it what the link is."
  (harness-linking-resolve url :session session))

(harness-defmethod link/canonicalize (text &optional session before)
  "Return TEXT with its harness links written out, and what was wrong with some.
The answer is a plist: `:text', the text, and `:problems', a sentence for
each link that names nothing, which was left as written.  SESSION is the
session the text is in, and BEFORE the id of the node, or of the call,
that wrote it: the handles of its links count the nodes before it.  A
link that is in full already stays as it is, so doing it twice changes
nothing.  Code is left alone."
  (let ((done (harness-linking-canonicalize text :session session :before before)))
    (list :text (car done) :problems (cdr done))))

;;;; The system prompt

(defun harness-linking--prompt-p (session)
  "Non-nil when SESSION, a plist, has a use for the Links section.
Not an internal session, the record of a model call the harness made on
its own: it writes no message anyone reads."
  (and session (not (eq (plist-get session :kind) 'internal))))

(defun harness-linking--system-prompt (prompt session)
  "Append the Links section to PROMPT for SESSION (`agent/system-prompt')."
  (if (harness-linking--prompt-p session)
      (concat prompt "\n\n" harness-linking-prompt-section "\n")
    prompt))

;;;; The module

(defun harness-linking--init ()
  "Register the module's filter (idempotent)."
  (harness-add-filter 'agent/system-prompt #'harness-linking--system-prompt 45))

(harness-linking--init)

(defun harness-linking--shutdown ()
  "Take the module's filter off the system prompt."
  (harness-remove-filter 'agent/system-prompt #'harness-linking--system-prompt))

(harness-define-module 'linking
  :doc "Links in what agents write: sessions, messages, tool calls, tasks and review threads, found and written out in full, and taught to agents in the system prompt."
  :requires '(session)
  :init #'harness-linking--init
  :shutdown #'harness-linking--shutdown)

(provide 'harness-linking)
;;; harness-linking.el ends here
