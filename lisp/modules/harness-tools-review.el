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
;; The tool is offered to task sessions: a session that is no task's has no
;; review (the filter `agent/tools' removes it), unless it names a task.
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
           (plist-get (and (harness-method-exists-p 'task/get)
                           (ignore-errors (harness-call 'task/get named)))
                      :id))
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
                                :description "A task id, to read another task's review. Default: your own.")))
  :kind 'meta
  :coalescable t
  :subject (lambda (input) (plist-get input :status))
  :handler #'harness-tools-review--threads)

(defun harness-tools-review--tools (names session)
  "Drop the review tool from NAMES unless SESSION is a task's.
The catalogue (SESSION nil) keeps every tool."
  (if (and session (not (and (harness-method-exists-p 'task/for-session)
                             (harness-call 'task/for-session (plist-get session :id)))))
      (cl-remove-if (lambda (name) (member name '("review_threads"))) names)
    names))

(defun harness-tools-review--init ()
  "Offer the review tool to task sessions only."
  (harness-add-filter 'agent/tools #'harness-tools-review--tools 50))

(harness-tools-review--init)

(harness-define-module 'tools-review
  :doc "The review_threads tool: a task's agent reads the threads of its review and answers them in <thread> blocks."
  :requires '(tools session)
  :init #'harness-tools-review--init)

(provide 'harness-tools-review)
;;; harness-tools-review.el ends here
