;;; harness-tools-review.el --- The review_threads and review_comment tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's review is a set of threads of comments (harness-patch-review.el).
;; The user writes in them; the task's agent reads and answers them with
;; two tools.
;;
;; `review_threads' lists the threads of the agent's own task -- or of
;; another task, named by id -- with the comments the user sent: the ids
;; the agent answers by, who wrote what, where in the change it is.  The
;; feedback that sends a task back already carries the threads it is
;; about, so the tool is for what the agent has lost since, a compacted
;; context say.
;;
;; `review_comment' adds a comment of the agent's to a thread, and may
;; close the thread or open it again; a thread it closes waits for the
;; user to review it, so its answer says what changed and where.  The
;; comment records the agent, the session and this very tool call, so
;; that whoever reads the thread can follow it to the point of the
;; conversation it came from, and the commit the agent was at, so that a
;; reply that says "fixed" says where.  With no thread it starts one, on
;; the change as a whole, or on a file and line of it.
;;
;; Both are offered to task sessions: a session that is no task's has no
;; review (the filter `agent/tools' removes them), unless it names a task.
;;
;; In the chat, runs of calls fold under one summary line, but only the
;; calls of tools on an explicit allow list (`:coalescable', see
;; harness-tools.el), so that a call the user should see stays in view.
;; `review_threads' is on it, with `session_read', `read_file' and the
;; other reads: it lists what is there and changes nothing, so its call
;; joins the run of reads around it instead of cutting that run in two.
;; `review_comment' is not: it writes what the user reads next, and its
;; call stays in view.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defun harness-tools-review--task-id (input ctx)
  "Return the id of the task the call with INPUT in CTX is about, or nil.
That is the task INPUT names, else the task of the calling session."
  (let ((named (plist-get input :task))
        (sid (plist-get ctx :session-id)))
    (cond ((and (stringp named) (not (string-blank-p named)))
           (plist-get (and (harness-method-exists-p 'task/get)
                           (ignore-errors (harness-call 'task/get named)))
                      :id))
          ((and (stringp sid) (harness-method-exists-p 'task/for-session))
           (plist-get (harness-call 'task/for-session sid) :id)))))

(defun harness-tools-review--head (ctx)
  "Return a promise of the commit the calling session is at, or nil."
  (let ((cwd (plist-get ctx :cwd)))
    (if (and (stringp cwd) (not (file-remote-p cwd)) (file-directory-p cwd))
        (harness-then
         (harness-run-command '("git" "--no-pager" "rev-parse" "--verify" "--quiet" "HEAD^{commit}")
                              :cwd cwd :timeout 20 :name "review-comment-head"
                              :env '(("GIT_OPTIONAL_LOCKS" . "0")))
         (lambda (result)
           (let ((out (string-trim (or (plist-get result :stdout) ""))))
             (and (eql (plist-get result :exit) 0) (string-match-p "\\`[0-9a-f]\\{7,64\\}\\'" out) out)))
         (lambda (_) nil))
      (harness-resolved nil))))

(defconst harness-tools-review--no-task
  "This session has no task, so no review to read or answer; name a task with the task argument."
  "What the tools say when there is no task to review.")

