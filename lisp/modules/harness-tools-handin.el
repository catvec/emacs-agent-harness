;;; harness-tools-handin.el --- The hand_in tool: finish a task and stop  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task session that is sure its work is done says so with `hand_in'
;; instead of just stopping: the tool records the final summary and the
;; evidence for it, and ends the turn as if the model had finished --
;; the review step then puts the task in front of the user as usual
;; (`agent/turn-ended' with `end-turn').  It is the reverse of plan
;; mode: where `plan' stops before the work to agree on it, `hand_in'
;; stops after it to hand it over.
;;
;; The problem statement is required too, and an optional reproduction
;; note: a short summary of what must be fixed and how to see it, which
;; the review shows at the top, so the user remembers what a task was
;; about when its name alone does not say.  The resolved report rides
;; the tool result's `:meta', so the transcript can draw the same review
;; after the task left review.
;;
;; Evidence is required, and at least one item; the tool description
;; tells the model that an image or a video is required whenever the
;; work has anything to show, and that a claim about a command (the
;; tests pass) belongs there as a reference to the tool call that made
;; it.  A call is named by its call id, its node id, the name of its
;; tool, or the `#N' handle the error on a miss lists -- the model
;; never sees its own call ids, so the name and handle make the common
;; case work on the first try.  Referenced calls are copied into the
;; report as a snapshot -- title, input, output, error flag -- so the
;; task view can show them as the link they are without re-reading the
;; session, and the file keeps them.
;;
;; The tool also takes two optional flags.  `cannot_continue' is for a
;; task that cannot be finished: it goes to the user's input instead of
;; review, nothing merges, evidence may be empty, and the refusal while
;; a sub-agent's merge is pending does not apply.  `no_merge' is for
;; work that needs no merge -- an informational task, or one that
;; changed nothing -- and verifying it completes it without the merge
;; queue.
;;
;; `merge_base' is how the task itself says where its work belongs: a
;; local branch, when the work is not made from the branch it belongs
;; on.  The task, not the user, is the one that knows -- it has read the
;; project -- so nothing of the board or of `task_submit' sets a base.
;; The task's default base is the branch checked out where it was
;; submitted (`harness-tasks--make-worktree'), and it names this only to
;; go elsewhere.  The branch is checked before the report is recorded:
;; one the project does not have, or the task's own branch, refuses the
;; hand-in and lists what it could name, so a typo does not merge the
;; work into nowhere.  A branch that is there becomes the task's
;; `:base': what the review reads its changes against and what
;; verifying merges them into (`task/hand-in').
;;
;; The tool is offered to task sessions only: the filter `agent/tools'
;; removes it where there is no task to hand the work in to.
;;
;; `hand_in' is what ends the working phase: until it is called, a turn
;; that ends with a reply is the agent talking to the user, and the task
;; stays at work (`harness-tasks-working-phase').  The phase is for what
;; is still owed, not a checkpoint before handing in, and the purpose is
;; to work with the user until they are satisfied, not to reach hand_in:
;; the tool's description and the task's prompt tell the agent to hand
;; in at once when nothing is outstanding, never to ask first whether
;; the work is ready to hand in, and never to close the review's threads
;; to get past the check.  A module can keep a hand-in from being made
;; at all while the work is not done, through
;; `harness-tools-handin-block-functions': each function is called with
;; the task before the report is recorded, and the first that returns
;; text refuses the hand-in with it.  The review adds the check that
;; every open thread of the review is answered and closed
;; (`harness-tools-handin-require-closed-threads', on by default); with
;; the module not loaded, or the option off, there is no such check.
;;
;; A project can hold a hand-in to checks of its own.  Before the report is
;; recorded, the asynchronous filter `task/before-hand-in' runs from nil
;; (see `harness-run-filter-async') with the task and the plist of its
;; session.  A function that refuses passes on the text that says why and
;; what to do first, after what an earlier function refused with, a blank
;; line between; the hand-in is then answered with that text, as an
;; error, and nothing is recorded.  A function with nothing to say hands
;; on the value it was given.  One that signals, or whose promise is
;; rejected, refuses nothing: a check that cannot be made is not a
;; reason to keep a task's work from the user.  A hand-in that says it
;; cannot continue, or that has nothing to merge, is not put to the
;; filter.  Nothing here knows of any project.  What a project asks of
;; its tasks is the project's: the harness's own repository asks that its
;; Flutter app was built, from its plugin
;; (.harness/plugins/dev/harness-client-check.el), which asks only the
;; sessions that use that plugin.
;;
;; Handing in ends the turn before its provider has said what the turn
;; used.  A hosted loop (Claude Code) reports that -- tokens, cost, the
;; size of the conversation and when its last request used the prompt
;; cache -- in the message that closes the turn, after the harness cancelled
;; it as the tool ended the turn; the agent takes that usage all the same
;; (`harness-agent--late-event'), so a task in review has its cost and its
;; prompt cache, and its chat says when that lapsed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defcustom harness-tools-handin-require-closed-threads t
  "When non-nil, an open review thread refuses a hand-in.
A thread of the task's review that has a sent comment and is still open
is a question the work has not answered: hand_in refuses, naming the
threads, until they are answered and closed.  They are the user's
questions, not a check to get past: a thread is closed when its point is
done, never in a batch to hand in.  The check is added by the module that
keeps the threads, so a harness without it gates nothing either way.
Off, hand_in takes the work even with open threads, and the reviewer
closes them or sends the task back."
  :type 'boolean :group 'harness)

(defvar harness-tools-handin-block-functions nil
  "Functions that can refuse a hand-in before its report is recorded.
Each is called with the TASK the hand-in is for, from nil, and returns
nil to let it through, or a string saying what must be done first.  The
first text refuses the hand-in; it is the error the agent reads.  A
function that signals refuses nothing.  A module adds its check here --
the review does, for open threads -- so a harness without that module
has no such check.")

(defun harness-tools-handin--blocked (task)
  "Return the text that refuses TASK's hand-in, or nil when none does.
Runs `harness-tools-handin-block-functions' in order and returns the
first text a function gives.  A function that signals is logged and
refuses nothing: a check that cannot be made is no reason to keep the
work from the user."
  (catch 'refused
    (dolist (function harness-tools-handin-block-functions)
      (condition-case err
          (when-let* ((text (funcall function task)))
            (throw 'refused text))
        (error (harness-log 'warn "hand_in: a block function of the harness failed: %s"
                            (harness-error-message err)))))
    nil))

(defvar harness-tools-handin--max-input 800
  "Characters of a referenced tool call's input the report keeps.")
(defvar harness-tools-handin--max-output 1500
  "Characters of a referenced tool call's output the report keeps.")

(defconst harness-tools-handin-image-types
  '("png" "jpg" "jpeg" "gif" "svg" "webp" "bmp" "tif" "tiff")
  "File extensions an image evidence may have.")

(defconst harness-tools-handin-video-types
  '("mp4" "webm" "mov" "mkv" "avi" "m4v" "ogv")
  "File extensions a video evidence may have.")

(defconst harness-tools-handin-design-limit 120000
  "Characters of a design document a report keeps.")

(defconst harness-tools-handin-demo-narration-limit 8000
  "Characters of a demo's narration a report keeps.")

(defconst harness-tools-handin-demo-command-args 20
  "Most arguments a demo command may have.")

(defconst harness-tools-handin-walkthrough-limit 24000
  "Characters of the presenter brief a report keeps.")

(defun harness-tools-handin--invalid (format-string &rest args)
  "Return the error result for a malformed call.
Its message is FORMAT-STRING formatted with ARGS, as by `format'."
  (harness-tool-error (apply #'format format-string args)))

(defun harness-tools-handin--session-plist (sid)
  "Return the session plist of SID, or a minimal stand-in."
  (or (and (harness-method-exists-p 'session/get) (harness-call 'session/get sid))
      (list :id sid :cwd (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-tools-handin--roots (session)
  "Return the directories evidence files may lie in for SESSION."
  (if (fboundp 'harness-perms-roots)
      (harness-perms-roots session)
    (delq nil (list (plist-get session :cwd) (plist-get session :worktree)))))

(defun harness-tools-handin--within-p (session path)
  "Non-nil when PATH lies in one of SESSION's directories."
  (let ((within (lambda (root)
                  (if (fboundp 'harness-perms--within-p)
                      (harness-perms--within-p root path)
                    (harness-path-within-p root path)))))
    (cl-some within (harness-tools-handin--roots session))))

(defun harness-tools-handin--file (raw kind number ctx)
  "Return the evidence plist for file RAW of KIND, the NUMBERth item, in CTX.
KIND is \"image\", \"video\" or \"file\".  The file must exist,
be readable, and lie inside the session's allowed directories; an image
or video must have an extension of its kind.  Return an error string
when it is none of that."
  (let* ((path (harness-tools-resolve-path raw ctx))
         (extension (downcase (or (file-name-extension path) "")))
         (session (harness-tools-handin--session-plist (plist-get ctx :session-id))))
    (cond
     ((not (file-regular-p path))
      (format "Evidence %d: %s not found (cwd %s)" number raw (plist-get ctx :cwd)))
     ((not (file-readable-p path))
      (format "Evidence %d: %s is not readable" number raw))
     ((not (harness-tools-handin--within-p session path))
      (format "Evidence %d: %s lies outside the directories this session may use" number raw))
     ((and (equal kind "image") (not (member extension harness-tools-handin-image-types)))
      (format "Evidence %d: %s is not an image (PNG, JPEG, GIF, SVG or WebP)" number raw))
     ((and (equal kind "video") (not (member extension harness-tools-handin-video-types)))
      (format "Evidence %d: %s is not a video (MP4, WebM, MOV or the like)" number raw))
     (t (list :kind kind :path path :extension extension)))))

(defun harness-tools-handin--relative-name (session path)
  "Return PATH as the session's directory shows it.
A path outside every directory of SESSION is its own name, so a report
never claims a file of the project that is not one."
  (let ((cwd (plist-get session :cwd)))
    (if (and cwd (harness-path-within-p cwd path))
        (directory-file-name (file-relative-name path cwd))
      (file-name-nondirectory path))))

(defun harness-tools-handin--read-text (path)
  "Return the UTF-8 text of the file at PATH."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents path))
    (buffer-string)))

(defun harness-tools-handin--first-heading (text)
  "Return the first Markdown heading of TEXT, or nil."
  (when (string-match "^#+[ \t]+\\(.+?\\)[ \t]*\r?$" text)
    (string-trim (match-string 1 text))))

(defun harness-tools-handin--design (value ctx)
  "Return the report's design document for VALUE, or an error string.
VALUE is a path or an object with `:path', and optional `:title' and
`:summary'.  The document is read at hand-in time and kept whole in the
report, so the review reads what the task explained and not whatever
the file says after the branch moved.  The path must lie in one of the
session's directories."
  (cond
   ((null value) nil)
   ((not (or (stringp value) (listp value)))
    "design is neither a path nor an object")
   (t
    (let* ((object (if (stringp value) (list :path value) value))
           (raw (harness-tools-handin--clean (plist-get object :path)))
           (given-title (harness-tools-handin--clean (plist-get object :title)))
           (given-summary (harness-tools-handin--clean (plist-get object :summary)))
           (session (harness-tools-handin--session-plist (plist-get ctx :session-id)))
           (path (and raw (harness-tools-resolve-path raw ctx))))
      (cond
       ((not raw)
        "design needs path: the Markdown document that explains the design")
       ((not (file-regular-p path))
        (format "design: %s not found" raw))
       ((not (file-readable-p path))
        (format "design: %s is not readable" raw))
       ((not (harness-tools-handin--within-p session path))
        (format "design: %s lies outside the directories this session may use" raw))
       ((> (or (file-attribute-size (file-attributes path)) 0)
           harness-tools-handin-design-limit)
        (format "design: %s is longer than %d characters; keep the design document to the design"
                raw harness-tools-handin-design-limit))
       (t
        (let ((text (harness-tools-handin--read-text path)))
          (cond
           ((harness-string-blank-p text)
            (format "design: %s is empty" raw))
           ((string-search "\0" text)
            (format "design: %s is not a text document" raw))
           (t
            (list :title (or given-title
                             (harness-tools-handin--first-heading text)
                             (file-name-base path))
                  :path path
                  :name (harness-tools-handin--relative-name session path)
                  :summary (and given-summary
                                (harness-truncate-end given-summary 4000))
                  :text (harness-truncate-end text harness-tools-handin-design-limit)))))))))))

(defun harness-tools-handin--demo-command (value)
  "Return VALUE as a demo command list, or an error string."
  (let ((command (and (or (listp value) (vectorp value)) (append value nil))))
    (cond
     ((not command) "demo command is not a list of arguments")
     ((> (length command) harness-tools-handin-demo-command-args)
      (format "demo command has more than %d arguments" harness-tools-handin-demo-command-args))
     ((cl-some (lambda (arg) (not (and (stringp arg) (not (string-empty-p arg)))))
               command)
      "demo command has an argument that is not a non-empty string")
     (t command))))

(defun harness-tools-handin--demo (value number ctx)
  "Return the report's demo evidence for VALUE, the NUMBERth item, or an error.
VALUE is a path or an object with `:path', `:url', `:command', `:cwd',
`:title', `:narration' and `:workspace'.  It names at least one of the
three ways to show the demo -- the file, the URL, the command -- and
every path must lie in one of the session's directories.  `:workspace'
binds the demo to a workspace whose computer runs it; without one the
demo runs where the harness does.  Nothing runs at hand-in time: running
the demo is the reviewer's action, confirmed then."
  (let ((object (cond ((stringp value) (list :path value))
                      ((listp value) value)
                      (t nil))))
    (if (not object)
        (format "Evidence %d: demo is neither a path nor an object" number)
      (let* ((raw-path (harness-tools-handin--clean (plist-get object :path)))
             (raw-url (harness-tools-handin--clean (plist-get object :url)))
             (raw-cwd (harness-tools-handin--clean (plist-get object :cwd)))
             (narration (harness-tools-handin--clean (plist-get object :narration)))
             (given-title (harness-tools-handin--clean (plist-get object :title)))
             (workspace (harness-tools-handin--clean (plist-get object :workspace)))
             (session (harness-tools-handin--session-plist (plist-get ctx :session-id)))
             (path (and raw-path (harness-tools-resolve-path raw-path ctx)))
             (command (and (plist-get object :command)
                           (harness-tools-handin--demo-command (plist-get object :command))))
             (cwd (and raw-cwd (harness-tools-resolve-path raw-cwd ctx)))
             (default-cwd (cond ((and path (file-directory-p path)) path)
                                ((and path (file-regular-p path)) (file-name-directory path))
                                (t (plist-get session :cwd)))))
        (cond
         ((and (null raw-path) (null raw-url) (null (plist-get object :command)))
          (format "Evidence %d: demo needs a path, a url or a command" number))
         ((and raw-path (not (file-exists-p path)))
          (format "Evidence %d: demo %s not found" number raw-path))
         ((and raw-path (not (harness-tools-handin--within-p session path)))
          (format "Evidence %d: demo %s lies outside the directories this session may use"
                  number raw-path))
         ((and raw-url (not (string-match-p "\\`https?://[^ \t\n]+\\'" raw-url)))
          (format "Evidence %d: demo url %s is not an http or https URL" number raw-url))
         ((stringp command) (format "Evidence %d: %s" number command))
         ((and raw-cwd (not (file-directory-p cwd)))
          (format "Evidence %d: demo cwd %s is not a directory" number raw-cwd))
         ((and raw-cwd (not (harness-tools-handin--within-p session cwd)))
          (format "Evidence %d: demo cwd %s lies outside the directories this session may use"
                  number raw-cwd))
         (t
          (list :kind "demo"
                :title (or given-title
                           (cond (path (file-name-base path))
                                 (raw-url (harness-truncate-end
                                           (replace-regexp-in-string "\\`https?://" "" raw-url)
                                           80))
                                 (t (file-name-nondirectory (car command)))))
                :path path
                :name (and path (harness-tools-handin--relative-name session path))
                :url raw-url
                :command command
                :cwd (or cwd default-cwd)
                :cwd-name (and (or cwd default-cwd)
                               (harness-tools-handin--relative-name
                                session (or cwd default-cwd)))
                :workspace workspace
                :narration (and narration
                                (harness-truncate-end
                                 narration harness-tools-handin-demo-narration-limit)))))))))


(defun harness-tools-handin--tool-name (node)
  "Return the tool name of call node NODE."
  (format "%s" (or (plist-get node :tool) "tool")))

(defun harness-tools-handin--calls (nodes)
  "Return the tool-call nodes among NODES (oldest first), hand_in aside.
A hand_in call is never named by the tool-name or the `#N' handle form,
and never counted: each failed attempt appends its own hand_in call, and
counting it would shift the handles the error message lists between the
miss and the retry.  An exact call id or node id still names one
\(`harness-tools-handin--resolve')."
  (cl-remove-if-not
   (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                    (not (equal "hand_in" (plist-get n :tool)))))
   nodes))

(defun harness-tools-handin--snippet (node)
  "Return the distinguishing one-line snippet of call node NODE.
For a bash call it is the first line of its command; otherwise its
title, or the tool's name.  Newlines and runs of blanks become one
space, so the snippet fits on the line of the error's list."
  (let* ((input (plist-get node :input))
         (command (and (listp input) (plist-get input :command)))
         (subject (cond
                   ((stringp command) (car (split-string command "[\n\r]" t)))
                   ((plist-get node :title) (plist-get node :title))
                   (t (harness-tools-handin--tool-name node)))))
    (harness-truncate-end
     (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or subject "")))
     60)))

(defun harness-tools-handin--result-node (nodes call-id)
  "Return the newest tool-result node of CALL-ID among NODES, or nil."
  (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                               (equal (plist-get n :call-id) call-id)))
              (reverse nodes)))

