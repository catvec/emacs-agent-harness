;;; harness-tools-agent.el --- Tools that talk to the user and the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; The "meta" tools: the ones whose effect is on the conversation
;; rather than on files.
;;
;; - `ask_user' blocks the turn on a pending question and resolves when
;;   a UI answers it through `question/answer'.  Its options may each
;;   have a diagram (ASCII art or an image), all of them or none.
;;   `question/ask' asks the same kind of question for the harness
;;   itself, with no tool call behind it (the cowboy module asks what
;;   to do about a cold prompt cache this way).
;; - `plan' records a plan on the session (and adds a Planning section
;;   to the system prompt that explains forks, sub-agents, worktrees
;;   and the merge queue, so plans can use them).
;; - `todo_write' replaces the session's todo list.
;; - `spawn_agent' creates a child session (fresh or forked, optionally
;;   in its own git worktree), runs one prompt in it and returns the
;;   child's final answer.
;; - `session_info' describes the current session to the model.
;;
;; Nothing here waits: every long operation returns a promise, and the
;; continuations of unanswered questions live in a `defvar' so a reload
;; does not lose them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Questions

(defvar harness-tools-agent--questions (make-hash-table :test 'equal)
  "Pending id -> continuation of an unanswered question.
\(:session-id ID :resolve FN) for an ask_user call, whose FN takes the
tool result; (:session-id ID :on-answer FN) for a question the harness
asked itself (`question/ask'), whose FN takes the answer text and
whether it was dismissed.")

(defun harness-tools-agent--pending-item (session-id pid)
  "Return the pending item PID of SESSION-ID, or nil."
  (cl-find pid (harness-call 'session/pending session-id)
           :key (lambda (it) (plist-get it :id)) :test #'equal))

;; An option is a string, or an object with a label and a diagram of the
;; answer: ASCII art (`diagram') or an image file (`image').  Either every
;; option has a diagram or none does, so the UI can show them in one
;; place and flip between them.  The pending question keeps the labels in
;; `:options', as before, and the diagrams in `:diagrams', one per option:
;; (:type "ascii" :text TEXT) or (:type "image" :path PATH :mime MIME).
;; An image travels as its path, never its data: pending items are saved
;; with the session and sent with every change to it.

(defconst harness-tools-agent-image-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("svg" . "image/svg+xml") ("webp" . "image/webp")
    ("bmp" . "image/bmp") ("tif" . "image/tiff") ("tiff" . "image/tiff"))
  "File extensions an ask_user image may have, with their MIME types.")

(defun harness-tools-agent--invalid (format-string &rest args)
  "Reject the ask_user call: its result is the message FORMAT-STRING with ARGS."
  (throw 'harness-tools-agent--invalid (apply #'format format-string args)))

