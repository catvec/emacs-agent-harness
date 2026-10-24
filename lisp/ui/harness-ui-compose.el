;;; harness-ui-compose.el --- The compose box shared by harness buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The editable box at the bottom of a chat buffer and of the task
;; board.  A host buffer calls `harness-compose-setup' once from its
;; major mode, then `harness-compose-insert' wherever it draws the box
;; (after making everything before it read-only).  The box gives:
;;
;;   - multi-line editing: RET and C-j insert a newline, a placeholder
;;     shows while the box is empty;
;;   - quoting to reply: C-c > quotes the region, or the message at
;;     point, in the box as Markdown, point under it for the reply, with
;;     the compose-quote library; in a quote in the box M-RET splits it,
;;     to answer the part above, and C-c [ elides part of it as [...]
;;     (a chat's C-c > starts a thread instead, its C-u C-c > quotes);
;;   - replies in threads: a card in the box for each region replied to,
;;     what it is and the part of it quoted, with the words of the reply
;;     typed under it, in the same box (see the Threads section).  Your
;;     own message has a line above the first card, and C-c < moves
;;     point out of a reply to it, and back into the reply;
;;   - typing anywhere in the buffer goes into the box: a printable
;;     character (or a yank) with point outside it moves point to the
;;     end of the box and types there -- once the box holds a card, to
;;     the end of the area written in last, your message or a reply --
;;     unless the key is a command where it is typed -- a button's, a
;;     panel's, the task board's.  A command that acts on what is at
;;     point says where that is with a `harness-compose-acts-p'
;;     property; elsewhere its key types too;
;;   - the keys of the panels above the box from the box: a question's
;;     digits, a permission's y and n, the task board's F type when
;;     typed in the box, so C-c . reads one key and runs it on the
;;     nearest panel that binds it, point returning to the box (a
;;     numeric argument takes the Nth panel up).  A host marks the text
;;     of a panel with a `harness-compose-panel' property, naming it,
;;     and says in its hints that C-c . is the way;
;;   - M-< and M-> go to the top and the bottom of the box, and on to
;;     those of the buffer from there (or with an argument, or outside
;;     the box);
;;   - a prompt that is a field of its own: C-a stops after it, as in
;;     the minibuffer, so C-a C-k clears the box's first line;
;;   - @file completion over the project's files, or over the file
;;     system for a path (/, ~/, ./, ../); each completed file becomes
;;     an attachment, its @ reference staying in the text, and so does
;;     the file an @ reference typed out in full names, once the message
;;     is sent; @task: completion over the project's tasks, the task
;;     chosen becoming an attachment; /skill completion at its start; a
;;     popup that shows as you type (corfu, company) shows for them even
;;     while the host redraws around the box;
;;   - the project's files of a chat working in a task's git worktree
;;     are those of the worktree and of the main checkout it was made
;;     from, which has what the worktree does not (untracked files, work
;;     not merged yet): the union of both, a file in both once, read
;;     from the worktree, and each marked with where it is, [task],
;;     [main] or [task, main] (`harness-compose-roots-function');
;;   - attachments: C-c C-a finds a file the same way, by part of a
;;     project file's name or by path (C-u C-c C-a: browse the file
;;     system), or a task as task:ID (M-x harness-compose-attach-task
;;     reads one by its title), C-y pastes what the clipboard holds (an
;;     image or copied files go on the media ring; M-x
;;     harness-compose-attach-clipboard for other MIME types), files
;;     dropped on the window attach;
;;   - tokens: an attachment puts its token into the text where point
;;     is -- an image [image 1], a file @ and its path, a task
;;     @task:ID -- shown as a chip a click opens, so a sentence can name
;;     it; deleting the token removes the attachment (see the Tokens
;;     section);
;;   - the text and attachments, kept across redraws of the host;
;;   - long lines that wrap under the text, never scrolling sideways;
;;   - the attachments above the box, which a host draws with
;;     `harness-compose-insert-attachments': one a line, each fitted to
;;     the narrowest window showing them (a long name shortened in the
;;     middle, its whole path in the tooltip) and fitted again when the
;;     windows change size;
;;   - optionally, the box at the bottom of the window: a buffer shorter
;;     than its window is padded at the top so it ends on the last line;
;;   - optionally, colours of its own: a host passes `:face' for the
;;     background and `:accent' for the prompt and a bar down the left
;;     edge, to mark a box that does something else than compose -- the
;;     task board's, which sends a message to a session.  It carries the
;;     bar onto its own lines around the box with `harness-compose-bar'.
;;
;; Hosts read the box with `harness-compose-text' and
;; `harness-compose-take', expand /skill references with
;; `harness-compose-with-expanded-text' and turn attachments into ACP
;; prompt blocks with `harness-compose-attachment-block'.
;;   - attachments: C-c C-a finds a project file by part of its name
;;   - links dropped from a web page download in the background, curl
;;   - yanking media: with `harness-compose-yank-media', C-y attaches

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)
(require 'image)
(require 'harness-http)
(require 'harness-ui-media-ring)
(require 'harness-ui)
(require 'harness-ui-drag)
(require 'harness-ui-markdown)

;; compose-quote is in lisp/vendor/compose-quote, which the harness puts
;; on `load-path' (`harness--setup-load-path').  A harness older than
;; that directory, reloading after an update, first checks that this
;; file compiles with the `load-path' it has, before it loads the
;; harness.el that adds the directory.  So when the library is not found,
;; look for it beside the file being compiled or loaded.
(defvar byte-compile-current-file)
(eval-and-compile
  (unless (or (featurep 'compose-quote) (locate-library "compose-quote"))
    (when-let* ((file (or (and (boundp 'byte-compile-current-file)
                               (stringp byte-compile-current-file)
                               byte-compile-current-file)
                          load-file-name
                          buffer-file-name))
                (dir (expand-file-name "../vendor/compose-quote/" (file-name-directory file)))
                ((file-directory-p dir)))
      (add-to-list 'load-path dir))))
(require 'compose-quote)

;;;; State

(defvar-local harness-compose-start nil "Marker: first character of the compose box.")
(defvar-local harness-compose-end nil "Marker: after the last character of the compose box.")
(defvar-local harness-compose-overlay nil "Overlay over the prompt and the box.")
(defvar-local harness-compose-attachments nil "Attachments for the next message.")
(defvar-local harness-compose--placeholder nil "Overlay showing the placeholder.")
(defvar-local harness-compose--indent nil "Overlay lining the box's lines up after the prompt.")
(defvar-local harness-compose--text "" "The box's text, kept across redraws.")
(defvar-local harness-compose--files nil
  "Project files for @ completion, relative to the root they are listed in.
When the box has several roots (`harness-compose--file-roots') these are
the files of all of them, each name once.")
(defvar-local harness-compose--file-roots nil
  "The roots `harness-compose--files' are listed in, when there are several.
\(DIR . LABEL) each, the root whose copy of a file wins first, as
`harness-compose-roots-function' says.  Nil for a box with its project
alone, which is all that `harness-compose-fetch-files' lists then.")
(defvar-local harness-compose--root-files nil
  "Alist: root -> the files listed in it, relative to it.
Kept for a box with several roots, whose lists arrive one by one and are
merged into `harness-compose--files' each time (`harness-compose--arrived-in').")
(defvar-local harness-compose--file-origins nil
  "Hash table: name of a project file -> the roots that hold it.
The root a file is read from is the first of them.  Nil for a box with
its project alone.")
(defvar-local harness-compose--skills nil "Skill names for / completion.")
(defvar-local harness-compose-commands nil
  "Names of the commands this box runs as /NAME, for / completion.
The chat sets them from `harness-chat-commands'.")
(defvar-local harness-compose--pads nil "Window -> overlay padding the buffer so the box sits at the bottom.")
(defvar-local harness-compose--pad-at nil "Function returning where the padding goes, or nil for the top.")
(defvar-local harness-compose--outside 0
  "Counts the changes to the buffer outside the box, which may move it.
See `harness-compose--outside-tick'.")
(defvar-local harness-compose--typed 0 "Counts the changes confined to the box.")
(defvar-local harness-compose--jumps 0
  "Counts the times typing, or a quote, was sent from outside the box into it.
The box may be out of sight then: its windows follow it again.")
(defvar-local harness-compose--seen-tick nil
  "`buffer-chars-modified-tick' after the last change the change hooks saw.")
(defvar-local harness-compose--box-change nil "Non-nil while a change confined to the box is under way.")
(defvar-local harness-compose--files-at nil "Start of the @ token whose completion last refreshed the files.")
(defvar-local harness-compose--last-token nil "The @file or /skill token at point after the last command.")
(defvar-local harness-compose--popup-timer nil "Timer asking the completion UI to show the token's completions.")
(defvar-local harness-compose--fit-room nil
  "Pixels the attachment lines were last fitted to (`harness-compose--room').")
(defvar-local harness-compose--face 'harness-compose-face
  "Face the box's background is drawn in, set by `harness-compose-insert'.")
(defvar-local harness-compose--accent nil
  "Face of the box's prompt and bar, or nil for an ordinary box.
A host sets it through `harness-compose-insert' to mark a box that does
something else than compose: sending a message to an existing session,
say.")
(defvar-local harness-compose--detached nil
  "Attachments whose tokens were deleted from the box: (TOKEN ATT INDEX) each.
TOKEN is what the text held, [image 1] or @notes.txt, and INDEX where
ATT stood among the attachments.  The token yanked, typed or undone back
brings ATT back, to where it stood (see `harness-compose--sync-tokens').")
(defvar-local harness-compose--token-overlays nil
  "Overlays showing the tokens of the box's attachments as chips.")
(defvar-local harness-compose--thread-rails nil
  "Overlays drawing the rail beside the words under the cards of threads.")
(defvar-local harness-compose--area nil
  "Where point was last in the box, once the box held a card.
`own' for your own message, or the number of the reply it was in.  What
is typed from outside the box goes there (`harness-compose--entry-point').")
(defvar-local harness-compose--here nil
  "The area point was in after the last command, nil when it was outside the box.
Like `harness-compose--area', and what a card's hint goes by
\(`harness-compose--card-hint'): a host that draws the box again moves
point meanwhile, which says nothing of where it will be.")
(defvar-local harness-compose--reply nil
  "The number of the reply point was last in.
`harness-compose-enter-reply' goes back into it.")
(defvar-local harness-compose--area-hints nil
  "Overlays saying that an empty area of the box is your message or a reply.
See `harness-compose--area-placeholders'.")
(defvar-local harness-compose--tasks nil
  "The tasks of the box's project, as `_harness/task/list' gives them.
For @task: completion and `harness-compose-attach-task'; nil without the
task module.")
(defvar-local harness-compose--tasks-at nil "Start of the @task: token whose completion last listed the tasks.")
(defvar-local harness-compose--undo-start nil
  "Where the box started when its undo entries were last lined up with it.
See `harness-compose--line-up-undo'.")

(defvar-local harness-compose-project-function (lambda () default-directory)
  "Function returning the project root files are completed and attached from.")
(defvar-local harness-compose-roots-function nil
  "Function returning the directories the box finds project files in, or nil.
Each is (DIR . LABEL): a directory name, and the short word that marks
the candidates found in it.  The box lists the files of all of them
\(`harness-compose-fetch-files') and offers their union: a file in
several is offered once, labelled with all, and is read from the first,
so the order is the order of precedence.  A chat working in a git
worktree names the worktree and the main checkout it was made from
\(`harness-chat--roots').  Nil, or fewer than two directories, leaves
the box with its project alone (`harness-compose-project-function').")
(defvar-local harness-compose-placeholder-function (lambda () "Message…")
  "Function returning the hint shown while the box is empty.")
(defvar-local harness-compose-redraw-function #'ignore
  "Function the host redraws the box with, after the attachments change.")

(defun harness-compose--project ()
  "Return the project root, as `harness-compose-project-function' says."
  (funcall harness-compose-project-function))

;;;; Setup and drawing

(defvar harness-compose-map (make-sparse-keymap)
  "Keys of the compose box.  Host major modes use it as their keymap's parent.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-compose-map))
  (define-key map (kbd "RET") #'harness-compose-newline)
  (define-key map (kbd "S-<return>") #'harness-compose-newline)
  (define-key map (kbd "C-j") #'harness-compose-newline)
  (define-key map (kbd "C-c C-a") #'harness-compose-add-attachment)
  ;; `>' is Markdown's quote, and C-c with a punctuation key is a major
  ;; mode's to bind, the box's hosts all being major modes.
  (define-key map (kbd "C-c >") #'compose-quote-reply)
  ;; `<' is `>''s other half: out of the reply `C-c >' started, to your own
  ;; message, and back into it.
  (define-key map (kbd "C-c <") #'harness-compose-toggle-reply)
  ;; A panel's key from the box, where the key itself types.  `.' is free
  ;; after C-c in every host: the harness menu writes a view's plain keys
  ;; behind a dot as well (". F").
  (define-key map (kbd "C-c .") #'harness-compose-panel-key)
  ;; The top and the bottom of the box, not of the buffer: what the buffer
  ;; holds above the box is read, not edited.  The keys are bound, and the
  ;; commands remapped for C-<home> and the rest: a minor mode's remap of
  ;; `beginning-of-buffer' outranks a major mode's, but not a binding of
  ;; the key to a command of our own, as with C-y below.
  (define-key map (kbd "M-<") #'harness-compose-beginning-of-buffer)
  (define-key map (kbd "M->") #'harness-compose-end-of-buffer)
  (define-key map [remap beginning-of-buffer] #'harness-compose-beginning-of-buffer)
  (define-key map [remap end-of-buffer] #'harness-compose-end-of-buffer)
  ;; C-c C-v, the clipboard's key once, is the review banner's [Verify]
  ;; in a chat; unbound here so a reload frees it there too.  Other
  ;; MIME types are chosen from with M-x harness-compose-attach-clipboard.
  (define-key map (kbd "C-c C-v") nil t)
  ;; Bound here, not remapped: a minor mode's remap (Doom's
  ;; `consult-yank-pop' for M-y, say) outranks a major mode's.  The
  ;; filter makes the key fall through to its usual command when yanking
  ;; media is off, remapping included.
  (define-key map (kbd "C-y") '(menu-item "" harness-compose-yank :filter harness-compose--yank-binding))
  (define-key map (kbd "M-y") '(menu-item "" harness-compose-yank-pop :filter harness-compose--yank-binding)))

(cl-defun harness-compose-setup (&key project placeholder redraw bottom roots)
  "Make this buffer host a compose box.
PROJECT returns the project root, PLACEHOLDER the hint for the empty
box, REDRAW redraws the box (it must call `harness-compose-insert').
ROOTS, when given, returns the directories the box finds project files
in, when it has more than the project (`harness-compose-roots-function').
With BOTTOM the box sits at the bottom of every window showing the
buffer, the way a chat app keeps its input there: t pads the top of a
short buffer, a function returning a position pads there instead (a
board above the box stays at the top, the gap opens below it).

The box wraps long lines and never scrolls sideways.  Emacs wraps whole
buffers, not regions, so the host's own lines wrap too: it fits to the
window the ones that must stay on one line."
  (when bottom
    (setq harness-compose--pad-at (and (functionp bottom) bottom))
    (add-hook 'pre-redisplay-functions #'harness-compose-pad-window nil t)
    (add-hook 'before-change-functions #'harness-compose--before-change nil t)
    (add-hook 'after-change-functions #'harness-compose--after-change nil t))
  (when project (setq harness-compose-project-function project))
  (when roots (setq harness-compose-roots-function roots))
  (when placeholder (setq harness-compose-placeholder-function placeholder))
  (when redraw (setq harness-compose-redraw-function redraw))
  ;; The last one keeps windows narrower than the frame (side windows)
  ;; from truncating anyway.
  (setq-local truncate-lines nil
              word-wrap t
              truncate-partial-width-windows nil)
  (harness-compose--setup-quoting)
  (add-hook 'pre-redisplay-functions #'harness-compose-unscroll nil t)
  (add-hook 'window-size-change-functions #'harness-compose--on-resize nil t)
  (setq-local hl-line-range-function #'harness-compose-hl-line-range)
  (harness-compose--setup-drops)
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'harness-compose--yank-media-image))
  (add-hook 'kill-buffer-hook #'harness-compose--drop-pending nil t)
  (add-hook 'completion-at-point-functions #'harness-compose-completion-at-point nil t)
  (add-hook 'before-change-functions #'harness-compose--line-up-undo nil t)
  (add-hook 'pre-command-hook #'harness-compose--line-up-undo nil t)
  (add-hook 'pre-command-hook #'harness-compose--pre-command nil t)
  (add-hook 'post-command-hook #'harness-compose-update-placeholder nil t)
  (add-hook 'post-command-hook #'harness-compose--after-command nil t)
  ;; Last, so it runs first: it may change the text the others look at.
  (add-hook 'post-command-hook #'harness-compose--keep-tokens nil t))

(defun harness-compose-live-p ()
  "Non-nil when the compose markers point into this buffer."
  (and harness-compose-start harness-compose-end
       (eq (marker-buffer harness-compose-start) (current-buffer))
       (<= harness-compose-start harness-compose-end)))

(defun harness-compose-capture ()
  "Remember the box's text, before the host deletes it to redraw."
  (when (harness-compose-live-p)
    (setq harness-compose--text
          (buffer-substring-no-properties harness-compose-start harness-compose-end))))

(defun harness-compose-text ()
  "Return the text in the box."
  (harness-compose-capture)
  harness-compose--text)

(defun harness-compose-in-p (&optional pos)
  "Non-nil when POS (default point) is inside the box."
  (let ((p (or pos (point))))
    (and (harness-compose-live-p) (>= p harness-compose-start) (<= p harness-compose-end))))

(defvar harness-compose--progress)

(defun harness-compose-insert-attachments (&optional prefix)
  "Insert the attachments at point, one a line (nothing without attachments).
The paperclip leads the first line, and the names below line up with
its name.  Every line fits the narrowest window showing the buffer
\(`harness-compose--room'): a name too long for it is shortened in the
middle, its whole path in the tooltip, and once a window changes size
the host draws the lines again (`harness-compose--on-resize').  Files,
images, captures and downloads are laid out alike.  PREFIX, a string,
starts every line, such as the bar of a box with an accent
\(`harness-compose-bar').

An image shows its thumbnail, and so does a video once one is made; a
link still downloading shows its progress, which an overlay redraws, so
the text is left alone while it ticks."
  (dolist (p harness-compose--progress) (delete-overlay (cdr p)))
  (setq harness-compose--progress nil
        harness-compose--fit-room (harness-compose--room))
  ;; A reply in a thread is a card in the box, not a line of this list.
  (when-let* ((atts (cl-remove-if #'harness-compose--thread-attachment-p harness-compose-attachments)))
    (let* ((prefix (or prefix ""))
           (lead (concat " " (propertize (harness-ui-icon 'harness-icon-attach) 'face 'harness-dim-face) " "))
           ;; As wide as the paperclip's lead, whatever the icon's size.
           (indent (propertize " " 'display `(space :width (,(harness-compose--pixels lead)))))
           (room (- harness-compose--fit-room (harness-compose--pixels (concat prefix lead)))))
      (cl-loop for att in atts
               for first = t then nil
               do (let ((start (point)))
                    (insert prefix (if first lead indent))
                    (if (plist-get att :pending)
                        (harness-compose--insert-pending-chip att room)
                      (insert (harness-compose--chip att room)))
                    (insert "\n")
                    ;; Should a line wrap all the same (a window narrower
                    ;; than any name), it goes on under the names.
                    (put-text-property start (point) 'wrap-prefix (concat prefix indent))))
      (harness-compose--start-progress))))

(defun harness-compose--room ()
  "Return how wide an attachment line may show, in pixels.
That is the body of the narrowest window showing the buffer, so that
the lines fit in every one, less a column for the continuation glyph of
a window without fringes.  A window of the initial frame, which a
daemon never shows, counts only when there is no other (batch mode).
Windows compare in columns, which frames of another font or a text
terminal share, and the result is in pixels of the selected frame,
where the lines are measured (`harness-compose--pixels').  With no
window, the width the lines were last fitted to, else the selected
frame's."
  (let* ((all (get-buffer-window-list nil nil t))
         (windows (or (cl-remove-if (lambda (w) (harness-compose--initial-frame-p (window-frame w))) all)
                      all)))
    (if windows
        (* (frame-char-width) (apply #'min (mapcar (lambda (w) (1- (window-body-width w))) windows)))
      (or harness-compose--fit-room (* (frame-char-width) (1- (frame-width)))))))

(defun harness-compose--initial-frame-p (frame)
  "Non-nil when FRAME is the initial frame, which a daemon never shows."
  (if (fboundp 'frame-initial-p)
      (frame-initial-p frame)
    ;; Before Emacs 31.
    (equal (terminal-name (frame-terminal frame)) "initial_terminal")))

(defun harness-compose--pixels (string)
  "Return how wide STRING shows in this buffer, in pixels.
Its images and faces count, and so does the buffer's face remapping."
  (string-pixel-width string (current-buffer)))

(defun harness-compose--on-resize (_window)
  "Have the attachment lines fitted again once the windows settle.
A window showing the buffer appeared or changed size: when that changes
the room the lines have (`harness-compose--room'), the host draws them
again, once the resizing has stopped.  Runs from
`window-size-change-functions'."
  (when (and harness-compose-attachments (not (eql harness-compose--fit-room (harness-compose--room))))
    ;; Later than a host's own refit (the board's), which makes this one moot.
    (harness-debounce (list 'harness-compose-refit (current-buffer)) 0.2 #'harness-compose--refit (current-buffer))))

(defun harness-compose--refit (buffer)
  "Draw BUFFER's attachments again unless they fit its windows already."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and harness-compose-attachments (not (eql harness-compose--fit-room (harness-compose--room))))
        (harness-compose-redraw)))))

(defconst harness-compose--min-name 10
  "Columns an attachment's name keeps, however narrow the window.
In a window too narrow for the line with that much of the name, the
line wraps instead.")

(defun harness-compose--shorten (name width)
  "Return NAME in at most WIDTH columns, its middle elided with \"…\".
A path keeps its file name whole when that leaves a few columns of the
directories in front, so the file still reads at a glance; a name with
no directory keeps as much of its start as of its end, extension and
all."
  (if (<= (string-width name) width)
      name
    (let* ((keep (max 0 (1- width)))
           (slash (string-match-p "/[^/]+\\'" name))
           (file (and slash (string-width (substring name slash))))
           (tail (if (and file (<= (+ file 4) keep)) file (/ keep 2))))
      (concat (truncate-string-to-width name (- keep tail)) "…"
              (harness-compose--last-columns name tail)))))

(defun harness-compose--last-columns (string width)
  "Return the longest end of STRING that takes at most WIDTH columns."
  (let ((start (length string)) (used 0))
    (while (and (> start 0) (<= (+ used (char-width (aref string (1- start)))) width))
      (setq start (1- start)
            used (+ used (char-width (aref string start)))))
    (substring string start)))

(defun harness-compose--fit (name room render)
  "Return NAME, shortened in the middle as much as ROOM pixels need.
RENDER makes the text that shows a name, which is what must fit in
ROOM.  NAME keeps `harness-compose--min-name' columns at least."
  (if (<= (harness-compose--pixels (funcall render name)) room)
      name
    ;; The longest shortening that fits: a binary search over its width.
    (let ((low harness-compose--min-name)
          (high (1- (string-width name)))
          (best nil))
      (while (<= low high)
        (let* ((mid (/ (+ low high) 2))
               (short (harness-compose--shorten name mid)))
          (if (<= (harness-compose--pixels (funcall render short)) room)
              (setq best short low (1+ mid))
            (setq high (1- mid)))))
      (or best (harness-compose--shorten name harness-compose--min-name)))))

(defun harness-compose-bar (&optional accent face)
  "Return the bar of a compose box in ACCENT on background FACE, and a space.
ACCENT and FACE default to the ones the box was last drawn with
\(`harness-compose--accent', `harness-compose--face'), so a host can carry
the bar onto the lines it draws around the box, such as the label saying
what the box does.  Two columns wide, the bar and a space; empty when
the box has no accent, since an ordinary box has no bar."
  (let ((accent (or accent harness-compose--accent))
        (face (or face harness-compose--face)))
    (if (null accent)
        ""
      (propertize "▌ " 'face (delq nil (list accent face))))))

(cl-defun harness-compose-insert (&optional text help &key face accent)
  "Insert the prompt and the box at point, holding TEXT or the kept text.
HELP is the prompt's tooltip.  FACE is the background to draw the box
in, `harness-compose-face' by default.  ACCENT, when given, is the face
of the box's prompt and the bar down its left edge, which marks a box
that does something else than compose -- sending a message to a session,
say.  Point ends after the box's final newline.  The tokens of its
attachments show as chips (`harness-compose--show-tokens')."
  (dolist (ov (append (list harness-compose-overlay harness-compose--placeholder harness-compose--indent)
                      harness-compose--token-overlays harness-compose--thread-rails
                      harness-compose--area-hints))
    (when ov (delete-overlay ov)))
  (setq harness-compose--token-overlays nil
        harness-compose--thread-rails nil
        harness-compose--area-hints nil)
  (when text
    ;; New text: the attachments whose tokens were deleted go for good.
    (setq harness-compose--text text
          harness-compose--detached nil))
  (let* ((background (or face 'harness-compose-face))
         (accent (and accent (list accent background)))
         (prompt (if accent (concat (harness-compose-bar (car accent) background) "❯ ") "❯ "))
         (label-start (point)))
    (setq harness-compose--face background
          harness-compose--accent (car accent))
    ;; The prompt is a field of its own, like the minibuffer's: C-a, and
    ;; whatever finds the line's start with `line-beginning-position',
    ;; stops after it, so C-a C-k clears the line rather than running
    ;; into the read-only prompt.  Rear-nonsticky, so text typed after
    ;; the prompt takes neither its field nor its read-only.
    (insert (propertize prompt 'face (or accent (list 'harness-dim-face background))
                        'help-echo help
                        'read-only t 'rear-nonsticky t 'field 'harness-compose-prompt))
    (setq harness-compose-start (copy-marker (point)))
    (insert harness-compose--text)
    (let ((end (point)))
      (insert (propertize "\n" 'read-only t))
      (setq harness-compose-end (copy-marker end t)))
    ;; FRONT-ADVANCE: text the host inserts just before the box stays outside.
    (setq harness-compose-overlay (make-overlay label-start (point) nil t t))
    (overlay-put harness-compose-overlay 'face background)
    ;; Wrapped lines, and lines after a newline, start under the text
    ;; rather than under the prompt.  The overlay starts after the prompt,
    ;; so the prompt's line gets no prefix, and ends after the final
    ;; newline, so an empty last line already has one.  A prefix is drawn
    ;; in the default face unless it brings its own.
    (let* ((width (string-width (buffer-substring label-start harness-compose-start)))
           (indent (if (car accent)
                       (concat (harness-compose-bar (car accent) background)
                               (propertize (make-string (- width 2) ?\s) 'face background))
                     (propertize (make-string width ?\s) 'face background))))
      (setq harness-compose--indent (make-overlay harness-compose-start (point)))
      (overlay-put harness-compose--indent 'line-prefix indent)
      (overlay-put harness-compose--indent 'wrap-prefix indent))
    (setq harness-compose--placeholder (make-overlay (1- (point)) (point)))
    (harness-compose-update-placeholder)
    (harness-compose--show-tokens)))

(defun harness-compose-update-placeholder ()
  "Show the placeholder while the box is empty.
A box that holds cards says what each of its empty areas is the same
way (`harness-compose--show-area-hints')."
  (when (and harness-compose--placeholder (overlay-buffer harness-compose--placeholder)
             (harness-compose-live-p))
    (overlay-put harness-compose--placeholder 'before-string
                 (and (= harness-compose-start harness-compose-end)
                      ;; Overlay strings miss the compose overlay's face.
                      (propertize (funcall harness-compose-placeholder-function)
                                  'face (list 'harness-dim-face harness-compose--face)
                                  'cursor t))))
  ;; From `post-command-hook': a failure must not take the hook off.
  (condition-case err
      (harness-compose--show-area-hints)
    (error (harness-log 'warn "compose: naming the empty areas failed: %S" err))))

(defun harness-compose-hl-line-range ()
  "Return the `hl-line-mode' range, empty inside the box.
The line highlight would cover the compose background, and outranking it
would hide the region too.  Never nil: `global-hl-line-mode' needs a range."
  (if (and harness-compose-overlay (overlay-buffer harness-compose-overlay)
           (>= (point) (overlay-start harness-compose-overlay)))
      (cons (point) (point))
    (cons (line-beginning-position) (line-beginning-position 2))))

(defconst harness-compose--typing-commands
  '(self-insert-command quoted-insert insert-char
    yank yank-pop clipboard-yank harness-compose-yank harness-compose-yank-pop)
  "Commands that type into the buffer: outside the box they type into it.")

;; A command bound to a printable key outside the box that acts on what
;; is at point -- a card of the task board, an option of a question --
;; says where it has something to act on with a `harness-compose-acts-p'
;; property: a function of no arguments, called in the buffer with point
;; where the key is typed.  Where it returns nil the key types, into the
;; box, instead of signalling that there is nothing there.  The keymaps
;; stay as they are, so help still lists the key under the command.

(defun harness-compose--idle-p (command)
  "Non-nil when COMMAND says it has nothing to act on at point.
That is its `harness-compose-acts-p' property returning nil.  An error
in the property counts as something to act on: the command then says
what is wrong."
  (when-let* ((acts (and (symbolp command) (get command 'harness-compose-acts-p))))
    (not (condition-case nil (funcall acts) (error t)))))

(defun harness-compose--typing-command ()
  "Return the command the key about to run types into the box with, or nil.
That is the key's command when it is one of
`harness-compose--typing-commands', as bound or before a remapping (a
minor mode's own `self-insert-command', say).  A printable character
that does nothing where it is typed -- unbound, `undefined' as in a
keymap that suppresses typing, or bound to a command with nothing to act
on at point outside the box (see `harness-compose--idle-p') -- types
too when it does in the box: its command is then the one it has there.
Any other key is a command where it is typed, not typing: nil."
  (cond
   ((or (memq this-command '(nil undefined))
        (and (not (harness-compose-in-p)) (harness-compose--idle-p this-command)))
    (and (characterp last-command-event)
         (aref printable-chars last-command-event)
         (equal (this-command-keys-vector) (vector last-command-event))
         (let ((command (key-binding (this-command-keys-vector) t nil harness-compose-end)))
           (and command (not (eq command 'undefined)) command))))
   ((or (memq this-command harness-compose--typing-commands)
        (memq this-original-command harness-compose--typing-commands))
    this-command)))

(defun harness-compose--pre-command ()
  "Send typing that lands outside the box into it.
Typing (see `harness-compose--typing-command') with point outside the
box moves point to the end of the box first, so a printable character
typed anywhere in the buffer goes into the box instead of signalling
that the text is read-only or doing nothing.  Once the box holds a
card, the end of the area written in last is where it goes, your own
message or a reply (`harness-compose--entry-point'): a message
stepped out of a reply into (\\<harness-compose-map>\\[harness-compose-toggle-reply]) stays the message, whatever is
read or clicked in between.  A key bound to a command
where point is -- a button's RET, a panel's digits, the task board's
letters -- is not typing, and runs as usual, unless the command has
nothing to act on there.

In the box the same keys type, whatever panel is above it.  To press
one on a panel from the box, \\<harness-compose-map>\\[harness-compose-panel-key] reads the key and runs
it there, as if point were on the panel (`harness-compose-panel-key').
At the edge of a card -- where moving up from a reply puts point -- they
type into the area next to it, not against the card
\(`harness-compose--card-edge-target').

A region reaching outside the box goes before the typing: with
`delete-selection-mode' the typing would delete it, read-only text and
all, and fail."
  (when-let* ((command (and (harness-compose-live-p) (harness-compose--typing-command))))
    (when (and (region-active-p)
               (not (and (harness-compose-in-p (region-beginning))
                         (harness-compose-in-p (region-end)))))
      (deactivate-mark))
    (unless (harness-compose-in-p)
      ;; The box may be out of sight: its windows follow it again.
      (cl-incf harness-compose--jumps))
    ;; A hook that signals is taken off the hook: whatever goes wrong
    ;; with the areas of a box with cards, typing goes where it did.
    (condition-case err
        (if (harness-compose-in-p)
            ;; At the edge of a card, which is no text to type against: the
            ;; words go into the area next to it (`harness-compose--card-edge-target').
            (unless (region-active-p)
              (when-let* ((target (harness-compose--card-edge-target (point))))
                (goto-char target)))
          (goto-char (harness-compose--entry-point)))
      (error
       (harness-log 'warn "compose: finding where typing goes failed: %S" err)
       (unless (harness-compose-in-p) (goto-char harness-compose-end))))
    (setq this-command command)))

;;;; A panel's key, from the box

;; A panel above the box -- a question's options, a permission's answers,
;; the task board -- has keys that act on it while point is on it.  Typed
;; in the box the same key types (`harness-compose--pre-command'), so
;; C-c . is the one way to press it from there: it reads a key, finds the
;; panel that binds it, and runs what the key does on that panel, as
;; though point were on it, then puts point back in the box.
;;
;; The host says which text is a panel with a `harness-compose-panel'
;; property, valued with something that names it: a request's id, `board',
;; `popout'.  The text next to it with an `equal' value is part of it,
;; however many pieces the host drew it in.  A panel's keys are those of
;; its own `keymap' (or `local-map') property; what the buffer's modes
;; bind is the buffer's, and no panel's.  The panel is where its text
;; starts, which is where its keymap and its `harness-compose-acts-p'
;; commands are asked.

(defun harness-compose-panel-keys ()
  "Return the key that presses a panel's key from the box, as text.
That is where `harness-compose-panel-key' is bound in `harness-compose-map',
so that the hints saying how to reach a panel from the box follow a
rebinding of it."
  (substitute-command-keys "\\<harness-compose-map>\\[harness-compose-panel-key]" t))

(defun harness-compose-panel-hint (key)
  "Return the dim hint saying how to press KEY on a panel from the box.
It reads \"from the box: \\<harness-compose-map>\\[harness-compose-panel-key] KEY\", the first key being where the
box binds `harness-compose-panel-key' (`harness-compose-panel-keys').  A
panel puts it on a line of its own, or after the line telling to type an
answer below, with a key of its own for KEY: its first option's, say."
  (concat (propertize "from the box: " 'face 'harness-dim-face)
          (harness-ui-kbd (format "%s %s" (harness-compose-panel-keys) key))))

(defun harness-compose--panel-before (pos)
  "Return the panel nearest before POS, as (START . END), or nil.
That is the one ending at POS or, if the text before POS is no panel,
the first one to be found going back; see `harness-compose-panel-key'."
  (let ((end pos) value)
    (while (and (> end (point-min))
                (not (setq value (get-char-property (1- end) 'harness-compose-panel))))
      (setq end (previous-single-char-property-change end 'harness-compose-panel)))
    (when value
      (let ((start (previous-single-char-property-change end 'harness-compose-panel)))
        ;; Pieces of one panel may have values that are `equal' but not `eq'.
        (while (and (> start (point-min))
                    (equal value (get-char-property (1- start) 'harness-compose-panel)))
          (setq start (previous-single-char-property-change start 'harness-compose-panel)))
        (cons start end)))))

(defun harness-compose--panel-command (keys pos)
  "Return the command KEYS run on the panel starting at POS, or nil.
The panel itself binds KEYS, in its `keymap' or `local-map' property, to
a command that is not typing and not `undefined'."
  (when (cl-some (lambda (property)
                   (let ((map (get-char-property pos property)))
                     (and (keymapp map)
                          (let ((binding (lookup-key map keys t)))
                            (and binding (not (numberp binding)))))))
                 '(keymap local-map))
    (let ((command (key-binding keys t nil pos)))
      (and command (commandp command)
           (not (eq command 'undefined))
           (not (memq command harness-compose--typing-commands))
           command))))

(defun harness-compose--on-panel-p (pos)
  "Non-nil when POS is in a panel, or right after one."
  (or (get-char-property pos 'harness-compose-panel)
      (and (> pos (point-min)) (get-char-property (1- pos) 'harness-compose-panel))))

(defun harness-compose--press-on-panel (keys command pos)
  "Run COMMAND, which KEYS run on the panel starting at POS, with point there.
Point goes back afterwards: to where it was in the box, at the same
offset in it, after the host drew the panels and the box again, as
answering a question does; or, from outside the box, to where it was.  It
stays where the command left it when that is above the box and on no
panel -- the command took it elsewhere, as to the transcript -- or in
another buffer.  Where the text point was on was deleted and drawn again,
point is where the host left it: in the box or after it, on a panel, or
at the start of the text that took the panel's place.  The prefix
argument was the panel's number: the command gets none."
  (let* ((buffer (current-buffer))
         (offset (and (harness-compose-in-p) (- (point) harness-compose-start)))
         (origin (copy-marker (point)))
         ;; Unmoved, or where a redraw of the panel left it: its start.
         (start (copy-marker pos)))
    (unwind-protect
        (progn
          (goto-char pos)
          (setq this-command command)
          (let ((current-prefix-arg nil)
                (last-command-event (car (last (listify-key-sequence keys)))))
            (call-interactively command)))
      (when (and (buffer-live-p buffer) (eq buffer (current-buffer))
                 (or (and (harness-compose-live-p) (>= (point) harness-compose-start))
                     (= (point) start)
                     (harness-compose--on-panel-p (point))))
        (cond ((null offset) (goto-char origin))
              ((harness-compose-live-p)
               (goto-char (min (+ harness-compose-start offset) harness-compose-end)))))
      (set-marker origin nil)
      (set-marker start nil))))

(defun harness-compose-panel-key (&optional n)
  "Press a key on a panel above the box, from the box.
The panels are the parts of the buffer above the box that bind keys of
their own, which type in the box as they do not act there: a question's
digits, a permission's y and n, the task board's F.  This reads one key
and runs what it does on the panel nearest above the box that binds it,
as though point were on the panel, then puts point back in the box.  With
numeric argument N, it is the Nth such panel up.  \\[keyboard-quit] quits.

A key the panel binds to a command that acts on what point is on, and
point is on nothing it acts on there -- the board's card keys, an
option a question has not -- is no key to press from the box: that is
said, and nothing runs."
  (interactive "p")
  (unless (harness-compose-live-p) (user-error "No compose box here"))
  (let* ((n (max 1 (or n 1)))
         (keys (read-key-sequence (if (> n 1)
                                      (format "Key for panel %d above (C-g quits): " n)
                                    "Key for the panel above (C-g quits): ")))
         (key (key-description keys))
         (pos (harness-compose--front))
         (found 0) (idle nil) (panel nil) (command nil))
    (while (and (not command) (setq panel (harness-compose--panel-before pos)))
      (setq pos (car panel))
      (when-let* ((candidate (harness-compose--panel-command keys pos)))
        (if (save-excursion (goto-char pos) (harness-compose--idle-p candidate))
            (setq idle t)
          (when (= (cl-incf found) n)
            (setq command candidate)))))
    (cond (command (harness-compose--press-on-panel keys command pos))
          ((> found 0) (user-error "Fewer than %d panels above the box have %s" n key))
          (idle (user-error "%s has nothing to act on from the box: it works on what point is on" key))
          (t (user-error "No panel above the box has %s" key)))))

;;;; The top and the bottom of the box

(defun harness-compose-beginning-of-buffer (&optional arg)
  "Move to the top of the compose box; from there, to the top of the buffer.
In the box, below its first character, this leaves the mark where point
was and goes to the box's start, as `beginning-of-buffer' does for the
buffer (no mark with an active region).  Outside the box, at its start
already, or with a prefix argument ARG, it is `beginning-of-buffer'; so
a second \\<harness-compose-map>\\[harness-compose-beginning-of-buffer] from the box's top reaches the buffer's."
  (interactive "^P")
  (if (and (null arg) (harness-compose-in-p) (> (point) harness-compose-start))
      (progn (or (region-active-p) (push-mark))
             (goto-char harness-compose-start))
    (call-interactively #'beginning-of-buffer)))

(defun harness-compose-end-of-buffer (&optional arg)
  "Move to the bottom of the compose box; from there, to the bottom of the buffer.
In the box, above its last character, this leaves the mark where point
was and goes to the box's end, as `end-of-buffer' does for the buffer
\(no mark with an active region).  Outside the box, at its end already,
or with a prefix argument ARG, it is `end-of-buffer'; so a second
\\<harness-compose-map>\\[harness-compose-end-of-buffer] from the box's bottom reaches the buffer's."
  (interactive "^P")
  (if (and (null arg) (harness-compose-in-p) (< (point) harness-compose-end))
      (progn (or (region-active-p) (push-mark))
             (goto-char harness-compose-end))
    (call-interactively #'end-of-buffer)))

(defun harness-compose--before-change (beg end)
  "Note whether the change from BEG to END stays in the box.
Runs from `before-change-functions'."
  ;; First count a change made unseen since the last one.
  (harness-compose--outside-tick)
  (setq harness-compose--box-change (and (harness-compose-in-p beg) (harness-compose-in-p end))))

(defun harness-compose--after-change (_beg _end _len)
  "Count the change just made, in the box or outside it.
Runs from `after-change-functions'."
  (if harness-compose--box-change
      (cl-incf harness-compose--typed)
    (cl-incf harness-compose--outside))
  (setq harness-compose--box-change nil
        harness-compose--seen-tick (buffer-chars-modified-tick)))

(defun harness-compose--outside-tick ()
  "Return a number that changes whenever the buffer changed outside the box.
Changes the change hooks saw are counted as they happen; text changed
with them inhibited (a rendering redrawn in place, say) counts too,
wherever it was.  Text properties changed that way, as `jit-lock' does
all the time, do not."
  (unless (eql harness-compose--seen-tick (buffer-chars-modified-tick))
    (cl-incf harness-compose--outside)
    (setq harness-compose--seen-tick (buffer-chars-modified-tick)))
  harness-compose--outside)

(defconst harness-compose--measure-whole 8000
  "The longest box, in characters, whose height is measured whole.")

(defun harness-compose--box-height (window limit)
  "Return what the height of the box's lines in WINDOW stands at.
Only the box is laid out, however long the buffer: one of up to
`harness-compose--measure-whole' characters whole, which is quick, and
its height in pixels is the answer.  A longer box is laid out up to
LIMIT pixels; one taller than that answers its height so far with the
count of changes to it (`harness-compose--typed'), as that is all that
says it may have grown."
  (if (<= (- harness-compose-end harness-compose-start) harness-compose--measure-whole)
      (cdr (window-text-pixel-size window harness-compose-start harness-compose-end))
    (let ((height (harness-ui-text-height window harness-compose-start harness-compose-end limit)))
      (if (> height limit) (list height harness-compose--typed) height))))

(defun harness-compose-pad-window (window)
  "Keep the box at the bottom of WINDOW.
A buffer shorter than WINDOW is padded so it ends at its bottom, each
window with its own overlay; a taller one scrolls to keep the box there
while the window's point is in it (`harness-compose--follow').  Runs
from `pre-redisplay-functions', before every redisplay, so after every
key: measuring the window lays out a window's worth of text, which
typing would wait on.  The window is measured again only once the
buffer changed outside the box (`harness-compose--outside-tick'), the
box changed height or the window changed; a key typed in the box costs
the box's lines alone (`harness-compose--box-height')."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             (harness-compose-live-p))
    ;; A dropped overlay is deleted too: kept, it would pad its window
    ;; again, twice over, once the window shows the buffer again.
    (setq harness-compose--pads
          (cl-remove-if-not (lambda (p) (or (and (window-live-p (car p)) (overlay-buffer (cdr p))
                                                 (eq (window-buffer (car p)) (current-buffer)))
                                            (progn (delete-overlay (cdr p)) nil)))
                            harness-compose--pads))
    (let* ((body (window-body-height window t))
           (outside (harness-compose--outside-tick))
           (measured (list outside (harness-compose--box-height window body))))
      (harness-compose--follow window measured)
      (let* ((ov (or (alist-get window harness-compose--pads)
                     (let ((o (make-overlay (point-min) (point-min) nil t)))
                       (overlay-put o 'window window)
                       (push (cons window o) harness-compose--pads)
                       o)))
             (at (if harness-compose--pad-at (funcall harness-compose--pad-at) (point-min)))
             (start (window-start window))
             (key (list measured body (window-body-width window t) start at)))
        (unless (equal key (overlay-get ov 'harness-compose-key))
          (overlay-put ov 'harness-compose-key key)
          (unless (eql (overlay-start ov) at) (move-overlay ov at at))
          ;; A window showing the buffer from further down has no padding,
          ;; and nothing to measure.
          (let ((pad nil))
            (when (= start (point-min))
              ;; Measured without the padding.
              (when (overlay-get ov 'before-string) (overlay-put ov 'before-string nil))
              ;; Padding at the top leaves a line for the empty one after
              ;; the box, where a host following the end (chat) puts the
              ;; bottom of the window; padding inside the buffer puts the
              ;; box on the last line.
              (let* ((line (frame-char-height (window-frame window)))
                     ;; More than BODY for a buffer taller than the window: no padding.
                     (used (harness-ui-text-height window (point-min) harness-compose-end body))
                     (lines (/ (- body used (if harness-compose--pad-at 0 line)) line)))
                (when (> lines 0)
                  ;; An explicit face: bare newlines would take the height of the
                  ;; text they precede (a smaller label face) and fall short.
                  (setq pad (propertize (make-string lines ?\n) 'face 'default)))))
            ;; Left alone when it stays the same: a changed overlay makes
            ;; redisplay draw the whole window again.
            (unless (equal pad (overlay-get ov 'before-string))
              (overlay-put ov 'before-string pad))))))))

(defun harness-compose-repad (window)
  "Drop WINDOW's padding so the next redisplay sizes it again.
A host about to scroll WINDOW calls this first: `recenter' would count
the padding as lines to keep in view."
  (when-let* ((pad (alist-get window harness-compose--pads)))
    (overlay-put pad 'before-string nil)
    (overlay-put pad 'harness-compose-key nil)))

(defun harness-compose-unscroll (window)
  "Scroll WINDOW back to its left edge.
The box wraps rather than scrolling sideways, yet \\[scroll-left] or a
shifted mouse wheel would still scroll the window, and a window scrolled
sideways truncates every line, the box's too.  Runs from
`pre-redisplay-functions'.  A buffer whose lines were made to truncate
again by hand is left to `auto-hscroll-mode'."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             (not truncate-lines) (/= (window-hscroll window) 0))
    (set-window-hscroll window 0)))

(defun harness-compose--follow (window measured)
  "Keep the box on WINDOW's last line while the window's point is in it.
The box's lines wrap, so it grows and shrinks as it is typed in, and
the host redraws around it.  Emacs would recenter once the box falls
off the bottom and leave a gap under it once it shrinks; instead WINDOW
scrolls just enough to keep the box's last line on its last line (above
the spare line of a host padding its top), the way a chat app's input
grows upwards.  A buffer that fits shows from its start, for the
padding.  Only after the text or the window's size changed: scrolling
is left to the user.

What it checks depends on the buffer outside the box, the box's height,
the window's size and the window's start.  MEASURED, from
`harness-compose-pad-window', stands for the first two: it changes once
the buffer changed outside the box or the box changed height (see
`harness-compose--box-height').  So it checks again once one of them
changed or typing jumped into the box (`harness-compose--jumps'); and
for the first change to the box after the window scrolled, as typing
brings the box back, but not for every key typed in the box: each check
lays out a window's worth of text.

The window's start is never forced: were point's line to fall outside
the window from there, redisplay would move point, out of the box, to
the window's last whole line or its middle, where a host's keys may be
commands, rather than scroll."
  (let ((key (list (current-buffer) measured harness-compose--jumps
                   (window-body-width window t) (window-body-height window t)))
        ;; (KEY START TYPED): the window's start after the last check, and
        ;; the box's changes then.
        (last (window-parameter window 'harness-compose-follow)))
    (unless (and (equal key (car-safe last))
                 (or (eql (window-start window) (nth 1 last))
                     (eql harness-compose--typed (nth 2 last))))
      ;; Noted first, so a check that fails is not made again on every
      ;; redisplay; the start it scrolls to is filled in after.
      (setq last (list key (window-start window) harness-compose--typed))
      (set-window-parameter window 'harness-compose-follow last)
      (when (harness-compose-in-p (window-point window))
        ;; Measured without the padding, which is sized again after this.
        (harness-compose-repad window)
        (let* ((body (window-body-height window t))
               (line (frame-char-height (window-frame window)))
               (room (- body (if harness-compose--pad-at 0 line)))
               ;; Exact up to ROOM and more than ROOM beyond, so a buffer
               ;; taller than the window never reads as one that fits:
               ;; showing it from its start would push point, and the
               ;; box with it, out of the window on every redraw.
               (height (lambda (from) (harness-ui-text-height window from harness-compose-end room)))
               (start (window-start window))
               (pt (window-point window))
               (anchor (if harness-compose--pad-at harness-compose-end (point-max))))
          (cond
           ((<= (funcall height (point-min)) room)
            (unless (= start (point-min)) (set-window-start window (point-min) t)))
           ;; Grown past the bottom.  Point's line goes there instead when
           ;; the box from point on is taller than the window.
           ((not (pos-visible-in-window-p pt window))
            (harness-compose--bottom-at
             window (if (<= (funcall height (save-excursion (goto-char pt) (vertical-motion 0 window) (point)))
                            room)
                        anchor
                      pt)))
           ;; Shrunk, leaving a gap under the box.
           ((and (> start (point-min)) (<= line (- room (funcall height start))))
            (harness-compose--bottom-at window anchor))))
        (setcar (cdr last) (window-start window))))))

(defun harness-compose--bottom-at (window pos)
  "Scroll WINDOW so the screen line of POS is its last."
  (with-selected-window window
    (save-excursion (goto-char pos) (recenter -1))))

;;;; Editing and reading

(defun harness-compose-set (text)
  "Replace the box's contents with TEXT.
The attachments whose tokens were deleted from the old text cannot come
back."
  (setq harness-compose--text text
        harness-compose--detached nil
        harness-compose--area nil
        harness-compose--here nil
        harness-compose--reply nil)
  (when (harness-compose-live-p)
    (let ((inhibit-read-only t))
      (delete-region harness-compose-start harness-compose-end)
      (save-excursion (goto-char harness-compose-start) (insert text)))
    (harness-compose-update-placeholder)
    (harness-compose--show-tokens)))

(defun harness-compose-clear ()
  "Empty the box and drop the attachments, then redraw."
  (harness-compose-set "")
  (harness-compose--drop-pending)
  (setq harness-compose-attachments nil)
  (funcall harness-compose-redraw-function))

(defun harness-compose-take ()
  "Return (TEXT . ATTACHMENTS) from the box, or signal when both are empty.
The files that @ references typed out in TEXT name are attached too,
after the box's own attachments (`harness-compose--references'), each
file once; the references stay in TEXT.  A box with cards of threads
\(see the Threads section) is split at them: TEXT is the message's own
words, and each reply is an attachment first among ATTACHMENTS, with
the words under its card as `:response'; a card with none signals.  A
link still downloading signals too: the message waits for it.  The
attachments with a token are those whose tokens TEXT holds
\(`harness-compose--sync-tokens'): an image with its label, a file with
its reference, a task."
  (when (harness-compose--sync-tokens) (harness-compose-redraw))
  (let* ((whole (string-trim (harness-compose-text)))
         (atts harness-compose-attachments)
         (split (harness-compose--split-threads whole atts))
         (text (car split))
         (threads (cdr split)))
    (when (and (string-empty-p whole) (null atts)) (user-error "Nothing to send"))
    (when-let* ((pending (cl-find-if (lambda (a) (plist-get a :pending)) atts)))
      (user-error "%s is still downloading: wait for it, or remove it (×)"
                  (or (plist-get pending :name) "An attachment")))
    (when-let* ((bare (cl-find-if (lambda (a) (string-empty-p (plist-get a :response))) threads)))
      (user-error "Write your reply under the card of %s, or remove it (×)"
                  (harness-compose--chip-what bare)))
    (cons text (append threads
                       (cl-remove-if #'harness-compose--thread-attachment-p atts)
                       (cl-remove-if #'harness-compose--attached-p (harness-compose--references whole))))))

(defun harness-compose-newline ()
  "Insert a newline in the box, or jump there from elsewhere.
Jumping drops the region, which would reach outside the box.  It goes
where typing from outside the box does (`harness-compose--entry-point')."
  (interactive)
  (if (harness-compose-in-p)
      (insert "\n")
    (deactivate-mark)
    (goto-char (harness-compose--entry-point))))

;;;; Quoting

;; C-c > quotes in the box, as Markdown, what the reply answers: the
;; region, or else the message at point.  The compose-quote library does
;; it, the box being the composition it quotes into
;; (`harness-compose--quote-area'): its prompt is the front of it, so a
;; region reaching in from above counts up to the prompt and is quoted at
;; the box's end.  What the region selects above the box is read back
;; into Markdown, the renderer undone, with `harness-ui-markdown-source'
;; (`compose-quote-source-function').  Which message is at point the host
;; says, as text it marks with a `compose-quote' property -- a string,
;; the Markdown the text was rendered from -- or, for the rest of the
;; buffer, with `compose-quote-function'.  In a quote in the box the
;; library's inline mode answers it part by part: M-RET splits it where
;; point is, C-c [ elides part of it as [...].  That mode binds nothing
;; else, so the box's own keys work in a quote too.

(defun harness-compose--front ()
  "Return where the box starts, its prompt included."
  (if (and harness-compose-overlay (overlay-buffer harness-compose-overlay))
      (min (overlay-start harness-compose-overlay) harness-compose-start)
    harness-compose-start))

(defun harness-compose--quote-area ()
  "Return where the box composes a reply, or nil without a box.
That is (START END FRONT), the box's text and where it starts with its
prompt: the `compose-quote-area-function' of the box's buffer."
  (and (harness-compose-live-p)
       (list harness-compose-start harness-compose-end (harness-compose--front))))

(defun harness-compose--quoted ()
  "Follow a quote that went into the box, point under it.
The box may have been out of sight: its windows follow it again
\(`harness-compose--jumps').  The placeholder goes.  On
`compose-quote-insert-hook' in the box's buffer."
  (cl-incf harness-compose--jumps)
  (harness-compose-update-placeholder))

(defun harness-compose--setup-quoting ()
  "Make this buffer quote in its box, with compose-quote."
  (setq-local compose-quote-area-function #'harness-compose--quote-area
              compose-quote-source-function #'harness-ui-markdown-source)
  (add-hook 'compose-quote-insert-hook #'harness-compose--quoted nil t)
  ;; Its post-command tracking turns the inline mode on in a quote of the
  ;; box, and off elsewhere.
  (compose-quote-mode 1))

;; Quoting was the box's own once: the library's names took over.
(define-obsolete-function-alias 'harness-compose-quote-reply #'compose-quote-reply "3.0.0")
(define-obsolete-function-alias 'harness-compose-quote-string #'compose-quote-string "3.0.0")
;; Emacs cannot make a buffer-local variable an alias, and this is one in
;; a harness reloading, from before the change, in the Emacs it ran in
;; (the chats set it).  There the alias waits for the next start.
(condition-case nil
    (define-obsolete-variable-alias 'harness-compose-quote-function 'compose-quote-function "3.0.0")
  (error nil))

(defun harness-compose-skill-reference-p (text)
  "Non-nil when TEXT references a skill by /name or @skill:name."
  (or (string-match-p "\\(?:\\`\\|[ \t\n]\\)@skill:[A-Za-z0-9_.-]+" text)
      (let ((case-fold-search nil) (found nil))
        (dolist (name harness-compose--skills found)
          (when (string-match-p (concat "\\(?:\\`\\|[ \t\n]\\)/" (regexp-quote name) "\\_>") text)
            (setq found t))))))

(defun harness-compose-with-expanded-text (text callback)
  "Call CALLBACK with TEXT after expanding the skill references in it."
  (if (harness-compose-skill-reference-p text)
      (harness-ui-call "_harness/skills/expand" (list :text text :cwd (harness-compose--project))
                       (lambda (r) (funcall callback (or (plist-get r :text) text)))
                       (lambda (_) (funcall callback text)))
    (funcall callback text)))

(defun harness-compose-attachment-block (att)
  "Return the ACP prompt block for attachment ATT.
An image's label goes along as `_harness.label', so the model reads its
token, [image 1], right before it (see `harness-compose--label').  An
attachment that is text of its own and no file, a task, is that text
\(`harness-compose--task-text'), marked `_harness.attached' so that the
transcript sets it apart from the words around it
\(`harness-acp--block-from-acp', `harness-agent--blocks-text').  A reply in
a thread is the words under its card, with the thread's data as
`_harness.thread'."
  (let* ((path (plist-get att :path))
         (mime (or (plist-get att :mime) "application/octet-stream"))
         (label (plist-get att :label)))
    (cond
     ((plist-get att :thread)
      (list :type "text" :text (or (plist-get att :response) "")
            :_harness (list :thread (plist-get att :thread))))
     ((and (stringp (plist-get att :text)) (null path))
      (list :type "text" :text (plist-get att :text) :_harness (list :attached t)))
     ((and (string-prefix-p "image/" mime) (file-readable-p path))
      (append (list :type "image" :mimeType mime
                    :data (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally path)
                            (base64-encode-string (buffer-string) t)))
              (and label (list :_harness (list :label label)))))
     (t
      (list :type "resource_link" :uri (concat "file://" path)
            :name (or (plist-get att :name) (file-name-nondirectory path))
            :size (plist-get att :size) :mimeType mime)))))

;;;; Finding files

;; @ references and the attach command find a file the same way.  Part
;; of a name finds a project file in any subdirectory, among the files
;; listed from the projectile cache (`harness-compose--files').  A path
;; finds any file of this machine: one starting with / or ~ (absolute,
;; or in a home directory), or with ./ or ../, relative to the root the
;; project's files are named from, so ../other-repo/README.md is the
;; README next door.  Paths complete directory by directory, the way
;; `read-file-name' does, but only on this machine: completing as you
;; type must never open a connection to a remote host.
;;
;; A session working in a git worktree, a task's, has two places its
;; files are: the worktree, where the work goes on, and the main
;; checkout it was made from, which holds what the worktree has not
;; merged yet, untracked files and all (`harness-compose-roots-function').
;; Its project files are the union of both.  A file that is in both is
;; offered once and is read from the worktree, the first root; each
;; candidate says where it is (`harness-compose--file-annotator'), and
;; a name is read from the root that holds it (`harness-compose--project-file').
;; A box with its project alone lists and reads as it always did.

(defun harness-compose--root ()
  "Return the directory the box's file names are relative to.
That is the project's root (`harness-compose-project-function'), as a
directory name."
  (file-name-as-directory (expand-file-name (or (harness-compose--project) default-directory))))

(defun harness-compose--roots ()
  "Return the roots the box finds project files in, or nil for its project alone.
\(DIR . LABEL) each, DIR a directory name, the root whose copy of a file
wins first (`harness-compose-roots-function').  A root named twice
counts once, and there must be two for the box to have several: the
host's failing to say leaves the box with its project."
  (when harness-compose-roots-function
    (let ((roots nil))
      (condition-case err
          (dolist (entry (funcall harness-compose-roots-function))
            (when (and (consp entry) (stringp (car entry)))
              (let ((dir (file-name-as-directory (expand-file-name (car entry)))))
                (unless (assoc dir roots)
                  (push (cons dir (cdr entry)) roots)))))
        (error (harness-log 'warn "compose: finding the roots of the box failed: %s"
                            (harness-error-message err))
               (setq roots nil)))
      (and (cdr roots) (nreverse roots)))))

(defun harness-compose--project-file (name root)
  "Return the absolute name of the project file NAME, as the box lists it.
That is NAME in the first of the box's roots that holds it
\(`harness-compose--file-origins'), else relative to ROOT, the project."
  (expand-file-name name (or (and harness-compose--file-roots harness-compose--file-origins
                                  (car (gethash name harness-compose--file-origins)))
                             root)))

(defun harness-compose--named-file (name root)
  "Return the absolute name of the file NAME, as the box reads it.
A path (`harness-compose--path-p') is relative to ROOT, the project; any
other name is a project file (`harness-compose--project-file')."
  (if (harness-compose--path-p name)
      (expand-file-name name root)
    (harness-compose--project-file name root)))

(defun harness-compose--relative-name (path root)
  "Return the name PATH goes by in the box.
That is its path in the project ROOT, else abbreviated
\(`harness-relative-path').  With several roots
\(`harness-compose--file-roots') it is its path in the first of them
that holds it instead, so that a file of a task's worktree, which lies
under the project it was made from, goes by its name in the worktree,
not by .worktrees/ and the worktree's name."
  (harness-relative-path
   (or (and harness-compose--file-roots
            (car (cl-find-if (lambda (entry) (harness-path-within-p (car entry) path))
                             harness-compose--file-roots)))
       root)
   path))

(defun harness-compose--path-p (name)
  "Non-nil when NAME is a path rather than part of a project file's name.
A path starts with / or ~, or with ./ or ../, or is just \"..\"."
  (string-match-p "\\`\\(?:[/~]\\|\\.\\.?/\\|\\.\\.\\'\\)" name))

(defun harness-compose--complete-path (root string pred action)
  "Complete the path STRING, relative to ROOT, for completion ACTION with PRED.
Only files of this machine complete: file name handlers are off, so a
remote name, which TRAMP would connect for, completes to nothing.  A
directory's ./ and ../ are offered only once a name starting with a dot
is typed, so a popup lists what the directory holds."
  (let* ((default-directory root)
         (file-name-handler-alist nil)
         (non-essential t)
         (found (completion-file-name-table string pred action)))
    (if (and (eq action t) (not (string-prefix-p "." (file-name-nondirectory string))))
        (cl-remove-if (lambda (name) (member name '("./" "../"))) found)
      found)))

(defun harness-compose--file-table ()
  "Return the completion table @ references and the attach command find files in.
Part of a name completes over the project's files, in the
`harness-compose-file' category, which matches with `flex' unless
configured otherwise.  A path (`harness-compose--path-p') completes
over the file system, relative to the box's root, directory by
directory, in the `file' category: the styles and the UI (vertico,
marginalia) of file names apply to it.  With several roots
\(`harness-compose-roots-function') the project's files are those of
all of them, each once, annotated with where it is
\(`harness-compose--file-annotator')."
  (let ((files (harness-compose--table 'harness-compose--files 'harness-compose-file
                                       (harness-compose--file-annotator)))
        (root (harness-compose--root)))
    (lambda (string pred action)
      (if (harness-compose--path-p string)
          (harness-compose--complete-path root string pred action)
        (funcall files string pred action)))))

(defun harness-compose--file-annotator ()
  "Return the annotation function of the project's files, or nil with one root.
It says which of the box's roots hold the file, by their labels:
\"  [task, main]\" for a file in the worktree and the main checkout,
\"  [main]\" for one only the main checkout has."
  (when harness-compose--file-roots
    (let ((buf (current-buffer)))
      (lambda (name)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when-let* ((held (and harness-compose--file-origins
                                   (gethash name harness-compose--file-origins))))
              (format "  [%s]"
                      (mapconcat (lambda (root)
                                   (or (cdr (assoc root harness-compose--file-roots))
                                       (abbreviate-file-name root)))
                                 held ", ")))))))))

(defun harness-compose--attach-table ()
  "Return the table the attach command reads a file, or a task, with.
That of @ references (`harness-compose--file-table'), but a leading @,
typed out of the habit of the box, is ignored: \"@notes\" finds what
\"notes\" does.  After \"task:\" a task's id completes instead, among
the project's tasks (`harness-compose--task-table')."
  (let ((files (harness-compose--file-table))
        (tasks (harness-compose--task-table)))
    (lambda (string pred action)
      (let* ((skip (if (string-prefix-p "@" string) 1 0))
             (task (harness-compose--task-name-p (substring string skip)))
             (skip (if task (+ skip 5) skip))
             (table (if task tasks files)))
        (if (= skip 0)
            (funcall table string pred action)
          (let ((name (substring string skip)))
            (pcase action
              ;; The @ and the task: are out of the field being completed.
              (`(boundaries . ,_)
               (let ((inner (funcall table name pred action)))
                 `(boundaries ,(+ skip (or (cadr inner) 0)) . ,(cddr inner))))
              ('nil (let ((found (funcall table name pred nil)))
                      (if (stringp found) (concat (substring string 0 skip) found) found)))
              (_ (funcall table name pred action)))))))))

(defun harness-compose--local-file (name root)
  "Return NAME, relative to ROOT, absolute when it is a regular file here, or nil.
A remote name is never looked at, as completing it never is."
  (let* ((file-name-handler-alist nil)
         (path (expand-file-name name root)))
    (and (file-regular-p path) path)))

;; An @ reference typed out in full, or pasted, rather than completed
;; names its file all the same: sending the message attaches it
;; (`harness-compose-take'), and the reference stays in the text, where
;; it says what the file is for.

(defconst harness-compose--reference-regexp "\\(?:\\`\\|[ \t\n]\\)@\\([^ \t\n]+\\)"
  "An @ reference: an @ starting a word, then the name up to a space.
That is the token @ completes in the box (`harness-compose--capf-bounds').")

(defun harness-compose--local-file-in-roots (name root)
  "Return NAME, a regular file here, absolute, or nil.
A path (`harness-compose--path-p') is relative to ROOT, the project.  Any
other name is relative to the first of the box's roots
\(`harness-compose--file-roots') that has such a file, as a project file
is (`harness-compose--project-file'), and to ROOT when the box has one."
  (if (or (harness-compose--path-p name) (null harness-compose--file-roots))
      (harness-compose--local-file name root)
    (cl-some (lambda (entry) (harness-compose--local-file name (car entry)))
             harness-compose--file-roots)))

(defun harness-compose--reference-file (name root)
  "Return the absolute name of the file the @ reference NAME means, or nil.
NAME is what follows the @: a file the project lists, or a path
relative to ROOT, absolute or under ~, of a regular file of this
machine.  A project file is the one of the first root that holds it,
when the box has several (`harness-compose-roots-function').
Punctuation ending a sentence or a bracket after it is no part of it
\(\"see @notes.txt.\"), and an @skill: reference names a skill, an
@task: one a task, not a file."
  (unless (or (string-prefix-p "skill:" name) (harness-compose--task-name-p name))
    (cl-some (lambda (candidate)
               (cond ((string-empty-p candidate) nil)
                     ((member candidate harness-compose--files)
                      (harness-compose--project-file candidate root))
                     (t (harness-compose--local-file-in-roots candidate root))))
             (delete-dups (list name (replace-regexp-in-string "[]),.;:!?'\"`>}]+\\'" "" name))))))

(defun harness-compose--references (text)
  "Return the attachments of the files the @ references in TEXT name.
In the order of TEXT, each file once; see
`harness-compose--reference-file' for what a reference may name."
  (let ((root (harness-compose--root)) (start 0) (paths nil))
    (while (string-match harness-compose--reference-regexp text start)
      (setq start (match-end 0))
      (when-let* ((path (harness-compose--reference-file (match-string 1 text) root)))
        (cl-pushnew path paths :test #'equal)))
    (mapcar #'harness-compose--file-attachment (nreverse paths))))

(defun harness-compose-without-references (atts text)
  "Return ATTS without the files and the tasks the @ references in TEXT name.
ATTS are the attachments `harness-compose-take' returned with TEXT: what
is left are the box's own, the files attached to it.  For an answer to
a question, say, whose text goes as it is: a file or a task the text
names -- one attached from the box puts its reference there -- stays its
reference, while the box's own attachments go with the answer."
  (let ((named (mapcar (lambda (att) (plist-get att :path)) (harness-compose--references text))))
    (cl-remove-if (lambda (att)
                    (if (plist-get att :task)
                        (harness-compose--token-spans (concat "@task:" (plist-get att :task)) text)
                      (member (plist-get att :path) named)))
                  atts)))

;;;; Attachments

(defun harness-compose--mime-of (path)
  "Return the MIME type of PATH."
  (or (mailcap-extension-to-mime (file-name-extension path t)) "application/octet-stream"))

(defun harness-compose-read-file (&optional any)
  "Read a file to attach and return its absolute name, or a task as task:ID.
Part of a name finds a project file in any subdirectory, and a path any
file: absolute, under ~, or relative to the project with ./ or ../,
completing directory by directory.  It is what @ completes in the box
\(`harness-compose--file-table'), so the project's files match with
`flex' unless configured otherwise, and a leading @ is ignored.  After
\"task:\" the id of a task of the project completes, which is returned
as it is, \"task:\" and all.  A directory is no file to attach: choosing
one reads again, from inside it, and so does an empty answer.  With
ANY, or when the project lists no files, browse the file system instead.
The project is never listed while you wait: a listing still running
fills the candidates in when it returns, and so do the tasks.

A box with several roots -- a chat working in a task's git worktree
\(`harness-compose-roots-function') -- offers the union of their files:
the worktree's and those of the main checkout it was made from, which
has what the worktree does not.  A file in both is offered once, and
the worktree's copy is the one attached; each candidate says where it
is, \"[task]\", \"[main]\" or \"[task, main]\", and the file chosen is
named in the root it was found in."
  (let ((root (harness-compose--root))
        (listing (harness-compose-fetch-files)))
    (if (or any (and (harness-promise-settled-p listing) (null harness-compose--files)))
        (expand-file-name (read-file-name "Attach file: " root nil t) root)
      (harness-compose-fetch-tasks)
      (let ((table (harness-compose--attach-table)) (initial nil) (name nil))
        (while (progn
                 (setq name (string-remove-prefix
                             "@" (completing-read "Attach a project file, a path (/ ~/ ../) or task:ID: "
                                                  table nil t initial)))
                 (and (not (harness-compose--task-name-p name))
                      (let ((file-name-handler-alist nil))
                        (file-directory-p (harness-compose--named-file name root)))))
          (setq initial (and (not (string-empty-p name)) (file-name-as-directory name))))
        (if (harness-compose--task-name-p name) name (harness-compose--named-file name root))))))

(defun harness-compose-add-attachment (path &optional mime)
  "Attach the file PATH (with MIME) to the next message.
Its token goes into the text where point is in the box, else at its end
\(`harness-compose--label'): an image's [image 1], else @ and the
file's name, its path in the project or else under ~ or absolute, as a
chip a click opens; a file whose name has a space attaches without one.
Interactively, part of its name finds a project file in any
subdirectory, and a path (/, ~/, ./, ../) any file; with a prefix
argument, the file system is browsed instead (see
`harness-compose-read-file').  In a task's git worktree the project's
files are those of the worktree and of the main checkout both.  PATH
task:ID attaches a task of the project instead
\(`harness-compose-attach-task')."
  (interactive (list (harness-compose-read-file current-prefix-arg)))
  (if (harness-compose--task-name-p path)
      (harness-compose-attach-task (substring path 5))
    (let ((path (expand-file-name path)))
      (harness-compose--attach (harness-compose--file-attachment path mime))
      (funcall harness-compose-redraw-function)
      (message "Attached %s" (abbreviate-file-name path)))))

(defun harness-compose-remove-attachment (what)
  "Remove the attachment WHAT: a file's path, a task's task:ID, or itself.
Its tokens go from the text too -- an image's [image 1], a file's or a
task's @ reference -- as deleting them would have removed it: undoing
brings both back (`harness-compose--sync-tokens').  Interactively, the
attachment is read with completion, a file by its path and a task as
task:ID."
  (interactive (list (completing-read "Remove attachment: "
                                      (delq nil (mapcar #'harness-compose--attachment-id harness-compose-attachments))
                                      nil t)))
  (when-let* ((id (harness-compose--what-id what)))
    (dolist (att harness-compose-attachments)
      (when-let* ((token (and (equal (harness-compose--attachment-id att) id) (harness-compose--att-token att))))
        (harness-compose--keep-aside att)
        (harness-compose--delete-tokens token)))
    (setq harness-compose-attachments
          (cl-remove id harness-compose-attachments :key #'harness-compose--attachment-id :test #'equal)))
  (funcall harness-compose-redraw-function))

;;;; Tokens

;; An attachment of the box has a token in its text that names it: an
;; image its label, [image 1]; a file its @ reference, @ and its path in
;; the project, else under ~ or absolute; a task @task: and its id.  The
;; token goes where point is when it is in the box -- where the image
;; was pasted, the file dropped or completed -- else at the end.  A
;; sentence can then say which screenshot, file or task it means: the
;; model reads an image's [image 1] right before the image itself, whose
;; prompt block carries the label (`harness-compose-attachment-block'),
;; and a reference where the text has it.  The token is text, so it
;; lives through redraws, drafts and queueing like the rest of the
;; message.  An overlay shows it as a chip, the same one for every kind
;; (`harness-compose--inline-chip'): an image's thumbnail, or the icon
;; of a file or a task, then the token as a link, which point steps over
;; as a whole.  A click opens the attachment, mouse-3 offers the rest.
;;
;; After every command the text and the attachments are made to agree,
;; token by token (`harness-compose--sync-tokens'): what is left of a
;; token cut short (DEL right after it) goes too; an attachment whose
;; tokens are all gone is detached, and kept aside, so that its token
;; yanked, typed or undone back brings it back; the × of its line in the
;; list deletes its tokens.  An @ reference is a word of its own, the
;; way `harness-compose--references' reads one: a letter typed against
;; it makes another word.  Only attachments with a token take part: a
;; file whose name can be no reference (it has a space), and what a
;; draft from before tokens attached, are left alone.
;;
;; An image's number never changes once given, since a sentence written
;; about [image 2] must keep meaning that image.  A new image takes the
;; number after the highest one attached: deleting the last image frees
;; its number, deleting one in the middle leaves a gap, and every
;; message starts again at 1.

(defvar harness-compose-thumbnail-lines)

(defface harness-compose-token-face '((t :inherit link))
  "The token of an attachment in the compose box: [image 1], @notes.txt.
An image's token shows in it in the transcript too."
  :group 'harness-compose)

(harness-ui-define-icon harness-icon-file "file" "▤" "file" "A file attached to a message.")
(harness-ui-define-icon harness-icon-task "task" "☑" "task" "A task attached to a message.")

(defconst harness-compose--token-max 32
  "Most characters of a name an inline chip shows: a file's, a task's title.")

(defun harness-compose--image-token (label)
  "Return the token of the image LABEL, as the text holds it."
  (concat "[" label "]"))

(defun harness-compose--image-attachment-p (att)
  "Non-nil when ATT is an image, which the model gets as one."
  (and (not (plist-get att :pending))
       (string-prefix-p "image/" (or (plist-get att :mime) ""))))

(defun harness-compose--task-name-p (name)
  "Non-nil when NAME, a reference or an answer to the attach command, is task:ID."
  (and (stringp name) (string-prefix-p "task:" name)))

(defun harness-compose--att-token (att)
  "Return the token of attachment ATT in the text, or nil when it has none.
An image's [image 1], from its label; a reply in a thread's [reply 1];
a file's or a task's @ reference, from its `:ref'.  A download under way
has none yet."
  (unless (plist-get att :pending)
    (cond ((plist-get att :thread) (harness-compose--thread-token att))
          ((plist-get att :label) (harness-compose--image-token (plist-get att :label)))
          ((plist-get att :ref) (concat "@" (plist-get att :ref))))))

(defun harness-compose--attachment-id (att)
  "Return what tells attachment ATT apart.
A task's task:ID, a reply in a thread's reply:N, else its file's path."
  (cond ((plist-get att :task) (concat "task:" (plist-get att :task)))
        ((plist-get att :thread) (format "reply:%s" (plist-get att :reply)))
        ((plist-get att :path) (expand-file-name (plist-get att :path)))))

(defun harness-compose--what-id (what)
  "Return the id of WHAT: an attachment, a file's path or a task's task:ID.
See `harness-compose--attachment-id'."
  (cond ((consp what) (harness-compose--attachment-id what))
        ((harness-compose--task-name-p what) what)
        ((and (stringp what) (string-prefix-p "reply:" what)) what)
        ((stringp what) (expand-file-name what))))

(defun harness-compose--attached-p (what)
  "Return the attachment WHAT is when it is attached, else nil.
WHAT is a file's path, a task's task:ID, or an attachment, which counts
when its file or its task is attached (`harness-compose--attachment-id')."
  (when-let* ((id (harness-compose--what-id what)))
    (cl-find id harness-compose-attachments :key #'harness-compose--attachment-id :test #'equal)))

(defun harness-compose--token-spans (token string)
  "Return where TOKEN stands in STRING: (START . END) offsets, in order.
An image's token counts wherever it is.  An @ reference counts as a
word of its own, the way `harness-compose--references' reads one: at
the start or after a space, and up to a space or the end, but for
punctuation ending a sentence or a bracket (\"see @notes.txt.\")."
  (let ((case-fold-search nil) (spans nil) (start 0) (at nil))
    (if (string-prefix-p "@" token)
        (let ((re (concat "\\(?:\\`\\|[ \t\n]\\)\\(" (regexp-quote token) "\\)"
                          "[]),.;:!?'\"`>}]*\\(?:[ \t\n]\\|\\'\\)")))
          (while (string-match re string start)
            (push (cons (match-beginning 1) (match-end 1)) spans)
            (setq start (match-end 1))))
      (while (setq at (string-search token string start))
        (push (cons at (+ at (length token))) spans)
        (setq start (+ at (length token)))))
    (nreverse spans)))

(defun harness-compose--box-string ()
  "Return the box's text: the buffer's while the box is drawn, else the kept one."
  (if (harness-compose-live-p)
      (buffer-substring-no-properties harness-compose-start harness-compose-end)
    harness-compose--text))

(defun harness-compose--token-in-box-p (token)
  "Non-nil when the box's text holds TOKEN (`harness-compose--token-spans')."
  (and (harness-compose--token-spans token (harness-compose--box-string)) t))

(defun harness-compose--tokened (token)
  "Return the attachment whose token is TOKEN, or nil."
  (cl-find token harness-compose-attachments :key #'harness-compose--att-token :test #'equal))

(defun harness-compose--forget-detached (token)
  "Forget the attachment kept aside under TOKEN, which no longer brings it back."
  (setq harness-compose--detached (cl-remove token harness-compose--detached :key #'car :test #'equal)))

(defun harness-compose--label-number (label)
  "Return the number of the image LABEL (3 for \"image 3\"), or nil."
  (and (stringp label) (string-match "\\`image \\([0-9]+\\)\\'" label)
       (string-to-number (match-string 1 label))))

(defun harness-compose--labelled (label)
  "Return the attached image of LABEL, or nil."
  (and label (cl-find label harness-compose-attachments
                      :key (lambda (a) (plist-get a :label)) :test #'equal)))

(defun harness-compose--next-label ()
  "Return the label of the next image: the one after the highest attached."
  (format "image %d"
          (1+ (apply #'max 0 (delq nil (mapcar (lambda (a) (harness-compose--label-number (plist-get a :label)))
                                               harness-compose-attachments))))))

(defun harness-compose--file-ref (path &optional name)
  "Return the @ reference, without its @, that names the file PATH, or nil.
NAME, when it names PATH -- the name a reference was completed as, a
path relative to the project, say -- else PATH's own name: its path in
the project, else under ~ or absolute (`harness-relative-path'); a file
of the box's other roots goes by its path in its root
\(`harness-compose--relative-name').  Nil when that has a space, which
would end the reference, or does not name PATH back
\(`harness-compose--reference-file'): the file has no reference then."
  (let ((root (harness-compose--root))
        (path (expand-file-name path)))
    (cl-find-if (lambda (ref)
                  (and (stringp ref) (not (string-empty-p ref))
                       (not (string-match-p "[ \t\n\r\f]" ref))
                       (equal (harness-compose--reference-file ref root) path)))
                (list name (harness-compose--relative-name path root)))))

(defun harness-compose--label (att &optional at-end)
  "Return ATT with its token, the token put into the box.
An image gets a label, its token [image 1]; a file an @ reference, when
its name can be one (`harness-compose--file-ref'); a task has its
reference, @task:ID, already.  The token goes where point is, or with
AT-END at the end of the box (`harness-compose--insert-token'), unless
the box holds it already: a reference typed or completed there.  A
download under way, and an image labelled already, are returned as
they are."
  (cond
   ((or (plist-get att :pending) (plist-get att :label)) att)
   ((harness-compose--image-attachment-p att)
    (let ((label (harness-compose--next-label)))
      ;; An image deleted under that number cannot come back now.
      (harness-compose--forget-detached (harness-compose--image-token label))
      (harness-compose--insert-token (harness-compose--image-token label) at-end)
      (append att (list :label label))))
   (t
    (let* ((ref (and (not (plist-get att :ref)) (not (plist-get att :task)) (plist-get att :path)
                     (harness-compose--file-ref (plist-get att :path))))
           (att (if ref (append att (list :ref ref)) att))
           (token (harness-compose--att-token att)))
      (when token
        ;; What was deleted under that token is this attachment now.
        (harness-compose--forget-detached token)
        (unless (harness-compose--token-in-box-p token)
          (harness-compose--insert-token token at-end)))
      att))))

(defun harness-compose--insert-token (token &optional at-end)
  "Put TOKEN, an attachment's, into the box.
At point when point is in the box, else, or with AT-END, at the end of
the box, point staying where it was.  A space keeps it apart from the
words on either side, and follows it at the end of the box, so typing
goes on after it.  A box not drawn gets it at the end of its text."
  (if (not (harness-compose-live-p))
      (setq harness-compose--text
            (concat harness-compose--text
                    (and (string-match-p "[^ \t\n]\\'" harness-compose--text) " ")
                    token " "))
    (if (and (not at-end) (harness-compose-in-p))
        (harness-compose--insert-spaced token)
      (save-excursion
        (goto-char harness-compose-end)
        (harness-compose--insert-spaced token)))
    (harness-compose-update-placeholder)))

(defun harness-compose--insert-spaced (token)
  "Insert TOKEN at point, in the box, apart from the words around it."
  (unless (or (= (point) harness-compose-start) (memq (char-before) '(?\s ?\t ?\n)))
    (insert " "))
  (insert token)
  (when (or (= (point) harness-compose-end) (not (memq (char-after) '(?\s ?\t ?\n))))
    (insert " ")))

(defun harness-compose--token-tail-p (token char)
  "Non-nil when CHAR, the one after TOKEN, goes with it when it is deleted.
That is the space that keeps it apart from the words, or, for the token
of a card (`harness-compose--thread-token'), the line break under it."
  (or (eq char ?\s) (and (eq char ?\n) (string-prefix-p "[reply " token))))

(defun harness-compose--token-from (token offset text)
  "Return the offset in TEXT where deleting TOKEN, which stands at OFFSET, starts.
OFFSET itself, but for the token of the first card of a box that holds
nothing before it except the line break the card left for your own
message (`harness-compose--card-break'): that goes too, rather than
leaving an empty line above the words that stay."
  (if (and (= offset 1) (string-prefix-p "[reply " token) (eq (aref text 0) ?\n))
      0
    offset))

(defun harness-compose--without-token (token text)
  "Return TEXT without TOKEN wherever it stands, a space after each too."
  (dolist (span (reverse (harness-compose--token-spans token text)) text)
    (let ((end (cdr span)))
      (setq text (concat (substring text 0 (harness-compose--token-from token (car span) text))
                         (substring text (if (and (< end (length text))
                                                  (harness-compose--token-tail-p token (aref text end)))
                                             (1+ end)
                                           end)))))))

(defun harness-compose--delete-tokens (token)
  "Delete TOKEN wherever it stands in the box, a space after each too.
See `harness-compose--token-spans' for where an @ reference stands."
  (if (not (harness-compose-live-p))
      (setq harness-compose--text (harness-compose--without-token token harness-compose--text))
    (let ((start (marker-position harness-compose-start))
          (text (harness-compose--box-string)))
      ;; From the last, so the offsets of the others hold.
      (dolist (span (reverse (harness-compose--token-spans token text)))
        (let ((end (+ start (cdr span))))
          (delete-region (+ start (harness-compose--token-from token (car span) text))
                         (if (and (< end harness-compose-end)
                                  (harness-compose--token-tail-p token (char-after end)))
                             (1+ end)
                           end)))))
    (harness-compose-update-placeholder)))

(defun harness-compose--keep-aside (att)
  "Keep ATT, an attachment whose tokens were deleted, for them to bring back.
Where it stood among the attachments goes with it."
  (when-let* ((token (harness-compose--att-token att)))
    (harness-compose--forget-detached token)
    (push (list token att (or (cl-position att harness-compose-attachments :test #'eq)
                              (length harness-compose-attachments)))
          harness-compose--detached)))

(defun harness-compose--reattach (entry)
  "Attach again the attachment that ENTRY of `harness-compose--detached' keeps.
It goes back where it stood, as far as the attachments left reach."
  (let ((at (min (nth 2 entry) (length harness-compose-attachments))))
    (setq harness-compose-attachments
          (append (seq-take harness-compose-attachments at) (list (nth 1 entry))
                  (seq-drop harness-compose-attachments at)))))

(defun harness-compose--finish-cut-tokens ()
  "Delete what is left of a token that a command cut short.
Deleting the character before point right after a token deletes its
last character, the one after point before it its first: the rest goes
too, rather than staying as text naming nothing.  The token of a card
goes with the line break that ends it, and the line the first card left
for your message when nothing is on it (`harness-compose--token-from'),
so deleting it by hand leaves the box as removing the thread does."
  (dolist (ov harness-compose--token-overlays)
    (when (overlay-buffer ov)
      (let* ((beg (overlay-start ov))
             (end (overlay-end ov))
             (token (overlay-get ov 'harness-compose-token))
             (text (buffer-substring-no-properties beg end)))
        (when (and token (< 0 (length text) (length token)) (string-search text token)
                   (harness-compose-in-p beg) (harness-compose-in-p end))
          (delete-region beg end)
          ;; A card's token goes as `harness-compose--delete-tokens' has it
          ;; go: the line break it ends with, and the empty line the first
          ;; card left for your message, with it.
          (when (string-prefix-p "[reply " token)
            (when (and (< beg harness-compose-end) (eq (char-after beg) ?\n))
              (delete-region beg (1+ beg)))
            (when (and (= beg (1+ harness-compose-start)) (eq (char-before beg) ?\n))
              (delete-region (1- beg) beg))))))))

(defun harness-compose--sync-tokens ()
  "Make the tokens of the box and its attachments agree; show the tokens.
What is left of a token a command cut short is deleted.  An attachment
none of whose tokens is left is detached and kept aside; one kept aside
whose token is back is attached again, where it stood.  Return non-nil
when the attachments changed, for the caller to redraw them."
  (when (and (harness-compose-live-p)
             (or harness-compose--detached harness-compose--token-overlays
                 (cl-some #'harness-compose--att-token harness-compose-attachments)))
    (harness-compose--finish-cut-tokens)
    (let* ((text (harness-compose--box-string))
           (gone (cl-remove-if-not (lambda (a) (let ((token (harness-compose--att-token a)))
                                                 (and token (not (harness-compose--token-spans token text)))))
                                   harness-compose-attachments))
           (changed (and gone t)))
      (dolist (att gone) (harness-compose--keep-aside att))
      (setq harness-compose-attachments (cl-remove-if (lambda (a) (memq a gone)) harness-compose-attachments))
      ;; Back where they stood: the first in the list first.
      (dolist (entry (sort (copy-sequence harness-compose--detached) (lambda (a b) (< (nth 2 a) (nth 2 b)))))
        (when (harness-compose--token-spans (car entry) text)
          (setq harness-compose--detached (delq entry harness-compose--detached))
          ;; Unless it was attached again since, under another token.
          (unless (or (harness-compose--tokened (car entry))
                      (harness-compose--attached-p (nth 1 entry)))
            (harness-compose--reattach entry)
            (setq changed t))))
      (harness-compose--show-tokens)
      changed)))

(defun harness-compose--keep-tokens ()
  "Keep the tokens and the attachments in step after a command.
Runs from `post-command-hook'; see `harness-compose--sync-tokens'.
The area of a box with cards that point is in is noted first
\(`harness-compose--note-area'), which the cards' hints say."
  (condition-case err
      (progn
        (harness-compose--note-area)
        (when (harness-compose--sync-tokens)
          (harness-compose-redraw)))
    (error (harness-log 'warn "compose: keeping the tokens failed: %S" err))))

(defun harness-compose--show-tokens ()
  "Show the token of each attachment in the box as a chip.
The chips are made again only when the tokens moved or changed.  Of
two tokens that overlap, the first shows, the longer of two that start
together."
  (when (harness-compose-live-p)
    (let ((text (harness-compose--box-string))
          (start (marker-position harness-compose-start))
          (want nil) (kept nil) (reach 0))
      (dolist (att harness-compose-attachments)
        (when-let* ((token (harness-compose--att-token att)))
          (dolist (span (harness-compose--token-spans token text))
            ;; The room a card has is part of what it shows.
            (push (list (+ start (car span)) (+ start (cdr span)) att
                        (and (plist-get att :thread) (harness-compose--thread-chip-room)))
                  want))))
      (dolist (w (sort want (lambda (a b) (or (< (car a) (car b))
                                              (and (= (car a) (car b)) (> (cadr a) (cadr b)))))))
        (when (>= (car w) reach)
          (push w kept)
          (setq reach (cadr w))))
      (setq want (nreverse kept))
      ;; What a card says of the key out of its reply depends on where
      ;; point is, so it is part of what is shown (`harness-compose--card-hint').
      (let ((cards (cl-loop for w in want
                            when (plist-get (nth 2 w) :thread)
                            collect (cons (nth 2 w) (cons (nth 0 w) (nth 1 w))))))
        (setq want (mapcar (lambda (w)
                             (append w (list (and (plist-get (nth 2 w) :thread)
                                                  (harness-compose--card-hint (nth 2 w) cards)))))
                           want)))
      (unless (equal want (mapcar (lambda (ov) (list (overlay-start ov) (overlay-end ov)
                                                     (overlay-get ov 'harness-compose-attachment)
                                                     (overlay-get ov 'harness-compose-room)
                                                     (overlay-get ov 'harness-compose-hint)))
                                  harness-compose--token-overlays))
        (mapc #'delete-overlay harness-compose--token-overlays)
        (setq harness-compose--token-overlays
              ;; The hint is for a card: the other chips are made as they were.
              (mapcar (lambda (w) (apply #'harness-compose--inline-chip (nth 0 w) (nth 1 w) (nth 2 w)
                                         (and (nth 4 w) (list (nth 4 w)))))
                      want)))
      (harness-compose--show-thread-rails))))

(defun harness-compose--inline-chip (beg end att &optional hint)
  "Return the overlay showing the token from BEG to END of attachment ATT.
Every kind of attachment shows the same way: what it is first -- an
image's thumbnail a line high, the icon of a file or a task
\(`harness-compose--chip-head') -- then its name in
`harness-compose-token-face' (`harness-compose--chip-text').  mouse-1
and mouse-2 open it, mouse-3 offers a menu (`harness-compose--chip-map').
The cursor shows on what comes first when point is before the token.
The token's display is a string, so point never rests inside it: the
command loop moves it to an edge.  A reply in a thread shows as the
card of the thread instead (`harness-compose--thread-card'), in as many
columns as the windows have (`harness-compose--thread-chip-room'), and
with HINT, a string, after its [×]."
  (let* ((ov (make-overlay beg end nil t nil))
         (thread (plist-get att :thread))
         (props (list 'help-echo (if thread
                                     (harness-compose--thread-help thread)
                                   (harness-compose--chip-help att))
                      'mouse-face 'highlight
                      'keymap (harness-compose--chip-map att) 'pointer 'hand))
         (head (and (not thread) (harness-compose--chip-head att))))
    (overlay-put ov 'harness-compose-token (buffer-substring-no-properties beg end))
    (when (plist-get att :label) (overlay-put ov 'harness-compose-label (plist-get att :label)))
    (overlay-put ov 'harness-compose-attachment att)
    (overlay-put ov 'evaporate t)
    (when head
      (overlay-put ov 'before-string
                   (concat (apply #'propertize head 'cursor t
                                  ;; A thumbnail on the box's background, an
                                  ;; icon in the link's colour, as its name.
                                  'face (if (plist-get att :label)
                                            harness-compose--face
                                          (list 'harness-compose-token-face harness-compose--face))
                                  props)
                           (propertize " " 'face harness-compose--face
                                       'display (if (display-graphic-p) '(space :width (3)) '(space :width 1))))))
    (overlay-put ov 'display (if thread
                                 (harness-compose--card-with-hint (harness-compose--thread-card att) hint props)
                               (apply #'propertize (harness-compose--chip-text att)
                                      'face (list 'harness-compose-token-face harness-compose--face)
                                      props)))
    (when thread
      (overlay-put ov 'harness-compose-room (harness-compose--thread-chip-room))
      (overlay-put ov 'harness-compose-hint hint))
    (dolist (p (seq-partition props 2)) (overlay-put ov (car p) (cadr p)))
    ov))

(defun harness-compose--chip-head (att)
  "Return what the inline chip of attachment ATT shows before its name, or nil.
An image's thumbnail, a line high, where images show (nothing else); a
task's icon, or a file's."
  (cond ((plist-get att :label)
         (and (display-images-p) (> harness-compose-thumbnail-lines 0)
              (harness-compose--image (plist-get att :path) (frame-char-height))))
        ((plist-get att :task) (harness-ui-icon 'harness-icon-task))
        (t (harness-ui-icon 'harness-icon-file))))

(defun harness-compose--chip-text (att)
  "Return the name the inline chip of attachment ATT shows for its token.
An image's token, [image 1]; @task: and a task's id, then its title cut
short; @ and a file's name without its directories, shortened in the
middle to `harness-compose--token-max' characters."
  (cond ((plist-get att :label) (harness-compose--image-token (plist-get att :label)))
        ((plist-get att :task)
         (let ((title (harness-ui-one-line (or (plist-get att :name) ""))))
           (concat "@task:" (plist-get att :task)
                   (if (string-empty-p title) ""
                     (concat " " (harness-truncate-end title harness-compose--token-max))))))
        (t (concat "@" (harness-compose--shorten
                        (replace-regexp-in-string
                         "[\n\r\t]" " " (file-name-nondirectory (or (plist-get att :ref) (plist-get att :path) "")))
                        harness-compose--token-max)))))

(defun harness-compose--chip-what (att)
  "Return what attachment ATT is, in a word or two: image 1, file, task t-1a2b."
  (cond ((plist-get att :thread) (format "reply %s" (plist-get att :reply)))
        ((plist-get att :label))
        ((plist-get att :task) (concat "task " (plist-get att :task)))
        (t "file")))

(defun harness-compose--chip-help (att)
  "Return the tooltip of the inline chip of attachment ATT."
  (harness-ui-one-line
   (format "%s: %s · mouse-1: open · mouse-3: more · deleting it removes the attachment"
           (harness-compose--chip-what att)
           (if (plist-get att :task)
               (concat (or (plist-get att :name) "")
                       (and (plist-get att :state) (format " (%s)" (plist-get att :state))))
             (abbreviate-file-name (or (plist-get att :path) ""))))))

(defun harness-compose--chip-command (fn)
  "Return a command of a mouse event that calls FN with it, in this buffer.
The window clicked is selected first, and FN runs in the box's buffer,
which the chip shows in, whatever buffer is current."
  (let ((buffer (current-buffer)))
    (lambda (event)
      (interactive "e")
      (let ((window (and (consp event) (posn-window (event-start event)))))
        (when (window-live-p window) (select-window window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (funcall fn event))))))

(defun harness-compose--chip-map (att)
  "Return the keymap of the chip of attachment ATT, inline in the box.
mouse-1 and mouse-2 open ATT (`harness-compose-open-attachment');
mouse-3 pops up the menu of what else there is to do with it
\(`harness-compose--chip-actions')."
  (let ((open (harness-compose--chip-command (lambda (_) (harness-compose-open-attachment att))))
        (menu (harness-compose--chip-command
               (lambda (event) (popup-menu (harness-compose--chip-menu att) event))))
        (map (make-sparse-keymap)))
    (define-key map [mouse-1] open)
    (define-key map [mouse-2] open)
    ;; The press would pop up the buffer's context menu.
    (define-key map [down-mouse-3] #'ignore)
    (define-key map [mouse-3] menu)
    map))

(defun harness-compose--chip-actions (att)
  "Return what the chip of attachment ATT offers: (NAME . FUNCTION) each.
Open it, remove it from the message, its tokens with it
\(`harness-compose-remove-attachment'), and copy its file's path, or its
task's id; a reply in a thread offers what its card does
\(`harness-compose--thread-actions')."
  (if (plist-get att :thread)
      (harness-compose--thread-actions att)
    (harness-compose--chip-file-actions att)))

(defun harness-compose--chip-file-actions (att)
  "Return what the chip of ATT, a file or a task, offers: (NAME . FUNCTION) each."
  (list (cons "Open" (lambda () (harness-compose-open-attachment att)))
        (cons "Remove from the message" (lambda () (harness-compose-remove-attachment att)))
        (if (plist-get att :task)
            (cons "Copy the task id" (lambda ()
                                       (kill-new (plist-get att :task))
                                       (message "Copied %s" (plist-get att :task))))
          (cons "Copy the path" (lambda ()
                                  (kill-new (plist-get att :path))
                                  (message "Copied %s" (plist-get att :path)))))))

(defun harness-compose--chip-menu (att)
  "Return the menu of the chip of attachment ATT, for `popup-menu'.
Its items run in this buffer, the box's (`harness-compose--chip-actions')."
  (let ((buffer (current-buffer)))
    (cons (harness-compose--chip-what att)
          (mapcar (lambda (action)
                    (vector (car action)
                            (lambda ()
                              (interactive)
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer (funcall (cdr action)))))
                            t))
                  (harness-compose--chip-actions att)))))

;;;; Tasks

;; A task of the project attaches to a message as what the model needs
;; to know of it, as text: its id, title, column, priority, session and
;; branch, then its prompt (`harness-compose--task-text').  The model
;; reads the rest with the task tools.  Its token is its reference,
;; @task:ID, which @task: completes in the box; C-c C-a attaches one as
;; task:ID, M-x harness-compose-attach-task by its title, and @ on a
;; card of the task board attaches that card's.  The project's tasks
;; are listed with the other completions, never waited for: what is not
;; listed yet fills in when the list comes.

(declare-function harness-ui-tasks-show-task "harness-ui-tasks")

(defconst harness-compose-task-mime "text/x-harness-task"
  "The MIME type of a task attached to a message.")

(defconst harness-compose--task-prompt-max 3000
  "Most characters of its prompt a task attached to a message gives the model.")

(defun harness-compose-fetch-tasks (&optional callback)
  "List the tasks of the box's project again, for @task: and the attach commands.
In the background: CALLBACK, when given, is called in the box's buffer
once they are in.  Without the task module there are none."
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/task/list" (list :cwd (harness-compose--root))
                     (lambda (tasks)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (harness-compose--arrived 'harness-compose--tasks (append tasks nil))
                           (when callback (funcall callback)))))
                     #'ignore)))

(defun harness-compose--task (id)
  "Return the task ID of the box's project, as last listed, or nil."
  (cl-find id harness-compose--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-compose--task-column (task)
  "Return the column TASK shows in on the task board, as a string."
  (format "%s" (or (plist-get task :column) (plist-get task :state) "")))

(defun harness-compose--task-text (task)
  "Return what the model reads of TASK attached to a message.
Its id and title, column and state, priority, session and branch, then
its prompt, cut at `harness-compose--task-prompt-max' characters, and
where to read more."
  (let* ((prompt (string-trim (or (plist-get task :prompt) "")))
         (cut (> (length prompt) harness-compose--task-prompt-max))
         (field (lambda (name value)
                  (let ((value (and value (format "%s" value))))
                    (and value (not (string-empty-p value)) (format "%s: %s\n" name value))))))
    (concat
     (format "Task %s, attached: %s\n" (plist-get task :id) (harness-ui-task-title task))
     (funcall field "Column" (harness-compose--task-column task))
     (and (not (equal (format "%s" (plist-get task :state)) (harness-compose--task-column task)))
          (funcall field "State" (plist-get task :state)))
     (funcall field "Priority" (plist-get task :priority))
     (funcall field "Session" (plist-get task :session))
     (funcall field "Branch" (plist-get task :branch))
     "Prompt:\n"
     (if cut (substring prompt 0 harness-compose--task-prompt-max) prompt) "\n"
     (and cut (format "[The prompt is cut here: %d of its %d characters.]\n"
                      harness-compose--task-prompt-max (length prompt)))
     "The task tools tell more: task_list shows the task, session_read reads its session.")))

(defun harness-compose--task-attachment (task)
  "Return the attachment of TASK, a task record: text for the model, no file."
  (let ((id (plist-get task :id)))
    (list :task id :name (harness-ui-task-title task) :session (plist-get task :session)
          :state (harness-compose--task-column task) :mime harness-compose-task-mime
          :ref (concat "task:" id) :text (harness-compose--task-text task))))

(defun harness-compose--task-annotator ()
  "Return the annotation function of task ids: each task's title and column."
  (let ((buf (current-buffer)))
    (lambda (id)
      (when-let* ((task (and (buffer-live-p buf) (with-current-buffer buf (harness-compose--task id)))))
        (format "  %s  [%s]" (harness-ui-task-title task) (harness-compose--task-column task))))))

(defun harness-compose--task-table ()
  "Return the completion table of the ids of the project's tasks, newest first.
The tasks are read each time the table is asked, as they arrive in the
background (`harness-compose-fetch-tasks'); each id is annotated with
its task's title and column."
  (let ((buf (current-buffer))
        (annotate (harness-compose--task-annotator)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata (category . harness-compose-task)
                     (annotation-function . ,annotate)
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
        (complete-with-action action
                              (and (buffer-live-p buf)
                                   (reverse (mapcar (lambda (task) (plist-get task :id))
                                                    (buffer-local-value 'harness-compose--tasks buf))))
                              string pred)))))

(defun harness-compose-read-task ()
  "Read a task of the box's project and return its id.
The candidates are \"ID  Title  [column]\", newest first, and fill in
as the list of tasks arrives: it is never waited for.  An id typed out
is taken as it is, after @task: or task: as well."
  (harness-compose-fetch-tasks)
  (let* ((buf (current-buffer))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (category . harness-compose-task)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action
                     action
                     (and (buffer-live-p buf)
                          (mapcar (lambda (task)
                                    (format "%s  %s  [%s]" (plist-get task :id) (harness-ui-task-title task)
                                            (harness-compose--task-column task)))
                                  (reverse (buffer-local-value 'harness-compose--tasks buf))))
                     string pred))))
         (answer (car (split-string (completing-read "Attach task: " table nil nil)))))
    (unless answer (user-error "No task given"))
    (string-remove-prefix "task:" (string-remove-prefix "@" answer))))

(defun harness-compose-attach-task (task)
  "Attach TASK, a task of the box's project, to the next message.
TASK is its id, or its record.  The model gets the task as text: its
title, column, session, branch and prompt (`harness-compose--task-text').
Its reference, @task:ID, goes into the box where point is, unless the
box holds it already, as a chip a click opens: the task's session, or
its card on the task board.  A task not listed yet is attached once
the list comes, its reference at the end of the box.  Interactively,
the task is read with completion (`harness-compose-read-task')."
  (interactive (list (harness-compose-read-task)))
  (let ((record (if (stringp task) (harness-compose--task task) task)))
    (if record
        (if (not (harness-compose--attach (harness-compose--task-attachment record)))
            (message "Task %s is attached already" (plist-get record :id))
          (funcall harness-compose-redraw-function)
          (message "Attached task %s" (plist-get record :id)))
      (harness-compose-fetch-tasks
       (lambda ()
         (let ((record (harness-compose--task task)))
           (cond ((null record) (message "No task %s in this project" task))
                 ((harness-compose--attach (harness-compose--task-attachment record) t)
                  (funcall harness-compose-redraw-function)
                  (message "Attached task %s" task)))))))))

(defun harness-compose--open-task (att)
  "Open the task ATT is: its session's chat, else its card on the task board."
  (let ((session (plist-get att :session)))
    (cond ((and (stringp session) (not (string-empty-p session)))
           (harness-ui-display-session session))
          ((fboundp 'harness-ui-tasks-show-task)
           (harness-ui-tasks-show-task (plist-get att :task) (harness-compose--root)))
          (t (user-error "Task %s has no session yet, and the task board is not loaded"
                         (plist-get att :task))))))

;;;; Threads

;; A THREAD is a reply to a region of something on the screen -- part of
;; a message, several messages, lines of a diff -- that the user starts
;; on purpose, with C-c >.  What the region is from is recorded as data,
;; the references of the thread (`harness-thread-block' says their shape),
;; so nothing is guessed from the words later.  In the box a thread is an
;; attachment, `(:thread DATA :reply N)', with the token [reply N] that
;; the others have: shown as a CARD, what the reply is to -- who wrote
;; it, and the part quoted, a few lines -- with a rail down its side that
;; goes on beside the words written under it.  Those words are the reply:
;; typed in the box as any, with all it has, the attachments, the @
;; references, the completions, the undo.  The text before the first
;; card is the message's own; the text after a card, up to the next, is
;; the response in that thread.
;;
;; The card is no text: the token is.  So moving, cutting, yanking and
;; undoing work on it as on an image's token, and deleting the token
;; removes the thread, the words under it staying as plain text.  A click
;; on the card shows what it is a reply to (`harness-compose-thread-open-function'),
;; mouse-3 offers the rest, and the [×] in its header removes it.
;;
;; `harness-compose-take' splits the box at the cards: the message's own
;; text is TEXT, and each thread is an attachment with the response under
;; it, `:response'.  An attachment of that kind is a text block of its own
;; when the message goes out (`harness-compose-attachment-block',
;; `harness-attachments-to-blocks'), and `harness-compose-restore' lays
;; the cards and their responses out in the box again for a message taken
;; back.

(defface harness-thread-rail-face '((t :inherit font-lock-keyword-face :weight bold))
  "The rail down the side of a thread's card and of the words under it."
  :group 'harness-compose)

(defface harness-thread-header-face '((t :inherit (shadow bold)))
  "The line of a thread's card that says what the reply is to."
  :group 'harness-compose)

(defface harness-thread-quote-face '((t :inherit (italic shadow)))
  "The part of a message a thread's card quotes."
  :group 'harness-compose)

(defcustom harness-thread-card-lines 5
  "Most lines of a quote a thread's card shows; the tooltip has the rest."
  :type 'natnum
  :group 'harness-compose)

(defvar harness-compose-thread-open-function #'ignore
  "Function showing what a thread's card is a reply to.
It is called with the data of the thread (`harness-thread-block') and the
reference clicked, a plist, or nil for the card as a whole; the host
sets it: the chat shows the message.")

(defun harness-compose--thread-attachment-p (att)
  "Non-nil when attachment ATT is a reply in a thread."
  (and (consp att) (plist-get att :thread) t))

(defun harness-compose--thread-token (att)
  "Return the token of ATT, a reply in a thread: [reply 1]."
  (and (integerp (plist-get att :reply)) (format "[reply %d]" (plist-get att :reply))))

(defun harness-thread-ref-label (ref)
  "Return what the card of a thread says REF, a region's reference, is.
Of a part of the chat that is who wrote it -- the agent's message, its
plan, its answer in a thread, your own message, a call of a tool -- and of
a diff or a buffer the file and its lines."
  (let ((lines (harness-thread-line-label ref)))
    (pcase (harness-thread-ref-kind ref)
      ("diff" (concat (or (plist-get ref :file) "the change")
                      (and lines (concat ":" lines))
                      (if (equal (format "%s" (plist-get ref :side)) "old") " (before)" " (after)")))
      ("buffer" (concat (or (plist-get ref :file) (plist-get ref :name) "buffer")
                        (and lines (concat ":" lines))))
      (_ (let ((label (plist-get ref :label)))
           (pcase (format "%s" (plist-get ref :who))
             ("agent" "agent's message")
             ("thread" "agent's answer in a thread")
             ("you" "your message")
             ("plan" "agent's plan")
             ("report" "hand-in report")
             ("tool" (if (stringp label) (format "%s call" label) "tool call"))
             (who (if (and (stringp label) (not (string-empty-p label))) label who))))))))

(defun harness-thread-ref-excerpt (ref room)
  "Return the lines of REF's quote a card shows, at most ROOM columns wide.
The first `harness-thread-card-lines' non-blank lines, a long one cut
short and the cut ones ending in an ellipsis."
  (let* ((text (or (plist-get ref :text) ""))
         (lines (cl-remove-if #'string-blank-p
                              (mapcar #'string-trim-right (split-string text "\n"))))
         (shown (seq-take lines harness-thread-card-lines)))
    (append (mapcar (lambda (line) (truncate-string-to-width line room nil nil "…")) shown)
            (and (> (length lines) (length shown)) (list "…")))))

(defun harness-thread-card-lines (data &optional room close)
  "Return the lines of the card for the thread DATA, as propertized strings.
Each reference is a header -- what it is (`harness-thread-ref-label') --
and the lines of its quote under it, ROOM columns wide at most (by
default 72), every line after the rail and with the reference it is of
as `harness-thread-ref', for a click to show.  CLOSE, a string, is put at
the end of the first header, such as a button that removes the thread.
The card is no text of the buffer; the caller puts it where it goes."
  (let* ((room (max 16 (- (or room 72) 2)))
         (rail (propertize "▎ " 'face 'harness-thread-rail-face))
         (refs (harness-thread-refs data))
         (first t) lines)
    (dolist (ref refs)
      (let ((header (concat rail
                            (propertize (concat "↩ " (harness-thread-ref-label ref))
                                        'face 'harness-thread-header-face))))
        (push (if (and first close) (concat header "  " close) header) lines)
        (setq first nil)
        (dolist (line (harness-thread-ref-excerpt ref room))
          (push (concat rail (propertize line 'face 'harness-thread-quote-face)) lines))
        ;; Each line of a reference says which it is: a click on it shows that one.
        (let ((here (cl-loop for l in lines
                             while (not (get-text-property 0 'harness-thread-ref l))
                             collect l)))
          (dolist (l here)
            (put-text-property 0 (length l) 'harness-thread-ref ref l)))))
    (nreverse lines)))

(defun harness-compose--thread-help (data)
  "Return the tooltip of a thread's card: the whole quote of each reference."
  (mapconcat (lambda (ref)
               (concat (harness-thread-ref-label ref) ":\n" (or (plist-get ref :text) "")))
             (harness-thread-refs data) "\n\n"))

(defun harness-compose--next-reply ()
  "Return the number of the next reply in a thread: the one after the highest.
The number of a reply never changes once given, as an image's, since the
words under it may name it."
  (1+ (apply #'max 0 (delq nil (append
                                (mapcar (lambda (a) (plist-get a :reply)) harness-compose-attachments)
                                (mapcar (lambda (entry) (plist-get (nth 1 entry) :reply))
                                        harness-compose--detached))))))

(defun harness-compose--card-break (before)
  "Return the line breaks that go between BEFORE and the token of a card.
BEFORE is the box's text up to where the token goes.  The token starts
a line, with a line above it for the words that belong above it: your
own message above the first card, the reply under the card before.  So
the box that holds nothing yet gets a line break for your message, text
that does not end a line gets the one that ends it, and the line break
a card's token ends with, a reply with no words yet, gets another one,
where those words go."
  (cond ((or (string-empty-p before) (not (string-suffix-p "\n" before))) "\n")
        ((string-match-p "\\(?:\\`\\|\n\\)\\[reply [0-9]+\\]\n\\'" before) "\n")
        (t "")))

(defun harness-compose--insert-thread-token (token)
  "Put TOKEN, a reply's, into the box on a line of its own; point goes under it.
At point when point is in the box, else at the end of the box; a line
break comes before it unless it starts a line, and one after it, where
the response is written.  The first card of a box that holds nothing
else leaves a line above it, for a message of your own, and a card
that follows another with no words under it leaves one for those
(`harness-compose--card-break').  A box not drawn gets it at the end of
its text.  Point ends where the response starts."
  (if (not (harness-compose-live-p))
      (setq harness-compose--text
            (concat harness-compose--text (harness-compose--card-break harness-compose--text)
                    token "\n"))
    (unless (harness-compose-in-p) (goto-char harness-compose-end))
    (insert (harness-compose--card-break
             (buffer-substring-no-properties harness-compose-start (point)))
            token "\n")
    (harness-compose-update-placeholder)))

(defun harness-compose-add-thread (refs)
  "Start a reply in a thread to REFS, references to regions, in the box.
The reply is a card -- what the regions are, and the part of each quoted
-- and the words written under it are the response.  Point goes there,
and it is the reply that typing from outside the box goes to until
point is in another area (\\<harness-compose-map>\\[harness-compose-toggle-reply] moves it out to your own message).
REFS are plists of the shape `harness-thread-block' describes.  Return
the attachment."
  (unless refs (user-error "Nothing to reply to"))
  (let ((att (list :thread (list :refs refs) :reply (harness-compose--next-reply))))
    (setq harness-compose-attachments (append harness-compose-attachments (list att)))
    (harness-compose--forget-detached (harness-compose--thread-token att))
    (harness-compose--insert-thread-token (harness-compose--thread-token att))
    (setq harness-compose--area (plist-get att :reply)
          harness-compose--here (plist-get att :reply)
          harness-compose--reply (plist-get att :reply))
    (funcall harness-compose-redraw-function)
    ;; Its windows follow point into the box, where the words go.
    (harness-compose--quoted)
    att))

(defun harness-compose--thread-spans (text atts)
  "Return where the cards of ATTS stand in TEXT: (ATT START . END), in order.
The first place a token is in TEXT; a reply whose token is not there is
left out."
  (let (spans)
    (dolist (att atts)
      (when (harness-compose--thread-attachment-p att)
        (when-let* ((token (harness-compose--thread-token att))
                    (span (car (harness-compose--token-spans token text))))
          (push (cons att span) spans))))
    (sort spans (lambda (a b) (< (cadr a) (cadr b))))))

(defun harness-compose--split-threads (text atts)
  "Return (OWN . THREADS) from TEXT, the box's, and ATTS, its attachments.
OWN is the text before the first card, with the cards and what is under
them cut out; THREADS are the replies in order, each its attachment with
`:response' the words under its card up to the next, trimmed.  A box with
no card is OWN alone, as it stands."
  (let ((spans (harness-compose--thread-spans text atts)))
    (if (null spans)
        (cons text nil)
      (let (threads)
        (cl-loop for (entry . more) on spans
                 do (let* ((att (car entry))
                           (from (cddr entry))
                           (to (if more (cadr (car more)) (length text))))
                      (push (append (list :response (string-trim (substring text from to)))
                                    (cl-loop for (k v) on att by #'cddr
                                             unless (eq k :response) append (list k v)))
                            threads)))
        (cons (string-trim (substring text 0 (cadr (car spans)))) (nreverse threads))))))

(defun harness-compose-restore (text atts)
  "Put TEXT and ATTS, a message taken back, into the box as `take' gave them.
A reply in a thread among ATTS has its words in `:response': they go
back under its card, after TEXT, and the attachment is kept without
them, as the box has it.  Return the attachments."
  (let ((box text) threads others)
    (dolist (att atts)
      (if (not (harness-compose--thread-attachment-p att))
          (push att others)
        (setq box (concat box (harness-compose--card-break box)
                          (harness-compose--thread-token att) "\n"
                          (or (plist-get att :response) "")))
        (push (cl-loop for (k v) on att by #'cddr unless (eq k :response) append (list k v)) threads)))
    (harness-compose-set box)
    (setq harness-compose-attachments (append (nreverse threads) (nreverse others)))))

(defun harness-compose-prepend (text replies)
  "Put TEXT and REPLIES, a message taken back, into the box, above its words.
REPLIES are attachments of replies in threads as `harness-compose-take'
gives them, `:response' the words under each card: they take the
numbers after the box's own, their cards come before the box's, and
TEXT goes ahead of the words the box has of its own, a blank line
between: the text before a card is the message's, and a card keeps
what follows it.  Return the box's attachments."
  (let* ((draft (harness-compose-text))
         (first (car (harness-compose--thread-spans draft harness-compose-attachments)))
         (own (string-trim (if first (substring draft 0 (cadr first)) draft)))
         (cards (and first (substring draft (cadr first))))
         (n (1- (harness-compose--next-reply)))
         (box (concat text (if (or (string-empty-p text) (string-empty-p own)) "" "\n\n") own))
         added)
    (dolist (reply replies)
      (setq n (1+ n))
      (let ((att (cons :reply (cons n (cl-loop for (k v) on reply by #'cddr
                                               unless (memq k '(:reply :response)) append (list k v))))))
        (setq box (concat box (harness-compose--card-break box)
                          (harness-compose--thread-token att) "\n" (or (plist-get reply :response) ""))
              added (append added (list att)))))
    (harness-compose-set (concat box (if cards (concat (harness-compose--card-break box) cards) "")))
    (setq harness-compose-attachments (append harness-compose-attachments added))))

(defun harness-compose--thread-chip-room ()
  "Return how many columns the card of a thread has: the narrowest window's body.
Less the prompt's and the rail's."
  (let ((windows (get-buffer-window-list nil nil t)))
    (max 24 (- (if windows (apply #'min (mapcar #'window-body-width windows)) (frame-width)) 6))))

(defun harness-compose--thread-card (att)
  "Return the card of ATT, a reply in a thread, as the string a token shows.
Its lines are parted by line breaks, the last without one, since the
text goes on with its own; the first header ends with [×], which removes
the thread.  A click on the rest shows what the reply is to."
  (let* ((data (plist-get att :thread))
         (props (list 'help-echo (harness-compose--thread-help data)
                      'keymap (harness-compose--chip-map att)
                      'mouse-face 'highlight 'pointer 'hand))
         (close (propertize "[×]" 'face 'harness-thread-header-face 'mouse-face 'highlight 'pointer 'hand
                            'help-echo "Remove this thread; the words under it stay"
                            'keymap (let ((m (make-sparse-keymap)))
                                      (define-key m [mouse-1]
                                                  (harness-compose--chip-command
                                                   (lambda (_) (harness-compose-remove-attachment att))))
                                      m)))
         (card (string-join (harness-thread-card-lines data (harness-compose--thread-chip-room) close) "\n"))
         (pos 0))
    ;; Everywhere but on the button, which has its own.
    (while (< pos (length card))
      (let ((next (next-single-property-change pos 'keymap card (length card))))
        (unless (get-text-property pos 'keymap card)
          (add-text-properties pos next props card))
        (setq pos next)))
    card))

(defun harness-compose--thread-rail ()
  "Return the prefix of the lines of the words under a card.
The box's indentation (`harness-compose--indent'), and the rail."
  (concat (or (and harness-compose--indent (overlay-buffer harness-compose--indent)
                   (overlay-get harness-compose--indent 'line-prefix))
              "")
          (propertize "▎ " 'face (list 'harness-thread-rail-face harness-compose--face))))

(defun harness-compose--thread-response-overlays ()
  "Return what covers the words under each card, to draw the rail beside them.
Each is (START END PREFIX): from the line after a token to the next card
or the end of the box, the box's last newline included, so that an empty
response has its line too."
  (let* ((text (harness-compose--box-string))
         (start (marker-position harness-compose-start))
         (spans (harness-compose--thread-spans text harness-compose-attachments))
         (rail (and spans (harness-compose--thread-rail))))
    (cl-loop for (entry . more) on spans
             for from = (+ start (cddr entry) 1)
             for to = (if more (+ start (cadr (car more))) (1+ (marker-position harness-compose-end)))
             when (and (< from to) (<= from (point-max))) collect (list from (min to (point-max)) rail))))

(defun harness-compose--show-thread-rails ()
  "Draw the rail beside the words under each card; draw it again only if it moved."
  (let ((want (harness-compose--thread-response-overlays)))
    (unless (equal want (mapcar (lambda (ov) (list (overlay-start ov) (overlay-end ov) (overlay-get ov 'line-prefix)))
                                harness-compose--thread-rails))
      (mapc #'delete-overlay harness-compose--thread-rails)
      (setq harness-compose--thread-rails
            (mapcar (lambda (w)
                      (let ((ov (make-overlay (nth 0 w) (nth 1 w) nil nil t)))
                        (overlay-put ov 'line-prefix (nth 2 w))
                        (overlay-put ov 'wrap-prefix (nth 2 w))
                        (overlay-put ov 'priority 10)
                        (overlay-put ov 'harness-compose-thread-rail t)
                        (overlay-put ov 'evaporate t)
                        ov))
                    want)))))

(defun harness-compose-open-thread (att &optional ref)
  "Show what ATT, a reply in a thread, is a reply to; REF, one reference of it.
The host does it (`harness-compose-thread-open-function')."
  (funcall harness-compose-thread-open-function (plist-get att :thread) ref))

(defun harness-compose--thread-actions (att)
  "Return what the card of ATT offers: (NAME . FUNCTION) each."
  (list (cons "Show what this replies to" (lambda () (harness-compose-open-thread att)))
        (cons "Remove the thread, keep my words" (lambda () (harness-compose-remove-attachment att)))
        (cons "Copy the quote" (lambda ()
                                 (kill-new (harness-thread-quote (plist-get att :thread)))
                                 (message "Copied the quote")))))

;;;; Your message, and the replies

;; A box that holds cards is not one place to write but several.  The
;; words before the first card are your own message, on a line of their
;; own that the first card leaves for them
;; (`harness-compose--card-break'); the words under a card are the reply
;; to it, with the rail beside them.  Each is an AREA, and the rail says
;; which one point is in: words with it are a reply, words without it
;; are yours.
;;
;; C-c > puts point in the reply it started, so the first thing typed is
;; the reply.  C-c < (`harness-compose-toggle-reply') moves point out of
;; it, to your own message, and back into the reply; its two halves are
;; `harness-compose-leave-reply' and `harness-compose-enter-reply'.  The
;; ordinary ways out work as well, being text: C-p, M-< (the top of the
;; box), a click.  Moving up from the reply puts point at the start of
;; the card, which is no text to type against: a key typed there goes
;; into your message above it (`harness-compose--card-edge-target'), and
;; at the card's end into the start of the reply.
;;
;; The box remembers which area point was in after each command
;; (`harness-compose--note-area'), so that what is typed from outside it
;; -- after reading the transcript, in another window -- goes to the
;; area written in last (`harness-compose--entry-point'), not always
;; under the last card.
;;
;; The card where point is says how to move out of its reply, and, with
;; point in your message, the card of the reply to go back into says so
;; (`harness-compose--card-hint'); an area with no words yet says what it
;; is, Message… or Reply… (`harness-compose--area-placeholders').

(defcustom harness-compose-reply-hints t
  "Non-nil: a card says how to move point out of its reply, and back in.
The card of the reply point is in names \\<harness-compose-map>\\[harness-compose-toggle-reply] as the way to your own
message; with point in your message, the card of the reply it goes
back into names it as the way back.  An empty area says what it is
\(Message…, Reply…) whatever this is set to."
  :type 'boolean
  :group 'harness-compose)

(defun harness-compose--cards ()
  "Return where the cards of the replies stand in the box.
A list of (ATT START . END), in order, START and END being the buffer
positions of the token each card shows for; nil when the box is not
drawn or holds no card."
  (when (and (harness-compose-live-p)
             (cl-some #'harness-compose--thread-attachment-p harness-compose-attachments))
    (let ((base (marker-position harness-compose-start)))
      (mapcar (lambda (entry) (cons (car entry) (cons (+ base (cadr entry)) (+ base (cddr entry)))))
              (harness-compose--thread-spans (harness-compose--box-string) harness-compose-attachments)))))

(defun harness-compose--card-with-hint (card hint props)
  "Return CARD, the string a card shows, with HINT at the end of its first line.
That is after its [×].  HINT, a string or nil, is part of the card: it
has PROPS, the properties the rest of the card has (a click shows what
the reply is to).  See `harness-compose--card-hint'."
  (if (null hint)
      card
    (let ((eol (or (string-search "\n" card) (length card))))
      (concat (substring card 0 eol)
              (apply #'propertize (concat "  " hint) props)
              (substring card eol)))))

(defun harness-compose--card-number (card)
  "Return the number of the reply CARD, an entry of `harness-compose--cards', is."
  (plist-get (car card) :reply))

(defun harness-compose--area-of (cards pos)
  "Return the area of the box POS is in, given its CARDS.
`own' for your own message, which is what comes before the first card,
else the number of the reply: the words after a card's token, up to
the next card's."
  (let ((area 'own))
    (dolist (card cards)
      (when (>= pos (cddr card))
        (setq area (harness-compose--card-number card))))
    area))

(defun harness-compose--before-break (pos)
  "Return POS, or where the line break that ends the line before POS starts.
The words of an area end before the line break that parts them from
the next card."
  (if (and (> pos harness-compose-start) (eq (char-before pos) ?\n))
      (1- pos)
    pos))

(defun harness-compose--reply-card (cards)
  "Return the card of CARDS point goes back into: the reply last in, else the last."
  (or (and harness-compose--reply
           (cl-find harness-compose--reply cards :key #'harness-compose--card-number))
      (car (last cards))))

(defun harness-compose--area-point (cards area)
  "Return where the words of AREA end in the box, given its CARDS.
AREA is `own' or a reply's number.  Your own message ends before the
first card, a reply before the next one, the last at the box's end -- as
a reply taken away does, which has no end of its own.  Every area has
a line for its words: one that has none yet -- the box that starts
with a card, words that run on into a token (\"XY[reply 1]\"), a token
that is the last thing before the next card or the box's end -- gets
the line break that makes it, which changes the box, point staying
where it is."
  (if (eq area 'own)
      (let ((token (cadr (car cards))))
        (cond ((null token) harness-compose-end)
              ((and (> token harness-compose-start) (eq (char-before token) ?\n)) (1- token))
              (t (save-excursion (goto-char token) (insert "\n"))
                 token)))
    (let* ((rest (cl-member area cards :key #'harness-compose--card-number))
           (card (car rest))
           (next (cadr rest))
           (end (if next (harness-compose--before-break (cadr next)) harness-compose-end)))
      (cond ((null card) harness-compose-end)
            ((> end (cddr card)) end)
            (t (save-excursion (goto-char end) (insert "\n"))
               (1+ (cddr card)))))))

(defun harness-compose--entry-point ()
  "Return where text that comes from outside the box goes in it.
The end of the area written in last (`harness-compose--note-area'), once
the box holds a card: your own message, or a reply.  Else the box's end,
which is where it goes when that reply was taken away too."
  (let ((cards (harness-compose--cards)))
    (if (and cards
             (or (eq harness-compose--area 'own)
                 (cl-find harness-compose--area cards :key #'harness-compose--card-number)))
        (harness-compose--area-point cards harness-compose--area)
      harness-compose-end)))

(defun harness-compose--card-edge-target (pos)
  "Return where text typed with point at POS goes instead, or nil.
A card is no text to type against: point goes to its start, the start
of the line it is on, when moving up from the reply under it, and typing
there would run the words into the card.  So typing at its start goes to
the end of the area above it, and typing at its end to the start of the
words of its reply, on the line under it."
  (let ((cards (harness-compose--cards)) (above 'own))
    (cl-dolist (card cards)
      (cond ((= pos (cadr card))
             (cl-return (harness-compose--area-point cards above)))
            ((= pos (cddr card))
             (harness-compose--area-point cards (harness-compose--card-number card))
             (cl-return (1+ (cddr card)))))
      (setq above (harness-compose--card-number card)))))

(defun harness-compose--note-area ()
  "Remember which area of the box point is in, when the box holds a card.
Runs after every command, from `post-command-hook'
\(`harness-compose--keep-tokens').
A command that takes point out of the box -- a key that goes up into the
transcript, a click, another window -- leaves the area it was in
remembered, for what is typed next to go to
\(`harness-compose--entry-point'); `harness-compose--here' is nil then."
  (condition-case err
      (let ((cards (and (harness-compose-in-p) (harness-compose--cards))))
        (if (null cards)
            (setq harness-compose--here nil)
          (let ((area (harness-compose--area-of cards (point))))
            (setq harness-compose--area area
                  harness-compose--here area)
            (when (integerp area) (setq harness-compose--reply area)))))
    (error (harness-log 'warn "compose: noting the area point is in failed: %S" err))))

(defun harness-compose--jump (pos)
  "Put point at POS in the box, from wherever it is; its windows follow it in.
From outside the box the region is dropped, which would reach out of it."
  (unless (harness-compose-in-p)
    (deactivate-mark)
    (cl-incf harness-compose--jumps))
  (goto-char pos)
  (harness-compose--note-area))

(defun harness-compose--need-cards ()
  "Return the cards of the box, or say that it holds none."
  (unless (harness-compose-live-p) (user-error "No compose box here"))
  (or (harness-compose--cards)
      (user-error "%s" (substitute-command-keys
                        "No reply in the box: \\<harness-compose-map>\\[compose-quote-reply] starts one"))))

(defun harness-compose-leave-reply ()
  "Move point out of the reply, to your own message above the first card.
The message is the words before the first card, a line of their own,
which is made if the box has none yet; point goes to its end.  What is
typed there is the message, whatever the replies say, and the replies
stay as they are, with their words.  \\<harness-compose-map>\\[harness-compose-toggle-reply] goes back into the reply."
  (interactive)
  (harness-compose--jump (harness-compose--area-point (harness-compose--need-cards) 'own)))

(defun harness-compose-enter-reply ()
  "Move point into a reply: to the end of the words under its card.
The reply that point was last in, else the last one.  Typing there is
the reply again, whatever the message above it says.  \\<harness-compose-map>\\[harness-compose-toggle-reply] moves
out again."
  (interactive)
  (let ((cards (harness-compose--need-cards)))
    (harness-compose--jump
     (harness-compose--area-point cards (harness-compose--card-number (harness-compose--reply-card cards))))))

(defun harness-compose-toggle-reply ()
  "Switch between your own message and the reply under a card.
\\<harness-compose-map>\\[harness-compose-toggle-reply] in a reply moves point out of it, to your message above the first
card (`harness-compose-leave-reply'); in your message it moves point
back into the reply (`harness-compose-enter-reply'); from outside the
box it goes in, to where you were writing last.  A reply is what a card
starts, the words with its rail beside them; the box keeps the words of
each, and what is sent is your message and then each reply as its
own."
  (interactive)
  (unless (harness-compose-live-p) (user-error "No compose box here"))
  (cond ((not (harness-compose-in-p))
         (harness-compose--jump (harness-compose--entry-point)))
        ((eq (harness-compose--area-of (harness-compose--need-cards) (point)) 'own)
         (harness-compose-enter-reply))
        (t (harness-compose-leave-reply))))

(defun harness-compose--toggle-hint (what)
  "Return the hint that says \\<harness-compose-map>\\[harness-compose-toggle-reply] goes WHAT: dim, the key in its face."
  (concat (harness-ui-kbd (substitute-command-keys
                           "\\<harness-compose-map>\\[harness-compose-toggle-reply]" t))
          (propertize (concat " " what) 'face 'harness-dim-face)))

(defun harness-compose--card-hint (att cards)
  "Return what the card of ATT, one of the box's CARDS, says of \\<harness-compose-map>\\[harness-compose-toggle-reply], or nil.
With point in its reply, that it moves out to your message; with point
in your message, on the card of the reply that goes in, that it goes
back.  Nothing for the other cards, nor with point outside the box, nor
with `harness-compose-reply-hints' off.  Where point is is where it was
after the last command (`harness-compose--here'), so that a host drawing
the box again, with point in between wherever it leaves it, shows the
same."
  (when (and harness-compose-reply-hints cards harness-compose--here)
    (let ((number (plist-get att :reply)))
      (cond ((eql harness-compose--here number) (harness-compose--toggle-hint "your message"))
            ((and (eq harness-compose--here 'own)
                  (eql number (harness-compose--card-number (harness-compose--reply-card cards))))
             (harness-compose--toggle-hint "back to the reply"))))))

(defun harness-compose--area-placeholders ()
  "Return the empty areas of the box that say what they are.
A list of (POSITION . TEXT): your own message when it has a line to
itself above the first card and no words on it -- the box's usual
placeholder -- and each reply with no words under its card, on the line
left for them, \"Reply…\".  nil without a card."
  (when-let* ((cards (harness-compose--cards)))
    (let* ((start (marker-position harness-compose-start))
           (end (marker-position harness-compose-end))
           (face (list 'harness-dim-face harness-compose--face))
           (said (lambda (text) (propertize text 'face face 'cursor t)))
           (blank (lambda (from to)
                    (save-excursion (goto-char from) (skip-chars-forward " \t\n" to) (= (point) to))))
           found)
      (when (and (= (cadr (car cards)) (1+ start)) (eq (char-after start) ?\n))
        (push (cons start (funcall said (funcall harness-compose-placeholder-function))) found))
      (cl-loop for (card . more) on cards
               for from = (1+ (cddr card))
               for to = (if more (cadr (car more)) end)
               when (and (<= from to)
                         (or (= from end) (eq (char-after from) ?\n))
                         (funcall blank from to))
               do (push (cons from (funcall said "Reply…")) found))
      (nreverse found))))

(defun harness-compose--show-area-hints ()
  "Show what the empty areas of the box are, and no longer what has words now.
Made again only when they changed (`harness-compose--area-placeholders')."
  (let ((want (harness-compose--area-placeholders)))
    (unless (equal want (mapcar (lambda (ov) (cons (overlay-start ov) (overlay-get ov 'harness-compose-area-hint)))
                                harness-compose--area-hints))
      (mapc #'delete-overlay harness-compose--area-hints)
      (setq harness-compose--area-hints
            (mapcar (lambda (w)
                      (let ((ov (make-overlay (car w) (car w))))
                        (overlay-put ov 'before-string (cdr w))
                        (overlay-put ov 'harness-compose-area-hint (cdr w))
                        ov))
                    want)))))

;;;; Undo

;; Hosts draw around the box with undo off, so what they draw above it
;; moves the box's text but not the positions its undo entries record:
;; undoing would change the wrong text, or signal that it is read-only.
;; Attaching an image draws its line above the box, so undoing right
;; after a paste would.  Before every command, and every change, the
;; entries move by as much as the box moved since the last time.

(defun harness-compose--line-up-undo (&rest _)
  "Move the undo entries by as much as the box moved since the last time.
Runs from `pre-command-hook' and `before-change-functions'.  Not while
undo is off, as a host redraws: the box is in pieces then, and moved
when it is whole again."
  (when (and (listp buffer-undo-list) (harness-compose-live-p))
    (let ((start (marker-position harness-compose-start)))
      (when (and harness-compose--undo-start (/= start harness-compose--undo-start))
        (harness-compose--shift-undo buffer-undo-list (- start harness-compose--undo-start)))
      (setq harness-compose--undo-start start))))

(defun harness-compose--shift-undo (entries delta)
  "Move the positions the undo list ENTRIES record by DELTA, in place.
`pending-undo-list', a tail of `buffer-undo-list' while undoing goes on,
moves with them."
  (while (consp entries)
    (let ((entry (car entries)))
      (pcase entry
        ((pred integerp) (setcar entries (+ entry delta)))
        (`(,(and beg (pred integerp)) . ,(and end (pred integerp)))
         (setcar entry (+ beg delta))
         (setcdr entry (+ end delta)))
        (`(,(pred stringp) . ,(and pos (pred integerp)))
         ;; Negative: point was at the end of the deleted text.
         (setcdr entry (if (< pos 0) (- pos delta) (+ pos delta))))
        (`(nil ,_ ,_ ,(and beg (pred integerp)) . ,(and end (pred integerp)))
         (setcar (nthcdr 3 entry) (+ beg delta))
         (setcdr (nthcdr 3 entry) (+ end delta)))
        (`(apply ,(pred integerp) ,(and beg (pred integerp)) ,(and end (pred integerp)) . ,_)
         (setcar (nthcdr 2 entry) (+ beg delta))
         (setcar (nthcdr 3 entry) (+ end delta)))))
    (setq entries (cdr entries))))

;;;; Downloads

;; A link dropped on the box downloads with curl as a subprocess
;; (`harness-http-download'), never blocking Emacs.  Until it arrived
;; its place among the attachments holds a pending entry, (:pending t
;; :id :url :name :download ...), whose chip shows the progress; then
;; the attachment of the file takes its place, in the downloads
;; directory under the name the server or the link gave.

(defun harness-compose-attach-clipboard (&optional from-ring)
  "Attach what the clipboard holds.
An image is attached and goes on the media ring, files copied in a
file manager are attached, data of other MIME types is offered to
choose from and attached, and plain text goes into the box.  With a
prefix argument FROM-RING, attach an earlier capture of the media ring
instead (`harness-compose-attach-from-ring')."
  (interactive "P")
  (if from-ring
      (call-interactively #'harness-compose-attach-from-ring)
    (unless (display-graphic-p) (user-error "The clipboard needs a graphical display"))
    (let* ((targets (harness-media-ring-clipboard-targets))
           (image (harness-media-ring-capture-image targets))
           (files (and (not image) (harness-media-ring-clipboard-files targets)))
           (mimes (cl-remove-if-not (lambda (s) (string-match-p "\\`[a-z]+/" (symbol-name s))) targets)))
      (cond
       (image (harness-compose--attach-captures (list image)))
       (files (harness-compose--attach-captures (mapcar #'harness-compose--file-attachment files)))
       (mimes
        (let* ((choice (intern (completing-read "Clipboard type: " (mapcar #'symbol-name mimes) nil t)))
               (att (harness-media-ring-capture choice)))
          (unless att (user-error "The clipboard gave nothing as %s" choice))
          (harness-compose--attach-captures (list att))))
       (t
        (let ((text (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING))))
          (unless (and (stringp text) (not (string-empty-p text)))
            (user-error "Nothing usable in the clipboard"))
          (unless (harness-compose-in-p) (goto-char harness-compose-end))
          (insert (substring-no-properties text))))))))

(defun harness-compose-dnd-open (uri action)
  "Attach the file dropped as URI; ACTION is returned unchanged."
  (when-let* ((path (dnd-get-local-file-name uri t)))
    (harness-compose-add-attachment path))
  action)

(defun harness-compose-fetch-files ()
  "Refresh the files @ completes from the project's file list.
Listed here, not by the harness process, so it is this Emacs's
projectile cache (cleared by `projectile-invalidate-cache') that answers;
a miss lists asynchronously.  On failure the previous list is kept.
Return a promise settled once the list is in place.

A box with several roots (`harness-compose-roots-function') lists them
all, each in its own time, and `harness-compose--files' holds the union
of the lists that arrived so far (`harness-compose--arrived-in'); the
promise settles once all of them have."
  (let ((buf (current-buffer))
        (roots (setq harness-compose--file-roots (harness-compose--roots))))
    (if (null roots)
        (harness-then (harness-files-list-limited (harness-compose--project) nil 20000)
                      (lambda (files)
                        (when (buffer-live-p buf)
                          (with-current-buffer buf (harness-compose--arrived 'harness-compose--files files))))
                      (lambda (err) (harness-log 'warn "compose: listing project files failed: %s" (harness-error-message err))))
      (harness-all
       (mapcar (lambda (entry)
                 (let ((root (car entry)))
                   (harness-then (harness-files-list-limited root nil 20000)
                                 (lambda (files)
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf (harness-compose--arrived-in root files))))
                                 (lambda (err) (harness-log 'warn "compose: listing the files of %s failed: %s"
                                                            root (harness-error-message err))))))
               roots)))))

(defun harness-compose--union-files (roots lists)
  "Return the union of the files LISTS hold, as (NAMES . ORIGINS).
ROOTS are (DIR . LABEL) each, LISTS an alist: root -> the files listed
in it, relative to it.  NAMES is every file once, in the order of
ROOTS and of their lists, and ORIGINS a hash table: name -> the roots
that hold it, ROOTS' order.  A name ending in a slash is no file to
attach, but a repository or a worktree nested in the root -- the main
checkout lists the worktrees under its .worktrees so -- and is left out."
  (let ((origins (make-hash-table :test #'equal))
        (names nil))
    (dolist (entry roots)
      (let ((root (car entry)))
        (dolist (name (cdr (assoc root lists)))
          (unless (string-suffix-p "/" name)
            (let ((held (gethash name origins)))
              (unless held (push name names))
              (unless (member root held)
                (puthash name (append held (list root)) origins)))))))
    (cons (nreverse names) origins)))

(defun harness-compose--arrived-in (root files)
  "Take FILES, the files listed in ROOT, into those of a box with several roots.
`harness-compose--files' becomes the union of what arrived for every
root so far (`harness-compose--union-files'), as `harness-compose--arrived'
sets it.  A root that failed to list, or has not yet, adds nothing:
what it listed before stays.  A list that arrives for a root the box
has no more -- its worktree gone since -- is dropped."
  (when (assoc root harness-compose--file-roots)
    (setf (alist-get root harness-compose--root-files nil nil #'equal) files)
    (pcase-let ((`(,names . ,origins)
                 (harness-compose--union-files harness-compose--file-roots harness-compose--root-files)))
      (setq harness-compose--file-origins origins)
      (harness-compose--arrived 'harness-compose--files names))))

(defun harness-compose-fetch-completions ()
  "Prefetch project files, skill names and the project's tasks for completion."
  (let ((buf (current-buffer)))
    (harness-compose-fetch-files)
    (harness-ui-call "_harness/skills/list" (list :cwd (harness-compose--project))
                     (lambda (skills)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (harness-compose--arrived 'harness-compose--skills
                                                     (mapcar (lambda (s) (plist-get s :name)) skills)))))
                     #'ignore)
    (harness-compose-fetch-tasks)))

(defun harness-compose--arrived (var value)
  "Set VAR, a completion source of the box, to VALUE.
A token typed before the source arrived was offered nothing: when VAR
was empty, the completion UI is asked again."
  (let ((was (symbol-value var)))
    (set var value)
    (when (and value (null was))
      (harness-compose--popup-later 0))))

(defun harness-compose--capf-bounds (char)
  "Return (START . END) of the token after CHAR before point in the box."
  (when (harness-compose-in-p)
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n" harness-compose-start)
        (when (and (< (point) end) (eq (char-after) char)
                   (or (= (point) harness-compose-start)
                       (memq (char-before) '(?\s ?\t ?\n))))
          (cons (1+ (point)) end))))))

(defun harness-compose--table (var category &optional annotate)
  "Return a completion table over the strings in VAR, with CATEGORY metadata.
VAR, a variable of the current buffer or a list of them whose strings
are offered together, is read each time the table is asked: the box's
sources arrive asynchronously, and a table made before one did offers
it once it has.  ANNOTATE, when given, is the function that annotates
the candidates."
  (let ((buf (current-buffer)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata (category . ,category)
                     ,@(and annotate `((annotation-function . ,annotate))))
        (complete-with-action action
                              (and (buffer-live-p buf)
                                   (delete-dups
                                    (mapcan (lambda (v) (copy-sequence (buffer-local-value v buf)))
                                            (ensure-list var))))
                              string pred)))))

(defun harness-compose--space-after-token ()
  "Put a space after the token just completed before point, unless one follows.
Typing goes on after it then, rather than against it, which would make
another word of it."
  (unless (and (< (point) harness-compose-end) (memq (char-after) '(?\s ?\t ?\n)))
    (insert " ")))

(defun harness-compose--attach-token (name root)
  "Attach the file the @ token NAME, just completed before point, names.
The token stays, as the file's reference, and a space after it: NAME
when it names the file back, else the file's own reference
\(`harness-compose--file-ref').  An image's token gives way to its
label, [image 1]; so does the token of a file whose name can be no
reference, which attaches without one.  A project file's name attaches
its file, the one of the first root that holds it when the box has
several (`harness-compose--project-file'); a path (relative to ROOT)
only a regular file of this machine: a directory stays in the box, for
its files to complete next."
  (when-let* ((path (if (harness-compose--path-p name)
                        (harness-compose--local-file name root)
                      (harness-compose--project-file name root))))
    (let* ((end (point))
           (start (- end (length name) 1))
           (here (and (harness-compose-in-p start)
                      (equal (buffer-substring-no-properties start end) (concat "@" name))))
           (att (harness-compose--file-attachment path))
           (ref (and here (not (harness-compose--image-attachment-p att))
                     (harness-compose--file-ref path name))))
      (cond (ref
             ;; Completed as another name of the file: that one is its reference.
             (unless (equal ref name)
               (delete-region start end)
               (insert "@" ref))
             (harness-compose--space-after-token)
             (setq att (append att (list :ref ref))))
            (here (delete-region start end)))
      (when (harness-compose--attach att)
        (funcall harness-compose-redraw-function)
        (message "Attached %s" (abbreviate-file-name path))))))

(defun harness-compose--attach-task-token (id)
  "Attach the task ID, whose @task: token was just completed before point.
The token stays, as the task's reference, and a space after it."
  (harness-compose--space-after-token)
  (harness-compose-attach-task id))

(defun harness-compose-completion-at-point ()
  "Complete @files, @task: ids and /skills in the box.
An @ completes a project file by part of its name, or any file by its
path (see `harness-compose--file-table'); a completed file becomes an
attachment, its token staying as its reference.  After @task: the id
of a task of the project completes, annotated with its title and
column, and the task chosen becomes an attachment
\(`harness-compose-attach-task').  A / at the start of the box completes
a skill, or a command of the box (`harness-compose-commands').  The
sigil is what starts completion, the way an LSP trigger character does:
popups that wait for a few characters show right after it."
  (let* ((file (harness-compose--capf-bounds ?@))
         (task (and file (harness-compose--task-name-p
                          (buffer-substring-no-properties (car file) (cdr file)))))
         (skill (harness-compose--capf-bounds ?/))
         (root (harness-compose--root)))
    (cond
     (task
      ;; A new @task: token lists the tasks again, as one for files does.
      (unless (eql (car file) harness-compose--tasks-at)
        (setq harness-compose--tasks-at (car file))
        (harness-compose-fetch-tasks))
      (list (+ (car file) (length "task:")) (cdr file) (harness-compose--task-table)
            :exclusive 'no
            :company-prefix-length t
            :annotation-function (harness-compose--task-annotator)
            :company-kind (lambda (_) 'reference)
            :exit-function
            (lambda (id status)
              (when (memq status '(finished sole))
                (harness-compose--attach-task-token id)))))
     (file
      ;; A new @ token refreshes the list, so files created since the
      ;; buffer opened show up once the listing returns.
      (unless (eql (car file) harness-compose--files-at)
        (setq harness-compose--files-at (car file))
        (harness-compose-fetch-files))
      (list (car file) (cdr file)
            (harness-compose--file-table)
            :exclusive 'no
            :company-prefix-length t
            :company-kind (lambda (name) (if (string-suffix-p "/" name) 'folder 'file))
            :exit-function
            (lambda (str status)
              (when (memq status '(finished sole))
                (harness-compose--attach-token str root)))))
     ((and skill (= (1- (car skill)) harness-compose-start))
      (list (car skill) (cdr skill)
            (harness-compose--table '(harness-compose-commands harness-compose--skills)
                                    'harness-compose-skill)
            :exclusive 'no
            :company-prefix-length t
            :exit-function (lambda (_str status) (when (memq status '(finished sole)) (insert " "))))))))

(defvar harness-state-directory)
(defvar x-dnd-types-alist)
(defvar x-dnd-known-types)
(defvar x-dnd-direct-save-function)
(defcustom harness-compose-thumbnail-lines 4
  "Height of the thumbnail an attached image or video shows, in lines.
0 shows none.  Videos need the media module and ffmpeg."
  :type 'number :group 'harness-compose)

(defcustom harness-compose-download-max-size (* 200 1024 1024)
  "Largest file, in bytes, that a link dropped on a compose box downloads."
  :type 'integer :group 'harness-compose)

(defcustom harness-compose-yank-media t
  "Non-nil: yanking in a compose box attaches the media on the clipboard.
When the clipboard holds an image (copied in a browser, or by a
screenshot tool) or files copied in a file manager, and this Emacs did
not put it there, \\[yank] attaches them instead of yanking text.  The
image goes on the media ring, a kill ring of its own that only compose
boxes read, and \\[yank-pop] right after swaps it for an earlier one.
`kill-ring' never sees an image, so other modes are not affected.
\\[universal-argument] \\[yank] yanks text whatever the clipboard holds,
and so does \\[yank] once the image is attached."
  :type 'boolean :group 'harness-compose)

(defface harness-compose-progress-face '((t :inherit success))
  "The filled part of a download's progress bar." :group 'harness-compose)

;;;; State

(defvar-local harness-compose--progress nil "Alist: id of a pending download -> overlay showing its progress.")
(defvar-local harness-compose--progress-timer nil "Timer animating the chips of pending downloads.")
(defvar-local harness-compose--yanked nil
  "What the last media yank attached: (:paths PATHS :index I).
I is the media ring entry it was, or -1 for files of a file manager.")
(defun harness-compose--yank-binding (command)
  "Return COMMAND, the box's own yank, unless yanking media is off."
  (and harness-compose-yank-media command))

(defun harness-compose--chip-name (att)
  "Return the name the chip of attachment ATT shows.
A file of the project goes by its path in the project, a capture or a
download of the harness by its name, any other file by its path.  With
several roots (`harness-compose-roots-function') a file goes by its
path in the root that holds it (`harness-compose--relative-name')."
  (let ((path (plist-get att :path)))
    (cond ((null path) (or (plist-get att :name) "attachment"))
          ((and (boundp 'harness-state-directory)
                (string-prefix-p (expand-file-name harness-state-directory) path))
           (or (plist-get att :name) (file-name-nondirectory path)))
          (t (harness-compose--relative-name path (harness-compose--project))))))

(defun harness-compose--chip (att &optional room)
  "Return the chip of attachment ATT: its thumbnail, name and size, and ×.
ROOM, in pixels, is how wide the chip may show: the name is shortened
in the middle as much as that needs, and a thumbnail takes a third of
it at most.  Without ROOM the name is whole.  The tooltip leads with
the file's whole path.  The thumbnail and the name drag the file into
another application (`harness-ui-drag-source').  A task has a chip of
its own (`harness-compose--task-chip')."
  (if (plist-get att :task)
      (harness-compose--task-chip att room)
    (harness-compose--file-chip att room)))

(defun harness-compose--file-chip (att &optional room)
  "Return the chip of ATT, a file attached, as `harness-compose--chip' does."
  (let* ((path (plist-get att :path))
         (size (harness-format-bytes (plist-get att :size)))
         (help (harness-ui-one-line
                (string-join (delq nil (list (abbreviate-file-name path) size (plist-get att :mime)
                                             (and (plist-get att :url) (concat "from " (plist-get att :url)))
                                             "mouse-1: open"))
                             " · ")))
         (open (lambda (&rest _) (interactive) (harness-compose-open-attachment att)))
         (thumb (harness-compose--thumbnail att (and room (/ room 3))))
         (head (if thumb
                   (concat (harness-ui-drag-source
                            (propertize thumb 'help-echo help 'pointer 'hand
                                        'keymap (harness-ui-mouse-keymap open))
                            path)
                           " ")
                 ""))
         (remove (concat " " (propertize (buttonize "×" (lambda (_) (harness-compose-remove-attachment path)) nil
                                                    (cond ((plist-get att :label)
                                                           "Remove this image, and its token from the text")
                                                          ((plist-get att :ref)
                                                           "Remove this file, and its reference from the text")
                                                          (t "Remove this attachment")))
                                         'face 'harness-dim-face)))
         ;; An image leads with its token, as the text shows it.
         (token (if (plist-get att :label)
                    (concat (propertize (harness-compose--image-token (plist-get att :label))
                                        'face 'harness-compose-token-face)
                            " ")
                  ""))
         (label (lambda (name) (buttonize (concat token (format "%s (%s)" name size)) open nil help)))
         ;; One line each, whatever a file is called.
         (name (replace-regexp-in-string "[\n\r\t]" " " (harness-compose--chip-name att))))
    (concat head
            (harness-ui-drag-source
             (funcall label (if room
                                (harness-compose--fit name (- room (harness-compose--pixels head)
                                                              (harness-compose--pixels remove))
                                                      label)
                              name))
             path)
            remove)))

(defun harness-compose--task-chip (att &optional room)
  "Return the chip of ATT, a task attached, in the list above the box.
The task's icon, then \"ID · Title (state)\", which a click opens
\(`harness-compose-open-attachment'), and × removing it, its reference
with it.  ROOM, in pixels, is how wide the chip may show: the title is
shortened as much as that needs."
  (let* ((id (plist-get att :task))
         (state (plist-get att :state))
         (help (harness-ui-one-line
                (string-join (delq nil (list (concat "task " id) (plist-get att :name) state
                                             (if (plist-get att :session) "mouse-1: open its session"
                                               "mouse-1: show it on the task board")))
                             " · ")))
         (open (lambda (&rest _) (interactive) (harness-compose-open-attachment att)))
         (head (concat (harness-ui-icon 'harness-icon-task) " "))
         (remove (concat " " (propertize (buttonize "×" (lambda (_) (harness-compose-remove-attachment att)) nil
                                                    "Remove this task, and its reference from the text")
                                         'face 'harness-dim-face)))
         (label (lambda (title)
                  (buttonize (concat id " · " title (if state (format " (%s)" state) "")) open nil help)))
         (title (harness-ui-one-line (or (plist-get att :name) ""))))
    (concat head
            (funcall label (if room
                               (harness-compose--fit title (- room (harness-compose--pixels head)
                                                              (harness-compose--pixels remove))
                                                     label)
                             title))
            remove)))

(defun harness-compose-open-attachment (att)
  "Open attachment ATT: a video or a sound in the player, anything else in Emacs.
A task opens its session's chat, or shows its card on the task board
while it has no session (`harness-compose--open-task')."
  (let ((path (plist-get att :path)))
    (cond ((plist-get att :thread) (harness-compose-open-thread att))
          ((plist-get att :task) (harness-compose--open-task att))
          ((null path) (user-error "%s is no file to open" (or (plist-get att :name) "This attachment")))
          ((not (file-exists-p path)) (user-error "%s is gone" (abbreviate-file-name path)))
          ((and (string-match-p "\\`\\(?:video\\|audio\\)/" (or (plist-get att :mime) ""))
                (fboundp 'harness-ui-media-open))
           (harness-ui-media-open path))
          (t (find-file-other-window path)))))

(defun harness-compose--thumbnail-height ()
  "Return the height of thumbnails in pixels, or nil when none are shown."
  (and (display-images-p) (> harness-compose-thumbnail-lines 0)
       (round (* harness-compose-thumbnail-lines (frame-char-height)))))

(defun harness-compose--image (file height &optional width)
  "Return a string showing the image FILE, or nil.
It is at most HEIGHT pixels high and WIDTH wide, three times HEIGHT by
default, and drawn in `harness-ui-image-colors'."
  (when (and file (file-readable-p file) (ignore-errors (image-supported-file-p file)))
    (when-let* ((image (ignore-errors (apply #'create-image file nil nil :max-height height
                                             :max-width (or width (* 3 height))
                                             :ascent 'center
                                             (harness-ui-image-color-props)))))
      (propertize " " 'display image))))

(defun harness-compose--thumbnail (att &optional max-width)
  "Return a string showing a thumbnail of attachment ATT, or nil.
MAX-WIDTH, in pixels, narrows it further than its usual three times
its height.  A video's is made by the media module, in the background:
the box is redrawn once it is there."
  (when-let* ((height (harness-compose--thumbnail-height))
              (path (plist-get att :path)))
    (let ((mime (or (plist-get att :mime) ""))
          (width (min (* 3 height) (or max-width (* 3 height)))))
      (cond ((string-prefix-p "image/" mime) (harness-compose--image path height width))
            ((and (string-prefix-p "video/" mime) (fboundp 'harness-ui-media-video-thumbnail))
             (let ((buf (current-buffer)))
               (harness-compose--image
                (harness-ui-media-video-thumbnail
                 path (lambda () (when (buffer-live-p buf)
                                   (with-current-buffer buf (harness-compose-redraw)))))
                height width)))))))

(defconst harness-compose--spinner ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the spinner of a pending download.")

(defun harness-compose--insert-pending-chip (att &optional room)
  "Insert the chip of ATT, a download under way, and the overlay drawing it.
ROOM, in pixels, is how wide the chip may show, as for
`harness-compose--chip'; the overlay keeps it for the ticks."
  (let* ((id (plist-get att :id))
         (start (point))
         (stop (concat " " (propertize (buttonize "×" (lambda (_) (harness-compose-cancel-download id)) nil
                                                  "Stop this download")
                                       'face 'harness-dim-face)))
         (room (and room (- room (harness-compose--pixels stop)))))
    (insert (propertize " " 'harness-compose-pending id))
    (let ((ov (make-overlay start (point) nil t nil)))
      (overlay-put ov 'harness-compose-room room)
      (overlay-put ov 'display (harness-compose--progress-string att room))
      (overlay-put ov 'help-echo (concat "Downloading " (plist-get att :url)))
      (push (cons id ov) harness-compose--progress))
    (insert stop)))

(defconst harness-compose--widest-progress (concat " " (make-string 10 ?━) " 100% of 1023.9 MiB")
  "The progress of a download at its widest, which its chip keeps room for.")

(defun harness-compose--progress-string (att &optional room)
  "Return what the chip of ATT, a download under way, shows now.
ROOM, in pixels, is how wide it may show: the name is shortened to
leave room for the progress at its widest, so that it keeps its length
while the download goes on."
  (let* ((dl (plist-get att :download))
         (received (if dl (harness-http-download-received dl) 0))
         (total (and dl (harness-download-total dl)))
         (fraction (and total (> total 0) (min 1.0 (/ (float received) total))))
         (frame (aref harness-compose--spinner
                      (mod (truncate (* 8 (float-time))) (length harness-compose--spinner))))
         (head (concat (propertize frame 'face 'harness-dim-face) " "))
         (name (replace-regexp-in-string "[\n\r\t]" " " (or (plist-get att :name) "download"))))
    (concat
     head
     (if room
         (harness-compose--fit name (- room (harness-compose--pixels head)
                                       (harness-compose--pixels
                                        (propertize harness-compose--widest-progress 'face 'harness-dim-face)))
                               #'identity)
       name)
     " "
     (if fraction
         (let ((filled (round (* 10 fraction))))
           (concat (propertize (make-string filled ?━) 'face 'harness-compose-progress-face)
                   (propertize (make-string (- 10 filled) ?─) 'face 'harness-dim-face)
                   (propertize (format " %d%% of %s" (floor (* 100 fraction)) (harness-format-bytes total))
                               'face 'harness-dim-face)))
       (propertize (if (> received 0) (format "%s so far" (harness-format-bytes received)) "connecting…")
                   'face 'harness-dim-face)))))

(defun harness-compose--start-progress ()
  "Animate the chips of pending downloads until there are none."
  (when (and harness-compose--progress (not harness-compose--progress-timer))
    (let ((buf (current-buffer)) (timer nil))
      (setq timer (run-at-time 0.15 0.15
                               (lambda ()
                                 (if (not (buffer-live-p buf))
                                     (cancel-timer timer)
                                   (with-current-buffer buf (harness-compose--tick-progress timer)))))
            harness-compose--progress-timer timer))))

(defun harness-compose--tick-progress (timer)
  "Redraw the chips of pending downloads; stop TIMER once there are none."
  (let ((live nil))
    (dolist (p harness-compose--progress)
      (let ((att (harness-compose--pending (car p))))
        (when (and att (overlay-buffer (cdr p)))
          (setq live t)
          (overlay-put (cdr p) 'display
                       (harness-compose--progress-string att (overlay-get (cdr p) 'harness-compose-room))))))
    (unless live
      (cancel-timer timer)
      (when (eq timer harness-compose--progress-timer)
        (setq harness-compose--progress-timer nil)))))

(defun harness-compose-redraw ()
  "Redraw the box, through its host."
  (funcall harness-compose-redraw-function))

(defun harness-compose--file-attachment (path &optional mime)
  "Return the attachment of the file PATH, of the MIME type MIME."
  (let ((path (expand-file-name path)))
    (list :path path :size (or (harness-file-size path) 0)
          :mime (or mime (harness-compose--mime-of path))
          :name (file-name-nondirectory path))))

(defun harness-compose--attach (att &optional at-end)
  "Add the attachment ATT, unless its file or its task is attached already.
No redraw.  Its token goes into the box where point is, or with AT-END
at its end (`harness-compose--label'): an image's label, a file's or a
task's @ reference.  Return non-nil when it was added."
  (unless (harness-compose--attached-p att)
    (setq harness-compose-attachments
          (append harness-compose-attachments (list (harness-compose--label att at-end))))
    t))

(defun harness-compose--downloads-directory ()
  "Return the directory links dropped on a compose box download into."
  (harness-ensure-directory
   (expand-file-name "downloads/" (if (boundp 'harness-state-directory) harness-state-directory
                                    (locate-user-emacs-file "harness/")))))

(defun harness-compose--pending (id)
  "Return the pending download ID of this box, or nil."
  (cl-find-if (lambda (a) (and (plist-get a :pending) (equal (plist-get a :id) id)))
              harness-compose-attachments))

(defun harness-compose--clean-partials ()
  "Remove downloads left half-written by an Emacs that died mid-download.
A fresh one is never touched: only files older than a day go."
  (dolist (file (ignore-errors (directory-files (harness-compose--downloads-directory) t "\\`\\.partial-")))
    (let ((age (ignore-errors (float-time (file-attribute-modification-time (file-attributes file))))))
      (when (and age (< age (- (float-time) 86400)))
        (ignore-errors (delete-file file))))))

(defun harness-compose--settle-pending (id &optional att)
  "Put the attachment ATT where the pending download ID was, or drop it; redraw."
  (setq harness-compose-attachments
        (delq nil (mapcar (lambda (a) (if (and (plist-get a :pending) (equal (plist-get a :id) id)) att a))
                          harness-compose-attachments)))
  (harness-compose-redraw))

(defun harness-compose--drop-pending ()
  "Stop every download of this box and forget their chips, without a redraw."
  (let ((pending (cl-remove-if-not (lambda (a) (plist-get a :pending)) harness-compose-attachments)))
    (when pending
      (setq harness-compose-attachments
            (cl-remove-if (lambda (a) (plist-get a :pending)) harness-compose-attachments))
      (dolist (a pending) (harness-http-download-cancel (plist-get a :download))))))

(defun harness-compose-cancel-download (id)
  "Stop the download ID and remove its chip."
  (when-let* ((att (harness-compose--pending id)))
    (harness-compose--settle-pending id nil)
    (harness-http-download-cancel (plist-get att :download))
    (message "Stopped downloading %s" (plist-get att :name))))

(defun harness-compose-download (url &optional name)
  "Download URL in the background, then attach the file.
NAME is the name to give the file, else the server's or the link's.
Meanwhile the chip of the download shows its progress, and its ×
stops it; the message waits for it.  A link to a web page (HTML) is
not downloaded: it goes into the box as text.  A link that arrives
with junk around it (a NUL, a newline, a byte order mark, a zero width
space) is cleaned first; one that is no http, https or ftp link with a
host to fetch is refused, shown with %S so that what was wrong with it
shows."
  (interactive (list (read-string "Download and attach the link: ")))
  (let ((raw url))
    (when (and (stringp raw) (> (length raw) 0) (text-properties-at 0 raw))
      ;; A link off a selection carries `foreign-selection'; worth a line,
      ;; since it is what used to make curl read a whole address as a
      ;; fragment.
      (harness-log 'info "compose: link arrived with text properties %S" (text-properties-at 0 raw)))
    (setq url (harness-http-clean-url url))
    (unless (equal raw url)
      ;; The junk a drop hides: it is what makes curl disagree with what
      ;; the box shows.
      (harness-log 'info "compose: link arrived as %S, cleaned to %S" raw url)))
  (harness-log 'debug "compose: link to download: %S" url)
  (unless (and (string-match-p "\\`\\(?:https?\\|ftps?\\)://" url) (harness-http-link-p url))
    (user-error "That is not a link I can fetch: %S" url))
  (unless harness-http--curl-program
    (user-error "Downloading a link needs curl"))
  (harness-compose--clean-partials)
  (if (cl-find url harness-compose-attachments :key (lambda (a) (plist-get a :url)) :test #'equal)
      (message "%s is attached already" url)
    (let* ((id (harness-short-id))
           (buf (current-buffer))
           (att (list :pending t :id id :url url :page nil :download nil :named (and name t)
                      :name (harness-compose--clean-name (or name (harness-http-url-file-name url) "download")))))
      (setq harness-compose-attachments (append harness-compose-attachments (list att)))
      (plist-put att :download
                 (harness-http-download
                  url (expand-file-name (concat ".partial-" id) (harness-compose--downloads-directory))
                  :max-size harness-compose-download-max-size
                  :on-headers (lambda (dl) (harness-compose--download-headers buf id dl))
                  :callback (lambda (dl err) (harness-compose--download-done buf id dl err))))
      (harness-compose-redraw)
      (message "Downloading %s…" (plist-get att :name)))))

(defun harness-compose--download-headers (buf id dl)
  "Take what the server said of DL, the download ID of BUF.
A web page is not downloaded: the link goes into the box instead."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when-let* ((att (harness-compose--pending id)))
        (cond ((member (harness-download-mime dl) '("text/html" "application/xhtml+xml"))
               (plist-put att :page t)
               (harness-http-download-cancel dl))
              ((and (harness-download-name dl) (not (plist-get att :named)))
               (plist-put att :name (harness-compose--clean-name (harness-download-name dl)))))))))

(defun harness-compose--download-done (buf id dl err)
  "Settle DL, the download ID of BUF, which ended with the error ERR or nil."
  (let ((att (and (buffer-live-p buf) (with-current-buffer buf (harness-compose--pending id)))))
    (cond
     ((null att)
      (unless err (ignore-errors (delete-file (harness-download-file dl)))))
     ((plist-get att :page)
      (with-current-buffer buf
        (harness-compose--settle-pending id nil)
        (harness-compose--append-text (plist-get att :url))
        (message "%s is a web page: its address went into the message" (plist-get att :url))))
     (err
      (with-current-buffer buf
        (harness-compose--settle-pending id nil)
        (harness-log 'warn "compose: download failed for %S: %s" (plist-get att :url) err)
        (message "Could not download %s: %s" (plist-get att :url) err)))
     (t
      (with-current-buffer buf
        (let* ((file (harness-download-file dl))
               (mime (harness-compose--download-mime dl file (plist-get att :name)))
               (path (harness-compose--unique-file (harness-compose--downloads-directory)
                                                   (harness-compose--name-for-mime (plist-get att :name) mime))))
          (rename-file file path)
          ;; An image's token goes at the end of the box: point has
          ;; moved on since the link was dropped.
          (harness-compose--settle-pending
           id (harness-compose--label (list :path path :size (or (harness-file-size path) 0) :mime mime
                                            :name (file-name-nondirectory path) :url (plist-get att :url))
                                      t))
          (message "Attached %s (%s)" (file-name-nondirectory path)
                   (harness-format-bytes (harness-file-size path)))))))))

(defun harness-compose--append-text (text)
  "Add TEXT at the end of the box, after a space, leaving point where it is."
  (when (harness-compose-live-p)
    (save-excursion
      (goto-char harness-compose-end)
      (when (and (> (point) harness-compose-start) (not (memq (char-before) '(?\s ?\t ?\n))))
        (insert " "))
      (insert text))
    (harness-compose-update-placeholder)))

(defconst harness-compose--vague-mimes
  '("application/octet-stream" "binary/octet-stream" "application/binary" "application/unknown"
    "application/download" "application/force-download" "application/x-download")
  "Content types that say nothing of what a download is.")

(defun harness-compose--download-mime (dl file name)
  "Return the MIME type of FILE, downloaded by DL under the name NAME.
The server's, unless it says nothing; then the file's first bytes or
its name tell."
  (let ((mime (harness-download-mime dl)))
    (if (and mime (not (string-empty-p mime)) (not (member mime harness-compose--vague-mimes)))
        mime
      (or (harness-compose--sniff-mime file)
          (let ((guess (harness-media-ring-mime (or name ""))))
            (and (not (equal guess "application/octet-stream")) guess))
          "application/octet-stream"))))

(defun harness-compose--sniff-mime (file)
  "Return the MIME type the first bytes of FILE say, or nil."
  (let* ((head (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (ignore-errors (insert-file-contents-literally file nil 0 64))
                 (buffer-string)))
         (at (lambda (from tag) (and (>= (length head) (+ from (length tag)))
                                     (string= (substring head from (+ from (length tag))) tag)))))
    (cond ((funcall at 0 "\211PNG") "image/png")
          ((funcall at 0 "\377\330\377") "image/jpeg")
          ((funcall at 0 "GIF8") "image/gif")
          ((and (funcall at 0 "RIFF") (funcall at 8 "WEBP")) "image/webp")
          ((and (funcall at 0 "RIFF") (funcall at 8 "WAVE")) "audio/wav")
          ((or (funcall at 4 "ftypavif") (funcall at 4 "ftypavis")) "image/avif")
          ((funcall at 4 "ftypqt") "video/quicktime")
          ((funcall at 4 "ftyp") "video/mp4")
          ((funcall at 0 "\032\105\337\243") "video/webm")
          ((funcall at 0 "%PDF-") "application/pdf")
          ((funcall at 0 "OggS") "audio/ogg")
          ((funcall at 0 "ID3") "audio/mpeg")
          ((string-match-p "\\`\\(?:<\\?xml[^>]*>[ \t\r\n]*\\)?<svg" head) "image/svg+xml"))))

(defun harness-compose--clean-name (name)
  "Return NAME fit to name a file: no slashes or control characters, not hidden."
  (let* ((clean (replace-regexp-in-string "\\`[. ]+" ""
                                          (replace-regexp-in-string "[/\\\\[:cntrl:]]+" "_" (string-trim name))))
         (ext (file-name-extension clean t)))
    (when (> (length clean) 100)
      (setq clean (concat (substring (file-name-sans-extension clean) 0 (max 1 (- 100 (length ext)))) ext)))
    (if (string-empty-p clean) "download" clean)))

(defun harness-compose--name-for-mime (name mime)
  "Return NAME with an extension saying MIME, unless its own says so."
  (let ((ext (file-name-extension name)))
    (cond ((member mime harness-compose--vague-mimes) name)
          ((null ext) (concat name "." (harness-media-ring-extension mime)))
          ((equal (harness-media-ring-mime name) mime) name)
          ;; An extension saying something else (photo.php) gives way.
          ((mailcap-extension-to-mime (concat "." ext))
           (concat (file-name-sans-extension name) "." (harness-media-ring-extension mime)))
          (t (concat name "." (harness-media-ring-extension mime))))))

(defun harness-compose--unique-file (dir name)
  "Return a file named NAME in DIR that does not exist yet, numbered if need be."
  (let* ((ext (or (file-name-extension name t) ""))
         (base (file-name-sans-extension name))
         (path (expand-file-name name dir))
         (n 1))
    (while (file-exists-p path)
      (setq path (expand-file-name (format "%s-%d%s" base n ext) dir)
            n (1+ n)))
    path))

(defun harness-compose--attach-bytes (bytes mime name)
  "Save BYTES, of the MIME type MIME, among the downloads as NAME; attach them."
  (let ((path (harness-compose--unique-file (harness-compose--downloads-directory)
                                            (harness-compose--name-for-mime (harness-compose--clean-name name) mime)))
        (coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert (if (multibyte-string-p bytes) (encode-coding-string bytes 'utf-8 t) bytes)))
    (harness-compose-add-attachment path mime)))

;;;; Dropping

;; What is dropped on a buffer with a box goes to the box, whatever the
;; window it lands on: files attach, links download and attach (or go
;; in as text when they lead to a web page), data: links are decoded,
;; and text is typed into the box rather than into the read-only text
;; around it.  The handlers are buffer-local, so other buffers drop as
;; they always did.  On X a drop also says which types it offers: an
;; image dragged out of a browser offers the image's own address (the
;; link around it is what it drops), and an image with no link at all
;; is taken as its bytes.

(defconst harness-compose--drop-image-types
  '("image/png" "image/jpeg" "image/webp" "image/gif" "image/svg+xml" "image/avif" "image/bmp" "image/tiff")
  "Image types of an X drop taken as the image itself, best first.")

(defconst harness-compose--drop-text-types
  '(("UTF8_STRING" . harness-compose--drop-utf8)
    ("text/plain;charset=UTF-8" . harness-compose--drop-utf8)
    ("text/plain;charset=utf-8" . harness-compose--drop-utf8)
    ("text/unicode" . harness-compose--drop-utf16)
    ("text/plain" . harness-compose--drop-plain)
    ("COMPOUND_TEXT" . harness-compose--drop-ctext)
    ("STRING" . harness-compose--drop-latin-1)
    ("TEXT" . harness-compose--drop-plain)
    ("DndTypeText" . harness-compose--drop-plain))
  "Text types of an X drop, and the functions putting them in the box.")

(defun harness-compose--setup-drops ()
  "Send what is dropped on this buffer to the box (see the Dropping section)."
  (setq-local dnd-protocol-alist
              (append '(("^file:" . harness-compose-dnd-open)
                        ("^\\(?:https?\\|ftps?\\)://" . harness-compose-dnd-download)
                        ("^data:" . harness-compose-dnd-data)
                        ("^blob:" . harness-compose-dnd-blob))
                      (default-value 'dnd-protocol-alist)))
  (when (boundp 'x-dnd-types-alist)
    (setq-local x-dnd-types-alist
                (append (mapcar (lambda (type) (cons type #'harness-compose--drop-image))
                                harness-compose--drop-image-types)
                        harness-compose--drop-text-types
                        (default-value 'x-dnd-types-alist)))
    ;; Images come after links, which name the file, and before text.
    (setq-local x-dnd-known-types
                (let* ((known (default-value 'x-dnd-known-types))
                       (at (or (cl-position-if (lambda (type) (assoc type harness-compose--drop-text-types)) known)
                               (length known))))
                  (append (seq-take known at) harness-compose--drop-image-types (seq-drop known at))))
    (setq-local x-dnd-direct-save-function #'harness-compose--drop-direct-save)))

(defun harness-compose-dnd-download (url action)
  "Download what the link URL dropped on the window leads to, and attach it.
See `harness-compose-download'; a browser's drop of an image inside a
link gets the image (`harness-compose--dropped-media').  Return ACTION."
  (pcase-let ((`(,media . ,name) (harness-compose--dropped-media url)))
    (if (string-prefix-p "data:" media)
        (harness-compose--attach-data-url media)
      (harness-compose-download media name)))
  action)

(defun harness-compose-dnd-data (url action)
  "Attach the data that the data: URL dropped on the window holds; return ACTION."
  (harness-compose--attach-data-url url)
  action)

(defun harness-compose-dnd-blob (_url action)
  "Attach the image a drop of a blob: link offers as data; return ACTION.
The link itself only means something inside the browser."
  (unless (harness-compose--attach-drop-image)
    (message "%s" (substitute-command-keys
                   "A blob: link works only inside the browser: copy the image there, then \\[yank] it here")))
  action)

(defun harness-compose--media-name-p (name)
  "Non-nil when the file NAME names an image, a video or a sound."
  (and name (string-match-p "\\`\\(?:image\\|video\\|audio\\)/" (harness-media-ring-mime name))))

(defun harness-compose--dropped-media (url)
  "Return (ADDRESS . NAME): the media a drop of the link URL is about.
URL itself when it names a media file.  Else what the X drop says the
dragged image is: Firefox's file promise, or the only image of the
drop's HTML (a browser dragging an image inside a link drops the
link).  Else URL.  NAME is the file name the drop suggests, or nil."
  (or (and (harness-compose--media-name-p (harness-http-url-file-name url)) (list url))
      (let ((promise (harness-compose--drop-text "application/x-moz-file-promise-url")))
        (and promise (string-match-p "\\`\\(?:https?\\|ftps?\\|data\\):" promise)
             (cons promise (harness-compose--drop-text "application/x-moz-file-promise-dest-filename"))))
      (let ((src (harness-compose--single-image (harness-compose--drop-text "text/html") url)))
        (and src (list src)))
      (list url)))

(defun harness-compose--drop-types ()
  "Return the types the X drop being handled offers, as strings, or nil."
  (when (and (eq (window-system) 'x) (fboundp 'x-dnd-get-state-for-frame))
    (ignore-errors
      (let ((types (aref (x-dnd-get-state-for-frame (selected-frame)) 2)))
        (and (vectorp types)
             (mapcar (lambda (type) (if (symbolp type) (symbol-name type) type)) types))))))

(defun harness-compose--drop-data (type)
  "Return the data of TYPE that the X drop being handled offers, or nil."
  (when (member type (harness-compose--drop-types))
    (let ((data (ignore-errors (x-get-selection-internal 'XdndSelection (intern type)))))
      (and (stringp data) (> (length data) 0) data))))

(defun harness-compose--drop-text (type)
  "Return the text of TYPE that the X drop being handled offers, or nil."
  (when-let* ((text (harness-media-ring-selection-text (harness-compose--drop-data type))))
    (let ((text (string-trim (car (split-string text "\0")))))
      (and (not (string-empty-p text)) text))))

(defun harness-compose--html-unescape (string)
  "Decode the character references HTML attributes use in STRING."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "&\\(amp\\|lt\\|gt\\|quot\\|apos\\|#[0-9]+\\|#x[0-9a-fA-F]+\\);"
     (lambda (m)
       (let ((ref (substring m 1 -1)))
         (pcase ref
           ("amp" "&") ("lt" "<") ("gt" ">") ("quot" "\"") ("apos" "'")
           (_ (string (if (string-prefix-p "#x" ref) (string-to-number (substring ref 2) 16)
                        (string-to-number (substring ref 1))))))))
     string t t)))

(defun harness-compose--single-image (html base)
  "Return the address of the only image in HTML, against BASE, or nil."
  (when html
    (let ((case-fold-search t) (srcs nil) (start 0))
      (while (string-match "<img\\b[^>]*?[ \t\r\n]src[ \t\r\n]*=[ \t\r\n]*\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\|\\([^ \t\r\n>]+\\)\\)"
                           html start)
        (push (or (match-string 1 html) (match-string 2 html) (match-string 3 html)) srcs)
        (setq start (match-end 0)))
      (setq srcs (delete-dups srcs))
      (when (= 1 (length srcs))
        (let ((src (harness-compose--html-unescape (string-trim (car srcs)))))
          (cond ((string-match-p "\\`\\(?:https?\\|ftps?\\|data\\):" src) src)
                ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" src) nil)
                ((string-empty-p src) nil)
                (t (require 'url-expand)
                   (ignore-errors (url-expand-file-name src base)))))))))

(defun harness-compose--attach-data-url (url)
  "Attach the data that the data: link URL holds."
  (if (not (string-match "\\`data:\\([^,;]*\\)\\(?:;[^,;]*\\)*?\\(;base64\\)?," url))
      (message "Not a data: link")
    (let* ((mime (downcase (string-trim (match-string 1 url))))
           (base64 (match-beginning 2))
           (payload (harness-http-unhex-bytes (substring url (match-end 0))))
           (bytes (if base64
                      (ignore-errors (base64-decode-string (replace-regexp-in-string "[ \t\r\n]+" "" payload)))
                    payload)))
      (if (not bytes)
          (message "The data: link holds no valid data")
        (harness-compose--attach-bytes bytes (if (string-empty-p mime) "text/plain" mime) "dropped")))))

(defun harness-compose--attach-drop-image ()
  "Attach the image the X drop being handled offers as data; non-nil if it did."
  (when-let* ((type (cl-find-if (lambda (type) (member type (harness-compose--drop-types)))
                                harness-compose--drop-image-types))
              (data (harness-compose--drop-data type)))
    (harness-compose--attach-bytes data type "dropped")
    t))

(defun harness-compose--drop-image (window action data)
  "Attach the image DATA dropped on WINDOW, of the drop's type; return ACTION."
  (when (and (windowp window) (stringp data) (> (length data) 0))
    (with-current-buffer (window-buffer window)
      (harness-compose--attach-bytes data (or (ignore-errors (x-dnd-current-type window)) "image/png") "dropped")))
  action)

(defun harness-compose--drop-insert (window action text)
  "Put TEXT dropped on WINDOW in the box; return ACTION.
Where it was dropped when that is in the box, else at its end."
  (when (and (windowp window) (stringp text))
    (with-selected-window window
      (when (harness-compose-live-p)
        (unless (harness-compose-in-p) (goto-char harness-compose-end))
        (insert (string-replace "\r\n" "\n" text)))))
  action)

(defun harness-compose--drop-utf8 (window action data)
  "Put the UTF-8 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (decode-coding-string data 'utf-8)))

(defun harness-compose--drop-utf16 (window action data)
  "Put the UTF-16 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action
                                (decode-coding-string data (if (eq (byteorder) ?B) 'utf-16be 'utf-16le))))

(defun harness-compose--drop-ctext (window action data)
  "Put the compound text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (decode-coding-string data 'compound-text-with-extensions)))

(defun harness-compose--drop-latin-1 (window action data)
  "Put the Latin-1 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action
                                (if (multibyte-string-p data) data (decode-coding-string data 'latin-1))))

(defun harness-compose--drop-plain (window action data)
  "Put the text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (harness-media-ring-selection-text data)))

(defun harness-compose--drop-direct-save (need-name filename)
  "Save a file dropped by X direct save among the downloads, then attach it.
NEED-NAME non-nil asks where to save FILENAME; nil says it is saved
there, which is when it is attached."
  (if need-name
      (harness-compose--unique-file (harness-compose--downloads-directory) (harness-compose--clean-name filename))
    (harness-compose-add-attachment filename)))

;;;; The clipboard and the media ring

(defun harness-compose--attach-captures (atts &optional quiet)
  "Attach ATTS, captures or copied files, and redraw.
Return the paths of those that were not attached before.  QUIET keeps
the message to the caller."
  (let ((added (delq nil (mapcar (lambda (a) (and (harness-compose--attach a) (plist-get a :path))) atts))))
    (harness-compose-redraw)
    (unless quiet
      (message "Attached %s" (mapconcat (lambda (a) (plist-get a :name)) atts ", ")))
    added))

(defun harness-compose--yank-media-image (type data)
  "Attach the image DATA, of TYPE, that `yank-media' took off the clipboard."
  (harness-compose--attach-captures (list (harness-media-ring-save data (symbol-name type)))))

(defun harness-compose-attach-from-ring ()
  "Attach an earlier capture of the media ring, chosen by name."
  (interactive)
  (let ((entries (harness-media-ring-entries)))
    (unless entries
      (user-error "%s" (substitute-command-keys "The media ring is empty: copy an image, then \\[yank] it here")))
    (let* ((choices (mapcar (lambda (e) (cons (harness-media-ring-describe e) e)) entries))
           (table (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
                      (complete-with-action action choices string pred))))
           (choice (completing-read "Attach from the media ring: " table nil t)))
      (harness-compose--attach-captures (list (cdr (assoc choice choices)))))))

(defun harness-compose--underlying (command)
  "Return what runs for COMMAND in this buffer, but for the box's remapping."
  (or (command-remapping command) command))

(defun harness-compose--yank-text (command)
  "Run COMMAND, `yank' or `yank-pop', as it runs without the box's remapping.
A region in the box goes first in `delete-selection-mode', as a yank
of text replaces it."
  (let ((cmd (harness-compose--underlying command)))
    (when (eq command 'yank)
      (if (and (bound-and-true-p delete-selection-mode) (use-region-p)
               (harness-compose-in-p (region-beginning)) (harness-compose-in-p (region-end)))
          (delete-region (region-beginning) (region-end))
        (when (and (harness-compose-live-p) (not (harness-compose-in-p)))
          (goto-char harness-compose-end))))
    (setq this-command cmd)
    (call-interactively cmd)))

(defun harness-compose--clipboard-media ()
  "Return the attachments a yank should add from the clipboard, or nil.
The image on the clipboard, captured on the media ring, else the files
a file manager copied.  Those attached already do not count, so
yanking again yanks text."
  (when-let* ((targets (and harness-compose-yank-media (harness-compose-live-p)
                            (harness-media-ring-clipboard-targets))))
    (let ((image (harness-media-ring-capture-image targets)))
      (if image
          (unless (harness-compose--attached-p (plist-get image :path)) (list image))
        (mapcar #'harness-compose--file-attachment
                (cl-remove-if #'harness-compose--attached-p (harness-media-ring-clipboard-files targets)))))))

(defun harness-compose-yank (&optional arg)
  "Attach the image or the files on the clipboard, else yank text.
See `harness-compose-yank-media'.  The image goes on the media ring,
which \\[yank-pop] right after goes back through.  With ARG, yank as
`yank' does, whatever the clipboard holds."
  (interactive "*P")
  (let ((media (and (not arg) (harness-compose--clipboard-media))))
    (if (not media)
        (harness-compose--yank-text 'yank)
      (let ((added (harness-compose--attach-captures media))
            (head (car (harness-media-ring-entries))))
        (setq harness-compose--yanked
              (list :paths added
                    :index (if (and head (equal (plist-get head :path) (plist-get (car media) :path))) 0 -1))
              this-command 'harness-compose-yank)))))

(defun harness-compose-yank-pop (&optional n)
  "Swap the media just yanked for an earlier capture of the media ring.
Each press goes one further back (N further with a numeric prefix
argument), its thumbnail showing in the box.  Right after anything but
a yank of media, run `yank-pop' as it runs without the box."
  (interactive "p")
  (if (not (and (eq last-command 'harness-compose-yank) harness-compose--yanked))
      (harness-compose--yank-text 'yank-pop)
    (let ((entries (harness-media-ring-entries)))
      (unless entries (user-error "The media ring is empty"))
      (let* ((index (mod (+ (plist-get harness-compose--yanked :index) (or n 1)) (length entries)))
             (entry (nth index entries))
             (paths (plist-get harness-compose--yanked :paths))
             (gone (cl-remove-if-not (lambda (a) (member (plist-get a :path) paths)) harness-compose-attachments))
             ;; The capture takes the place of the first image yanked,
             ;; token and number; the others' tokens go.
             (label (cl-some (lambda (a) (plist-get a :label)) gone)))
        (setq harness-compose-attachments (cl-remove-if (lambda (a) (memq a gone)) harness-compose-attachments))
        (dolist (a gone)
          (when-let* ((token (and (not (and label (equal (plist-get a :label) label)))
                                  (harness-compose--att-token a))))
            (harness-compose--delete-tokens token)))
        (setq harness-compose--yanked (list :paths (harness-compose--attach-captures
                                                    (list (if label (append entry (list :label label)) entry))
                                                    t)
                                            :index index)
              this-command 'harness-compose-yank)
        ;; A capture attached already has a token of its own.
        (when (and label (not (harness-compose--labelled label)))
          (harness-compose--delete-tokens (harness-compose--image-token label))
          (harness-compose-redraw))
        (message "Media ring %d/%d: %s%s" (1+ index) (length entries) (plist-get entry :name)
                 (if (= 1 (length entries)) " (the only capture)" ""))))))

;;;; Completion

;;;; Completing as you type

;; Completion UIs that pop up as you type (corfu with `corfu-auto',
;; company) wait a moment after a key, then give up when the buffer
;; changed meanwhile.  Hosts change all the time -- a chat streams its
;; reply, a task board follows its tasks -- so the popup for an @file or
;; /skill token rarely showed.  Once the token stops changing, the box
;; asks them again, ignoring changes outside it.

(defvar corfu-auto)
(defvar corfu-auto-delay)
(defvar company-idle-delay)
(defvar company-candidates)
(declare-function corfu-auto--complete-deferred "corfu-auto")
(declare-function corfu--auto-complete-deferred "corfu")
(declare-function company-idle-begin "company")

(defun harness-compose--token ()
  "Return the @file or /skill token before point as (OFFSET . TEXT), or nil.
TEXT starts with the sigil.  OFFSET is point's distance from the start
of the box, which a host's redraws move."
  (when-let* ((bounds (or (harness-compose--capf-bounds ?@)
                          (let ((skill (harness-compose--capf-bounds ?/)))
                            (and skill (= (1- (car skill)) harness-compose-start) skill)))))
    (cons (- (point) harness-compose-start)
          (buffer-substring-no-properties (1- (car bounds)) (cdr bounds)))))

(defun harness-compose--corfu-delay ()
  "Seconds corfu waits before popping up in this buffer, or nil if it does not."
  (and (bound-and-true-p corfu-mode) (bound-and-true-p corfu-auto)
       (let ((delay (bound-and-true-p corfu-auto-delay))) (if (numberp delay) delay 0))))

(defun harness-compose--company-delay ()
  "Seconds company waits before popping up in this buffer, or nil if it does not."
  (and (bound-and-true-p company-mode) (boundp 'company-idle-delay)
       (let ((delay (if (functionp company-idle-delay) (funcall company-idle-delay) company-idle-delay)))
         (cond ((numberp delay) delay) (delay 0)))))

(defun harness-compose--popup ()
  "Ask the completion UIs that pop up by themselves to complete at point.
Only a UI that is not showing already is asked."
  (when (and (harness-compose--corfu-delay) (not completion-in-region-mode))
    (cond ((fboundp 'corfu-auto--complete-deferred) (corfu-auto--complete-deferred))
          ((fboundp 'corfu--auto-complete-deferred) (corfu--auto-complete-deferred))))
  (when (and (harness-compose--company-delay) (not (bound-and-true-p company-candidates))
             (fboundp 'company-idle-begin))
    ;; The tick and position it checks are the ones of now.
    (company-idle-begin (current-buffer) (selected-window) (buffer-chars-modified-tick) (point))))

(defun harness-compose--popup-later (&optional delay)
  "Ask the completion UIs for the token at point after DELAY seconds.
DELAY defaults to just after the UIs' own wait, so that they show the
popup themselves when nothing changed the buffer.  Nothing happens
without a token at point or a UI that pops up by itself."
  (when-let* ((wait (let ((delays (delq nil (list (harness-compose--corfu-delay)
                                                  (harness-compose--company-delay)))))
                      (and delays (apply #'max delays))))
              (token (and (harness-compose-live-p) (harness-compose--token))))
    (when harness-compose--popup-timer (cancel-timer harness-compose--popup-timer))
    (setq harness-compose--popup-timer
          (run-at-time (or delay (+ wait 0.05)) nil #'harness-compose--popup-if-unchanged
                       (current-buffer) token))))

(defun harness-compose--popup-if-unchanged (buffer token)
  "Ask the completion UIs to complete TOKEN, if it is still at point in BUFFER.
BUFFER must be the selected window's, with no input waiting."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-compose--popup-timer nil)
      (when (and (eq (window-buffer (selected-window)) buffer)
                 (not (input-pending-p))
                 (harness-compose-live-p)
                 (equal token (harness-compose--token)))
        (condition-case err
            (harness-compose--popup)
          (error (harness-log 'warn "compose: completion popup failed: %S" err)))))))

(defun harness-compose--after-command ()
  "Ask the completion UIs again once the token at point stops changing.
Runs from `post-command-hook'."
  (when harness-compose--popup-timer
    (cancel-timer harness-compose--popup-timer)
    (setq harness-compose--popup-timer nil))
  (condition-case err
      (let ((token (and (harness-compose-live-p) (harness-compose--token))))
        (when (and token (not (equal token harness-compose--last-token)))
          (harness-compose--popup-later))
        (setq harness-compose--last-token token))
    (error (harness-log 'warn "compose: following the token failed: %S" err))))

;; Boxes set up before a reload follow their tokens and fit their
;; attachments to their windows too, keep the tokens of their
;; attachments in step and their undo entries lined up, and those kept
;; at the bottom count their changes.  They quote with compose-quote too:
;; in the box, and finding the message at point as their host's function
;; did, under its old name.
(dolist (buf (buffer-list))
  (with-current-buffer buf
    (when (memq #'harness-compose-completion-at-point completion-at-point-functions)
      (add-hook 'post-command-hook #'harness-compose--after-command nil t)
      (add-hook 'post-command-hook #'harness-compose--keep-tokens nil t)
      (add-hook 'before-change-functions #'harness-compose--line-up-undo nil t)
      (add-hook 'pre-command-hook #'harness-compose--line-up-undo nil t)
      (add-hook 'window-size-change-functions #'harness-compose--on-resize nil t)
      (unless (eq compose-quote-area-function #'harness-compose--quote-area)
        (let ((function (and (local-variable-p 'harness-compose-quote-function)
                             (symbol-value 'harness-compose-quote-function))))
          (harness-compose--setup-quoting)
          (when (and function (not compose-quote-function))
            (setq-local compose-quote-function function)))))
    (when (memq #'harness-compose-pad-window pre-redisplay-functions)
      (add-hook 'before-change-functions #'harness-compose--before-change nil t)
      (add-hook 'after-change-functions #'harness-compose--after-change nil t))))

(add-to-list 'completion-category-defaults '(harness-compose-file (styles flex)))
(add-to-list 'completion-category-defaults '(harness-compose-skill (styles basic flex)))
(add-to-list 'completion-category-defaults '(harness-compose-task (styles basic substring)))

(harness-define-module 'ui-compose
  :doc "The compose box shared by chat buffers and the task board."
  :requires '(ui))

(provide 'harness-ui-compose)
;;; harness-ui-compose.el ends here