(defun harness-tools-handin--resolve (ref calls nodes)
  "Return the call node REF names, CALLS the candidates, oldest first.
NODES is every node of the session, oldest first, for a tool-result's
node id.  REF is trimmed, and may be:

- `#N', the N-th newest call of the session, 1 the newest;
- `NAME#N', the N-th newest call of the tool NAME;
- `last', `newest' or `latest', the newest call;
- a call id, or the node id of a call or of its tool-result node, a
  hand_in call's included (an exact id is the one form that names one);
- the name of a tool, its newest call."
  (let* ((ref (string-trim ref))
         (down (downcase ref))
         (all-calls (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'tool-call))
                                      nodes))
         (newest (reverse calls))
         (nth-of (lambda (seq n) (nth (1- n) seq)))
         (by-tool (lambda (name)
                    (cl-remove-if-not
                     (lambda (n) (equal (downcase (harness-tools-handin--tool-name n))
                                        (downcase name)))
                     newest))))
    (cond
     ((string-empty-p ref) nil)
     ;; `#N': the N-th newest call of the session.
     ((string-match-p "\\`#[0-9]+\\'" ref)
      (funcall nth-of newest (string-to-number (substring ref 1))))
     ;; `NAME#N': the N-th newest call of the named tool.
     ((string-match "\\`\\(.+?\\)#\\([0-9]+\\)\\'" ref)
      (funcall nth-of (funcall by-tool (string-trim (match-string 1 ref)))
               (string-to-number (match-string 2 ref))))
     ;; The newest call, however it is asked for.
     ((member down '("last" "newest" "latest")) (car newest))
     ;; A call id or a call node's id.  An exact id names a hand_in call
     ;; too: the UI review fixture's session hands in quoting its own
     ;; call, and an id was always taken as it is.
     ((cl-find-if (lambda (n) (or (equal (plist-get n :call-id) ref)
                                  (equal (plist-get n :id) ref)))
                  all-calls))
     ;; A tool-result node's id: follow it to its call.
     ((let ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                 (equal (plist-get n :id) ref)))
                                nodes)))
        (and result
             (cl-find-if (lambda (n) (equal (plist-get n :call-id)
                                            (plist-get result :call-id)))
                         all-calls))))
     ;; The name of a tool: its newest call.
     (t (cl-find-if (lambda (n) (equal (downcase (harness-tools-handin--tool-name n)) down))
                    newest)))))

