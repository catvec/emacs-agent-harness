;;; harness-ui-linking-test.el --- Tests for following harness links  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; An agent writes a link to a session, a message, a tool call, a task or
;; a thread (lisp/harness-links.el); the Markdown renderer draws it and
;; ui-linking is what a click does.  These tests drive the chat buffer
;; against the real state layer and the in-process ACP connection, as the
;; chat's own suite does, with the harness's answer to `link/resolve'
;; stubbed where the calls made are what is looked at: that method is the
;; linking module's, which the UI never requires.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-links)

(defvar harness-provider-demo--delay)
(defvar harness-ui--sessions)
(defvar harness-ui-linking-handlers)
(defvar harness-ui-linking-context-functions)
(defvar harness-ui-markdown-harness-link-function)
(defvar harness-ui-markdown-link-describe-function)
(declare-function harness-ui-cache-session "harness-ui")
(declare-function harness-ui-linking-follow "harness-ui-linking" (url))
(declare-function harness-ui-linking-describe "harness-ui-linking" (url))
(declare-function harness-ui-linking-context "harness-ui-linking" ())

(defvar harness-ui-linking-test-requests nil
  "The (METHOD . PARAMS) the UI asked the harness for, newest first.")

(defmacro harness-ui-linking-test-with (&rest body)
  "Load the state layer, ACP, the chat and ui-linking, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-ui-linking-test-requests nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (harness-ui-linking-handlers nil)
           (harness-ui-linking-context-functions nil)
           (default-directory dir))
       (harness-define-tool "bash" :label "Bash" :description "bash" :kind 'exec
                            :handler (lambda (input _ctx) (format "ran %s" (plist-get input :command))))
       (dolist (m '(ui ui-markdown ui-chat ui-linking))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-linking-test-session (&optional name)
  "Create a demo session called NAME and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                           :name (or name "Linking test"))
             :id))

(defun harness-ui-linking-test-node (sid kind &rest plist)
  "Append a node of KIND with PLIST to session SID; return its id."
  (plist-get (harness-call 'session/append sid (append (list :kind kind) plist)) :id))

(defun harness-ui-linking-test-open (sid)
  "Open the chat buffer of SID and wait until it has rendered."
  (let ((buf (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                       5 "chat buffer loaded")
    buf))

(defun harness-ui-linking-test-cached (&rest ids)
  "Wait until the UI's session cache holds every one of IDS."
  (harness-test-wait (lambda () (cl-every #'harness-ui-session ids)) 5 "the sessions in the cache"))

(defmacro harness-ui-linking-test-answering (answers &rest body)
  "Run BODY with the harness's answers to what the UI asks it, ANSWERS an alist.
Each key is a method name; the value is the plist its callback gets, or
\(:fail MESSAGE), which fails the request.  Every request is recorded in
`harness-ui-linking-test-requests'; one nobody answers fails the test."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'harness-ui-call)
              (lambda (method params callback &optional on-error)
                (push (cons method params) harness-ui-linking-test-requests)
                (let ((answer (assoc method ,answers)))
                  (cond ((null answer) (ert-fail (list "Asked the harness for" method params)))
                        ((eq :fail (car-safe (cdr answer)))
                         (funcall on-error (list 'error (cadr (cdr answer)))))
                        (t (funcall callback (cdr answer))))))))
     ,@body))

(defmacro harness-ui-linking-test-visiting (&rest body)
  "Run BODY with `harness-ui-visit-session' recording the sessions it is given.
They are in `visited', newest first; the session shows nowhere, and no
chat is made for it."
  (declare (indent 0))
  `(let ((visited nil))
     (cl-letf (((symbol-function 'harness-ui-visit-session)
                (lambda (id &rest _) (push id visited))))
       ,@body)))

(defun harness-ui-linking-test-messages ()
  "Return the echo area messages made while this runs, as one string."
  (with-current-buffer "*Messages*" (buffer-string)))

;;;; What a link is

(ert-deftest harness-ui-linking-describes-a-session-by-its-name ()
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session "Fix the build")))
      (harness-ui-linking-test-cached sid)
      (let ((described (harness-ui-linking-describe (harness-links-session-url sid))))
        (should (equal "Fix the build" (plist-get described :label)))
        (should (string-match-p "open the session Fix the build (idle)\\'" (plist-get described :help))))
      ;; By its name or the start of its id, as the session tools take it.
      (should (equal "Fix the build" (plist-get (harness-ui-linking-describe "harness:session/Fix%20the%20build")
                                                :label)))
      (should (equal "Fix the build" (plist-get (harness-ui-linking-describe
                                                 (harness-links-session-url (substring sid 0 8)))
                                                :label)))
      ;; A session this Emacs does not know has no name to give.
      (let ((unknown (harness-ui-linking-describe "harness:session/nobody")))
        (should-not (plist-get unknown :label))
        (should (string-match-p "open the session nobody" (plist-get unknown :help)))))))

