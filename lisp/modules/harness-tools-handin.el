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
;; Evidence is required, and at least one item; the tool description
;; tells the model that an image or a video is required whenever the
;; work has anything to show, and that a claim about a command (the
;; tests pass) belongs there as a reference to the tool call that made
;; it, by its call id.  Referenced calls are copied into the report as
;; a snapshot -- title, input, output, error flag -- so the task view
;; can show them as the link they are without re-reading the session,
;; and the file keeps them.
;;
;; The tool is offered to task sessions only: the filter `agent/tools'
;; removes it where there is no task to hand the work in to.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

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

(defun harness-tools-handin--call (sid ref number)
  "Return the evidence plist of tool call REF of session SID, the NUMBERth item.
REF is the call id as the transcript shows it.  The newest call whose
call id or node id is REF is copied: what the task view shows is a
snapshot of the same call the session shows, its `:child-id' -- the
sub-agent a spawn_agent call started -- included, so the report links
the same session the chat does.  Return an error string when there is
no such call, naming the recent ones."
  (let ((nodes (if (harness-method-exists-p 'session/nodes) (harness-call 'session/nodes sid) nil)))
    (if-let* ((node (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                 (or (equal (plist-get n :call-id) ref)
                                                     (equal (plist-get n :id) ref))))
                                (reverse nodes))))
        (let* ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                    (equal (plist-get n :call-id) (plist-get node :call-id))))
                                   (reverse nodes)))
               (child (or (plist-get (plist-get node :meta) :child-id)
                          (and result (plist-get (plist-get result :meta) :child-id)))))
          (append
           (list :kind "tool-call"
                 :id (plist-get node :id)
                 :call-id (plist-get node :call-id)
                 :tool (format "%s" (or (plist-get node :tool) "tool"))
                 :title (or (plist-get node :title) (plist-get node :tool))
                 :input (harness-truncate-end
                         (harness-json-encode-text (or (plist-get node :input) :empty))
                         harness-tools-handin--max-input)
                 :output (and result (harness-truncate-end (or (plist-get result :output) "")
                                                           harness-tools-handin--max-output))
                 :is-error (and result (harness-json-true-p (plist-get result :is-error)))
                 :at (plist-get node :ts))
           (and (stringp child) (not (string-empty-p child)) (list :child-id child))))
      (let ((recent (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'tool-call)) nodes)))
        (format "Evidence %d: no tool call %s in this session. The recent calls are: %s"
                number ref
                (if recent
                    (mapconcat (lambda (n) (format "%s (%s)" (plist-get n :call-id) (or (plist-get n :title) (plist-get n :tool))))
                               (last recent (min 10 (length recent))) ", ")
                  "none"))))))