(defun harness-tools-handin--miss (ref calls number)
  "Return the error string for REF, which names no call among CALLS.
The list shows the last 12 candidates newest first, each with the
`#N', node id and call id a retry may quote, and a distinguishing
snippet."
  (let ((newest (reverse calls)))
    (format "Evidence %d: no tool call %s in this session. The recent calls are: %s"
            number ref
            (if newest
                (cl-loop for n in newest for i from 1 while (<= i 12)
                         concat (format "%s#%d %s %s (%s: %s)"
                                        (if (> i 1) ", " "")
                                        i
                                        (plist-get n :id)
                                        (plist-get n :call-id)
                                        (harness-tools-handin--tool-name n)
                                        (harness-tools-handin--snippet n)))
              "none"))))

(defun harness-tools-handin--call (sid ref number)
  "Return the evidence plist of tool call REF of session SID, the NUMBERth item.
REF names an earlier call of the session -- by its call id, its node
id (a call's or its tool-result node's), the name of its tool (its
newest call), `NAME#N', `#N', or `last' -- see
`harness-tools-handin--resolve'.  hand_in's own calls are named only by
an exact id, never by the tool-name or handle forms.  The newest call
named is copied: what the task view shows
is a snapshot of the same call the session shows, its `:child-id' --
the sub-agent a spawn_agent call started -- included, so the report
links the same session the chat does.  Return an error string when
there is no such call, listing the recent ones with the handles a retry
may quote."
  (let* ((nodes (if (harness-method-exists-p 'session/nodes) (harness-call 'session/nodes sid) nil))
         (calls (harness-tools-handin--calls nodes))
         (node (harness-tools-handin--resolve ref calls nodes)))
    (if node
        (let* ((result (harness-tools-handin--result-node nodes (plist-get node :call-id)))
               (child (or (plist-get (plist-get node :meta) :child-id)
                          (and result (plist-get (plist-get result :meta) :child-id)))))
          (append
           (list :kind "tool-call"
                 :id (plist-get node :id)
                 :call-id (plist-get node :call-id)
                 :tool (harness-tools-handin--tool-name node)
                 :title (or (plist-get node :title) (plist-get node :tool))
                 :input (harness-truncate-end
                         (harness-json-encode-text (or (plist-get node :input) :empty))
                         harness-tools-handin--max-input)
                 :output (and result (harness-truncate-end (or (plist-get result :output) "")
                                                           harness-tools-handin--max-output))
                 :is-error (and result (harness-json-true-p (plist-get result :is-error)))
                 :at (plist-get node :ts))
           (and (stringp child) (not (string-empty-p child)) (list :child-id child))))
      (harness-tools-handin--miss ref calls number))))

