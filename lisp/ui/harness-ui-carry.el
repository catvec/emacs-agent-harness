;;; harness-ui-carry.el --- The panel that asks how to carry a conversation over  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that cannot go on as it is has to be carried over some
;; way: summarised, written to a file, left behind, sent whole.  Two
;; questions ask which: the cold-cache question, when a message meets a
;; prompt cache gone cold (harness-ui-cowboy.el), and the model switch,
;; when the new model keeps a conversation of its own and would lose this
;; one (harness-ui-handoff.el).  This is the one panel that draws both, and
;; the one place that shows the switch's.
;;
;; The panel is made from a spec, a plist, and each question only says
;; what to put in it: a heading (an icon, a title and some detail), dim
;; lines and labelled rows of facts, an imperative line, the choices, and
;; footer lines.  A choice is one of the ways of harness-carry.el with
;; what the question knows of it -- its key, its label, its cost, the
;; model that writes it, what it does -- and has a row: its key, a button,
;; its cost in a column of its own, and its wording, a segment after
;; another, the default marked.  Each key answers while point is on the
;; panel; a click answers from anywhere; a capital key answers "always"
;; where the spec allows it (`:always'); and in the compose box, where the
;; keys type, C-c . and a key press it from there
;; (`harness-compose-panel-key'), which the panel's last line says.  The
;; amber behind it, `harness-ui-carry-face', says a conversation is being
;; carried over at a cost.
;;
;; The cold-cache question is a pending question like any other, so the
;; chat and a popout draw it where they draw a request.  The model switch
;; is a question of the UI's own: it needs a host, a buffer that shows the
;; panel until it is answered.  A chat does, above its compose box; so do
;; the session list, above its rows, and the task board, above the lines
;; over its compose box, each through a hook of its own
;; (`harness-chat-panel-functions', `harness-ui-sessions-panel-functions',
;; `harness-ui-tasks-panel-functions') that this module adds to.  A switch
;; of many sessions has no chat of its own, so its host is the buffer the
;; command ran in, if that one can host (`harness-ui-carry-hosts'), and
;; otherwise the session list, opened for it: wherever it starts, the
;; question is the same panel, and never the minibuffer
;; (`harness-ui-carry-host').  Point goes to the panel when it is drawn,
;; and stays on it while the host is drawn again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-carry)
(require 'harness-ui)
(require 'harness-ui-compose)           ; `harness-compose-panel-hint'

(defvar harness-chat-panel-functions)
(defvar harness-compose-redraw-function)
(defvar harness-ui-sessions--buffer-name)
(defvar harness-ui-sessions-panel-functions)
(defvar harness-ui-tasks-panel-functions)
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-sessions "harness-ui-sessions" (&optional all-projects position blocked-only))
(declare-function harness-ui-sessions--redraw "harness-ui-sessions" ())

(defgroup harness-ui-carry nil
  "Asking how to carry a conversation over."
  :group 'harness-ui)

(defface harness-ui-carry-face
  '((((background light)) :background "#fff3d6" :extend t)
    (((background dark)) :background "#3a3117" :extend t))
  "Background of the panel asking how to carry a conversation over.
A cold prompt cache and a model switch both carry one over at a cost."
  :group 'harness-ui-carry)

(define-obsolete-face-alias 'harness-chat-switch-face 'harness-ui-carry-face "3.1")
(define-obsolete-face-alias 'harness-ui-cowboy-face 'harness-ui-carry-face "3.1")

;;;; The panel

(defconst harness-ui-carry--indent "   "
  "What a line of the panel starts with, and a wrapped one is indented by.")

(defun harness-ui-carry-text (value)
  "Return VALUE when it is a string with something in it, else nil.
A question's payload leaves out what it does not know, or says it blank."
  (and (stringp value) (not (string-blank-p value)) value))

(defun harness-ui-carry-choices (spec)
  "Return the choices of SPEC, a list, whatever way they came."
  (cl-remove-if-not #'consp (append (plist-get spec :choices) nil)))

(defun harness-ui-carry--heading (spec)
  "Return the first line of the panel of SPEC: its icon, its title and its detail."
  (concat " " (propertize (concat (harness-ui-icon (or (plist-get spec :icon) 'harness-icon-system))
                                  " " (plist-get spec :title))
                          'face 'harness-label-face)
          (if-let* ((detail (harness-ui-carry-text (plist-get spec :detail))))
              (concat "  " (propertize detail 'face (or (plist-get spec :detail-face) 'harness-dim-face)))
            "")
          "\n"))

(defun harness-ui-carry--lines (lines)
  "Return LINES, strings, as dim lines of the panel."
  (mapconcat (lambda (line)
               (propertize (concat harness-ui-carry--indent line "\n")
                           'face 'harness-dim-face 'wrap-prefix harness-ui-carry--indent))
             (delq nil lines) ""))

(defun harness-ui-carry--rows (rows)
  "Return ROWS, a list of (LABEL TEXT), as aligned lines.
The labels are padded to their widest, and a long TEXT wraps under
itself, not under its label."
  (let* ((rows (cl-remove-if-not (lambda (row) (harness-ui-carry-text (cadr row))) rows))
         (width (apply #'max 0 (mapcar (lambda (row) (string-width (car row))) rows)))
         (format-string (format "%s%%-%ds  " harness-ui-carry--indent width)))
    (mapconcat
     (lambda (row)
       (let* ((prefix (format format-string (propertize (car row) 'face 'harness-label-face)))
              (indent (make-string (string-width prefix) ?\s))
              (text (harness-ui-add-face (cadr row) 'harness-dim-face)))
         (put-text-property 0 (length text) 'wrap-prefix indent text)
         (concat prefix text "\n")))
     rows "")))

(defun harness-ui-carry--segments (choice spec)
  "Return the segments of CHOICE's wording, in order, for SPEC.
The model that writes it first, then what it does, and last that it is
the default."
  (append (delq nil (list (harness-ui-carry-text (plist-get choice :by))))
          (split-string (or (harness-ui-carry-text (plist-get choice :what)) "") " · " t)
          (and (equal (plist-get choice :choice) (plist-get spec :default)) (list "default"))))

(defun harness-ui-carry--flow (segments indent width)
  "Return SEGMENTS, strings, joined by \" · \" and broken between them.
A line takes at most WIDTH columns, the next ones INDENT columns in; with
no WIDTH the segments are one line, which the window wraps."
  (if (or (null width) (null (cdr segments)))
      (string-join segments " · ")
    (let ((room (max 24 (- width indent))) (lines nil) (line nil) (used 0))
      (dolist (segment segments)
        (let ((w (string-width segment)))
          (if (and line (> (+ used 3 w) room))
              (progn (push (string-join (nreverse line) " · ") lines)
                     (setq line (list segment) used w))
            (setq used (if line (+ used 3 w) w))
            (push segment line))))
      (when line (push (string-join (nreverse line) " · ") lines))
      (string-join (nreverse lines) (concat "\n" (make-string indent ?\s))))))

(defun harness-ui-carry--always-p (spec choice)
  "Non-nil when SPEC lets CHOICE be answered \"always\": its capital key."
  (and (plist-get spec :always) (not (equal (plist-get choice :choice) "hold"))))

(defun harness-ui-carry--help (choice spec)
  "Return the tooltip of CHOICE's button in the panel of SPEC, in one line.
It names the choice and its cost, what it does, the context after it and
the keys that answer it."
  (let ((name (plist-get choice :choice))
        (key (plist-get choice :key))
        (cost (harness-ui-carry-text (plist-get choice :cost-text)))
        (after (plist-get choice :after)))
    (harness-ui-one-line
     (string-join
      (delq nil
            (list (concat (plist-get choice :label) (if cost (format " (%s)" cost) ""))
                  (string-join (harness-ui-carry--segments choice spec) " · ")
                  (and (numberp after) (> after 0) (not (member name '("carry-on" "ignore" "hold")))
                       (format "After: ~%s tokens" (harness-format-tokens after)))
                  (concat (format "Press %s on this panel, or click" key)
                          (if (harness-ui-carry--always-p spec choice)
                              (format "; %s: default for every session, no asking" (upcase key))
                            ""))))
      " · "))))

(defun harness-ui-carry--options (spec)
  "Return the lines of the choices of SPEC: key, button, cost and wording.
The labels and the costs are columns of their own, the wording wraps
under itself, and a click on a button, or the key, answers."
  (let* ((choices (harness-ui-carry-choices spec))
         (answer (plist-get spec :answer))
         (width (plist-get spec :width))
         (label-width (apply #'max 0 (mapcar (lambda (c) (string-width (plist-get c :label))) choices)))
         (cost-column (let ((w (apply #'max 0 (mapcar (lambda (c)
                                                        (string-width (or (plist-get c :cost-text) "")))
                                                      choices))))
                        (if (> w 0) (+ w 2) 0))))
    (mapconcat
     (lambda (choice)
       (let* ((name (plist-get choice :choice))
              (key (or (plist-get choice :key) ""))
              (label (plist-get choice :label))
              (cost (or (harness-ui-carry-text (plist-get choice :cost-text)) ""))
              (prefix (concat harness-ui-carry--indent (harness-ui-kbd (format " %s " key)) " "))
              (indent (+ (string-width prefix) label-width 2 cost-column))
              (what (harness-ui-carry--flow (harness-ui-carry--segments choice spec) indent width)))
         (concat prefix
                 (harness-ui-action-button label (lambda () (when answer (funcall answer name nil)))
                                           :help (harness-ui-carry--help choice spec))
                 (make-string (- (+ label-width 2) (string-width label)) ?\s)
                 cost
                 (make-string (- cost-column (string-width cost)) ?\s)
                 (propertize what 'face 'harness-dim-face 'wrap-prefix (make-string indent ?\s))
                 "\n")))
     choices "")))

(defun harness-ui-carry--footer (spec)
  "Return the lines under the choices of SPEC.
The capitals' line when the choices can be answered \"always\", the
footer lines the question brings, and the line saying how to press a
key from the compose box."
  (let* ((choices (harness-ui-carry-choices spec))
         (capitals (cl-remove-if-not (lambda (c) (harness-ui-carry--always-p spec c)) choices))
         (footer (delq nil (plist-get spec :footer))))
    (concat
     (if (or capitals footer) "\n" "")
     (if capitals
         (concat (propertize harness-ui-carry--indent 'wrap-prefix harness-ui-carry--indent)
                 (mapconcat (lambda (c) (harness-ui-kbd (format " %s " (upcase (plist-get c :key)))))
                            capitals " ")
                 (propertize "  default for every session, no asking\n" 'face 'harness-dim-face))
       "")
     (harness-ui-carry--lines footer)
     ;; The keys type in the compose box: this is how to press one there.
     (if (if (plist-member spec :hint) (plist-get spec :hint) t)
         (propertize (concat harness-ui-carry--indent
                             (harness-compose-panel-hint (or (plist-get (car choices) :key) "b"))
                             "\n")
                     'wrap-prefix harness-ui-carry--indent)
       ""))))

(defun harness-ui-carry--paint-prefixes (string face)
  "Return STRING with its wrap prefixes in FACE, as its text is.
A line that wraps shows its `wrap-prefix' with the prefix's own faces,
not the text's: without FACE, a panel's wrapped lines would show the
buffer's background where they are indented."
  (let ((pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((next (or (next-single-property-change pos 'wrap-prefix string len) len))
            (prefix (get-text-property pos 'wrap-prefix string)))
        (when (stringp prefix)
          (put-text-property pos next 'wrap-prefix (propertize prefix 'face face) string))
        (setq pos next))))
  string)

(defun harness-ui-carry-panel-string (spec)
  "Return the panel of SPEC, a plist, as a string, without its keys.
For the keys see `harness-ui-carry-keymap'.  SPEC has these keys.  `:id'
names the panel, which is a panel of the compose box
\(`harness-compose-panel') so that \\<harness-compose-map>\\[harness-compose-panel-key] reaches its keys.
`:icon', `:title' and `:detail' make its heading, `:detail-face' the
face of the detail.  `:lines' are dim lines under it and `:rows' are
labelled facts, (LABEL TEXT) each, aligned.  `:ask' is the imperative
line over the choices, which are `:choices': plists as
`harness-carry-choice' makes them, one row each, in order, with
`:default', the name of the one marked so.  `:always' lets a capital key
answer \"always\" (not for `hold'), and says so.  `:footer' are lines
under the choices.  `:answer' is called with the name of the choice and
whether it was answered \"always\".  `:width' breaks the wording of a
choice between its segments at that many columns, for a buffer that
truncates lines instead of wrapping them.  `:hint' nil leaves out the last
line, the way to press a key from the compose box, for a host with no box."
  (let* ((string (concat (harness-ui-carry--heading spec)
                         (harness-ui-carry--lines (plist-get spec :lines))
                         (harness-ui-carry--rows (plist-get spec :rows))
                         "\n"
                         (if-let* ((ask (harness-ui-carry-text (plist-get spec :ask))))
                             (propertize (concat harness-ui-carry--indent ask "\n")
                                         'face 'bold 'wrap-prefix harness-ui-carry--indent)
                           "")
                         (harness-ui-carry--options spec)
                         (harness-ui-carry--footer spec)))
         (id (or (plist-get spec :id) t)))
    (add-text-properties 0 (length string) (list 'harness-ui-carry-panel id 'harness-compose-panel id) string)
    (harness-ui-carry--paint-prefixes (harness-ui-add-face string 'harness-ui-carry-face)
                                      'harness-ui-carry-face)))

(defun harness-ui-carry-keymap (spec &optional parent)
  "Return the keymap of the panel of SPEC: each choice's key answers it.
With `:always' its capital answers \"always\" (not for `hold').  PARENT,
a keymap, is under it: the digits of a question, say."
  (let ((map (make-sparse-keymap))
        (answer (plist-get spec :answer)))
    (when parent (set-keymap-parent map parent))
    (dolist (choice (harness-ui-carry-choices spec))
      (let ((name (plist-get choice :choice))
            (key (plist-get choice :key))
            (always (harness-ui-carry--always-p spec choice)))
        (when (and answer (stringp key) (= (length key) 1))
          (define-key map key (lambda () (interactive) (funcall answer name nil)))
          (when always
            (define-key map (upcase key) (lambda () (interactive) (funcall answer name t)))))))
    map))

(defun harness-ui-carry-render (spec)
  "Return the panel of SPEC with its keys, for a host to show.
A button keeps its own keys under them (`harness-ui-with-keymap')."
  (harness-ui-with-keymap (harness-ui-carry-panel-string spec) (harness-ui-carry-keymap spec)))

;;;; Hosts

(defvar harness-ui-carry-hosts
  '((harness-chat-mode . harness-ui-carry--redraw-compose)
    (harness-ui-tasks-mode . harness-ui-carry--redraw-compose)
    (harness-ui-sessions-mode . harness-ui-sessions--redraw))
  "The buffers that can show the panel of a question the UI asks.
Each entry is (MODE . REDRAW): a buffer whose major mode derives from MODE
is a host, and REDRAW, called without arguments in it, draws it again
with the panel (or without, once it is answered).  A host draws the panel
where its own hook puts it, and this module adds to that hook.")

(defvar-local harness-ui-carry--prompt nil
  "The question this buffer asks, or nil.
A plist (:id ID :spec FUNCTION :callback FUNCTION): FUNCTION makes the
spec of the panel (see `harness-ui-carry-panel-string') each time it is
drawn, so that it follows what changed meanwhile, and CALLBACK is called
with the name of the choice that answers it.")

(defun harness-ui-carry--redraw-compose ()
  "Draw the tail of this buffer, a chat's or a board's, again."
  (when (functionp harness-compose-redraw-function)
    (funcall harness-compose-redraw-function)))

(defun harness-ui-carry--host-entry (buffer)
  "Return the entry of `harness-ui-carry-hosts' that BUFFER is a host by, or nil."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (cl-find-if (lambda (entry) (derived-mode-p (car entry))) harness-ui-carry-hosts))))

(defun harness-ui-carry-host-p (buffer)
  "Non-nil when BUFFER can show the panel of a question."
  (and (harness-ui-carry--host-entry buffer) t))

(defun harness-ui-carry--chat (session)
  "Return the live chat buffer of SESSION, an id, or nil."
  (and session (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for session)))

(defun harness-ui-carry--session-list ()
  "Return the session list, shown, or nil when there is none to show."
  (when (fboundp 'harness-sessions)
    (harness-sessions t)
    (and (boundp 'harness-ui-sessions--buffer-name)
         (get-buffer harness-ui-sessions--buffer-name))))

(defun harness-ui-carry-host (session host)
  "Return the buffer to show a question in, or nil when there is none.
HOST is the buffer the command ran in, if it can host it
\(`harness-ui-carry-hosts'); else SESSION's own chat, if it has one; else
the session list, which is shown for it.  A switch of many sessions has
no SESSION: it asks where it was started, and never in the minibuffer."
  (cond ((harness-ui-carry-host-p host) host)
        ((harness-ui-carry-host-p (harness-ui-carry--chat session)) (harness-ui-carry--chat session))
        (t (harness-ui-carry--session-list))))

(defun harness-ui-carry-position (&optional buffer)
  "Return where the panel of the question BUFFER asks starts, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (text-property-not-all (point-min) (point-max) 'harness-ui-carry-panel nil)))

(defun harness-ui-carry-on-panel-p (&optional pos)
  "Non-nil when POS, point by default, is in the panel of a question."
  (and (get-text-property (or pos (point)) 'harness-ui-carry-panel) t))

(defun harness-ui-carry--focus ()
  "Put point on the panel of this buffer, where it shows, so its keys work."
  (when-let* ((pos (harness-ui-carry-position)))
    (when (get-buffer-window (current-buffer) t)
      (goto-char pos)
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (set-window-point window pos)))))

(defun harness-ui-carry--width ()
  "Return the columns a line of this buffer's panel may take, or nil.
A buffer that wraps its lines wraps the panel's; one that truncates them
\(the session list) needs the wording broken between its segments, to fit
the narrowest window that shows it."
  (when truncate-lines
    (let ((windows (cl-remove-if-not (lambda (window) (frame-visible-p (window-frame window)))
                                     (get-buffer-window-list (current-buffer) nil t))))
      (max 40 (1- (if windows (apply #'min (mapcar #'window-body-width windows)) 100))))))

(defun harness-ui-carry--spec (prompt)
  "Return the spec to draw PROMPT's panel with in this buffer."
  (let ((buffer (current-buffer))
        (spec (copy-sequence (funcall (plist-get prompt :spec)))))
    (setq spec (plist-put spec :id (or (plist-get spec :id) (plist-get prompt :id))))
    ;; Only a host with a compose box has a box to press a key from.
    (setq spec (plist-put spec :hint (and (harness-compose-live-p) t)))
    (setq spec (plist-put spec :answer (lambda (name _always) (harness-ui-carry--choose buffer prompt name))))
    (if-let* ((width (harness-ui-carry--width)))
        (plist-put spec :width width)
      spec)))

(defun harness-ui-carry-panel ()
  "Return the panel of the question this buffer asks, or nil.
For the hooks of the hosts (`harness-chat-panel-functions' and the like)."
  (when harness-ui-carry--prompt
    (harness-ui-carry-render (harness-ui-carry--spec harness-ui-carry--prompt))))

(defun harness-ui-carry--choose (buffer prompt name)
  "Answer PROMPT, asked in BUFFER, with the choice NAME.
The panel goes and the callback runs.  Nothing happens when PROMPT was
answered or replaced already."
  (let ((current nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq harness-ui-carry--prompt prompt)
          (setq current t
                harness-ui-carry--prompt nil)
          (harness-ui-carry--redraw))))
    (when current
      (funcall (plist-get prompt :callback) name))))

(defun harness-ui-carry--redraw ()
  "Draw this buffer again, with its panel or without."
  (when-let* ((entry (harness-ui-carry--host-entry (current-buffer))))
    (funcall (cdr entry))))

(defun harness-ui-carry-show (buffer id spec callback)
  "Ask a question in BUFFER, a host: show its panel until it is answered.
ID names the panel.  SPEC is a function of no arguments that makes the
spec of the panel (see `harness-ui-carry-panel-string') whenever it is
drawn; its `:answer' is this module's.  CALLBACK is called, once, with
the name of the choice that answers.  A question already asked in BUFFER
is replaced and never answered.  Point goes to the panel where BUFFER
shows; elsewhere the echo area says where to answer.  Return t."
  (with-current-buffer buffer
    (setq harness-ui-carry--prompt (list :id id :spec spec :callback callback))
    (harness-ui-carry--redraw)
    (harness-ui-carry--focus)
    (unless (get-buffer-window buffer t)
      (message "Choose how to carry the conversation over in %s" (buffer-name buffer))))
  t)

;;;; Setup

(defun harness-ui-carry--init ()
  "Show the panels of the questions a host asks, in the hosts."
  (add-hook 'harness-chat-panel-functions #'harness-ui-carry-panel t)
  (add-hook 'harness-ui-sessions-panel-functions #'harness-ui-carry-panel t)
  (add-hook 'harness-ui-tasks-panel-functions #'harness-ui-carry-panel t))

(harness-define-module 'ui-carry
  :doc "The panel that asks how to carry a conversation over: a cold prompt cache, a model switch."
  :requires '(ui ui-chat ui-compose)
  :init #'harness-ui-carry--init)

(provide 'harness-ui-carry)
;;; harness-ui-carry.el ends here