(defun harness-tools-handin--item (item number ctx)
  "Return the report evidence item for ITEM, the NUMBERth, of CTX.
ITEM is a string (a note), or an object with exactly one of `:image',
`:video', `:file', `:code', `:note' and `:tool_call', and an optional
`:caption'.  Return an error string when it is none of that."
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
             (kinds (delq nil (list (and image 'image) (and video 'video) (and file 'file)
                                    (and (stringp code) (not (harness-string-blank-p code)) 'code)
                                    (and (stringp note) (not (harness-string-blank-p note)) 'note)
                                    (and call 'tool-call))))
             (one (lambda (result)
                    ;; An error string stays as it is.
                    (if (and caption (listp result))
                        (plist-put (copy-sequence result) :caption caption)
                      result))))
        (cond
         ((null kinds)
          (format "Evidence %d says nothing: give it an image, a video, a file, code, a note or a tool_call" number))
         ((cdr kinds)
          (format "Evidence %d gives %s: give it exactly one of image, video, file, code, note or tool_call"
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
         (t (funcall one (or (harness-tools-handin--call sid call number)
                             (format "Evidence %d: no tool call %s" number call))))))))))

(defun harness-tools-handin--clean (value)
  "Return VALUE as a non-blank trimmed string, or nil."
  (and (stringp value) (not (harness-string-blank-p value)) (string-trim value)))

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

(defun harness-tools-handin--hand-in (input ctx)
  "Handler of the hand_in tool: record the report of INPUT and end the turn.
The report goes on the task of the session in CTX.  A malformed call
returns an error saying what to fix, and ends nothing.  A session whose
sub-agents' merges are not through yet cannot hand in either: the work
the session's branch is built on has to be in it first."
  (let* ((sid (plist-get ctx :session-id))
         (summary (let ((s (plist-get input :summary)))
                    (and (stringp s) (not (harness-string-blank-p s)) (string-trim s))))
         (raw (append (plist-get input :evidence) nil))
         (pending (harness-tools-handin--merges-pending sid)))
    (cond
     (pending
      (harness-tools-handin--invalid
       "%s. Let them merge (the queue takes them in turn), or have the conflicts of the one in conflict resolved in the child's worktree, then hand in."
       (harness-tools-handin--merges-text pending)))
     ((null summary)
      (harness-tools-handin--invalid "hand_in needs summary: your final message to the user, in markdown"))
     ((null raw)
      (harness-tools-handin--invalid
       "hand_in needs evidence: at least one image, video, file, code block, note or tool_call. Show the work, do not just describe it; when it has anything to see, an image or a video is required."))
     (t
      (let ((items (cl-loop for item in raw for n from 1
                            collect (harness-tools-handin--item item n ctx)))
            (bad nil))
        (dolist (item items) (when (stringp item) (push item bad)))
        (if bad
            (harness-tools-handin--invalid "%s" (string-join (nreverse bad) "\n"))
          (let ((task (and (harness-method-exists-p 'task/for-session)
                           (harness-call 'task/for-session sid))))
            (if (not task)
                (harness-tools-handin--invalid
                 "hand_in is for a task's session, and this session is no task. Finish your turn normally instead.")
              (let ((report (list :summary summary :evidence items :at (float-time))))
                (harness-call 'task/hand-in (plist-get task :id) report)
                (harness-call 'session/hint sid "Handed in for review")
                (harness-tool-ok
                 (format "Handed in: %s\n\n%d piece%s of evidence; the task now waits for the user's review, and this turn ends."
                         (harness-first-line summary 200) (length items) (if (= 1 (length items)) "" "s"))
                 :end-turn t))))))))))

(harness-define-tool "hand_in"
  :label "Hand in the finished work"
  :description "Hand the finished work in and stop: the turn ends and the task waits for the user's review, with your summary and evidence in front of them. Call it once, when you are sure the task is complete, instead of replying normally. summary is your final message, in markdown. evidence is required and holds at least one item; an item is an object with exactly one of: image or video (a path to a file you made, such as a screenshot); file (a path); code (with language); note (markdown text); or tool_call (the call id of an earlier call of yours, which the user then sees as a link to that call in the session). Show, do not tell: when the work has anything to see -- a UI, a rendering, a chart, a layout, anything a screenshot can show -- an image, or a video for motion, is required, not just nice to have; take the screenshot with bash first. Quote the tool call that proves a claim (the tests pass, the command's output) as a tool_call item. A file, code or note is evidence only when nothing visual applies. caption says what the item shows."
  :schema '(:type "object"
            :properties (:summary (:type "string"
                                   :description "Your final message to the user, in markdown: what was done and how it was verified.")
                         :evidence (:type "array"
                                    :items (:type "object"
                                            :properties (:image (:type "string" :description "Path of an image file showing the work (PNG, JPEG, GIF, SVG, WebP).")
                                                         :video (:type "string" :description "Path of a video file showing the work in motion (MP4, WebM, MOV).")
                                                         :file (:type "string" :description "Path of a file the user should look at.")
                                                         :code (:type "string" :description "A code block that is evidence by itself.")
                                                         :language (:type "string" :description "Language of code, for its highlighting.")
                                                         :note (:type "string" :description "Markdown text as evidence.")
                                                         :tool_call (:type "string" :description "Call id of an earlier tool call of this session, shown to the user as a link to that call.")
                                                         :caption (:type "string" :description "What this item shows, under it.")))
                                    ;; No `:required' here: any one key is enough.  An empty
                                    ;; `:required ()' would encode as JSON null, which providers
                                    ;; refuse ("null is not of type array").
                                    :description "At least one piece of evidence. Prefer an image or a video whenever the work has anything to see; a tool_call for claims about commands or tests."))
            :required ("summary" "evidence"))
  :kind 'meta
  :timeout 60000
  :subject (lambda (input) (harness-first-line (plist-get input :summary) 60))
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