(defun harness-tools-handin--item (item number ctx)
  "Return the report evidence item for ITEM, the NUMBERth, of CTX.
ITEM is a string (a note), or an object with exactly one of `:image',
`:video', `:file', `:code', `:note', `:tool_call' and `:demo', and an
optional `:caption'.  Return an error string when it is none of that."
  (let ((caption (let ((c (plist-get item :caption)))
                   (and (stringp c) (not (harness-string-blank-p c)) (string-trim c))))
        (sid (plist-get ctx :session-id)))
    (cond
     ((stringp item) (if (harness-string-blank-p item)
                         (format "Evidence %d is empty" number)
                       (list :kind "note" :text (string-trim item))))
     ((not (listp item)) (format "Evidence %d is neither text nor an object" number))
     (t
      (let* ((image (harness-tools-handin--clean (plist-get item :image)))
             (video (harness-tools-handin--clean (plist-get item :video)))
             (file (harness-tools-handin--clean (plist-get item :file)))
             (code (plist-get item :code))
             (note (plist-get item :note))
             (call (harness-tools-handin--clean (plist-get item :tool_call)))
             (demo (plist-get item :demo))
             (kinds (delq nil (list (and image 'image) (and video 'video) (and file 'file)
                                    (and (stringp code) (not (harness-string-blank-p code)) 'code)
                                    (and (stringp note) (not (harness-string-blank-p note)) 'note)
                                    (and call 'tool-call)
                                    (and demo 'demo))))
             (one (lambda (result)
                    ;; An error string stays as it is.
                    (if (and caption (listp result))
                        (plist-put (copy-sequence result) :caption caption)
                      result))))
        (cond
         ((null kinds)
          (format "Evidence %d says nothing: give it an image, a video, a file, code, a note, a tool_call or a demo" number))
         ((cdr kinds)
          (format "Evidence %d gives %s: give it exactly one of image, video, file, code, note, tool_call or demo"
                  number (mapconcat (lambda (kind) (if (eq kind 'tool-call) "tool_call" (symbol-name kind)))
                                    kinds " and ")))
         ((eq (car kinds) 'image) (funcall one (or (harness-tools-handin--file image "image" number ctx)
                                                   (format "Evidence %d: %s is not an image" number image))))
         ((eq (car kinds) 'video) (funcall one (or (harness-tools-handin--file video "video" number ctx)
                                                   (format "Evidence %d: %s is not a video" number video))))
         ((eq (car kinds) 'file) (funcall one (or (harness-tools-handin--file file "file" number ctx)
                                                  (format "Evidence %d: %s is not a file" number file))))
         ((eq (car kinds) 'code) (funcall one (list :kind "code"
                                                    :language (or (harness-tools-handin--clean
                                                                   (plist-get item :language))
                                                                  "text")
                                                    :code (harness-truncate-end code 20000))))
         ((eq (car kinds) 'note) (funcall one (list :kind "note" :text (string-trim note))))
         ((eq (car kinds) 'demo)
          (funcall one (or (harness-tools-handin--demo demo number ctx)
                           (format "Evidence %d: demo needs a path, a url or a command" number))))
         (t (funcall one (or (harness-tools-handin--call sid call number)
                             (format "Evidence %d: no tool call %s" number call))))))))))

(defun harness-tools-handin--clean (value)
  "Return VALUE as a non-blank trimmed string, or nil."
  (and (stringp value) (not (harness-string-blank-p value)) (string-trim value)))

(defun harness-tools-handin--demo-ids (items)
  "Return ITEMS with each demo numbered among the demos: `demo-1', `demo-2'."
  (let ((n 0))
    (mapcar (lambda (item)
              (if (equal (plist-get item :kind) "demo")
                  (plist-put (copy-sequence item) :id (format "demo-%d" (cl-incf n)))
                item))
            items)))

(defun harness-tools-handin--item-written (item written)
  "Return the report evidence ITEM with the links in its words written out.
WRITTEN, a function of a text, returns the text with its links in full
\(`harness-tools-written').  The words of an item are those of a note and
of a caption; a code block is code, and what it says is left alone."
  (let ((item (copy-sequence item)))
    (when (equal (plist-get item :kind) "note")
      (setq item (plist-put item :text (funcall written (plist-get item :text)))))
    (when (and (equal (plist-get item :kind) "demo")
               (stringp (plist-get item :narration)))
      (setq item (plist-put item :narration
                            (funcall written (plist-get item :narration)))))
    (when (stringp (plist-get item :caption))
      (setq item (plist-put item :caption (funcall written (plist-get item :caption)))))
    item))

(defun harness-tools-handin--walkthrough (report task)
  "Return the presenter brief for REPORT, TASK's hand-in, or nil.
A report with a design document or an interactive demo gets a brief a
review conversation starts from: a session of its own, on the task's
model, that explains the work, runs the demo and answers the reviewer's
questions without changing anything.  A report with neither has no
brief."
  (let* ((design (plist-get report :design))
         (demos (cl-remove-if-not (lambda (item) (equal (plist-get item :kind) "demo"))
                                  (append (plist-get report :evidence) nil)))
         (prompt (or (plist-get task :prompt) ""))
         (title (harness-first-line (if (harness-string-blank-p prompt) "the task" prompt) 80))
         (where (or (plist-get task :worktree) (plist-get task :project) (plist-get task :cwd))))
    (when (or design demos)
      (let* ((design-text
              (when design
                (format "The design document is %s. Read it before you start: it explains the design as a whole, not a list of files.%s%s"
                        (or (plist-get design :name) (plist-get design :path) "the design document")
                        (if-let* ((summary (plist-get design :summary)))
                            (format "\nIts summary: %s" summary)
                          "")
                        (if-let* ((text (plist-get design :text)))
                            (format "\nIts first part:\n%s"
                                    (harness-truncate-end text 6000))
                          ""))))
             (demo-text
              (when demos
                (concat
                 "When you show a demo, open its URL or run its command, then narrate each step in one or two sentences. Wait for the reviewer after each step. The demos are:\n"
                 (string-join
                  (mapcar
                   (lambda (demo)
                     (concat "- " (or (plist-get demo :title) "demo")
                             (if-let* ((workspace (plist-get demo :workspace)))
                                 (format " · on the workspace computer %s" workspace) "")
                             (if-let* ((url (plist-get demo :url)))
                                 (format " · %s" url) "")
                             (if-let* ((command (plist-get demo :command)))
                                 (format " · %s%s"
                                         (mapconcat #'shell-quote-argument command " ")
                                         (if-let* ((cwd (plist-get demo :cwd-name)))
                                             (format " · in %s" cwd) ""))
                               "")
                             (if-let* ((narration (plist-get demo :narration)))
                                 (format " · narration: %s" narration)
                               " · narrate what you do")))
                   demos)
                  "\n"))))
             (parts
              (delq nil
                    (list
                     (format "You are presenting the finished work of the task \"%s\" to its reviewer. The task is in review: do not change files, do not call hand_in, and do not send the task back. You are its presenter, not its worker." title)
                     "Start with one sentence on what the work does, then ask what the reviewer wants to look at first. Keep replies short: they may be spoken. Do not read the whole design or the whole demo at once; go a step at a time and wait for the reviewer after each."
                     "The reviewer may interrupt at any time. When they do, stop and answer what they ask, then carry on where you were. When they ask to see a different part, show that part."
                     (format "The work is in %s." (or where "the task's directory"))
                     design-text
                     demo-text
                     (unless demos
                       "Walk through the design a section at a time. Say what the section decides and why, then wait for questions.")
                     "The reviewer may ask for a change. That belongs in the task's review feedback: say so, and do not change the work here. If they ask what a comment means or where something is, answer it."))))
        (harness-truncate-end (string-join parts "\n\n")
                              harness-tools-handin-walkthrough-limit)))))


(defun harness-tools-handin--branches (root)
  "Return a promise of the local branches of the repository at ROOT.
They are the newest commit first.  The promise resolves to nil when git
cannot read ROOT, so a check that cannot be made refuses nothing."
  (harness-catch
   (harness-then
    (harness-run-command (list "git" "for-each-ref" "--sort=-committerdate"
                               "--format=%(refname:short)" "refs/heads/")
                         :cwd root :name "harness-hand-in-git")
    (lambda (result)
      (and (eql (plist-get result :exit) 0)
           (split-string (or (plist-get result :stdout) "") "\n" t))))
   (lambda (_) nil)))

(defun harness-tools-handin--merge-base (task declared)
  "Return a promise of what DECLARED, a branch, is for TASK's hand-in.
The promise resolves to `(:base NAME)' when TASK's work can merge into
that branch, and to `(:error TEXT)' when it cannot: the task has no
branch of its own, DECLARED is that branch, or the project has no local
branch of that name -- whose branches the error then lists.  A project
whose branches cannot be read takes the name as it is: the merge queue
says what it cannot do."
  (cond
   ((not (plist-get task :worktree))
    (harness-resolved
     (list :error
           "hand_in: this task has no branch of its own to merge, so merge_base has nothing to name; hand in without it.")))
   ((equal declared (plist-get task :branch))
    (harness-resolved
     (list :error
           (format "hand_in: %s is this task's own branch.  merge_base names the local branch the work belongs on, other than the task's own; leave it out to merge into the branch the task was made from." declared))))
   (t
    (harness-then
     (harness-tools-handin--branches (plist-get task :project))
     (lambda (branches)
       (cond
        ((or (null branches) (member declared branches)) (list :base declared))
        (t (list :error
                 (format "hand_in: the project has no local branch %s.  Its branches are: %s.  Give merge_base one of them, or leave it out to merge into the branch the task was made from."
                         declared
                         (let ((names (seq-take branches 20)))
                           (concat (string-join names ", ")
                                   (if (> (length branches) (length names)) ", …" ""))))))))))))

(defun harness-tools-handin--merges-pending (sid)
  "Return the merges SID waits for, or nil.
Those are the branches its own sub-agents have merging into its working
directory that are not through yet -- queued, merging or in conflict.
Nothing of the session's own can be handed in while any of them is: the
work it builds on has to be in the branch first.  A merge that failed
does not wait here; the queue told the session, and the child's work is
the child's to fix."
  (and (harness-method-exists-p 'merge/pending)
       (ignore-errors (harness-call 'merge/pending sid))))

(defun harness-tools-handin--merges-text (pending)
  "Return the refusal for PENDING, the merges the session waits for."
  (format "hand_in: %s into this session's worktree %s not through yet: %s"
          (if (cdr pending) (format "%d merges" (length pending)) "a merge")
          (if (cdr pending) "are" "is")
          (string-join
           (mapcar (lambda (item)
                     (format "%s (%s)" (or (plist-get item :name)
                                           (substring (plist-get item :child) 0 8))
                             (plist-get item :status)))
                   pending)
           ", ")))

(defun harness-tools-handin--refusal (task sid)
  "Return a promise of the text the project's checks refuse TASK's hand-in with.
The promise is of nil when none refuses.  The checks are the functions
of the asynchronous filter `task/before-hand-in', run from nil with
TASK and the plist of session SID (see the Commentary).  A text that is
blank refuses nothing."
  (harness-then
   (harness-run-filter-async 'task/before-hand-in nil task (harness-call 'session/get sid))
   (lambda (refusal)
     (and (stringp refusal) (not (harness-string-blank-p refusal)) refusal))))

(defun harness-tools-handin--hand-in (input ctx)
  "Handler of the hand_in tool: record the report of INPUT and end the turn.
The report goes on the task of the session in CTX.  A malformed call
returns an error saying what to fix, and ends nothing.  A session whose
sub-agents' merges are not through yet cannot hand in either: the work
the session's branch is built on has to be in it first."
  (let* ((sid (plist-get ctx :session-id))
         ;; The words of the report may link sessions, messages and the
         ;; calls that ran: written out in full, in the terms of this
         ;; session before this call, they mean the same at every review.
         (notes nil)
         (written (lambda (text)
                    (if (stringp text)
                        (let ((done (harness-tools-written text ctx)))
                          (when (cdr done) (push (cdr done) notes))
                          (car done))
                      text)))
         (summary (funcall written (harness-tools-handin--clean (plist-get input :summary))))
         (problem (funcall written (harness-tools-handin--clean (plist-get input :problem))))
         (reproduction (funcall written (harness-tools-handin--clean (plist-get input :reproduction))))
         (cannot (harness-json-true-p (plist-get input :cannot_continue)))
         (no-merge (harness-json-true-p (plist-get input :no_merge)))
         (raw (append (plist-get input :evidence) nil))
         (pending (harness-tools-handin--merges-pending sid)))
    (cond
     ((and pending (not cannot))
      (harness-tools-handin--invalid
       "%s. Let them merge (the queue takes them in turn), or have the conflicts of the one in conflict resolved in the child's worktree, then hand in."
       (harness-tools-handin--merges-text pending)))
     ((null summary)
      (harness-tools-handin--invalid "hand_in needs summary: your final message to the user, in markdown"))
     ((null problem)
      (harness-tools-handin--invalid
       "hand_in needs problem: a short summary of what must be fixed and how to see it, which the review shows at the top"))
     ((and (null raw) (not cannot))
      (harness-tools-handin--invalid
       "hand_in needs evidence: at least one image, video, file, code block, note, tool_call or demo. Show the work, do not just describe it; when it has anything to see, an image or a video is required."))
     (t
      (let* ((design (harness-tools-handin--design (plist-get input :design) ctx))
             (items (cl-loop for item in raw for n from 1
                             collect (harness-tools-handin--item item n ctx)))
             (bad (and (stringp design) (list design))))
        (dolist (item items) (when (stringp item) (push item bad)))
        (unless bad
          (setq items (harness-tools-handin--demo-ids items))
          (setq items (mapcar (lambda (item) (harness-tools-handin--item-written item written)) items))
          (when design
            (when-let* ((summary (plist-get design :summary)))
              (setq design (plist-put (copy-sequence design)
                                      :summary (funcall written summary))))))
        (if bad
            (harness-tools-handin--invalid "%s" (string-join (nreverse bad) "\n"))
          (let ((task (and (harness-method-exists-p 'task/for-session)
                           (harness-call 'task/for-session sid)))
                (declared (harness-branch-name (plist-get input :merge_base))))
            (if (not task)
                (harness-tools-handin--invalid
                 "hand_in is for a task's session, and this session is no task. Finish your turn normally instead.")
              (harness-then
               ;; The branch the task names is checked before anything is
               ;; recorded: a hand-in for work that merges says where it
               ;; merges, and the review reads the work against it.
               (if (and declared (not cannot) (not no-merge))
                   (harness-tools-handin--merge-base task declared)
                 (harness-resolved (list :base nil)))
               (lambda (check)
                 (if (plist-get check :error)
                     (harness-tools-handin--invalid "%s" (plist-get check :error))
                   (let ((base (plist-get check :base))
                         (refusal (and (not cannot)
                                       (harness-tools-handin--blocked task))))
                     (if refusal
                         (harness-tools-handin--invalid "%s" refusal)
                       (let* ((body (append (list :summary summary :problem problem)
                                            (and design (list :design design))
                                            (and reproduction (list :reproduction reproduction))
                                            (list :evidence items :at (float-time))
                                            ;; The call that handed the work in: the review
                                            ;; names it as the author of the version.
                                            (and (plist-get ctx :call-id) (list :call-id (plist-get ctx :call-id)))
                                            (and cannot (list :cannot-continue t))
                                            (and no-merge (list :no-merge t))
                                            ;; Where the work belongs, when the task named
                                            ;; another branch than the one it was made from.
                                            (and base (list :merge-base base))))
                              (walk (harness-tools-handin--walkthrough body task))
                              (report (append body (and walk (list :walkthrough walk))))
                              (record
                               (lambda ()
                                 (harness-call 'task/hand-in (plist-get task :id) report)
                                 (harness-call 'session/hint sid
                                               (cond (cannot "Task cannot continue; it waits for the user")
                                                     (no-merge "Handed in; nothing to merge")
                                                     (t "Handed in for review")))
                                 (harness-tool-ok
                                  (harness-tools-with-note
                                   (cond
                                    (cannot
                                     (format "Recorded: this task cannot continue. %s\n\nThe task goes to Requires your input for the user's decision, and nothing merges; this turn ends."
                                             (harness-first-line summary 200)))
                                    (no-merge
                                     (format "Handed in (nothing to merge): %s\n\n%d piece%s of evidence; the task waits for the user's review, and verifying it completes it without merging."
                                             (harness-first-line summary 200) (length items) (if (= 1 (length items)) "" "s")))
                                    (t
                                     (format "Handed in: %s\n\n%d piece%s of evidence; the task now waits for the user's review, and this turn ends."
                                             (harness-first-line summary 200) (length items) (if (= 1 (length items)) "" "s"))))
                                   (and notes (string-join (delete-dups (nreverse notes)) "\n")))
                                  :end-turn t
                                  ;; The report rides the result, so the transcript can draw
                                  ;; the review the task view draws, after it left review too.
                                  :meta (list :report report :task-id (plist-get task :id))))))
                         ;; Work that is to be merged is put to the project's own checks
                         ;; (`task/before-hand-in'), when it has any; a task that
                         ;; cannot continue, or has nothing to merge, is not.
                         (if (or cannot no-merge
                                 (not (memq 'task/before-hand-in (harness-filters))))
                             (funcall record)
                           (harness-then (harness-tools-handin--refusal task sid)
                                         (lambda (refusal)
                                           (if refusal
                                               (harness-tools-handin--invalid "%s" refusal)
                                             (funcall record)))
                                         ;; A check that cannot be made refuses nothing.
                                         (lambda (_) (funcall record))))))))))))))))))

(harness-define-tool "hand_in"
  :label "Hand in the finished work"
  :description "Hand the finished work in and stop: the turn ends, the task leaves the working phase, and it waits for the user's review with your summary and evidence in front of them. Call it when the work is complete, not to answer a message or report progress: a plain reply is the working phase, and the task stays with you. Do not ask first whether the work is ready to hand in, and do not show what you are about to hand in for approval -- before the first hand-in, hand it in. When the review has open threads, they are the user's questions: answer each in its thread and close it only when done -- never in a batch just to hand in. Every open thread must be answered and closed first, or hand_in is refused. problem is required: a short summary of what must be fixed and how to see it, which the review shows at the top, where the task's name alone would not remind the user what it was about. summary is your final message, in markdown. reproduction is optional: how to see the problem, or the steps to check the fix, for the review. design is optional and is what the review reads first when the work has a design to explain: an object with path (a Markdown document in the worktree) and optional title and summary. Write it for the reviewer: what the design decides and why, the alternatives, and the shape of the change; one line of code shows no design, the document shows the whole. The review comments on its sections, and a walkthrough explains it. If the task cannot be finished, call it with cannot_continue true and say what blocks it in summary: it goes to the user's input instead of review and nothing merges. If the work needs no merge -- an informational task, or one that changed nothing -- pass no_merge true: verifying it completes without merging. If the work belongs on another local branch of the project than the one the task was made from, pass merge_base with that branch: the review then reads your changes against it and verifying merges them into it, rather than into the branch the task was made from. A branch the project does not have, or the task's own branch, is refused with the branches it could name. A project can refuse a hand-in until a check of its own has passed; the refusal then says what to run first. evidence is required and holds at least one item; an item is an object with exactly one of: image or video (a path to a file you made, such as a screenshot); file (a path); code (with language); note (markdown text); tool_call (an earlier call of yours, which the user then sees as a link to that call in the session); or demo (something the reviewer can try: an object with title and any of path, url, command (an argv list, never a shell string), cwd, narration and workspace). A demo bound to a workspace (workspace) runs on that workspace's computer when the reviewer starts it, and the presenter drives it there; without one it runs where the harness does. The review opens a demo, runs it after the reviewer confirms, and a walkthrough narrates it; when the work has an interactive surface or a concept to show, build a demo and add it. Show, do not tell: when the work has anything to see -- a UI, a rendering, a chart, a layout, anything a screenshot can show -- an image, or a video for motion, is required, not just nice to have; take the screenshot with bash first. Quote the tool call that proves a claim (the tests pass, the command's output) as a tool_call item. A file, code or note is evidence only when nothing visual applies. caption says what the item shows. A tool_call may name the call by its tool's name (the newest call of that tool, e.g. \"bash\"), by `#N` or `<tool>#N` as an earlier hand_in error listed it (1 = newest), or by its call or node id. The summary, problem, reproduction and notes can link those calls too, and messages and sessions: [the test run](harness:call/bash#2), as the system prompt says."
  :schema '(:type "object"
            :properties (:problem (:type "string"
                                  :description "A short summary of what must be fixed and how to see it, in markdown. The review shows it at the top: with many tasks going on, the title alone does not say what the work was for. Say what the user must check, not the task prompt again.")
                         :design (:type "object"
                                  :properties (:path (:type "string"
                                                     :description "Path of the Markdown design document in the task's worktree.")
                                               :title (:type "string"
                                                       :description "The design's title, when its first heading is not the one to show.")
                                               :summary (:type "string"
                                                         :description "A few lines on what the design decides and why, shown under the title."))
                                  :required ("path")
                                  :description "The design document the review reads first: what the design decides and why, the alternatives, and the shape of the change. Optional, but for work that changes how something is designed or behaves it is what the reviewer reads and comments on before the code.")
                         :reproduction (:type "string"
                                        :description "Optional: how to see the problem, or the steps to check the fix, for the review.")
                         :summary (:type "string"
                                   :description "Your final message to the user, in markdown: what was done and how it was verified.")
                         :evidence (:type "array"
                                    :items (:type "object"
                                            :properties (:image (:type "string" :description "Path of an image file showing the work (PNG, JPEG, GIF, SVG, WebP).")
                                                         :video (:type "string" :description "Path of a video file showing the work in motion (MP4, WebM, MOV).")
                                                         :file (:type "string" :description "Path of a file the user should look at.")
                                                         :code (:type "string" :description "A code block that is evidence by itself.")
                                                         :language (:type "string" :description "Language of code, for its highlighting.")
                                                         :note (:type "string" :description "Markdown text as evidence.")
                                                         :tool_call (:type "string" :description "An earlier tool call of this session, shown to the user as a link to that call: its call id or node id, the name of its tool (the newest call of that tool, e.g. \"bash\"), or `#N`/`<tool>#N` (1 = newest) as an earlier hand_in error listed it.")
                                                         :demo (:type "object"
                                                                :properties (:title (:type "string" :description "What the demo shows.")
                                                                             :path (:type "string" :description "Path of a page, program or directory of the demo in the task's worktree.")
                                                                             :url (:type "string" :description "An http or https URL the reviewer opens.")
                                                                             :command (:type "array" :items (:type "string")
                                                                                       :description "An argv list that starts the demo, never a shell string.")
                                                                             :cwd (:type "string" :description "Where the command runs, by default the demo's directory.")
                                                                             :narration (:type "string" :description "How to show it, step by step, for the walkthrough.")
                                                                             :workspace (:type "string" :description "The workspace whose computer runs the demo. With one the demo opens on that computer, and the reviewer sees its screen in the app; without one it runs where the harness does."))
                                                                :description "Something the reviewer can try: a page, a URL or a program, with the narration of what to show.")
                                                         :caption (:type "string" :description "What this item shows, under it.")))
                                    ;; No `:required' here: any one key is enough.  An empty
                                    ;; `:required ()' would encode as JSON null, which providers
                                    ;; refuse ("null is not of type array").
                                    :description "At least one piece of evidence. Prefer an image or a video whenever the work has anything to see; a demo when the reviewer can try it; a tool_call for claims about commands or tests.")
                         :cannot_continue (:type "boolean"
                                           :description "Set true when the task cannot be finished. Record what blocks it in summary; evidence may be empty. The task goes to the user's input instead of review, and nothing merges.")
                         :no_merge (:type "boolean"
                                    :description "Set true when the work needs no merge, such as an informational task or one that changed nothing: verifying it completes it without the merge queue.")
                         :merge_base (:type "string"
                                      :description "Optional: the local branch the work belongs on, when it is not the branch the task was made from. The review reads the changes against it and verifying merges them into it. A branch the project does not have, or the task's own, is refused, listing the branches that exist."))
            :required ("problem" "summary" "evidence"))
  :kind 'meta
  :timeout 60000
  :subject (lambda (input)
             (harness-first-line (or (plist-get input :problem) (plist-get input :summary)) 60))
  :handler #'harness-tools-handin--hand-in)

(defun harness-tools-handin--tools (names session)
  "Drop hand_in from NAMES unless SESSION is a task's.
The catalogue (SESSION nil) keeps every tool."
  (if (and session (not (and (harness-method-exists-p 'task/for-session)
                             (harness-call 'task/for-session (plist-get session :id)))))
      (remove "hand_in" names)
    names))

(defun harness-tools-handin--init ()
  "Offer hand_in to task sessions only."
  (harness-add-filter 'agent/tools #'harness-tools-handin--tools 50))

(harness-tools-handin--init)

(harness-define-module 'tools-handin
  :doc "The hand_in tool: a task session hands its finished work in and stops."
  :requires '(tools session)
  :init #'harness-tools-handin--init)

(provide 'harness-tools-handin)
;;; harness-tools-handin.el ends here