(defun harness-tools-review--threads (input ctx)
  "Handler of review_threads: list the threads of the task INPUT and CTX name."
  (let ((id (harness-tools-review--task-id input ctx))
        (status (let ((value (plist-get input :status)))
                  (and (stringp value) (member value '("open" "closed")) value))))
    (cond
     ((null id) (harness-tool-error harness-tools-review--no-task))
     ((not (harness-method-exists-p 'patch-review/threads-text))
      (harness-tool-error "Reviews with threads are not enabled in this harness (the patch-review module)."))
     (t (harness-tool-ok (harness-call 'patch-review/threads-text id status))))))

(defun harness-tools-review--comment (input ctx)
  "Handler of review_comment: add the agent's comment INPUT says, in CTX's session.
The links in the comment are written out in full first
\(`harness-tools-written'): the reviewer follows them from the thread,
not from the session the comment was written in."
  (let* ((id (harness-tools-review--task-id input ctx))
         (written (harness-tools-written (plist-get input :body) ctx))
         (body (car written)))
    (cond
     ((null id) (harness-tool-error harness-tools-review--no-task))
     ((not (harness-method-exists-p 'patch-review/comment))
      (harness-tool-error "Reviews with threads are not enabled in this harness (the patch-review module)."))
     (t
      (harness-then
       (harness-tools-review--head ctx)
       (lambda (head)
         (condition-case err
             (let* ((result (harness-call 'patch-review/comment id body
                                          :thread (plist-get input :thread)
                                          :status (plist-get input :status)
                                          :file (plist-get input :file)
                                          :line (plist-get input :line)
                                          :side (plist-get input :side)
                                          :session (plist-get ctx :session-id)
                                          :call-id (plist-get ctx :call-id)
                                          :revision head))
                    (comment (plist-get result :comment)))
               (harness-tool-ok
                (harness-tools-with-note
                 (format "%s thread %s, which is now %s."
                         (if comment
                             (format "Added comment %s to%s" (plist-get comment :id)
                                     (if (plist-get input :thread) "" " the new"))
                           "Changed")
                         (plist-get result :thread) (plist-get result :status))
                 (cdr written))))
           (harness-error (harness-tool-error (harness-error-message err))))))))))

(harness-define-tool "review_threads"
  :label "Review threads"
  :description "List the threads of comments in the review of your task's work: for each, its id, whether it is open or closed, where in the change it is, a link to it that you can put in a message, and the comments the user sent, with who wrote them. Use it to find the thread to answer with review_comment when the feedback that sent the task back is no longer in your context. With status, only the open or only the closed threads; with task, another task's review."
  :schema '(:type "object"
            :properties (:status (:type "string" :enum ("open" "closed")
                                  :description "Only the threads with this status. Default: all.")
                         :task (:type "string"
                                :description "A task id, to read another task's review. Default: your own.")))
  :kind 'meta
  :coalescable t
  :subject (lambda (input) (plist-get input :status))
  :handler #'harness-tools-review--threads)

(harness-define-tool "review_comment"
  :label "Review comment"
  :description "Answer a thread of the review of your work, or start one. The thread id is given in the feedback after \"[thread ...]\", and review_threads lists them. Write what you did or why you disagree, briefly, in Markdown: the review draws it rendered, so name code in `backquotes`, put lines of code in a fenced block and steps in a list; the user looks at every thread you close, so when you close one say what you changed and where. Close the thread (status closed) once what it raises is done; leave it open when it is not, or when you want the user's answer, and never close a thread you only argued against. Without thread a new thread starts: on the change as a whole, or on file and line of it, to explain something to the user where they will read the diff. The comment records this call, so the user can follow it back to this point of the conversation. Link what you mean in it, the tool call that proves a fix or the message you answer: [the test run](harness:call/bash#1). With thread and status but no body, only the status changes."
  :schema '(:type "object"
            :properties (:thread (:type "string"
                                  :description "The id of the thread to answer, or the start of it when unique. Omit to start a new thread.")
                         :body (:type "string"
                                :description "Your comment, in Markdown. Optional only when changing a thread's status.")
                         :status (:type "string" :enum ("open" "closed")
                                  :description "Set the thread's status after the comment: closed when it is done.")
                         :file (:type "string"
                                :description "For a new thread: the path of the file it is about.")
                         :line (:type "integer"
                                :description "For a new thread: the line of that file, as in the file after your change (the file before it with side old).")
                         :side (:type "string" :enum ("new" "old")
                                :description "For a new thread: new, the default, or old for a line of the file before your change.")
                         :task (:type "string"
                                :description "A task id, to comment in another task's review. Default: your own.")))
  :kind 'meta
  :subject (lambda (input) (harness-first-line (or (plist-get input :body) (plist-get input :status) "") 60))
  :handler #'harness-tools-review--comment)

(defun harness-tools-review--tools (names session)
  "Drop the review tools from NAMES unless SESSION is a task's.
The catalogue (SESSION nil) keeps every tool."
  (if (and session (not (and (harness-method-exists-p 'task/for-session)
                             (harness-call 'task/for-session (plist-get session :id)))))
      (cl-remove-if (lambda (name) (member name '("review_threads" "review_comment"))) names)
    names))

(defun harness-tools-review--init ()
  "Offer the review tools to task sessions only."
  (harness-add-filter 'agent/tools #'harness-tools-review--tools 50))

(harness-tools-review--init)

(harness-define-module 'tools-review
  :doc "The review_threads and review_comment tools: a task's agent reads and answers the threads of its review."
  :requires '(tools session)
  :init #'harness-tools-review--init)

(provide 'harness-tools-review)
;;; harness-tools-review.el ends here
