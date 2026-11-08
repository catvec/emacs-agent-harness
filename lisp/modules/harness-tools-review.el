;;; harness-tools-review.el --- The review_threads tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's review is a set of threads of comments (harness-patch-review.el).
;; The user writes in them; the task's agent reads them with one tool and
;; answers them in the <thread> blocks of its message.
;;
;; `review_threads' lists the threads of the agent's own task -- or of
;; another task, named by id -- with the comments the user sent: the ids
;; the agent answers by, who wrote what, where in the change it is.  The
;; feedback that sends a task back already carries the threads it is
;; about, so the tool is for what the agent has lost since, a compacted
;; context say.
;;
;; The agent answers in the message itself, as a <thread> block
;; (harness-patch-review.el), the format the task's prompt names: no call
;; is needed to answer, and the harness has no reply tool.  A thread gets
;; as many blocks as the agent has things to say in it, and every one is
;; kept.  A block that names no thread starts one, on the change as a
;; whole; status="closed" closes the thread, status="open" opens it again.
;;
;; Any session can name a task explicitly, so a voice-driven assistant
;; can read and open its review without being the agent working on it.
;; Omitting the task still means the calling session's own task.
;; docs/review-navigation.md is the page for what may be opened, and why
;; the vocabulary is fixed.
;;
;; The user's replies that quote the agent's words are comments in threads
;; of the review too, and the message the agent reads names the thread each
;; is in (harness-patch-review.el): the agent answers it in the block that
;; names the thread.
;;
;; In the chat, runs of calls fold under one summary line, but only the
;; calls of tools on an explicit allow list (`:coalescable', see
;; harness-tools.el), so that a call the user should see stays in view.
;; `review_threads' is on it, with `session_read', `read_file' and the
;; other reads: it lists what is there and changes nothing, so its call
;; joins the run of reads around it instead of cutting that run in two.

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
           (harness-tools-resolve-task named))
          ((and (stringp sid) (harness-method-exists-p 'task/for-session))
           (plist-get (harness-call 'task/for-session sid) :id)))))

(defconst harness-tools-review--no-task
  "This session has no task, so no review to read; name a task with the task argument."
  "What the tool says when there is no task to review.")

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

(harness-define-tool "review_threads"
  :label "Review threads"
  :description "List the threads of comments in the review of your task's work: for each, its id, whether it is open or closed, where in the change it is, a link to it that you can put in a message, and the comments the user sent, with who wrote them. Use it to find the thread to answer when the feedback that sent the task back is no longer in your context: answer in your message with a <thread id=\"...\"><quote>what you answer</quote>your answer</thread> block, and put status=\"closed\" in the tag to close the thread. With status, only the open or only the closed threads; with task, another task's review."
  :schema '(:type "object"
            :properties (:status (:type "string" :enum ("open" "closed")
                                  :description "Only the threads with this status. Default: all.")
                         :task (:type "string"
                                :description "A task id, unique id prefix or exact task name, to read another task's review. Default: your own.")))
  :kind 'meta
  :coalescable t
  :subject (lambda (input) (plist-get input :status))
  :handler #'harness-tools-review--threads)

(defun harness-tools-review--init ()
  "Offer review tools to ordinary sessions as well as task sessions.
A voice-driven request in an ordinary chat can name a task explicitly.
Remove the old task-only filter on reload too."
  (harness-remove-filter 'agent/tools 'harness-tools-review--tools))

(harness-tools-review--init)

(defun harness-tools-review--open (input ctx)
  "Open the review INPUT names in the user's Emacs, for the session of CTX."
  (condition-case err
      (let ((task (harness-tools-review--task-id input ctx)))
        (unless task (user-error "Review task required"))
        (harness-then
         ;; The view refuses after 25 seconds.  Answering it after the tool
         ;; has timed out would report failure while the view still opens.
         (harness-tools-ask-emacs "review_open" (plist-put (copy-sequence input) :task task) 30)
         (lambda (answer) (harness-tool-ok (harness-json-encode-text answer)))
         (lambda (reason) (harness-tool-error (harness-tools-reason reason)))))
    (error (harness-tool-error (harness-error-message err)))))

(harness-define-tool "review_open"
  :label "Review"
  :description "Open a task's review in the user's Emacs: changes (the report and file tree), Ediff with its file tree and threads beside it, or the threads view. Use this when the user asks you to navigate the harness for them, including speech-to-text requests. Name any task by id, unique id prefix or exact name, or omit task for your own. diff selects base (the branch against its merge base), since-review, or git revisions such as main..task/fix or HEAD~2...HEAD. file is an exact repository-relative changed path, including the old name of a renamed file. thread is an id or unique prefix from review_threads; it is expanded and revealed even when closed. Ediff can start at a line on the old or new side; without a file it opens the thread's file or the first comparable file. The result arrives after the view opens and includes its buffer, actual commit ids, files and thread ids. Invalid targets or unavailable UI modules return errors, not success for a different diff. Navigation only: no approvals, feedback submission, permission answers or settings changes. Requires a connected Emacs with the review UI enabled."
  :schema '(:type "object"
            :properties (:task (:type "string" :description "Task id, unique id prefix or exact task name. Default: your task.")
                         :view (:type "string" :enum ("changes" "ediff" "threads")
                                :description "Review surface. Default: changes.")
                         :diff (:type "string" :description "base (default), since-review, or git revisions (A..B, A...B, A B, or A against the task branch).")
                         :file (:type "string" :description "Exact repository-relative changed file, not a file to visit outside the selected diff.")
                         :thread (:type "string" :description "Thread id or unique prefix to reveal and expand.")
                         :line (:type "integer" :minimum 1 :description "Ediff source line, 1-based.")
                         :side (:type "string" :enum ("old" "new") :description "Ediff side for line. Default: new.")
                         :filter (:type "string" :enum ("open" "closed" "all" "unreviewed" "reviewed")
                                  :description "Thread status filter. Default: all; a named thread is always revealed.")))
  :kind 'meta
  :subject (lambda (input) (or (plist-get input :file) (plist-get input :thread)
                               (plist-get input :view) (plist-get input :task)))
  :handler #'harness-tools-review--open)

(harness-define-module 'tools-review
  :doc "Review threads and navigation: read review_threads and answer in <thread> blocks, or open a task's changes, Ediff or threads in the user's Emacs with review_open."
  :requires '(tools session)
  :init #'harness-tools-review--init)

(provide 'harness-tools-review)
;;; harness-tools-review.el ends here