(ert-deftest harness-ui-linking-describes-what-a-message-a-call-a-thread-and-a-task-open ()
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session "Fix the build")))
      (harness-ui-linking-test-cached sid)
      (pcase-dolist (`(,url ,label ,help)
                     `((,(harness-links-message-url sid "n-1") "message n-1 of Fix the build"
                        "open that message in the session Fix the build")
                       (,(harness-links-call-url sid "n-2") "tool call n-2 of Fix the build"
                        "open that tool call in the session Fix the build")
                       ("harness:call/last" "tool call last" "open that tool call in this session")
                       ("harness:message/n-1" "message n-1" "open that message in this session")
                       ("harness:thread/t-3" "thread t-3" "open that thread of a review")
                       ("harness:task/t-4" "task t-4" "open that task")))
        (ert-info (url)
          (let ((described (harness-ui-linking-describe url)))
            (should (equal label (plist-get described :label)))
            (should (string-match-p (concat (regexp-quote help) "\\'") (plist-get described :help)))))))
    (should-not (harness-ui-linking-describe "harness:nothing/here"))
    (should-not (harness-ui-linking-describe "https://example.org"))))

(ert-deftest harness-ui-linking-gives-the-renderer-its-words ()
  "A link with no words of its own shows the session's name; the author's words stay."
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session "Fix the build")))
      (harness-ui-linking-test-cached sid)
      (let ((s (harness-ui-markdown-inline
                (format "See <%s> and [the build](%s)." (harness-links-session-url sid)
                        (harness-links-session-url sid)))))
        (should (equal "See Fix the build and the build." (substring-no-properties s)))
        (should (string-match-p "open the session Fix the build"
                                (get-text-property (string-search "build." s) 'help-echo s)))
        (should (get-text-property (string-search "Fix" s) 'harness-url s))))))

(ert-deftest harness-ui-linking-names-a-node-its-chat-shows ()
  "A link with no words of its own to a call or a message the chat of its
session shows reads as the call's title or the start of the message."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session "Fix the build"))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there, please look at this\nsecond line"))
           (call (harness-ui-linking-test-node sid 'tool-call :call-id "toolu_42" :tool "bash"
                                               :title "Bash: scripts/test.sh" :input '(:command "ls")))
           (answer (harness-ui-linking-test-node sid 'assistant :content "The tests pass."))
           (marked (harness-ui-linking-test-node
                    sid 'assistant :content "The `hand_in` tool is **defined** in [the code](https://example.org/a)."))
           (buf (progn (harness-ui-linking-test-node sid 'tool-result :call-id "toolu_42" :output "ok")
                       (harness-ui-linking-test-open sid))))
      (harness-ui-linking-test-cached sid)
      (let ((label (lambda (url) (plist-get (harness-ui-linking-describe url) :label))))
        (should (equal "Bash: scripts/test.sh" (funcall label (harness-links-call-url sid call))))
        (should (equal "Bash: scripts/test.sh" (funcall label (harness-links-call-url sid "toolu_42"))))
        (should (equal "your message “Hello there, please look at this”"
                       (funcall label (harness-links-message-url sid hello))))
        (should (equal "reply “The tests pass.”" (funcall label (harness-links-message-url sid answer))))
        ;; What the first line says as it shows: the markers of its Markdown are not words.
        (should (equal "reply “The hand_in tool is defined in the code.”"
                       (funcall label (harness-links-message-url sid marked))))
        ;; In its own chat a link needs no session.
        (with-current-buffer buf
          (should (equal "Bash: scripts/test.sh" (funcall label (harness-links-call-url nil call)))))
        ;; A node no chat shows, or a handle, reads as what it is made of.
        (should (equal "message n-unknown of Fix the build"
                       (funcall label (harness-links-message-url sid "n-unknown"))))
        (should (equal "tool call last" (funcall label "harness:call/last")))
        (kill-buffer buf)
        (should (equal (format "tool call %s of Fix the build" call)
                       (funcall label (harness-links-call-url sid call)))))
      ;; Drawn, the autolink shows the words.
      (let ((s (harness-ui-markdown-inline (format "See <%s>." (harness-links-call-url sid call)))))
        (should (string-match-p "tool call n-" (substring-no-properties s)))))))

;;;; Whose text it is

(ert-deftest harness-ui-linking-context-is-the-session-the-buffer-holds ()
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (chat (harness-ui-linking-test-open sid)))
      (with-current-buffer chat
        (should (equal sid (harness-ui-linking-context))))
      (with-temp-buffer
        (should-not (harness-ui-linking-context))
        ;; Another view says whose text it holds through the hook.
        (let ((harness-ui-linking-context-functions (list (lambda () "someone"))))
          (should (equal "someone" (harness-ui-linking-context))))
        (let ((harness-ui-linking-context-functions (list (lambda () nil) (lambda () "second"))))
          (should (equal "second" (harness-ui-linking-context))))
        (let ((harness-ui-linking-context-functions (list (lambda () ""))))
          (should-not (harness-ui-linking-context))))
      ;; The chat's own session comes first.
      (with-current-buffer chat
        (let ((harness-ui-linking-context-functions (list (lambda () "someone"))))
          (should (equal sid (harness-ui-linking-context)))))
      ;; A report says the session of its task.
      (with-temp-buffer
        (cl-letf (((symbol-function 'harness-ui-report-task) (lambda () (list :id "t-1" :session "worker"))))
          (should (equal "worker" (harness-ui-linking-context))))))))

;;;; Following without asking

(ert-deftest harness-ui-linking-opens-a-session-the-cache-knows-without-asking ()
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session "Fix the build")))
      (harness-ui-linking-test-cached sid)
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering nil
          (dolist (ref (list sid (substring sid 0 8) "fix the build"))
            (setq visited nil)
            (harness-ui-linking-follow (harness-links-session-url ref))
            (ert-info (ref)
              (should (equal (list sid) visited))))))
      (should-not harness-ui-linking-test-requests))))

(ert-deftest harness-ui-linking-says-when-a-link-names-nothing ()
  (harness-ui-linking-test-with
    (dolist (url '("harness:nothing/here" "harness:session" "https://example.org" ""))
      (ert-info (url)
        (should-error (harness-ui-linking-follow url) :type 'user-error)))))

(ert-deftest harness-ui-linking-opens-a-node-its-chat-shows-without-asking ()
  "A link to a message or a call by the id of its node, in a chat that shows
the node, goes to it: the session is opened and the chat taken to the node."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there"))
           (call (harness-ui-linking-test-node sid 'tool-call :call-id "toolu_42" :tool "bash"
                                               :title "Bash: ls" :input '(:command "ls")))
           (answer (harness-ui-linking-test-node sid 'assistant :content "The tests pass."))
           (buf (progn (harness-ui-linking-test-node sid 'tool-result :call-id "toolu_42" :output "ok")
                       (harness-ui-linking-test-open sid))))
      (harness-ui-linking-test-cached sid)
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering nil
          (dolist (case (list (list (harness-links-message-url sid hello) hello "Hello there")
                              (list (harness-links-message-url sid answer) answer "The tests pass.")
                              (list (harness-links-call-url sid call) call "ran ls")
                              ;; By the id its provider gave it.
                              (list (harness-links-call-url sid "toolu_42") call "ran ls")))
            (ert-info ((car case))
              (setq visited nil)
              (with-current-buffer buf (goto-char (point-max)))
              (harness-ui-linking-follow (car case))
              (should (equal (list sid) visited))
              (with-current-buffer buf
                (should (equal (cadr case) (get-text-property (point) 'harness-chat-node))))))))
      (should-not harness-ui-linking-test-requests))))

(ert-deftest harness-ui-linking-takes-a-link-without-a-session-to-the-session-the-text-is-in ()
  "`harness:message/NODE' in a chat is a message of that chat."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there"))
           (buf (harness-ui-linking-test-open sid)))
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering nil
          (with-current-buffer buf
            (goto-char (point-max))
            (harness-ui-linking-follow (harness-links-message-url nil hello))
            (should (equal hello (get-text-property (point) 'harness-chat-node))))
          (should (equal (list sid) visited))))
      (should-not harness-ui-linking-test-requests))))

(ert-deftest harness-ui-linking-opens-a-link-given-as-text ()
  "The command takes the link as typed, or as the kill ring holds it."
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session "Fix the build")))
      (harness-ui-linking-test-cached sid)
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering nil
          (harness-ui-linking-open (concat "  " (harness-links-session-url sid) "\n"))
          (should (equal (list sid) visited))
          ;; Called as a command, it offers what the kill ring holds when that is a link.
          (setq visited nil)
          (let ((kill-ring (list (harness-links-session-url sid)))
                (asked nil))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (prompt &optional initial &rest _) (setq asked (list prompt initial)) initial)))
              (call-interactively #'harness-ui-linking-open))
            (should (equal (list "Harness link: " (harness-links-session-url sid)) asked))
            (should (equal (list sid) visited)))
          ;; Anything else in the ring is not offered.
          (let ((kill-ring (list "https://example.org/"))
                (asked nil))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (_prompt &optional initial &rest _) (setq asked (list initial)) "harness:nothing/here")))
              (should-error (call-interactively #'harness-ui-linking-open) :type 'user-error))
            (should (equal '(nil) asked))))))))

;;;; Asking the harness

(ert-deftest harness-ui-linking-asks-the-harness-for-the-rest ()
  "What the UI cannot tell -- a handle, a name it does not know, a thread -- is
resolved by the harness, in the session the text is in."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (other (harness-ui-linking-test-session "Elsewhere"))
           (buf (harness-ui-linking-test-open sid)))
      (harness-ui-linking-test-cached sid other)
      (harness-ui-linking-test-visiting
        ;; A handle: the harness knows what `last' is, here.
        (harness-ui-linking-test-answering
            `(("_harness/link/resolve" :kind "call" :url "harness:session/x/call/n-9"
               :session ,other :node "n-9" :call-id "toolu_9"))
          (with-current-buffer buf
            (harness-ui-linking-follow "harness:call/last")))
        (should (equal (list (cons "_harness/link/resolve"
                                   (list :url "harness:call/last" :session sid)))
                       harness-ui-linking-test-requests))
        ;; It opens the session and goes to the node.
        (should (equal (list other) visited)))
      ;; Where no session holds the text there is none to send.
      (setq harness-ui-linking-test-requests nil)
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering
            `(("_harness/link/resolve" :kind "session" :session ,other))
          (with-temp-buffer
            (harness-ui-linking-follow "harness:session/unknown-name")))
        (should (equal (list (cons "_harness/link/resolve" (list :url "harness:session/unknown-name")))
                       harness-ui-linking-test-requests))
        (should (equal (list other) visited))))))

(ert-deftest harness-ui-linking-goes-to-the-node-the-harness-names ()
  "A message or a call the harness resolved: the session opens, then the chat
goes to the node, as far back as it takes."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there"))
           (answer (harness-ui-linking-test-node sid 'assistant :content "The tests pass."))
           (buf (harness-ui-linking-test-open sid))
           (went nil))
      (harness-ui-linking-test-visiting
        (cl-letf (((symbol-function 'harness-ui-chat-goto-node)
                   (lambda (node &optional session regexp) (push (list node session regexp) went))))
          (dolist (kind '("message" "call"))
            (setq went nil)
            (harness-ui-linking-test-answering
                `(("_harness/link/resolve" :kind ,kind :session ,sid :node ,answer))
              (with-current-buffer buf (harness-ui-linking-follow "harness:call/last")))
            (should (equal (list (list answer sid nil)) went)))
          ;; An answer with no node opens the session and goes nowhere.
          (setq went nil)
          (harness-ui-linking-test-answering `(("_harness/link/resolve" :kind "message" :session ,sid))
            (with-current-buffer buf (harness-ui-linking-follow "harness:message/last")))
          (should-not went)))
      (ignore hello))))

(ert-deftest harness-ui-linking-opens-the-report-of-a-task ()
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (shown nil))
      (harness-ui-linking-test-visiting
        (cl-letf (((symbol-function 'harness-ui-report-popout) (lambda (task) (push task shown))))
          ;; A task that handed a report in shows it.
          (harness-ui-linking-test-answering
              `(("_harness/link/resolve" :kind "task" :task "t-4" :session ,sid)
                ("_harness/task/get" :id "t-4" :session ,sid :report (:summary "Done")))
            (with-temp-buffer (harness-ui-linking-follow "harness:task/t-4")))
          (should (equal (list (list :id "t-4" :session sid :report '(:summary "Done"))) shown))
          (should-not visited)
          ;; One that did not opens its session.
          (setq shown nil)
          (harness-ui-linking-test-answering
              `(("_harness/link/resolve" :kind "task" :task "t-4" :session ,sid)
                ("_harness/task/get" :id "t-4" :session ,sid))
            (with-temp-buffer (harness-ui-linking-follow "harness:task/t-4")))
          (should-not shown)
          (should (equal (list sid) visited))
          ;; A task the harness cannot give opens its session all the same.
          (setq visited nil)
          (harness-ui-linking-test-answering
              `(("_harness/link/resolve" :kind "task" :task "t-4" :session ,sid)
                ("_harness/task/get" :fail "No task t-4"))
            (with-temp-buffer (harness-ui-linking-follow "harness:task/t-4")))
          (should (equal (list sid) visited)))))))

(ert-deftest harness-ui-linking-leaves-a-thread-to-the-module-that-draws-reviews ()
  "A thread is opened by the handler a module registered for threads; with none
the session is shown and the echo area says why."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (answer `(("_harness/link/resolve" :kind "thread" :task "t-4" :thread "t-3" :session ,sid)))
           (got nil))
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering answer
          (with-temp-buffer (harness-ui-linking-follow "harness:thread/t-3")))
        (should (equal (list sid) visited))
        (should (string-match-p "A link to a thread cannot be shown here" (harness-ui-linking-test-messages)))
        (setq visited nil)
        (let ((harness-ui-linking-handlers (list (cons "thread" (lambda (result) (push result got))))))
          (harness-ui-linking-test-answering answer
            (with-temp-buffer (harness-ui-linking-follow "harness:thread/t-3"))))
        (should-not visited)
        (should (equal (list (list :kind "thread" :task "t-4" :thread "t-3" :session sid)) got))))))

(ert-deftest harness-ui-linking-says-what-the-harness-says-when-it-cannot-resolve ()
  (harness-ui-linking-test-with
    (let ((sid (harness-ui-linking-test-session)))
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering
            `(("_harness/link/resolve" :error "No tool call matches bash#9 in this session"))
          (with-temp-buffer (harness-ui-linking-follow "harness:call/bash#9")))
        (should (string-match-p "No tool call matches bash#9 in this session" (harness-ui-linking-test-messages)))
        (should-not visited)
        ;; A harness that has no linking module, or an old one.
        (harness-ui-linking-test-answering
            `(("_harness/link/resolve" :fail "Method not found: No such ACP method _harness/link/resolve"))
          (with-temp-buffer (harness-ui-linking-follow "harness:call/last")))
        (should (string-match-p "cannot resolve links: it has no linking module" (harness-ui-linking-test-messages)))
        ;; Any other failure is told as it is.
        (harness-ui-linking-test-answering `(("_harness/link/resolve" :fail "boom"))
          (with-temp-buffer (harness-ui-linking-follow "harness:call/last")))
        (should (string-match-p "Could not follow the link: boom" (harness-ui-linking-test-messages)))
        ;; An answer that makes no sense is no reason to fail.
        (harness-ui-linking-test-answering `(("_harness/link/resolve" :kind "banana"))
          (with-temp-buffer (harness-ui-linking-follow "harness:call/last")))
        (should (string-match-p "A link to a banana cannot be shown here" (harness-ui-linking-test-messages)))
        (should-not visited))
      (ignore sid))))

(ert-deftest harness-ui-linking-does-not-wait-for-the-harness ()
  "A click makes the request and returns: the answer opens the link when it comes,
where the click was, whatever buffer or window the Emacs has gone to by then."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (promise (harness-make-promise))
           (clicked (generate-new-buffer " *clicked*"))
           (other (generate-new-buffer " *elsewhere*"))
           (where nil))
      (harness-ui-linking-test-cached sid)
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-request)
                     (lambda (method params)
                       (push (cons method params) harness-ui-linking-test-requests)
                       promise))
                    ((symbol-function 'harness-ui-visit-session)
                     (lambda (id &rest _) (setq where (list id (current-buffer) (selected-window))))))
            (with-current-buffer clicked
              (switch-to-buffer clicked)
              (let ((window (selected-window)))
                (harness-ui-linking-follow "harness:session/somebody-else")
                (should (equal 1 (length harness-ui-linking-test-requests)))
                (should-not where)
                ;; The Emacs goes elsewhere before the answer comes.
                (switch-to-buffer other)
                (harness-resolve promise (list :kind "session" :session sid))
                (harness-test-wait (lambda () where) 5 "the answer to open the session")
                (should (equal (list sid clicked window) where)))))
        (kill-buffer clicked)
        (kill-buffer other)))))

