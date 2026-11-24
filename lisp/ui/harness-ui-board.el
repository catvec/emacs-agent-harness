;;; harness-ui-board.el --- The freeform board: a rendered snapshot and its objects  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The board pages.  `harness-boards' lists the boards of the project,
;; and RET opens one: the rendered snapshot of the diagram at the top --
;; the SVG the engine's own renderer draws, from the same geometry the
;; Flutter client draws -- then the breadcrumb of the diagram walked
;; into, the last commit, and every object with its exact words, its
;; role and the links it carries.
;;
;; Nothing here is a second model of the board.  The page reads
;; `_harness/board/get', which answers the document a client draws from,
;; and shows it: a picture, and the text beside it.  A link an object
;; carries is opened by the house navigation (`harness-ui-linking'), so a
;; task, a message, a tool call or a review thread opens where it opens
;; everywhere else.  Opening the board in Flutter is a real
;; `_harness/board/focus' request; when no client is connected the page
;; says so rather than pretending one is.
;;
;; The pages talk ACP only, so they show the harness the UI is connected
;; to, on this machine or another, the same way.  They never block: a
;; request's answer redraws the page when it comes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-links)
(require 'harness-ui)
(require 'harness-ui-linking)

(defvar harness-ui-session-id)
(declare-function harness-ui-connected-p "harness-ui" ())
(declare-function harness-ui-call "harness-ui" (method params callback &optional on-error))
(declare-function harness-ui-display-view "harness-ui" (buffer &optional position frame))
(declare-function transient-append-suffix "transient" (prefix loc suffix &optional keep))

(defgroup harness-ui-board nil
  "The freeform board pages."
  :group 'harness-ui
  :prefix "harness-ui-board-")

(defcustom harness-ui-board-buffer-name "*harness boards*"
  "Name of the buffer that lists the boards."
  :type 'string :group 'harness-ui-board)

(defcustom harness-ui-board-page-name "*harness board: %s*"
  "Name of the buffer that shows one board; %s is its id."
  :type 'string :group 'harness-ui-board)

(defface harness-board-heading-face '((t :inherit bold :height 1.05))
  "Headings of the board pages."
  :group 'harness-ui-board)

(defface harness-board-label-face '((t :inherit shadow))
  "Labels and secondary words of the board pages."
  :group 'harness-ui-board)

(defface harness-board-name-face '((t :inherit bold))
  "The names of boards and of their objects."
  :group 'harness-ui-board)

(defconst harness-ui-board--label-column 12
  "Width of the label column of a row of a board page.")

(defconst harness-ui-board--kind-column 11
  "Width of the kind column of an object row.")

(defconst harness-ui-board--name-column 20
  "Width of the name column of an object row.")

;;;; Buffer state

(defvar-local harness-ui-board--boards nil
  "The boards `_harness/board/list' answered, or nil.")
(defvar-local harness-ui-board--document nil
  "The board `_harness/board/get' answered, or nil.")
(defvar-local harness-ui-board--id nil
  "The id of the board the page shows, or nil.")
(defvar-local harness-ui-board--diagram nil
  "The diagram the page shows, or nil for the board's first.")
(defvar-local harness-ui-board--project nil
  "The project the list is narrowed to, or nil.")
(defvar-local harness-ui-board--all nil
  "Non-nil when the list shows every project's boards.")
(defvar-local harness-ui-board--loaded nil
  "Non-nil once an answer came for the boards.")
(defvar-local harness-ui-board--error nil
  "What the last request failed with, or nil.")
(defvar-local harness-ui-board--pins nil
  "The pins `_harness/board/pins' answered: the revisions tasks delivered.")
(defvar-local harness-ui-board--pins-loaded nil
  "Non-nil once an answer came for the pins.")

;;;; The buffers

(defun harness-ui-board--list-buffer ()
  "Return the buffer that lists the boards, making it if needed."
  (get-buffer-create harness-ui-board-buffer-name))

(defun harness-ui-board--board-buffer (id)
  "Return the buffer that shows board ID, making it if needed."
  (get-buffer-create (format harness-ui-board-page-name id)))

;;;; Drawing helpers

(defun harness-ui-board--width ()
  "Return the width the page draws in.
It is the narrowest window of the selected frame that shows it, so the
page fits each of them; with none, the page's own width of a hundred
columns."
  (let ((windows (cl-remove-if-not
                  (lambda (window) (eq (window-buffer window) (current-buffer)))
                  (window-list (selected-frame) 'nomini))))
    (max 20 (if windows
                 (1- (apply #'min (mapcar #'window-width windows)))
               100))))

(defun harness-ui-board--cell (text width)
  "Return TEXT as a column exactly WIDTH wide, elided when it is longer."
  (let ((text (harness-truncate-end (or text "") (max 1 (1- width)))))
    (concat text (make-string (max 1 (- width (length text))) ?\s))))

(defun harness-ui-board--section (title width)
  "Insert TITLE as a section heading, ruled to WIDTH."
  (insert "\n " (propertize title 'face 'harness-board-heading-face)
          " " (propertize (make-string (max 2 (- width (length title) 3)) ?─)
                          'face 'harness-board-label-face)
          "\n"))

(defun harness-ui-board--row (label &rest parts)
  "Insert LABEL and PARTS as a row of the page."
  (insert " " (propertize label 'face 'harness-board-label-face)
          (make-string (max 1 (- harness-ui-board--label-column (length label))) ?\s))
  (dolist (part parts)
    (cond ((stringp part) (insert part))
          ((functionp part) (funcall part))))
  (insert "\n"))

(defun harness-ui-board--fit-lines (width)
  "Elide the end of every line of the page longer than WIDTH."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((start (point)) (end (line-end-position)))
        (when (> (string-width (buffer-substring-no-properties start end)) width)
          (let ((text (harness-truncate-end (buffer-substring start end) width)))
            (delete-region start end)
            (goto-char start)
            (insert text)
            (goto-char (line-end-position)))))
      (forward-line 1))))

(defun harness-ui-board--time (time)
  "Return TIME, a float, as a short relative word, or nil."
  (when (numberp time)
    (or (ignore-errors (harness-relative-time time)) (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time time)))))

(defun harness-ui-board--count (n singular &optional plural)
  "Return N with SINGULAR, or with PLURAL when N is not one."
  (format "%d %s" n (if (and (/= n 1) plural) plural singular)))


;;;; Reading

(defun harness-ui-board--note-error (buffer prefix err)
  "Show ERR, a failed request, in BUFFER and the echo area, as PREFIX says."
  (let ((message-text (harness-error-message err)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq harness-ui-board--error message-text)
        (if (derived-mode-p 'harness-ui-board-mode)
            (harness-ui-board--render)
          (harness-ui-boards--render))))
    (message "Harness: %s: %s" prefix message-text)))

(defun harness-ui-boards-refresh ()
  "Fetch the boards of the project, or of every project, and redraw."
  (interactive)
  (let ((buffer (harness-ui-board--list-buffer))
        (connected (harness-ui-connected-p)))
    (with-current-buffer buffer
      (setq harness-ui-board--error nil))
    (if (not connected)
        (progn
          (with-current-buffer buffer
            (setq harness-ui-board--error "no connection"
                  harness-ui-board--loaded t)
            (harness-ui-boards--render))
          (message "Harness: no connection"))
      (let ((project (with-current-buffer buffer harness-ui-board--project))
            (all (with-current-buffer buffer harness-ui-board--all)))
        (harness-ui-call
         "_harness/board/list"
         (and (or (and project (not all)) all)
              (list :opts (append (and project (not all) (list :project project))
                                  (and all (list :all t)))))
         (lambda (boards)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq harness-ui-board--boards (append boards nil)
                     harness-ui-board--loaded t
                     harness-ui-board--error nil)
               (harness-ui-boards--render))))
         (lambda (err)
           (harness-ui-board--note-error buffer "board list" err))))))
  nil)

(defun harness-ui-board-refresh ()
  "Read the board the page shows again, and redraw."
  (interactive)
  (let ((buffer (current-buffer)))
    (cond
     ((not (derived-mode-p 'harness-ui-board-mode))
      (call-interactively #'harness-ui-boards-refresh))
     ((not (harness-ui-connected-p))
      (setq harness-ui-board--error "no connection")
      (harness-ui-board--render)
      (message "Harness: no connection"))
     (t
      (setq harness-ui-board--error nil)
      (harness-ui-call
       "_harness/board/get"
       (append (list :id harness-ui-board--id)
               (and harness-ui-board--diagram
                    (list :opts (list :diagram harness-ui-board--diagram
                                      :image t))))
       (lambda (document)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-board--document document
                   harness-ui-board--error nil)
             (unless harness-ui-board--diagram
               (setq harness-ui-board--diagram
                     (or (plist-get (plist-get document :diagram) :id)
                         (plist-get (car (append (plist-get document :diagrams) nil))
                                    :id))))
             (harness-ui-board--render))))
       (lambda (err)
         (harness-ui-board--note-error buffer "board read" err)))
      ;; The pins come after the board the page draws: the drawing is what
      ;; the page is for, and the artifacts are a section of it.
      (harness-ui-board--read-pins buffer))))
  nil)

(defun harness-ui-board--read-pins (buffer)
  "Ask for the pins of the board BUFFER shows, and draw them when they come.
A harness without `board/pins' has none, and says nothing: the section is
left out rather than drawn empty."
  (with-current-buffer buffer
    (let ((id harness-ui-board--id))
      (if (not (stringp id))
          (setq harness-ui-board--pins nil
                harness-ui-board--pins-loaded t)
        ;; A harness older than the pins answers an error, which reads the
        ;; same as none: the page does not invent an artifact.
        (harness-ui-call
         "_harness/board/pins"
         (list :id id)
         (lambda (pins)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq harness-ui-board--pins (append pins nil)
                     harness-ui-board--pins-loaded t)
               (harness-ui-board--render))))
         (lambda (_err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq harness-ui-board--pins nil
                     harness-ui-board--pins-loaded t)
               (harness-ui-board--render)))))))))

(defun harness-ui-board--read (buffer id diagram)
  "Ask for board ID of DIAGRAM into BUFFER, drawing it when the answer comes."
  (with-current-buffer buffer
    (setq harness-ui-board--id id
          harness-ui-board--diagram (and diagram (not (string-empty-p diagram)) diagram)
          harness-ui-board--document nil
          harness-ui-board--pins nil
          harness-ui-board--pins-loaded nil
          harness-ui-board--error nil)
    (harness-ui-board--render))
  (with-current-buffer buffer
    (harness-ui-board-refresh)))


;;;; The list of boards

(defun harness-ui-boards--header ()
  "Return the header line of the list."
  (let ((boards harness-ui-board--boards))
    (list (propertize " Boards " 'face 'harness-board-heading-face)
          (cond ((and boards harness-ui-board--all) (format "%d · all projects" (length boards)))
                (boards (format "%d boards" (length boards)))
                (harness-ui-board--loaded (propertize "no board" 'face 'harness-dim-face))
                (t (propertize "…" 'face 'harness-dim-face)))
          (if harness-ui-board--error
              (concat (propertize (format "  %s" harness-ui-board--error) 'face 'harness-failure-face)
                      (harness-ui-retry-header #'harness-ui-boards-refresh "Load the boards again"))
            ""))))

(defun harness-ui-boards--render ()
  "Redraw the list of boards."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (width (harness-ui-board--width)))
    (erase-buffer)
    (setq header-line-format (harness-ui-boards--header))
    (insert "\n " (propertize "Boards" 'face 'harness-board-heading-face)
            "  " (propertize "project · theme · revision" 'face 'harness-board-label-face)
            "\n")
    (harness-ui-board--insert-boards width)
    (harness-ui-boards--insert-keys width)
    (harness-ui-board--fit-lines width)
    (goto-char (point-min))
    (forward-line (1- (max 1 line)))))

(defun harness-ui-board--insert-boards (width)
  "Insert the boards section, ruled to WIDTH."
  (harness-ui-board--section "Boards" width)
  (if (null harness-ui-board--boards)
      (insert " " (cond
                    (harness-ui-board--error
                     (harness-ui-failure-string
                      (propertize harness-ui-board--error 'face 'harness-failure-face)
                      #'harness-ui-boards-refresh "Load the boards again"))
                    (harness-ui-board--loaded
                     (propertize "no board" 'face 'harness-dim-face))
                    (t (propertize "…" 'face 'harness-dim-face)))
              "\n")
    (dolist (board (append harness-ui-board--boards nil))
      (harness-ui-board--insert-board board width))))

(defun harness-ui-board--insert-board (board width)
  "Insert one BOARD row of the list, its name, figures and project, in WIDTH."
  (let ((start (point))
        (id (or (plist-get board :id) ""))
        (name (or (plist-get board :name) (plist-get board :id) "board"))
        (markers (or (plist-get board :markers) 0))
        (objects (or (plist-get board :objects) 0)))
    (insert " ")
    (insert (harness-ui-board--cell
             (propertize name 'face 'harness-board-name-face)
             harness-ui-board--name-column))
    (insert (harness-ui-board--cell
             (propertize (format "rev %s" (or (plist-get board :revision) 0))
                         'face 'harness-board-label-face)
             10))
    (insert (harness-truncate-end
             (format "%s · %s · %s · %s"
                     (or (plist-get board :theme) "theme")
                     (harness-ui-board--count objects "object" "objects")
                     (if (zerop markers)
                         (propertize "no task marker" 'face 'harness-dim-face)
                       (harness-ui-board--count markers "task marker" "task markers"))
                     (if-let* ((updated (harness-ui-board--time (plist-get board :updated))))
                         updated ""))
             (max 8 (- width 1 harness-ui-board--name-column 10))))
    (insert "\n")
    (when-let* ((project (plist-get board :project)))
      (insert " " (propertize project 'face 'harness-board-label-face) "\n"))
    (insert " ")
    (harness-ui-button "[Open]" (lambda () (harness-ui-board-open id))
                       :help "open the board at point (RET)")
    (insert " ")
    (harness-ui-button "[Flutter]" (lambda () (harness-ui-board-focus nil id))
                       :help "the board at point in the Flutter client (f)")
    (insert "\n")
    (put-text-property start (point) 'harness-ui-board-id id)))

(defun harness-ui-boards--insert-keys (width)
  "Insert the keys section of the board list, ruled to WIDTH."
  (harness-ui-board--section "Keys" width)
  (insert " ")
  (harness-ui-button "[Refresh]" #'harness-ui-boards-refresh
                     :help "board list refresh (g)")
  (insert "  ")
  (harness-ui-button "[Every project]" #'harness-ui-boards-toggle-all
                     :help "boards of every project (a)")
  (insert "\n"))

(defun harness-ui-boards-toggle-all ()
  "Show every project's boards, or only the page's project."
  (interactive)
  (let ((buffer (harness-ui-board--list-buffer)))
    (with-current-buffer buffer
      (setq harness-ui-board--all (not harness-ui-board--all)
            harness-ui-board--loaded nil
            harness-ui-board--boards nil))
    (harness-ui-boards-refresh))
  nil)

(defun harness-ui-board--board-at-point ()
  "Return the id of the board whose row point is on, or nil."
  (get-text-property (point) 'harness-ui-board-id))


;;;; One board

(defun harness-ui-board--document-objects ()
  "Return the objects of the page's document, in layer order."
  (append (plist-get harness-ui-board--document :objects) nil))

(defun harness-ui-board--object (id)
  "Return the object of the page's document named ID, or nil."
  (when (and id harness-ui-board--document)
    (cl-find id (harness-ui-board--document-objects)
             :key (lambda (object) (plist-get object :id)) :test #'equal)))

(defun harness-ui-board--diagram ()
  "Return the diagram the page shows, as the document reads it.
It is the document's own `:diagram' when the read answered for the
diagram the page is on, and else the one `harness-ui-board--diagram'
names among the document's diagrams."  (or (plist-get harness-ui-board--document :diagram)
      (and harness-ui-board--diagram
           (cl-find harness-ui-board--diagram (harness-ui-board--diagrams)
                    :key (lambda (d) (plist-get d :id)) :test #'equal))))

(defun harness-ui-board--diagrams ()
  "Return every diagram of the page's document."
  (append (plist-get harness-ui-board--document :diagrams) nil))

(defun harness-ui-board--line-of (id)
  "Return the diagram ID and its parents, root first."
  (let ((line nil) (here id) (seen nil))
    (while (and here (not (member here seen)))
      (push here seen)
      (let ((diagram (cl-find here (harness-ui-board--diagrams)
                              :key (lambda (d) (plist-get d :id)) :test #'equal)))
        (unless diagram (setq here nil))
        (when diagram
          (push diagram line)
          (setq here (plist-get diagram :parent)))))
    line))

(defun harness-ui-board--header ()
  "Return the header line of the board page."
  (let ((document harness-ui-board--document))
    (list (propertize " Board " 'face 'harness-board-heading-face)
          (or (plist-get document :name) harness-ui-board--id "board")
          (format "  rev %s" (or (plist-get document :revision) 0))
          (format "  %s" (harness-ui-board--count (length (harness-ui-board--document-objects))
                                                  "object" "objects"))
          (if harness-ui-board--error
              (concat (propertize (format "  %s" harness-ui-board--error) 'face 'harness-failure-face)
                      (harness-ui-retry-header #'harness-ui-board-refresh "Load the board again"))
            ""))))

(defun harness-ui-board--render ()
  "Redraw the board page."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (width (harness-ui-board--width))
        (document harness-ui-board--document))
    (erase-buffer)
    (setq header-line-format (harness-ui-board--header))
    (insert "\n " (propertize (or (plist-get document :name) harness-ui-board--id "Board")
                               'face 'harness-board-heading-face)
            "  " (propertize (format "%s · %s · rev %s"
                                     (or (plist-get document :id) harness-ui-board--id)
                                     (or (plist-get document :theme) "theme")
                                     (or (plist-get document :revision) 0))
                             'face 'harness-board-label-face)
            "\n")
    (cond
     ((null document)
      (insert " " (if harness-ui-board--error
                      (harness-ui-failure-string
                       (propertize harness-ui-board--error 'face 'harness-failure-face)
                       #'harness-ui-board-refresh "Load the board again")
                    (propertize "…" 'face 'harness-dim-face))
              "\n"))
     (t
      (harness-ui-board--insert-snapshot width)
      (harness-ui-board--insert-diagram width)
      (harness-ui-board--insert-pins width)
      (harness-ui-board--insert-commit width)
      (harness-ui-board--insert-objects width)
      (harness-ui-board--insert-relationships width)
      (harness-ui-board--insert-keys width)))
    (harness-ui-board--fit-lines width)
    (goto-char (point-min))
    (forward-line (1- (max 1 line)))))

(defun harness-ui-board--insert-snapshot (width)
  "Insert the rendered snapshot of the diagram, ruled to WIDTH."
  (harness-ui-board--section "Snapshot" width)
  (let ((image (plist-get harness-ui-board--document :image)))
    (insert " ")
    (cond
     ((and (stringp image) (not (string-empty-p image)))
      (insert (harness-ui-board--picture image)))
     ((stringp image) (insert (propertize "no snapshot · no SVG display"
                                          'face 'harness-dim-face)))
     (t (insert (propertize "no snapshot" 'face 'harness-dim-face))))
    (insert "\n"))
  (insert " " (propertize (format "%s · %s"
                                  (harness-ui-board--count
                                   (length (harness-ui-board--document-objects))
                                   "object" "objects")
                                  (harness-ui-board--count
                                   (length (append (plist-get harness-ui-board--document :relationships) nil))
                                   "connection" "connections"))
                          'face 'harness-board-label-face)
          "\n"))

(defun harness-ui-board--insert-pins (width)
  "Insert the pinned revisions a task delivered, ruled to WIDTH.
A pin is the artifact: it stays as it was handed in while the board goes
on, so each row says the revision and what it holds, and opens the pin
rather than the board as it is now."
  (harness-ui-board--section "Pinned" width)
  (if (null harness-ui-board--pins)
      (insert " " (propertize (if harness-ui-board--pins-loaded
                                  "no pinned revision"
                                "…")
                              'face 'harness-dim-face)
              "\n")
    (dolist (pin harness-ui-board--pins)
      (insert " "
              (harness-ui-board--cell
               (propertize (or (plist-get pin :title) (plist-get pin :id) "pin")
                           'face 'harness-board-name-face)
               harness-ui-board--name-column)
              (propertize (format "rev %s" (or (plist-get pin :revision) 0))
                          'face 'harness-board-label-face)
              " · "
              (propertize (format "%s · %s"
                                  (or (plist-get pin :diagram) "diagram")
                                  (harness-ui-board--count
                                   (or (plist-get pin :objects) 0) "object" "objects"))
                          'face 'harness-board-label-face)
              (if-let* ((task (plist-get pin :task)))
                  (format " · %s" (harness-links-markdown
                                   task (harness-links-task-url task)))
                "")
              "\n")
      (insert " ")
      (harness-ui-button "[Open]" (lambda () (harness-ui-board-open-pin pin))
                         :help "the pinned revision, as it was delivered")
      (insert " ")
      (harness-ui-button "[Current board]" (lambda () (harness-ui-board-open
                                                      (plist-get pin :board)
                                                      (plist-get pin :diagram)))
                         :help "the board as it is now, not the artifact")
      (insert "\n"))))

(defun harness-ui-board-open-pin (pin)
  "Show the pinned revision PIN as a page of its own."
  (interactive)
  (let ((buffer (get-buffer-create (format "*Harness Board · %s*"
                                           (or (plist-get pin :title) (plist-get pin :id) "pin")))))
    (with-current-buffer buffer
      (harness-ui-board-mode)
      (setq harness-ui-board--id (plist-get pin :board)
            harness-ui-board--diagram (plist-get pin :diagram))
      (harness-ui-board--read-pin buffer pin))
    (switch-to-buffer buffer)))

(defun harness-ui-board--read-pin (buffer pin)
  "Ask for the document PIN kept, into BUFFER, drawing it when it comes."
  (with-current-buffer buffer
    (setq harness-ui-board--error nil)
    (harness-ui-call
     "_harness/board/pins"
     (list :id (plist-get pin :board) :opts (list :pin (plist-get pin :id)))
     (lambda (answer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-board--document
                 (plist-put (copy-sequence (plist-get answer :document))
                            :image (plist-get answer :image))
                 harness-ui-board--error nil)
           (harness-ui-board--render))))
     (lambda (err)
       (harness-ui-board--note-error buffer "pinned revision" err)))))

(defun harness-ui-board--picture (svg)
  "Return SVG drawn as an image, or the words that say it cannot be here."
  (if (not (and (display-images-p) (image-type-available-p 'svg)))
      (propertize "no snapshot · no SVG display" 'face 'harness-dim-face)
    (let ((image (ignore-errors
                   (create-image svg 'svg t
                                 :max-width (max 120 (min 900 (* 3 (harness-ui-board--width))))
                                 :max-height 520
                                 :ascent 'center))))
      (if (null image)
          (propertize "no snapshot · no SVG display" 'face 'harness-dim-face)
        (concat (propertize " " 'display image)
                )))))

(defun harness-ui-board--insert-diagram (width)
  "Insert the diagram, its parents and its selection, ruled to WIDTH."
  (harness-ui-board--section "Diagram" width)
  (let* ((diagram (harness-ui-board--diagram))
         (id (plist-get diagram :id))
         (line (harness-ui-board--line-of id))
         (selection (append (plist-get diagram :selection) nil)))
    (insert " ")
    (dolist (entry line)
      (when (not (eq entry (car line)))
        (insert (propertize " › " 'face 'harness-board-label-face)))
      (insert (propertize (or (plist-get entry :name) (plist-get entry :id) "diagram")
                          'face (if (equal (plist-get entry :id) id)
                                    'harness-board-name-face
                                  'harness-board-label-face))))
    (insert "\n")
    (harness-ui-board--row "Selection"
                           (if selection
                               (string-join selection ", ")
                             (propertize "no selection" 'face 'harness-dim-face)))
    (harness-ui-board--row "Diagrams"
                           (format "%d" (length (harness-ui-board--diagrams))))
    (harness-ui-board--row "Viewport"
                           (let ((viewport (plist-get diagram :viewport)))
                             (format "%s, %s · %sx"
                                     (or (plist-get viewport :x) 0)
                                     (or (plist-get viewport :y) 0)
                                     (or (plist-get viewport :zoom) 1))))))

(defun harness-ui-board--insert-commit (width)
  "Insert what the newest commit did, ruled to WIDTH."
  (harness-ui-board--section "Last commit" width)
  (let ((last (plist-get harness-ui-board--document :last)))
    (if (null last)
        (insert " " (propertize "no commit" 'face 'harness-dim-face) "\n")
      (harness-ui-board--row "Revision" (format "%s" (or (plist-get last :revision) 0)))
      (harness-ui-board--row "Patch" (or (plist-get last :patch) "-"))
      (harness-ui-board--row "Created"
                             (harness-ui-board--count (length (append (plist-get last :created) nil))
                                                      "object" "objects"))
      (harness-ui-board--row "Changed"
                             (harness-ui-board--count (length (append (plist-get last :changed) nil))
                                                      "object" "objects"))
      (when-let* ((time (harness-ui-board--time (plist-get last :time))))
        (harness-ui-board--row "Time" time)))))


(defun harness-ui-board--insert-objects (width)
  "Insert every object of the diagram, ruled to WIDTH."
  (harness-ui-board--section "Objects" width)
  (let ((objects (harness-ui-board--document-objects)))
    (if (null objects)
        (insert " " (propertize "no object" 'face 'harness-dim-face) "\n")
      (dolist (object objects)
        (harness-ui-board--insert-object object width)))))

(defun harness-ui-board--object-role (object)
  "Return OBJECT's role as a word, or nil."
  (let ((role (plist-get object :role)))
    (and role (format "%s" role))))

(defun harness-ui-board--object-text (object width)
  "Return what OBJECT says, on one line, fitted to WIDTH."
  (let ((text (or (plist-get object :text) "")))
    (harness-truncate-end (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim text))
                          (max 8 width))))

(defun harness-ui-board--insert-object (object width)
  "Insert one OBJECT of the page, its words, role and links, in WIDTH."
  (let ((start (point))
        (id (or (plist-get object :id) ""))
        (name (or (plist-get object :name) (plist-get object :id) "object"))
        (kind (format "%s" (or (plist-get object :kind) "object")))
        (role (harness-ui-board--object-role object))
        (task (plist-get object :source-status))
        (resources (append (plist-get object :resources) nil)))
    (insert " ")
    (insert (harness-ui-board--cell (propertize kind 'face 'harness-board-label-face)
                                    harness-ui-board--kind-column))
    (insert (harness-ui-board--cell (propertize name 'face 'harness-board-name-face)
                                    harness-ui-board--name-column))
    (insert (harness-ui-board--object-text
             object (max 10 (- width 1 harness-ui-board--kind-column
                               harness-ui-board--name-column 24))))
    (insert " " (propertize (format "%s" (or role "-")) 'face 'harness-board-label-face))
    (when (plist-get object :locked)
      (insert " " (propertize "locked" 'face 'harness-board-label-face)))
    (when (plist-get object :mirrored)
      (insert " " (propertize "mirrored" 'face 'harness-board-label-face)))
    (insert "\n")
    (when resources
      (insert "   " (propertize "links" 'face 'harness-board-label-face) "\n")
      (dolist (resource resources)
        (let* ((kind (or (plist-get resource :kind) "link"))
               (ref (or (plist-get resource :ref) ""))
               (state (or (plist-get resource :state) "?"))
               (note (plist-get resource :note))
               (room (max 8 (- width 8 (length (format "%s %s" kind ref))))))
          (insert "     "
                  (propertize (format "%s %s" kind ref) 'face 'harness-board-name-face)
                  " · "
                  (propertize state
                              'face (if (equal state "resolved")
                                        'harness-success-face
                                      'harness-board-label-face))
                  (if note (format " · %s" (harness-truncate-end note room)) "")
                  "\n"))))
    (when task
      (insert "   " (propertize "task" 'face 'harness-board-label-face) " "
              (propertize (or (plist-get task :label) (format "%s" (plist-get task :status)))
                          'face (if (equal (plist-get task :status) "resolved")
                                    'harness-success-face
                                  'harness-caution-face))
              "\n"))
    (insert " ")
    (harness-ui-button "[Links]" (lambda () (harness-ui-board-links object))
                       :help "links of the object at point (RET)")
    (insert " ")
    (harness-ui-button "[Diagram]" (lambda () (harness-ui-board-open
                                               harness-ui-board--id
                                               (or (plist-get object :diagram)
                                                   harness-ui-board--diagram)
                                               id))
                       :help "the diagram at point (d)")
    (insert " ")
    (harness-ui-button "[Flutter]" (lambda () (harness-ui-board-focus object))
                       :help "the object at point in the Flutter client (f)")
    (insert "\n")
    (put-text-property start (point) 'harness-ui-board-object id)))

(defun harness-ui-board--insert-relationships (width)
  "Insert the connections of the diagram, ruled to WIDTH."
  (harness-ui-board--section "Connections" width)
  (let ((relationships (append (plist-get harness-ui-board--document :relationships) nil)))
    (if (null relationships)
        (insert " " (propertize "no connection" 'face 'harness-dim-face) "\n")
      (dolist (relationship relationships)
        (insert " "
                (harness-ui-board--cell
                 (propertize (format "%s" (or (plist-get relationship :kind) "connection"))
                             'face 'harness-board-label-face)
                 harness-ui-board--kind-column)
                (propertize (format "%s.%s → %s.%s"
                                    (or (plist-get (plist-get relationship :from) :object) "?")
                                    (or (plist-get (plist-get relationship :from) :anchor) "center")
                                    (or (plist-get (plist-get relationship :to) :object) "?")
                                    (or (plist-get (plist-get relationship :to) :anchor) "center"))
                            'face 'harness-board-name-face)
                (if-let* ((label (plist-get relationship :label)))
                    (format " · %s" (harness-truncate-end label (max 8 (- width 40))))
                  "")
                " " (propertize (format "%s" (or (plist-get relationship :role) "-"))
                                'face 'harness-board-label-face)
                "\n")))))

(defun harness-ui-board--insert-keys (width)
  "Insert the keys of the page, ruled to WIDTH."
  (harness-ui-board--section "Keys" width)
  (insert " ")
  (harness-ui-button "[Refresh]" #'harness-ui-board-refresh
                     :help "board refresh (g)")
  (insert "  ")
  (harness-ui-button "[Snapshot]" #'harness-ui-board-snapshot
                     :help "the snapshot of the diagram at point (s)")
  (insert "  ")
  (harness-ui-button "[Flutter]" (lambda () (harness-ui-board-focus
                                             (harness-ui-board--object-at-point)))
                     :help "the object at point in the Flutter client (f)")
  (insert "  ")
  (harness-ui-button "[Board list]" #'harness-boards
                     :help "board list (l)")
  (insert "\n"))

(defun harness-ui-board--object-at-point ()
  "Return the object whose row point is on, or nil."
  (when-let* ((id (get-text-property (point) 'harness-ui-board-object)))
    (harness-ui-board--object id)))


;;;; The commands

;;;###autoload
(defun harness-boards ()
  "Show the boards the harness keeps, and open one."
  (interactive)
  (let ((buffer (harness-ui-board--list-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-boards-mode)
        (harness-ui-boards-mode))
      (when (null harness-ui-board--project)
        (setq harness-ui-board--project (harness-ui-board--project)))
      (harness-ui-boards--render))
    (harness-ui-display-view buffer)
    (harness-ui-boards-refresh)
    buffer))

(defun harness-ui-board--project ()
  "Return the project the board list is about, or nil."
  (let ((cwd (ignore-errors (harness-ui-board--cwd))))
    (and (stringp cwd) (not (string-empty-p cwd)) cwd)))

(defun harness-ui-board--cwd ()
  "Return the directory the UI is about: the session's, else this Emacs's."
  (or (and (boundp 'harness-ui-session-id) harness-ui-session-id
           (let ((session (ignore-errors (harness-ui-session harness-ui-session-id))))
             (plist-get session :cwd)))
      (and (fboundp 'project-current)
           (when-let* ((project (ignore-errors (project-current))))
             (ignore-errors (project-root project))))
      (and (bound-and-true-p default-directory)
           (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-ui-board-open (id &optional diagram object)
  "Open board ID, at DIAGRAM and OBJECT when they are named."
  (interactive (list (harness-ui-board--board-at-point)))
  (let ((id (or id (harness-ui-board--board-at-point))))
    (if (null id)
        (message "Harness: no board at point")
      (let ((buffer (harness-ui-board--board-buffer id)))
        (with-current-buffer buffer
          (unless (derived-mode-p 'harness-ui-board-mode)
            (harness-ui-board-mode)))
        (harness-ui-board--read buffer id diagram)
        (harness-ui-display-view buffer)
        (when (and object (stringp object) (not (string-empty-p object)))
          (with-current-buffer buffer
            (harness-ui-board--reveal object)))
        buffer))))

(defun harness-ui-board--reveal (object)
  "Put point on OBJECT's row of the page, when it has one."
  (save-excursion
    (goto-char (point-min))
    (when (text-property-search-forward 'harness-ui-board-object object
                                        (lambda (value wanted) (equal value wanted)))
      (beginning-of-line))))

(defun harness-ui-board-snapshot ()
  "Show the rendered snapshot of the diagram in a viewer of its own."
  (interactive)
  (let ((image (plist-get harness-ui-board--document :image)))
    (cond
     ((not (and (stringp image) (not (string-empty-p image))))
      (message "Harness: no snapshot"))
     (t (let ((file (make-temp-file "harness-board-" nil ".svg"
                                    (encode-coding-string image 'utf-8))))
          (if (fboundp 'harness-ui-image-open)
              (harness-ui-image-open file)
            (find-file-other-window file))))))
  nil)

(defun harness-ui-board--resource-kind (resource)
  "Return RESOURCE's kind as the word the page draws it as."
  (let ((kind (plist-get resource :kind)))
    (if (or (null kind) (stringp kind)) kind (format "%s" kind))))

(defun harness-ui-board--resource-line (resource)
  "Return RESOURCE as the one line the page offers it as."
  (format "%s %s · %s"
          (or (harness-ui-board--resource-kind resource) "link")
          (or (plist-get resource :ref) "")
          (or (plist-get resource :state) "?")))

(defun harness-ui-board-links (object &optional board)
  "Offer what OBJECT, or BOARD, is linked to: the precise targets it names."
  (interactive (list (harness-ui-board--object-at-point)))
  (let ((resources (append (and object (plist-get object :resources)) nil))
        (title (if object
                   (or (plist-get object :name) (plist-get object :id))
                 (or board harness-ui-board--id "board"))))
    (if (null resources)
        (message "Harness: no link at point")
      (let* ((lines (mapcar #'harness-ui-board--resource-line resources))
             (choice (completing-read (format "Link · %s: " title) lines nil t))
             (index (cl-position choice lines :test #'equal)))
        (when index
          (harness-ui-board--follow (nth index resources))))))
  nil)

(defun harness-ui-board--follow (resource)
  "Open RESOURCE, the precise thing it names, or say why it cannot be."
  (let ((target (plist-get resource :target))
        (state (or (plist-get resource :state) "missing")))
    (cond
     ((and (stringp target) (string-match-p "\\`https?://" target))
      (browse-url target))
     ((and (stringp target) (harness-links-p target)
           (not (equal (plist-get (harness-links-parse target) :kind) 'board)))
      (harness-ui-linking-follow target))
     ((and (stringp target) (harness-links-p target))
      (let ((link (harness-links-parse target)))
        (harness-ui-board-open (plist-get link :board)
                               (plist-get link :board-diagram)
                               (plist-get link :board-object))))
     (t (message "Harness: %s · %s" (or (plist-get resource :label) "link") state))))
  nil)

(defun harness-ui-board-focus (&optional object board)
  "Ask a connected Flutter client to show OBJECT, or BOARD, and say if none is."
  (interactive (list (harness-ui-board--object-at-point)))
  (let* ((board (or board harness-ui-board--id))
         (diagram (or (and object (plist-get object :diagram)) harness-ui-board--diagram))
         (id (and object (plist-get object :id))))
    (cond
     ((null board) (message "Harness: no board at point"))
     ((not (harness-ui-connected-p)) (message "Harness: no connection"))
     (t
      (harness-ui-call
       "_harness/board/focus"
       (append (list :id board)
               (and (or diagram id)
                    (list :opts (append (and diagram (list :diagram diagram))
                                        (and id (list :object id))))))
       (lambda (place)
         (message "Harness: focus: %s"
                  (if (plist-get place :client)
                      (or (plist-get place :object) (plist-get place :diagram) board)
                    "no client connected")))
       (lambda (err)
         (message "Harness: focus failure: %s" (harness-error-message err)))))))
  nil)


;;;; The pages' modes and keys

(defvar harness-ui-boards-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-boards-refresh)
    (define-key map (kbd "a") #'harness-ui-boards-toggle-all)
    (define-key map (kbd "RET") #'harness-ui-board-open)
    (define-key map (kbd "l") #'harness-ui-board-open)
    (define-key map (kbd "f") #'harness-ui-board-focus)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keys of the board list: each key has a button on the page.")

(define-derived-mode harness-ui-boards-mode special-mode "Boards"
  "Major mode of the list of boards."
  (setq-local revert-buffer-function (lambda (&rest _) (harness-ui-boards-refresh)))
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(put 'harness-ui-boards-mode 'harness-menu-group
     '("Boards"
       ["Board list"
        (". g" "Board list refresh" harness-ui-boards-refresh)
        (". a" "Boards of every project" harness-ui-boards-toggle-all)
        (". RET" "Board at point" harness-ui-board-open)
        (". f" "Board at point in the Flutter client" harness-ui-board-focus)]))

(defvar harness-ui-board-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-board-refresh)
    (define-key map (kbd "RET") #'harness-ui-board-links)
    (define-key map (kbd "d") #'harness-ui-board-open)
    (define-key map (kbd "f") #'harness-ui-board-focus)
    (define-key map (kbd "s") #'harness-ui-board-snapshot)
    (define-key map (kbd "l") #'harness-boards)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keys of a board page: each key has a button on the page.")

(define-derived-mode harness-ui-board-mode special-mode "Board"
  "Major mode of a board page."
  (setq-local revert-buffer-function (lambda (&rest _) (harness-ui-board-refresh)))
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(put 'harness-ui-board-mode 'harness-menu-group
     '("Board"
       ["Page"
        (". g" "Board refresh" harness-ui-board-refresh)
        (". s" "Snapshot of the diagram" harness-ui-board-snapshot)
        (". l" "Board list" harness-boards)]
       ["At point"
        (". RET" "Links of the object at point" harness-ui-board-links)
        (". d" "Diagram of the object at point" harness-ui-board-open)
        (". f" "Object at point in the Flutter client" harness-ui-board-focus)]))

;;;; Module

(defun harness-ui-board--on-event (event _args)
  "Redraw the pages a board event is about: a commit or a focus request."
  (when (member event '("board/changed" "board/created" "board/deleted" "board/focused"))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (cond
         ((derived-mode-p 'harness-ui-boards-mode)
          (harness-ui-boards-refresh))
         ((and (derived-mode-p 'harness-ui-board-mode)
               (not (equal event "board/focused")))
          (harness-ui-board-refresh)))))))

(defun harness-ui-board--on-connect ()
  "Refresh every board page after a connection, or a change."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (cond ((derived-mode-p 'harness-ui-boards-mode) (harness-ui-boards-refresh))
            ((derived-mode-p 'harness-ui-board-mode) (harness-ui-board-refresh))))))

(defvar harness-ui-board--key "J"
  "The harness key (`harness-ui-map') that opens the board list.")

(defun harness-ui-board--init ()
  "Bind the board list key and hear when a board changes.  Idempotent."
  (define-key harness-ui-map (kbd harness-ui-board--key) #'harness-boards)
  (add-hook 'harness-ui-connected-hook #'harness-ui-board--on-connect)
  (add-hook 'harness-ui-event-functions #'harness-ui-board--on-event)
  (when (fboundp 'transient-append-suffix)
    (transient-append-suffix 'harness-task-menu "a"
      '("J" "Boards" harness-boards))))

(defun harness-ui-board--shutdown ()
  "Unbind the board list key and stop hearing a board change."
  (when (eq (lookup-key harness-ui-map (kbd harness-ui-board--key)) #'harness-boards)
    (define-key harness-ui-map (kbd harness-ui-board--key) nil))
  (remove-hook 'harness-ui-connected-hook #'harness-ui-board--on-connect)
  (remove-hook 'harness-ui-event-functions #'harness-ui-board--on-event))

(when (harness-module-ready-p 'ui-board)
  (harness-ui-board--init))

(harness-define-module 'ui-board
  :doc "The freeform board pages (harness-boards, J in the harness map): the boards of the project, the rendered snapshot of one, its diagram's breadcrumb, the last commit and every object with its words, its role and the precise links it carries."
  :requires '(ui ui-linking)
  :init #'harness-ui-board--init
  :shutdown #'harness-ui-board--shutdown)

(provide 'harness-ui-board)
;;; harness-ui-board.el ends here
