;;; harness-provider-demo.el --- Scripted provider for demos and tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider that never talks to a network.  It replays a script of
;; events with small delays so streaming, tool calls, permissions and
;; markdown rendering can be exercised in a live Emacs without cost.
;; The script is chosen from the last user message:
;;
;;   "tour"        thinking, text, a read_file call, markdown
;;   "tools"       two coalescable tool calls, then a bash call
;;   "work"        a todo list worked through with tool calls (task mode);
;;                 in a worktree it also writes and commits notes/ID.md
;;   "ask"         calls ask_user
;;   anything else echo the prompt back as markdown

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

(defcustom harness-provider-demo-delay 0.03
  "Seconds between scripted events."
  :type 'number :group 'harness)

(defvar harness-provider-demo-script-override nil
  "When non-nil, a list of events used instead of the built-in scripts.")

(defun harness-provider-demo--last-user-text (request)
  (let ((msgs (plist-get request :messages)) text)
    (dolist (m msgs)
      (when (equal (plist-get m :role) 'user)
        (dolist (b (plist-get m :content))
          (when (equal (plist-get b :type) "text") (setq text (plist-get b :text))))))
    (or text "")))

(defun harness-provider-demo--script (request)
  (let ((text (downcase (harness-provider-demo--last-user-text request)))
        (cwd (or (plist-get (plist-get request :session) :cwd) default-directory)))
    (cond
     (harness-provider-demo-script-override harness-provider-demo-script-override)
     ((string-match-p "\\btour\\b" text)
      `((:type thinking :delta "The user wants a tour. ")
        (:type thinking :delta "I will read a file, then summarise.")
        (:type text :delta "Let me look at the project first.\n")
        (:type tool-call :id "demo-1" :name "list_dir" :input (:path ,cwd))
        (:type text :delta "# Tour\n\nThis session runs the **demo** provider. It streams *markdown*, `code`, and tool calls.\n\n")
        (:type text :delta "- streamed text\n- a tool call above\n- a fenced block below\n\n```emacs-lisp\n(defun hello ()\n  (message \"hi\"))\n```\n\n> Quotes render too.\n")
        (:type usage :input 1200 :output 180 :cache-read 800 :cache-write 0 :cost 0.0042 :context 2000)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\btools\\b" text)
      `((:type text :delta "Running a few tools.\n")
        (:type tool-call :id "demo-a" :name "glob" :input (:pattern "*.el" :path ,cwd))
        (:type tool-call :id "demo-b" :name "grep" :input (:pattern "defun" :path ,cwd))
        (:type tool-call :id "demo-c" :name "bash" :input (:command "echo hello from bash"))
        (:type text :delta "Done.")
        (:type usage :input 900 :output 60 :cache-read 0 :cache-write 900 :cost 0.003 :context 1500)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\bwork\\b" text)
      (let ((todos (lambda (&rest statuses)
                     (list :todos (cl-mapcar (lambda (id label status) (list :id id :text label :status status))
                                             '("1" "2" "3")
                                             '("Survey the project" "Make the change" "Check the result")
                                             statuses)))))
        `((:type thinking :delta "A task. I will plan it as todos and work through them.")
          (:type tool-call :id "demo-w1" :name "todo_write" :input ,(funcall todos "in-progress" "pending" "pending"))
          (:type tool-call :id "demo-w2" :name "list_dir" :input (:path ,cwd))
          (:type tool-call :id "demo-w3" :name "todo_write" :input ,(funcall todos "done" "in-progress" "pending"))
          (:type text :delta "Making the change.\n")
          (:type tool-call :id "demo-w4" :name "glob" :input (:pattern "*.el" :path ,cwd))
          ;; In a task's worktree, make and commit a real change, as the task prompt asks.
          ,@(when-let* ((session (plist-get request :session))
                        ((plist-get session :worktree))
                        (name (format "notes/%s.md" (substring (plist-get session :id) 0 8))))
              `((:type tool-call :id "demo-w4a" :name "write_file"
                       :input (:path ,(expand-file-name name cwd) :content ,(format "# %s\n\nDone by the demo agent.\n" text)))
                (:type tool-call :id "demo-w4b" :name "bash"
                       :input (:command ,(format "git add -A && git -c user.name=Demo -c user.email=demo@example.invalid commit -q --no-gpg-sign -m 'Add %s'" name)))))
          (:type tool-call :id "demo-w5" :name "todo_write" :input ,(funcall todos "done" "done" "in-progress"))
          (:type tool-call :id "demo-w6" :name "grep" :input (:pattern "defun" :path ,cwd))
          (:type tool-call :id "demo-w7" :name "todo_write" :input ,(funcall todos "done" "done" "done"))
          (:type text :delta "Done: surveyed the project, made the change and checked it.")
          (:type usage :input 2400 :output 220 :cache-read 1800 :cost 0.006 :context 2600)
          (:type done :stop-reason end-turn))))
     ((string-match-p "\\bask\\b" text)
      `((:type text :delta "I need to check something with you.\n")
        (:type tool-call :id "demo-q" :name "ask_user" :input (:question "Which colour?" :options ("red" "green" "blue")))
        (:type text :delta "Thanks, noted.")
        (:type usage :input 500 :output 40 :cost 0.001 :context 600)
        (:type done :stop-reason end-turn)))
     (t
      `((:type text :delta ,(format "You said: *%s*\n\nThis is the demo provider; try `tour`, `tools` or `ask`." text))
        (:type usage :input 400 :output 30 :cost 0.0008 :context 450)
        (:type done :stop-reason end-turn))))))

(defvar harness-provider-demo--continuations (make-hash-table :test 'equal)
  "Session id -> remaining script after a tool call, resumed on the next request.")

(defun harness-provider-demo--complete (request)
  (let* ((on-event (plist-get request :on-event))
         (sid (or (plist-get (plist-get request :session) :id) "none"))
         (script (harness-provider-demo--script request))
         (cancelled nil)
         (timer nil)
         (steps 0))
    (cl-labels ((step ()
                  (unless cancelled
                    (if (null script)
                        nil
                      (let ((ev (pop script)))
                        (cl-incf steps)
                        (if (eq (plist-get ev :type) 'tool-call)
                            ;; Native loop: emit the call, then stop with tool-use so the
                            ;; agent executes it and calls us again; the rest of the script
                            ;; continues on the next request.
                            (progn
                              (funcall on-event ev)
                              (puthash sid script harness-provider-demo--continuations)
                              (funcall on-event '(:type done :stop-reason tool-use)))
                          (funcall on-event ev)
                          (unless (eq (plist-get ev :type) 'done)
                            (setq timer (run-at-time harness-provider-demo-delay nil #'step)))))))))
      (when (and (gethash sid harness-provider-demo--continuations)
                 (harness-provider-demo--has-tool-results-p request))
        (setq script (gethash sid harness-provider-demo--continuations))
        (remhash sid harness-provider-demo--continuations))
      (funcall on-event '(:type start))
      (setq timer (run-at-time harness-provider-demo-delay nil #'step)))
    (list :cancel (lambda ()
                    (setq cancelled t)
                    (when timer (cancel-timer timer))
                    (funcall on-event '(:type done :stop-reason cancelled))))))

(defun harness-provider-demo--has-tool-results-p (request)
  (let ((last (car (last (plist-get request :messages)))))
    (and last (cl-some (lambda (b) (equal (plist-get b :type) "tool_result"))
                       (plist-get last :content)))))

(harness-define-provider 'demo
  :label "Demo"
  :doc "Scripted provider that never calls a network."
  :models (lambda ()
            (harness-resolved
             (list (list :name "scripted" :label "Demo scripted" :context-window 8000
                         :input-modalities '("text" "image")
                         :pricing '(:input 1.0 :output 2.0 :cache-read 0.1 :cache-write 1.25)
                         :thinking-levels '("low" "high")))))
  :complete #'harness-provider-demo--complete
  :capabilities '(:vision t :thinking t))

(harness-define-module 'provider-demo
  :doc "Scripted provider for demos and tests."
  :requires '(provider))

(provide 'harness-provider-demo)
;;; harness-provider-demo.el ends here