;;;; In a message

(ert-deftest harness-ui-linking-a-click-on-a-link-in-a-message-follows-it ()
  "The link an agent wrote, drawn in its message, opens what it names."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there"))
           (answer (harness-ui-linking-test-node
                    sid 'assistant
                    :content (format "As said in [your first message](%s), all fine." (harness-links-message-url sid hello))))
           (buf (harness-ui-linking-test-open sid)))
      (harness-ui-linking-test-visiting
        (harness-ui-linking-test-answering nil
          (with-current-buffer buf
            (let ((pos (save-excursion (goto-char (point-min))
                                       (search-forward "your first message")
                                       (match-beginning 0))))
              (should (equal (harness-links-message-url sid hello) (get-text-property pos 'harness-url)))
              (should (memq 'link (let ((f (get-text-property pos 'face))) (if (listp f) f (list f)))))
              (goto-char pos)
              (should (eq #'harness-ui-markdown-follow-link (key-binding (kbd "RET"))))
              (call-interactively #'harness-ui-markdown-follow-link)
              (should (equal hello (get-text-property (point) 'harness-chat-node)))
              (should-not (equal answer (get-text-property (point) 'harness-chat-node)))))
          (should (equal (list sid) visited)))))))

(ert-deftest harness-ui-linking-links-a-session-id-in-a-message ()
  "The id of a session the UI knows, in what an agent wrote, is a link to it;
what shows as code is meant literally and stays as it is."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (other (harness-ui-linking-test-session "Worker"))
           (unknown (harness-uuid)))
      (harness-ui-linking-test-cached sid other)
      (harness-ui-linking-test-node
       sid 'assistant
       :content (format "Plain %s here, quoted `%s`, unknown %s.\n\n```\nfenced %s\n```\n" other other unknown other))
      (let ((buf (harness-ui-linking-test-open sid)))
        (with-current-buffer buf
          (let* ((link-p (lambda (pos) (memq 'harness-ui-session-link-face
                                             (let ((f (get-text-property pos 'face))) (if (listp f) f (list f))))))
                 ;; Where the first eight characters of the id after WORD are.
                 (id-after (lambda (word id)
                             (save-excursion (goto-char (point-min))
                                             (search-forward (format "%s %s" word (substring id 0 8)))
                                             (- (point) 4))))
                 (plain (funcall id-after "Plain" other))
                 (quoted (funcall id-after "quoted" other))
                 (strange (funcall id-after "unknown" unknown))
                 (fenced (funcall id-after "fenced" other)))
            (should (funcall link-p plain))
            ;; The positions checked are where the code is.
            (should (memq 'harness-md-code (let ((f (get-text-property quoted 'face))) (if (listp f) f (list f)))))
            (should (eq 'code (get-text-property fenced 'harness-md-block)))
            (should-not (funcall link-p quoted))
            (should-not (funcall link-p strange))
            (should-not (funcall link-p fenced))
            ;; The link opens the session, as the shared session link does.
            (let (opened)
              (cl-letf (((symbol-function 'harness-ui-visit-session) (lambda (id &rest _) (setq opened id))))
                (goto-char plain)
                (call-interactively (lookup-key (get-text-property plain 'keymap) [mouse-1])))
              (should (equal other opened)))))))))

;;;; Copying a link

(ert-deftest harness-ui-linking-copies-a-link-to-a-message-a-call-and-the-session ()
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session "Fix the build"))
           (hello (harness-ui-linking-test-node sid 'user :content "Hello there\nsecond line"))
           (call (harness-ui-linking-test-node sid 'tool-call :call-id "toolu_42" :tool "bash"
                                               :title "Bash: ls" :input '(:command "ls")))
           (buf (progn (harness-ui-linking-test-node sid 'tool-result :call-id "toolu_42" :output "ok")
                       (harness-ui-linking-test-open sid)))
           (kill-ring nil))
      (harness-ui-linking-test-cached sid)
      (with-current-buffer buf
        (should (eq #'harness-chat-copy-link (key-binding (kbd "C-c C-l"))))
        (should (eq #'harness-chat-copy-session-link (key-binding (kbd "C-c M-l"))))
        ;; A message.
        (goto-char (harness-chat-block-start (gethash hello harness-chat--blocks)))
        (harness-chat-copy-link)
        (should (equal (harness-links-message-url sid hello) (car kill-ring)))
        (should (equal sid (plist-get (harness-links-parse (car kill-ring)) :session)))
        ;; A tool call.
        (goto-char (harness-chat-block-start (gethash call harness-chat--blocks)))
        (harness-chat-copy-link)
        (should (equal (harness-links-call-url sid call) (car kill-ring)))
        ;; With a prefix argument, the Markdown link: the start of the message, the call's title.
        (let ((current-prefix-arg '(4)))
          (goto-char (harness-chat-block-start (gethash hello harness-chat--blocks)))
          (harness-chat-copy-link)
          (should (equal (format "[Hello there](%s)" (harness-links-message-url sid hello)) (car kill-ring)))
          (goto-char (harness-chat-block-start (gethash call harness-chat--blocks)))
          (harness-chat-copy-link)
          (should (equal (format "[Bash: ls](%s)" (harness-links-call-url sid call)) (car kill-ring))))
        ;; Where there is no node, the compose box, it is the session's.
        (goto-char harness-compose-end)
        (harness-chat-copy-link)
        (should (equal (harness-links-session-url sid) (car kill-ring)))
        ;; The session's link, and the Markdown one with a prefix argument.
        (setq kill-ring nil)
        (harness-chat-copy-session-link)
        (should (equal (harness-links-session-url sid) (car kill-ring)))
        (let ((current-prefix-arg '(4)))
          (harness-chat-copy-session-link))
        (should (equal (format "[Fix the build](%s)" (harness-links-session-url sid)) (car kill-ring)))
        (should (string-match-p "Copied the Markdown link to the session"
                                (harness-ui-linking-test-messages)))))))

(ert-deftest harness-ui-linking-copies-a-link-only-to-what-the-session-has ()
  "A block that exists in this buffer only is no node, so the link is the session's."
  (harness-ui-linking-test-with
    (let* ((sid (harness-ui-linking-test-session))
           (buf (harness-ui-linking-test-open sid))
           (kill-ring nil))
      (with-current-buffer buf
        (harness-chat--append-local-block "error" "could not do it")
        (goto-char (point-min))
        (search-forward "could not do it")
        (harness-chat-copy-link)
        (should (equal (harness-links-session-url sid) (car kill-ring)))))))

;;;; Off and on

(ert-deftest harness-ui-linking-stops-when-the-module-goes ()
  "Without the module the renderer says it cannot follow a harness link, and
it follows again once the module is on."
  (harness-ui-linking-test-with
    (should (eq #'harness-ui-linking-follow harness-ui-markdown-harness-link-function))
    (should (eq #'harness-ui-linking-describe harness-ui-markdown-link-describe-function))
    (harness-module-disable 'ui-linking)
    (should-not harness-ui-markdown-harness-link-function)
    (should-not harness-ui-markdown-link-describe-function)
    (should-error (harness-ui-markdown-open-link "harness:session/abc") :type 'user-error)
    (setf (harness-module-state (harness-module-get 'ui-linking)) 'registered)
    (harness-module-start 'ui-linking)
    (should (eq #'harness-ui-linking-follow harness-ui-markdown-harness-link-function))
    ;; Handlers other modules registered stay through a restart.
    (let ((harness-ui-linking-handlers (list (cons "thread" #'ignore))))
      (harness-module-start 'ui-linking)
      (should (eq #'ignore (cdr (assoc "thread" harness-ui-linking-handlers))))
      (should (assoc "session" harness-ui-linking-handlers)))))

(provide 'harness-ui-linking-test)
;;; harness-ui-linking-test.el ends here
