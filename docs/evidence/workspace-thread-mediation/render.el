;;; render.el --- Draw the workspace buffers this branch writes -*- lexical-binding: t; -*-

;; The task's sandbox has no display (`scripts/dev.sh start' answers
;; "Display :1 can't be opened"), so the Emacs pictures in this
;; directory are drawn from the buffers themselves: each buffer is
;; rendered by its own code with its own faces, every run of text is
;; read with the face it carries, and `render.py' draws those runs in
;; the face's colours.  A picture and its copy cannot drift apart,
;; because the words in it are the words the buffer holds.
;;
;;   emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui \
;;     -l test/harness-test-helpers.el \
;;     -l docs/evidence/workspace-thread-mediation/render.el \
;;     --eval '(ws-evidence-render "/tmp/shots")'
;;
;; and then, for each JSON it writes:
;;
;;   python3 render.py /tmp/shots/emacs-inbox.json /tmp/shots/emacs-inbox.png

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'harness-ui-workspace)

(defconst ws-evidence--palette
  '(("default" . "#1a1a1a")
    ("harness-header-face" . "#3d2f6b")
    ("harness-dim-face" . "#6a6a6a")
    ("harness-label-face" . "#2b2b2b")
    ("harness-hint-face" . "#4a6a8a")
    ("harness-caution-face" . "#8a5a00")
    ("harness-failure-face" . "#b00020")
    ("harness-user-label-face" . "#1f4e9c")
    ("button" . "#1f4e9c"))
  "Each face these buffers draw with, and the colour it is drawn in.
The faces inherit from faces a batch Emacs has no colours for, so the
colours are named here; the words and their faces are the buffer's own.")

(defun ws-evidence--face-of (position)
  "Return the face POSITION is drawn with, as a symbol."
  (let ((face (get-text-property position 'face)))
    (cond ((null face) 'default)
          ((listp face) (or (car face) 'default))
          (t face))))

(defun ws-evidence--colour (face)
  "Return the colour FACE is drawn in."
  (or (cdr (assoc (format "%s" face) ws-evidence--palette))
      (let ((foreground (and (facep face)
                             (face-attribute face :foreground nil t))))
        (and (stringp foreground)
             (not (string-prefix-p "unspecified" foreground))
             foreground))
      "#1a1a1a"))

(defun ws-evidence--runs (begin end)
  "Return BEGIN..END as runs of (TEXT COLOUR WEIGHT SLANT)."
  (let ((position begin) (runs nil) (run nil))
    (while (< position end)
      (let* ((face (ws-evidence--face-of position))
             (colour (ws-evidence--colour face))
             (weight (if (eq (face-attribute face :weight nil t) 'bold)
                         "bold" "normal"))
             (slant (if (eq (face-attribute face :slant nil t) 'italic)
                        "italic" "normal"))
             (character (char-to-string (char-after position))))
        (if (and run (equal (cdr run) (list colour weight slant)))
            (setcar run (concat (car run) character))
          (when run (push run runs))
          (setq run (list character colour weight slant)))
        (setq position (1+ position))))
    (when run (push run runs))
    (vconcat (mapcar #'vconcat (nreverse runs)))))

(defun ws-evidence--lines ()
  "Return the buffer's lines as runs of text, each line a vector."
  (save-excursion
    (goto-char (point-min))
    (let ((lines nil) (continue t))
      (while continue
        (let ((begin (line-beginning-position)) (end (line-end-position)))
          (push (ws-evidence--runs begin end) lines))
        (setq continue (zerop (forward-line 1))))
      (vconcat (nreverse lines)))))

(defun ws-evidence--write (path &optional limit)
  "Write the current buffer's text and faces to PATH as JSON.
LIMIT keeps at most that many lines, so a picture is the part that
shows what it was made for rather than a page of empty box."
  (let ((lines (ws-evidence--lines)))
    (when (and limit (> (length lines) limit))
      (setq lines (cl-subseq lines 0 limit)))
    (with-temp-file path
      (insert (json-encode (list :lines lines :size 30 :pad 26)))
      (insert "\n")))
  path)

(defun ws-evidence--inbox (path)
  "Draw the inbox buffer the renderer writes, and write it to PATH."
  (with-temp-buffer
    (harness-ui-inbox-mode)
    (setq harness-ui-inbox--id "w-1"
          harness-ui-inbox--state 'ready
          harness-ui-inbox--inbox
          (list :workspace "w-1" :name "Home" :scope "workspace"
                :items (list (list :session "s-1" :thread "th-1"
                                   :workspace "w-1" :workspace-name "Home"
                                   :title "Kitchen renovation"
                                   :text "Try the slate." :state "queued")
                             (list :session "s-1" :thread "th-1"
                                   :workspace "w-1" :workspace-name "Home"
                                   :title "Kitchen renovation"
                                   :text "And the grout." :state "waiting")
                             (list :session "s-9" :thread "th-2"
                                   :workspace "w-1" :workspace-name "Home"
                                   :title "Harness memory"
                                   :text "" :state "unavailable"
                                   :why "Session unavailable"))
                :counts (list :queued 1 :waiting 1 :unavailable 1)))
    (harness-ui-inbox--render)
    (ws-evidence--write path)))

(defun ws-evidence--inbox-all (path)
  "Draw the inbox in the all scope, where rows name their workspace."
  (with-temp-buffer
    (harness-ui-inbox-mode)
    (setq harness-ui-inbox--id "w-1"
          harness-ui-inbox--scope "all"
          harness-ui-inbox--state 'ready
          harness-ui-inbox--inbox
          (list :workspace "w-1" :name "Home" :scope "all"
                :items (list (list :session "s-1" :thread "th-1"
                                   :workspace "w-1" :workspace-name "Home"
                                   :title "Kitchen renovation"
                                   :text "Try the slate." :state "queued")
                             (list :session "s-2" :thread "th-3"
                                   :workspace "w-2" :workspace-name "Studio"
                                   :title "Harness memory"
                                   :text "Remember the grout." :state "waiting"))
                :counts (list :queued 1 :waiting 1 :unavailable 0)))
    (harness-ui-inbox--render)
    (ws-evidence--write path)))

(defun ws-evidence--workspace (path)
  "Draw a workspace timeline with a routed message and a reassignment."
  (with-temp-buffer
    (harness-ui-workspace-mode)
    (setq harness-ui-workspace--data
          (list :id "w-1" :name "Home" :profile "text"
                :threads (list (list :id "th-1" :title "Kitchen renovation"
                                     :status "idle")
                               (list :id "th-2" :title "Harness memory"
                                     :status "running"))
                :last-thread "th-2"
                :model "openrouter:deepseek/deepseek-v4.1-flash-1017")
          harness-ui-workspace--thread "th-2"
          harness-ui-workspace--state 'ready
          harness-ui-workspace--entries
          (list (list :kind "message" :role "user" :thread "th-1"
                      :origin "th-1" :handling "th-1" :profile "voice"
                      :text "Try the slate in the hall.")
                (list :kind "message" :role "assistant" :thread "th-1"
                      :text "The hall reads well in slate.")
                (list :kind "message" :role "user" :thread "th-2"
                      :origin "th-1" :handling "th-2" :profile "voice"
                      :text "Remember the grout is warm."
                      :reassigned (list :to "th-2" :by "mediator"))
                (list :kind "reassignment" :thread "th-2"
                      :origin "th-1" :handling "th-2"
                      :delivery "queued" :by "person"
                      :text "Remember the grout is warm.")
                (list :kind "message" :role "assistant" :thread "th-2"
                      :text "Noted: the grout is warm.")))
    (harness-ui-workspace--render)
    (ws-evidence--write path 22)))

(defun ws-evidence-render (directory)
  "Write the JSON pictures of this branch's buffers into DIRECTORY.
The inbox pictures keep every line: the whole buffer is what they show.
The workspace picture keeps the header, the threads and the timeline,
and stops before the compose box, which draws the settings line twice in
a batch Emacs and shows nothing about provenance."
  (make-directory directory t)
  (dolist (case '(("emacs-inbox.json" . ws-evidence--inbox)
                  ("emacs-inbox-all.json" . ws-evidence--inbox-all)
                  ("emacs-workspace.json" . ws-evidence--workspace)))
    (funcall (cdr case) (expand-file-name (car case) directory)))
  directory)

(provide 'render)
;;; render.el ends here