(defun harness-tools-agent--ascii-text (text)
  "Return ASCII diagram TEXT without blank lines or a Markdown fence around it.
The lines in between keep their indentation, which places the drawing."
  (let* ((trim (lambda (lines)
                 (dotimes (_ 2)
                   (while (and lines (string-blank-p (car lines))) (pop lines))
                   (setq lines (nreverse lines)))
                 lines))
         (lines (funcall trim (split-string (string-replace "\r" "" text) "\n"))))
    (when (and (cdr lines)
               (string-prefix-p "```" (string-trim-left (car lines)))
               (string-match-p "\\`[ \t]*```[ \t]*\\'" (car (last lines))))
      (setq lines (funcall trim (butlast (cdr lines)))))
    (mapconcat #'identity lines "\n")))

(defconst harness-tools-agent-image-max-side 8000
  "Most pixels an ask_user image may have on a side.
Emacs draws no image larger than `max-image-size' allows, ten times its
frame by default, however small it would show it; and an image this
large shows so small beside the options that nothing in it can be read.")

(defun harness-tools-agent--image (file n ctx)
  "Return the diagram of option N showing image FILE, relative to CTX's cwd."
  (let* ((path (harness-tools-resolve-path file ctx))
         (mime (cdr (assoc (downcase (or (file-name-extension path) "")) harness-tools-agent-image-types))))
    (cond
     ((not mime)
      (harness-tools-agent--invalid "Option %d: %s is not an image file; use a PNG, JPEG, GIF, SVG or WebP file, or an ASCII diagram"
                                    n file))
     ((not (and (file-regular-p path) (file-readable-p path)))
      (harness-tools-agent--invalid "Option %d: image %s not found (cwd %s)" n file (plist-get ctx :cwd)))
     (t
      (let ((size (harness-image-pixel-size path)))
        (when (and size (> (max (car size) (cdr size)) harness-tools-agent-image-max-side))
          (harness-tools-agent--invalid
           "Option %d: image %s is %dx%d pixels, too large to show; crop it to the part the user should compare, or scale it down, to at most %d pixels on a side (about 600x400 shows best)"
           n file (car size) (cdr size) harness-tools-agent-image-max-side)))
      (list :type "image" :path path :mime mime)))))

(defun harness-tools-agent--option (item n ctx)
  "Return option ITEM, the Nth, of an ask_user call in CTX as (LABEL . DIAGRAM).
ITEM is a string, or an object (a plist) with `:label' and at most one
of `:diagram' (ASCII art) and `:image' (an image file).  DIAGRAM is nil
when ITEM has none."
  (if (stringp item)
      (cons item nil)
    (let* ((label (plist-get item :label))
           (ascii (plist-get item :diagram))
           (ascii (and (stringp ascii) (harness-tools-agent--ascii-text ascii)))
           (ascii (and ascii (not (string-empty-p ascii)) ascii))
           (image (plist-get item :image))
           (image (and (stringp image) (not (string-blank-p image)) (string-trim image))))
      (unless (and (stringp label) (not (string-blank-p label)))
        (harness-tools-agent--invalid "Option %d needs a label: the answer, as a string" n))
      (when (and ascii image)
        (harness-tools-agent--invalid "Option %d has both a diagram and an image; give it one of them" n))
      (cons label (cond (ascii (list :type "ascii" :text ascii))
                        (image (harness-tools-agent--image image n ctx)))))))

(defun harness-tools-agent--numbers (numbers)
  "Return NUMBERS as words: \"2\", \"2 and 3\", \"1, 2 and 4\"."
  (let ((words (mapcar #'number-to-string numbers)))
    (if (cdr words)
        (concat (string-join (butlast words) ", ") " and " (car (last words)))
      (car words))))

(defun harness-tools-agent--options (input ctx)
  "Return (LABELS . DIAGRAMS) for the options of ask_user INPUT in CTX.
DIAGRAMS is nil when no option has one, else a list with one per option.
Items that are neither strings nor objects are left out.  Throws the
message for the model to `harness-tools-agent--invalid' when an option
is malformed, or when only some options have a diagram."
  (let* ((items (cl-remove-if-not (lambda (it) (or (stringp it) (and (consp it) (keywordp (car it)))))
                                  (append (plist-get input :options) nil)))
         (parsed (cl-loop for item in items for n from 1
                          collect (harness-tools-agent--option item n ctx)))
         (missing (cl-loop for option in parsed for n from 1 unless (cdr option) collect n)))
    (when (and missing (< (length missing) (length parsed)))
      (harness-tools-agent--invalid
       "Every option needs a diagram once one has: option%s %s ha%s none. Give each option a diagram or an image, or none of them a diagram"
       (if (cdr missing) "s" "") (harness-tools-agent--numbers missing) (if (cdr missing) "ve" "s")))
    (cons (mapcar #'car parsed)
          (and parsed (not missing) (mapcar #'cdr parsed)))))

(defun harness-tools-agent--ask-user (input ctx)
  "Handler of the ask_user tool: block on a pending question from INPUT in CTX.
A malformed call (see `harness-tools-agent--options') returns an error
saying what to fix, and asks nothing."
  (let* ((sid (plist-get ctx :session-id))
         (question (or (plist-get input :question) ""))
         (free (if (plist-member input :allow_free_text)
                   (harness-json-true-p (plist-get input :allow_free_text))
                 t))
         (parsed (catch 'harness-tools-agent--invalid
                   (harness-tools-agent--options input ctx))))
    (if (stringp parsed)
        (harness-tool-error parsed)
      (harness-with-promise (resolve reject)
        (ignore reject)
        (let ((pid (harness-call 'session/pending-add sid
                                 (list :kind 'question
                                       :payload (append (list :question question :options (car parsed))
                                                        (and (cdr parsed) (list :diagrams (cdr parsed)))
                                                        (list :allow-free-text free
                                                              :call-id (plist-get ctx :call-id)))))))
          (puthash pid (list :session-id sid :resolve resolve) harness-tools-agent--questions)
          (harness-emit 'question/asked sid (harness-tools-agent--pending-item sid pid)))))))

(defun harness-tools-agent--answer-text (answer)
  "Return the answer text from ANSWER, a string or a plist with `:answer'."
  (cond ((stringp answer) answer)
        ((and (listp answer) (plist-get answer :answer)) (format "%s" (plist-get answer :answer)))
        ((null answer) "")
        (t (format "%s" answer))))

(defun harness-tools-agent--settle-question (session-id pid answer &optional dismissed)
  "Resolve pending question PID of SESSION-ID with ANSWER.
DISMISSED non-nil says nobody answered: the question was dismissed.
Return non-nil when a continuation was waiting."
  (let ((entry (gethash pid harness-tools-agent--questions)))
    (harness-call 'session/pending-resolve session-id pid answer)
    (when entry
      (remhash pid harness-tools-agent--questions)
      (if (plist-get entry :on-answer)
          (funcall (plist-get entry :on-answer) (harness-tools-agent--answer-text answer) dismissed)
        (funcall (plist-get entry :resolve) (harness-tool-ok (harness-tools-agent--answer-text answer))))
      (harness-emit 'question/answered session-id pid answer)
      t)))

(harness-defmethod question/answer (session-id pid answer)
  "Answer pending question PID of SESSION-ID with ANSWER.
ANSWER is a string or a plist (:answer STRING).  The waiting ask_user
call returns the text as its result; a question the harness asked
\(`question/ask') gets the text.  Return non-nil when a question was
waiting."
  (harness-tools-agent--settle-question session-id pid answer))

(harness-defmethod question/cancel (session-id pid)
  "Dismiss pending question PID of SESSION-ID.
The waiting ask_user call returns \"The user dismissed the question\";
a question the harness asked (`question/ask') is told it was dismissed."
  (harness-tools-agent--settle-question session-id pid "The user dismissed the question" t))

(harness-defmethod question/ask (session-id request on-answer)
  "Ask the user REQUEST's question in SESSION-ID for the harness; return its id.
This is ask_user's question without a tool call: the harness, not the
model, wants to know something before it goes on.  REQUEST is
\(:question TEXT :options LABELS :allow-free-text BOOL . MORE), as
ask_user's pending payload is; MORE goes into the payload as it is,
for the clients that know what it means (the cowboy module's `:cowboy',
say) -- the others show an ordinary question.  The question is pending
on SESSION-ID, which is blocked on it, and is answered as any other is,
with `question/answer' (UIs, ACP clients) or dismissed with
`question/cancel'.  ON-ANSWER is called once, then, with the answer's
text and a flag that is non-nil when the question was dismissed rather
than answered.  A question still waiting when the harness stops is gone
with the process, as an ask_user call's is."
  (let* ((options (append (plist-get request :options) nil))
         (payload (append (list :question (or (plist-get request :question) "")
                                :options options
                                :allow-free-text (if (plist-member request :allow-free-text)
                                                     (harness-json-true-p (plist-get request :allow-free-text))
                                                   t))
                          (harness-plist-remove request :question :options :allow-free-text)))
         (pid (harness-call 'session/pending-add session-id (list :kind 'question :payload payload))))
    (puthash pid (list :session-id session-id :on-answer on-answer) harness-tools-agent--questions)
    (harness-emit 'question/asked session-id (harness-tools-agent--pending-item session-id pid))
    pid))

(harness-defmethod question/pending (session-id)
  "Return the pending requests of SESSION-ID whose kind is `question'."
  (cl-remove-if-not (lambda (it) (eq (plist-get it :kind) 'question))
                    (harness-call 'session/pending session-id)))

(defconst harness-tools-agent-image-max-bytes (* 16 1024 1024)
  "Largest image file, in bytes, `question/image' sends.")

(harness-defmethod question/image (session-id pid index)
  "Return the image of option INDEX of pending question PID of SESSION-ID.
INDEX counts from 0.  The value is (:mime MIME :data BASE64), the bytes
of the file the option shows, read here, where the harness runs: for a
client that cannot read them itself, such as a UI on another machine,
or one whose session works on a remote host.  Only an image of a
question still waiting is given.  Signal an error when there is none,
or the file cannot be read or is larger than
`harness-tools-agent-image-max-bytes'."
  (let* ((item (harness-tools-agent--pending-item session-id pid))
         (diagrams (and (eq (plist-get item :kind) 'question)
                        (append (plist-get (plist-get item :payload) :diagrams) nil)))
         (diagram (and (natnump index) (nth index diagrams)))
         (path (plist-get diagram :path)))
    (cond
     ((not item) (error "No question %s waits in session %s" pid session-id))
     ((not (and (equal (format "%s" (plist-get diagram :type)) "image") (stringp path)))
      (error "Option %s of question %s shows no image" index pid))
     ((not (and (file-regular-p path) (file-readable-p path)))
      (error "The image %s cannot be read any more" path))
     ((> (or (file-attribute-size (file-attributes path)) 0) harness-tools-agent-image-max-bytes)
      (error "The image %s is larger than %s" path (file-size-human-readable harness-tools-agent-image-max-bytes)))
     (t (list :mime (plist-get diagram :mime)
              :data (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally path)
                      (base64-encode-region (point-min) (point-max) t)
                      (buffer-string)))))))

(harness-define-tool "ask_user"
  :label "Question"
  :description "Ask the user a question and wait for the answer. Use it when only the user can decide (ambiguous requirements, destructive choices, credentials). Offer options when there is a small set of sensible answers; the user may also type a free-form answer unless allow_free_text is false. When the options are easier to tell apart seen than described (layouts, architectures, data flows, UI sketches), give each option a diagram: ASCII art in diagram, or an image file in image. If one option has a diagram, every option must have one; the user flips between them in one place before answering. An image shows what ASCII art cannot, such as a mockup of a page or a chart: write an SVG with write_file, or save a screenshot of a mockup cropped to what differs between the options, in your temporary directory rather than the working directory, so it stays out of the work. Each image is shown at most about 400 pixels high, less in a small window, drawn on white as a browser shows it: draw about 600x400 with large text, and give an SVG a viewBox."
  :schema '(:type "object"
            :properties (:question (:type "string" :description "The question to ask.")
                         ;; Plain objects: the schema reaches every provider
                         ;; as it is, and not all of them may take anyOf.  A
                         ;; string is accepted too, as todo_write does.
                         :options (:type "array"
                                   :items (:type "object"
                                           :properties (:label (:type "string" :description "The answer, as the user reads it and as it is returned when picked.")
                                                        :diagram (:type "string" :description "ASCII diagram of this answer, shown in a fixed-width font.")
                                                        :image (:type "string" :description "Path of an image file (PNG, JPEG, GIF, SVG or WebP) showing this answer, instead of an ASCII diagram, such as an SVG you wrote in your temporary directory. A relative path is taken in the working directory."))
                                           :required ("label"))
                                   :description "Optional list of suggested answers, each with a label and, to compare them by sight, a diagram or an image illustrating it; a plain string is an option without one. If one option has a diagram or image, every option must have one.")
                         :allow_free_text (:type "boolean"
                                           :description "Whether a free-form answer is acceptable (default true)."))
            :required ("question"))
  :kind 'meta
  :timeout 86400
  :subject (lambda (input) (harness-first-line (plist-get input :question) 60))
  :handler #'harness-tools-agent--ask-user)

;;;; Plan

(defconst harness-tools-agent-planning-section
  "## Planning
When a task is complex (several files, several steps, anything you cannot verify in one go), produce a plan with the `plan` tool before changing anything. The plan states the approach, the concrete steps, how the result will be verified, and how the work will be split.

Split work with the mechanisms this harness provides:
- Session forks share the cached context of the current session, so they are much cheaper than a fresh sub-agent that has to gather all the context again. Prefer a fork (spawn_agent with fork=true) when the sub-task needs what you already know.
- spawn_agent starts a fresh sub-agent (fork=false) when the sub-task is self-contained and does not need the current context; it gets its own session and returns its final answer to you.
- Each sub-agent can work in its own git worktree (worktree=true), so independent steps run in parallel worktrees without touching each other's files.
- A merge queue brings a worktree's branch back into the parent session's working directory, one child at a time; conflicts are handed to the child to resolve. Plan independent steps as parallel worktrees that merge back, and dependent steps sequentially in this session.
Keep the plan short and concrete; update the todo list (todo_write) as steps complete."
  "Text appended to the system prompt by the tools-agent module.")

(defun harness-tools-agent--system-prompt (prompt _session)
  "Append the Planning section to PROMPT (the `agent/system-prompt' filter)."
  (concat prompt "\n\n" harness-tools-agent-planning-section "\n"))

(defun harness-tools-agent--plan (input ctx)
  "Handler of the plan tool: record INPUT's plan on the session in CTX."
  (let ((sid (plist-get ctx :session-id))
        (plan (or (plist-get input :plan) ""))
        (title (plist-get input :title)))
    (harness-call 'session/set-plan sid plan)
    (harness-call 'session/append sid (list :kind 'plan :content plan :title title))
    (harness-call 'session/hint sid "Plan updated")
    (harness-tool-ok "Plan recorded. Proceed when the user agrees or continue if they asked you to just do it.")))

(harness-define-tool "plan"
  :label "Plan"
  :description "Record a plan for a complex task before starting it: approach, steps, verification, and how the work is split (forks, sub-agents, worktrees, merges). The plan is shown to the user."
  :schema '(:type "object"
            :properties (:plan (:type "string" :description "The plan in markdown.")
                         :title (:type "string" :description "Optional short title."))
            :required ("plan"))
  :kind 'meta
  :subject (lambda (input) (let ((title (plist-get input :title)))
                             (if (harness-string-blank-p title) (harness-first-line (plist-get input :plan) 60) title)))
  :handler #'harness-tools-agent--plan)

;;;; Todos

(defun harness-tools-agent--todo-status (value)
  "Return VALUE as one of the symbols pending, in-progress or done."
  (let ((s (downcase (format "%s" (or value "pending")))))
    (cond ((member s '("done" "completed" "complete")) 'done)
          ((member s '("in-progress" "in_progress" "in progress" "active" "doing")) 'in-progress)
          (t 'pending))))

(defun harness-tools-agent--normalise-todo (item index)
  "Return todo ITEM (a plist or a string) as (:id :text :status); INDEX numbers it."
  (if (stringp item)
      (list :id (format "t%d" index) :text item :status 'pending)
    (list :id (format "%s" (or (plist-get item :id) (format "t%d" index)))
          :text (or (plist-get item :text) (plist-get item :content) "")
          :status (harness-tools-agent--todo-status (plist-get item :status)))))

(defun harness-tools-agent--render-todos (todos)
  "Return a compact rendering of TODOS with counts."
  (let ((done 0) (active 0) (pending 0))
    (dolist (todo todos)
      (pcase (plist-get todo :status)
        ('done (cl-incf done))
        ('in-progress (cl-incf active))
        (_ (cl-incf pending))))
    (concat
     (mapconcat (lambda (todo)
                  (format "%s %s"
                          (pcase (plist-get todo :status)
                            ('done "[x]") ('in-progress "[~]") (_ "[ ]"))
                          (plist-get todo :text)))
                todos "\n")
     (if todos "\n" "")
     (format "%d todos: %d done, %d in progress, %d pending"
             (length todos) done active pending))))

(defun harness-tools-agent--todo-write (input ctx)
  "Handler of the todo_write tool.
Replace the todos of the session in CTX with those in INPUT."
  (let* ((raw (plist-get input :todos))
         (todos (cl-loop for item in raw for i from 1
                         collect (harness-tools-agent--normalise-todo item i))))
    (harness-call 'session/set-todos (plist-get ctx :session-id) todos)
    (harness-tool-ok (harness-tools-agent--render-todos todos))))

(harness-define-tool "todo_write"
  :label "Todo list"
  :description "Replace the session's todo list. Each item has id, text and status (pending, in-progress or done); plain strings are accepted as pending items. Keep exactly one item in progress at a time and mark items done as soon as they are."
  :schema '(:type "object"
            :properties (:todos (:type "array"
                                 :items (:type "object"
                                         :properties (:id (:type "string")
                                                      :text (:type "string")
                                                      :status (:type "string" :enum ("pending" "in-progress" "done")))
                                         :required ("text"))))
            :required ("todos"))
  :kind 'meta
  :coalescable t
  :subject (lambda (input) (let ((n (length (plist-get input :todos))))
                             (format "%d item%s" n (if (= n 1) "" "s"))))
  :handler #'harness-tools-agent--todo-write)

;;;; Sub-agents

(defvar harness-tools-agent--children (make-hash-table :test 'equal)
  "Child session id -> (:report FN :calls N) while a spawn_agent call runs.")

(defun harness-tools-agent--short-id (id)
  "Return the first eight characters of session ID."
  (substring id 0 (min 8 (length id))))

(defun harness-tools-agent--on-child-tool-call (session-id node)
  "Report the tool call NODE of a running child SESSION-ID to its parent's call."
  (let ((entry (gethash session-id harness-tools-agent--children)))
    (when entry
      (cl-incf (plist-get entry :calls))
      (when (plist-get entry :report)
        (ignore-errors
          (funcall (plist-get entry :report)
                   (format "sub-agent %s: %s" (harness-tools-agent--short-id session-id)
                           (or (plist-get node :title) (plist-get node :tool)))))))))

(defun harness-tools-agent--child-summary (child-id)
  "Return the final text of CHILD-ID plus a footer with its tool calls and cost."
  (let* ((child (harness-call 'session/get child-id))
         (own (cl-remove-if-not (lambda (n) (equal (plist-get n :session) child-id))
                                (harness-call 'session/nodes child-id)))
         (last-assistant (cl-find-if (lambda (n) (eq (plist-get n :kind) 'assistant)) (reverse own)))
         (calls (cl-count-if (lambda (n) (eq (plist-get n :kind) 'tool-call)) own)))
    (format "%s\n\n[sub-agent session: %s, %d tool calls, cost %s]"
            (or (plist-get last-assistant :content) "(the sub-agent produced no answer)")
            child-id calls (harness-format-spend (plist-get child :usage)))))

(defun harness-tools-agent--create-child (parent input child-id cwd worktree call-id)
  "Return a promise of the child session plist for PARENT from INPUT.
CHILD-ID is the id to use, CWD its working directory and WORKTREE
its worktree path (or nil).  CALL-ID is the spawn_agent call's: a fork
copies it among the parent's calls still running, and answers it with
a result saying the fork is the sub-agent it started."
  (let ((fork (harness-json-true-p (plist-get input :fork)))
        (name (plist-get input :name))
        (model (or (plist-get input :model) (plist-get parent :model))))
    (if fork
        (harness-as-promise
         (harness-call 'session/fork (plist-get parent :id)
                       :id child-id :kind 'subagent :name name :model model
                       :cwd cwd :worktree worktree :call-id call-id))
      (harness-as-promise
       (harness-call 'session/create
                     :id child-id :cwd cwd :worktree worktree :kind 'subagent
                     :parent-id (plist-get parent :id) :name name :model model
                     :host (plist-get parent :host)
                     :permission-mode (plist-get parent :permission-mode)
                     :thinking (plist-get parent :thinking)
                     ;; Off too, not left to the setting.
                     :non-interactive (if (harness-json-true-p (plist-get parent :non-interactive)) t :false))))))

(defun harness-tools-agent--spawn (input ctx)
  "Handler of the spawn_agent tool.
Run INPUT's prompt in a child of the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (parent (harness-call 'session/get sid))
         (prompt (or (plist-get input :prompt) ""))
         (child-id (harness-uuid))
         (want-worktree (and (harness-json-true-p (plist-get input :worktree))
                             (harness-method-exists-p 'worktree/create)))
         (cwd (or (plist-get input :cwd) (plist-get parent :cwd))))
    (when (string-empty-p (string-trim prompt))
      (signal 'harness-error (list "spawn_agent needs a prompt")))
    (harness-then
     (if want-worktree
         (harness-then
          (harness-call 'worktree/create (or (plist-get parent :project) (plist-get parent :cwd))
                        :branch (concat "harness/" (harness-tools-agent--short-id child-id)))
          (lambda (wt) (plist-get wt :path)))
       (harness-resolved nil))
     (lambda (worktree)
       (harness-then
        (harness-tools-agent--create-child parent input child-id (or worktree cwd) worktree
                                           (plist-get ctx :call-id))
        (lambda (child)
          (let ((cid (plist-get child :id)))
            (puthash cid (list :report (plist-get ctx :report) :calls 0) harness-tools-agent--children)
            (harness-emit 'agent/spawned sid cid)
            (when (plist-get ctx :report)
              (funcall (plist-get ctx :report)
                       (format "sub-agent %s started%s" (harness-tools-agent--short-id cid)
                               (if worktree (format " in worktree %s" (abbreviate-file-name worktree)) ""))))
            (harness-then
             ;; The parent's agent wrote the prompt, not the user.
             (harness-call-async 'agent/prompt cid prompt (list :from (harness-sender-session parent)))
             (lambda (result)
               (remhash cid harness-tools-agent--children)
               (let ((text (harness-tools-agent--child-summary cid)))
                 (if (memq (plist-get result :stop-reason) '(end-turn max-tokens))
                     (harness-tool-ok text :meta (list :child-id cid))
                   (harness-tool-error
                    (format "%s\n\n(sub-agent stopped: %s%s)" text (plist-get result :stop-reason)
                            (if (plist-get result :error) (format ", %s" (plist-get result :error)) ""))
                    :meta (list :child-id cid)))))
             (lambda (err)
               (remhash cid harness-tools-agent--children)
               (signal 'harness-error (list (harness-error-message err))))))))))))

(harness-define-tool "spawn_agent"
  :label "Sub-agent"
  :description "Run a sub-agent on a prompt and return its final answer. fork=true forks this session (the child shares your context and its cached prefix; cheaper when the task needs what you already know); fork=false starts a fresh session with only the prompt. worktree=true gives the child its own git worktree and branch so it can change files in parallel; merge its branch back afterwards through the merge queue. The call returns when the child finishes."
  :schema '(:type "object"
            :properties (:prompt (:type "string" :description "The task for the sub-agent.")
                         :fork (:type "boolean" :description "Fork this session instead of starting fresh (default false).")
                         :model (:type "string" :description "Model id for the child (default: this session's model).")
                         :name (:type "string" :description "Display name for the child session.")
                         :cwd (:type "string" :description "Working directory for the child (default: this session's), inside this session's allowed directories.")
                         :worktree (:type "boolean" :description "Create a git worktree and branch for the child (default false)."))
            :required ("prompt"))
  :kind 'meta
  ;; The child works where it starts: the jail checks that like bash's cwd.
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :timeout 3600
  :subject (lambda (input) (format "%s%s"
                                   (or (plist-get input :name) (harness-first-line (plist-get input :prompt) 50))
                                   (if (harness-json-true-p (plist-get input :fork)) " (fork)" "")))
  :handler #'harness-tools-agent--spawn)

;;;; Session info

(defun harness-tools-agent--window-text (window)
  "Describe the quota WINDOW plist in a few words."
  (let ((used (round (* 100 (or (plist-get window :used) 0))))
        (resets (plist-get window :resets)))
    (concat (format "%s %d%% used" (or (plist-get window :label) (plist-get window :name)) used)
            (if (numberp resets) (format-time-string " (resets %a %H:%M)" resets) ""))))

(defun harness-tools-agent--quota-line (session-id)
  "Return a line with the plan quota last reported to SESSION-ID, or \"\"."
  (let ((windows (ignore-errors (harness-call 'session/runtime session-id :quota :get))))
    (if windows
        (format "Plan quota: %s\n" (mapconcat #'harness-tools-agent--window-text windows "; "))
      "")))

(defun harness-tools-agent--session-info (_input ctx)
  "Handler of the session_info tool: describe the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (s (harness-call 'session/get sid))
         (u (plist-get s :usage))
         (children (harness-call 'session/list (list :parent-id sid))))
    (harness-tool-ok
     (concat
      (format "Session: %s\nName: %s\nKind: %s\nModel: %s\nWorking directory: %s\nWorktree: %s\nTemporary directory: %s\nPermission mode: %s\nNon-interactive: %s\nStatus: %s\n"
              sid (or (plist-get s :name) "(unnamed)") (plist-get s :kind) (plist-get s :model)
              (plist-get s :cwd) (or (plist-get s :worktree) "none")
              (or (ignore-errors (harness-call 'session/tmp-dir sid)) "none")
              (plist-get s :permission-mode)
              (if (harness-json-true-p (plist-get s :non-interactive))
                  "on (the user is away: the auto-mode judge decides what would ask them for permission)"
                "off")
              (plist-get s :status))
      (format "Usage: %s input, %s output, %s cache read, cost %s, %d turns, context %s of %s\n"
              (harness-format-tokens (plist-get u :input)) (harness-format-tokens (plist-get u :output))
              (harness-format-tokens (plist-get u :cache-read)) (harness-format-spend u)
              (or (plist-get u :turns) 0) (harness-format-tokens (plist-get u :context))
              (harness-format-tokens (plist-get s :context-window)))
      (harness-tools-agent--quota-line sid)
      (format "Parent: %s\n" (or (plist-get s :parent-id) "none"))
      (format "Children: %s"
              (if children
                  (mapconcat (lambda (c) (format "%s (%s, %s)" (plist-get c :id) (plist-get c :kind) (plist-get c :status)))
                             children ", ")
                "none"))))))

(harness-define-tool "session_info"
  :label "Session info"
  :description "Describe the current session: id, name, model, working directory, temporary directory, permission mode, non-interactive mode, status, usage and related sessions."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :subject #'ignore
  :handler #'harness-tools-agent--session-info)

;;;; Registration

(defun harness-tools-agent--init ()
  "Register the module's filter and subscriber (idempotent)."
  (harness-add-filter 'agent/system-prompt #'harness-tools-agent--system-prompt 40)
  (harness-on 'agent/tool-call #'harness-tools-agent--on-child-tool-call))

(harness-tools-agent--init)

(harness-declare-event 'question/asked "(SESSION-ID PENDING) after ask_user or `question/ask' added a pending question.")
(harness-declare-event 'question/answered "(SESSION-ID PENDING-ID ANSWER) after a question was answered or dismissed.")
(harness-declare-event 'agent/spawned "(PARENT-ID CHILD-ID) after spawn_agent created a child session.")

(harness-define-module 'tools-agent
  :doc "Question, Plan, Todo list, Sub-agent and Session info tools."
  :requires '(tools session agent)
  :init #'harness-tools-agent--init)

(provide 'harness-tools-agent)
;;; harness-tools-agent.el ends here
