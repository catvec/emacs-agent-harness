;;; harness-ui-tree.el --- Conversation tree  -*- lexical-binding: t; -*-

;;; Commentary:

;; A git-log-like view of a session's fork family.  Every node of the
;; family (the session, its ancestors and every fork, BTW and sub-agent
;; forked from them) is one row: newest at the top, the rails of the
;; graph on the left, a short id, the kind, a one-line excerpt and the
;; relative time.  Each session owns a lane with its own colour; where a
;; fork begins its first own row carries the session name and its lane
;; curves into the node it was forked from, exactly like a branch in a
;; git graph.  The current head of every session is drawn as a ring.
;;
;; Rails are small SVG images, one per row (`svg.el'); in a terminal the
;; same geometry is drawn with box characters, the one place where that
;; is the right medium.  Everything arrives through ACP
;; (`_harness/session/tree'); the view refreshes itself, debounced, on
;; node updates of any session in the family.
;;
;; Keys: RET open the session at that node, c check out (move the head:
;; time travel), f fork here, b BTW here, TAB expand the node, n/p move
;; within the lane, g refresh, q quit.  Every key has a header-line
;; button or a mouse target on the row.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'text-property-search)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-markdown)

(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-chat-goto-node "harness-ui-chat")

(defgroup harness-ui-tree nil
  "The conversation tree." :group 'harness-ui)

(defcustom harness-ui-tree-lane-width 16
  "Horizontal pixels per lane in the graph."
  :type 'integer :group 'harness-ui-tree)

(defcustom harness-ui-tree-lane-colors
  '(("#2a78d6" . "#3987e5") ("#eb6834" . "#d95926") ("#1baf7a" . "#199e70")
    ("#eda100" . "#c98500") ("#e87ba4" . "#d55181") ("#008300" . "#008300")
    ("#4a3aa7" . "#9085e9") ("#e34948" . "#e66767"))
  "Lane colours as (LIGHT . DARK) pairs, assigned to sessions in order."
  :type '(repeat (cons color color)) :group 'harness-ui-tree)

(defcustom harness-ui-tree-expand-limit 6000
  "Characters of node content shown when a row is expanded."
  :type 'integer :group 'harness-ui-tree)

(defface harness-tree-id-face '((t :inherit shadow :family "Monospace"))
  "Short node ids." :group 'harness-ui-tree)
(defface harness-tree-fork-face '((t :inherit bold))
  "Session names where a fork begins." :group 'harness-ui-tree)
(defface harness-tree-head-face '((t :inherit (bold success)))
  "The head marker." :group 'harness-ui-tree)
(defface harness-tree-current-line-face
  '((((background light)) :background "#eef1f6" :extend t)
    (((background dark)) :background "#2a2f3a" :extend t))
  "Rows of the session the tree was opened for." :group 'harness-ui-tree)

(harness-ui-define-icon harness-icon-hint "hint" "ⓘ" "hint" "A harness hint.")
(harness-ui-define-icon harness-icon-fork "fork" "↱" "fork" "A fork begins.")

;;;; Buffer state

(defvar-local harness-ui-tree--session-id nil "Session the tree was opened for.")
(defvar-local harness-ui-tree--data nil "Last (:sessions … :nodes …) received.")
(defvar-local harness-ui-tree--rows nil "Laid out rows, top to bottom.")
(defvar-local harness-ui-tree--family nil "Ids of every session in the family.")
(defvar-local harness-ui-tree--expanded nil "Ids of expanded nodes.")
(defvar-local harness-ui-tree--loading nil "Non-nil while a request is in flight.")
(defvar-local harness-ui-tree--error nil "Last request error message.")

(defvar harness-ui-tree--svg-cache (make-hash-table :test 'equal)
  "Rail geometry -> image spec.")

;;;; Layout

(defun harness-ui-tree--color (index)
  "Return the lane colour for lane INDEX in the current theme."
  (let ((pair (nth (mod index (length harness-ui-tree-lane-colors)) harness-ui-tree-lane-colors)))
    (if (eq (frame-parameter nil 'background-mode) 'dark) (cdr pair) (car pair))))

(defun harness-ui-tree--nodes-with-placeholders (data)
  "Return the nodes of DATA plus one placeholder per fork without own nodes."
  (let* ((nodes (plist-get data :nodes))
         (by-id (make-hash-table :test 'equal))
         (owned (make-hash-table :test 'equal))
         (extra nil))
    (dolist (n nodes)
      (puthash (plist-get n :id) n by-id)
      (puthash (plist-get n :session) t owned))
    (dolist (s (plist-get data :sessions))
      (let ((sid (plist-get s :id)))
        (unless (gethash sid owned)
          (let ((fork (gethash (plist-get s :fork-node) by-id)))
            (push (list :id (concat "session:" sid) :session sid :kind "empty"
                        :content "no messages yet"
                        :ts (+ 0.001 (or (and fork (plist-get fork :ts)) 0)))
                  extra)))))
    (append nodes extra)))

(defun harness-ui-tree--layout (data)
  "Lay out DATA into rows, newest first.
Each row is a plist (:node N :lane L :color C :segments ((LANE COLOR TOP
BOTTOM) …) :joins ((FROM TO COLOR) …) :head-p BOOL :fork-start-p BOOL
:after ((LANE . COLOR) …)); `:after' lists the lanes that continue
below the row."
  (let* ((sessions (plist-get data :sessions))
         (nodes (sort (copy-sequence (harness-ui-tree--nodes-with-placeholders data))
                      (lambda (a b) (> (or (plist-get a :ts) 0) (or (plist-get b :ts) 0)))))
         (by-sid (make-hash-table :test 'equal))
         (lane-of (make-hash-table :test 'equal))
         (color-of (make-hash-table :test 'equal))
         (remaining (make-hash-table :test 'equal))
         (node-ids (make-hash-table :test 'equal))
         (heads (make-hash-table :test 'equal))
         (children (make-hash-table :test 'equal))
         (lanes (make-vector 64 nil))
         (next-color 0)
         rows)
    (dolist (s sessions)
      (puthash (plist-get s :id) s by-sid)
      (when (plist-get s :head) (push (plist-get s :id) (gethash (plist-get s :head) heads)))
      (when (plist-get s :fork-node) (push (plist-get s :id) (gethash (plist-get s :fork-node) children))))
    (dolist (n nodes)
      (puthash (plist-get n :id) t node-ids)
      (cl-incf (gethash (plist-get n :session) remaining 0)))
    (cl-flet ((lane-for (sid)
                (or (gethash sid lane-of)
                    (let ((i 0))
                      (while (aref lanes i) (cl-incf i))
                      (aset lanes i sid)
                      (puthash sid i lane-of)
                      (puthash sid (harness-ui-tree--color next-color) color-of)
                      (cl-incf next-color)
                      i)))
              (free (sid)
                (let ((i (gethash sid lane-of)))
                  (when i (aset lanes i nil)))))
      (dolist (n nodes)
        (let* ((sid (plist-get n :session))
               (session (gethash sid by-sid))
               (new (not (gethash sid lane-of)))
               (lane (lane-for sid))
               (color (gethash sid color-of))
               (last-own (= 1 (gethash sid remaining 1)))
               (fork-node (plist-get session :fork-node))
               (keep-open (and last-own fork-node (gethash fork-node node-ids)
                               (not (equal fork-node (plist-get n :id)))))
               (joiners (cl-remove-if-not (lambda (c) (gethash c lane-of)) (gethash (plist-get n :id) children)))
               segments joins after)
          (cl-decf (gethash sid remaining 0))
          (dotimes (i (length lanes))
            (when-let* ((owner (aref lanes i)))
              (cond
               ((member owner joiners)
                (push (list (gethash owner lane-of) lane (gethash owner color-of)) joins))
               ((equal owner sid)
                (push (list i color (not new) (or (not last-own) keep-open)) segments))
               (t (push (list i (gethash owner color-of) t t) segments)))))
          (dolist (c joiners) (free c))
          (when (and last-own (not keep-open)) (free sid))
          (dotimes (i (length lanes))
            (when-let* ((owner (aref lanes i)))
              (push (cons i (gethash owner color-of)) after)))
          (push (list :node n :lane lane :color color
                      :segments (nreverse segments) :joins (nreverse joins)
                      :head-p (and (gethash (plist-get n :id) heads) t)
                      :head-of (gethash (plist-get n :id) heads)
                      :fork-start-p (and last-own (plist-get session :parent-id) t)
                      :after (nreverse after))
                rows))))
    (nreverse rows)))

(defun harness-ui-tree--lane-count (rows)
  "Return the number of lanes needed to draw ROWS."
  (let ((n 1))
    (dolist (r rows n)
      (dolist (s (plist-get r :segments)) (setq n (max n (1+ (car s)))))
      (dolist (j (plist-get r :joins)) (setq n (max n (1+ (car j)) (1+ (cadr j)))))
      (setq n (max n (1+ (plist-get r :lane)))))))

;;;; Rails

(defun harness-ui-tree--window ()
  "Return a window showing the current buffer on any frame, or nil."
  (get-buffer-window (current-buffer) t))

(defun harness-ui-tree--frame ()
  "Return the frame the buffer is (or will be) displayed on."
  (let ((win (harness-ui-tree--window)))
    (if win (window-frame win) (selected-frame))))

(defun harness-ui-tree--graphic-p ()
  "Non-nil when the buffer's frame can show SVG rails."
  (and (display-graphic-p (harness-ui-tree--frame)) (image-type-available-p 'svg)))

(defvar-local harness-ui-tree--height nil "Row height in pixels for the current render.")

(defun harness-ui-tree--line-height ()
  "Return the pixel height of a text line in the buffer's window.
Selecting a window moves point, so the value is measured once per
render and cached in `harness-ui-tree--height'."
  (or harness-ui-tree--height
      (let ((win (harness-ui-tree--window)))
        (if win
            (save-excursion (with-selected-window win (default-line-height)))
          (frame-char-height (harness-ui-tree--frame))))))

(defun harness-ui-tree--svg-rails (nlanes height segments joins dot-lane dot-color head-p)
  "Return an SVG image of the rails for one row.
NLANES lanes of HEIGHT pixels; SEGMENTS, JOINS, DOT-LANE, DOT-COLOR and
HEAD-P are as in a layout row (DOT-LANE nil draws no dot)."
  (let ((key (list nlanes height segments joins dot-lane dot-color head-p)))
    (or (gethash key harness-ui-tree--svg-cache)
        (let* ((lw harness-ui-tree-lane-width)
               (width (+ 4 (* lw nlanes)))
               (svg (svg-create width height))
               (cy (/ height 2.0))
               (x (lambda (lane) (+ 2 (* lw lane) (/ lw 2.0)))))
          (pcase-dolist (`(,lane ,color ,top ,bottom) segments)
            (let ((lx (funcall x lane)))
              (when top (svg-line svg lx 0 lx (if (eql lane dot-lane) cy height)
                                  :stroke-color color :stroke-width 2))
              (when bottom (svg-line svg lx (if (eql lane dot-lane) cy 0) lx height
                                     :stroke-color color :stroke-width 2))))
          (pcase-dolist (`(,from ,to ,color) joins)
            (svg-node svg 'path
                      :d (format "M %s 0 Q %s %s %s %s" (funcall x from) (funcall x from) cy (funcall x to) cy)
                      :stroke color :stroke-width 2 :fill "none" :stroke-linecap "round"))
          (when dot-lane
            (let ((cx (funcall x dot-lane)))
              (if head-p
                  (progn (svg-circle svg cx cy 5.5 :fill-color "none" :stroke-color dot-color :stroke-width 2)
                         (svg-circle svg cx cy 2.5 :fill-color dot-color))
                (svg-circle svg cx cy 4 :fill-color dot-color))))
          (puthash key (svg-image svg :ascent 'center :scale 1) harness-ui-tree--svg-cache)))))

(defun harness-ui-tree--text-rails (nlanes segments joins dot-lane dot-color head-p)
  "Return the box-character rails for one row (terminal fallback).
NLANES, SEGMENTS, JOINS, DOT-LANE, DOT-COLOR and HEAD-P are as in
`harness-ui-tree--svg-rails'."
  (let ((cells (make-vector nlanes (propertize " " 'face 'default))))
    (pcase-dolist (`(,lane ,color ,top ,bottom) segments)
      (aset cells lane (propertize (cond ((and top bottom) "│") (top "╵") (bottom "╷") (t " "))
                                   'face (list :foreground color))))
    (pcase-dolist (`(,from ,_to ,color) joins)
      (aset cells from (propertize "╯" 'face (list :foreground color))))
    (when dot-lane
      (aset cells dot-lane (propertize (if head-p "◉" "●") 'face (list :foreground dot-color))))
    (concat (mapconcat #'identity (append cells nil) " ") " ")))

(defun harness-ui-tree--rails (nlanes row &optional continuation)
  "Return the rails string for ROW over NLANES lanes.
With CONTINUATION, draw only the lanes continuing below the row."
  (let* ((segments (if continuation
                       (mapcar (lambda (c) (list (car c) (cdr c) t t)) (plist-get row :after))
                     (plist-get row :segments)))
         (joins (unless continuation (plist-get row :joins)))
         (dot-lane (unless continuation (plist-get row :lane)))
         (color (plist-get row :color))
         (head-p (plist-get row :head-p)))
    (if (harness-ui-tree--graphic-p)
        (propertize (make-string (max 1 (ceiling (+ 4 (* nlanes harness-ui-tree-lane-width))
                                                 (max 1 (frame-char-width (harness-ui-tree--frame)))))
                                 ?\s)
                    'display (harness-ui-tree--svg-rails nlanes (harness-ui-tree--line-height)
                                                         segments joins dot-lane color head-p)
                    'rear-nonsticky t)
      (harness-ui-tree--text-rails nlanes segments joins dot-lane color head-p))))

;;;; Rows

(defun harness-ui-tree--kind (node)
  "Return NODE's kind as a string."
  (format "%s" (or (plist-get node :kind) "")))

(defun harness-ui-tree--kind-icon (node)
  "Return the icon string for NODE's kind, with face."
  (pcase (harness-ui-tree--kind node)
    ("user" (propertize (harness-ui-icon 'harness-icon-user) 'face 'bold))
    ((or "assistant" "plan") (harness-ui-icon 'harness-icon-agent))
    ("thinking" (propertize (harness-ui-icon 'harness-icon-thinking) 'face 'harness-thinking-face))
    ((or "tool-call" "tool-result") (propertize (harness-ui-icon 'harness-icon-tool) 'face 'harness-tool-title-face))
    ("empty" (propertize (harness-ui-icon 'harness-icon-fork) 'face 'harness-dim-face))
    (_ (propertize (harness-ui-icon 'harness-icon-hint) 'face 'harness-hint-face))))

(defun harness-ui-tree--excerpt (node)
  "Return a one-line excerpt of NODE."
  (pcase (harness-ui-tree--kind node)
    ("tool-call" (or (plist-get node :title)
                     (format "%s %s" (plist-get node :tool) (harness-first-line (format "%S" (plist-get node :input))))))
    ("tool-result" (concat (if (harness-json-true-p (plist-get node :is-error)) "✗ " "→ ")
                           (harness-first-line (or (plist-get node :output) ""))))
    (_ (harness-first-line (or (plist-get node :content) "")))))

(defun harness-ui-tree--excerpt-face (node)
  "Return the face for NODE's excerpt."
  (pcase (harness-ui-tree--kind node)
    ("thinking" 'harness-thinking-face)
    ((or "hint" "compaction" "empty") 'harness-hint-face)
    ("tool-result" (if (harness-json-true-p (plist-get node :is-error)) 'error 'harness-dim-face))
    ("tool-call" 'harness-tool-title-face)
    (_ 'default)))

(defun harness-ui-tree--session-name (sid)
  "Return a display name for session SID."
  (let* ((s (or (cl-find sid (plist-get harness-ui-tree--data :sessions)
                         :key (lambda (x) (plist-get x :id)) :test #'equal)
                (harness-ui-session sid)))
         (name (plist-get s :name)))
    (if (and name (not (string-empty-p name))) name
      (format "%s %s" (or (plist-get s :kind) "session") (substring sid 0 (min 6 (length sid)))))))

(defun harness-ui-tree--insert-row (row nlanes width)
  "Insert ROW drawn over NLANES lanes into WIDTH columns."
  (let* ((node (plist-get row :node))
         (sid (plist-get node :session))
         (id (plist-get node :id))
         (short (if (string-prefix-p "session:" id) "      " (substring id (max 0 (- (length id) 6)))))
         (time (if (string-prefix-p "session:" id) "" (harness-relative-time (or (plist-get node :ts) 0))))
         (label (when (plist-get row :fork-start-p)
                  (propertize (format "%s %s " (harness-ui-icon 'harness-icon-fork) (harness-ui-tree--session-name sid))
                              'face (list 'harness-tree-fork-face (list :foreground (plist-get row :color))))))
         (head (when (plist-get row :head-p)
                 (propertize (if (member sid (plist-get row :head-of)) " HEAD" " head")
                             'face 'harness-tree-head-face
                             'help-echo (format "Current head of %s"
                                                (mapconcat #'harness-ui-tree--session-name (plist-get row :head-of) ", ")))))
         (rails (harness-ui-tree--rails nlanes row))
         (rail-cols (length rails))
         (fixed (+ rail-cols 1 6 2 2 (length (or label "")) (length (or head "")) 2 (length time)))
         (room (max 12 (- width fixed)))
         (excerpt (harness-truncate-end (harness-ui-tree--excerpt node) room))
         (start (point)))
    (insert rails " "
            (propertize short 'face 'harness-tree-id-face) "  "
            (harness-ui-tree--kind-icon node) " "
            (or label "")
            (propertize excerpt 'face (harness-ui-tree--excerpt-face node))
            (or head ""))
    (insert (propertize " " 'display `(space :align-to (- right ,(1+ (length time)))))
            (propertize time 'face 'harness-dim-face)
            "\n")
    (add-text-properties start (point)
                         (list 'harness-ui-tree-node node 'harness-ui-tree-row row
                               'mouse-face 'highlight
                               'help-echo "mouse-1: open the session here; c: check out; f: fork; TAB: expand"))
    (when (equal sid harness-ui-tree--session-id)
      (add-face-text-property start (point) 'harness-tree-current-line-face t))
    (when (member id harness-ui-tree--expanded)
      (harness-ui-tree--insert-expansion row nlanes))))

(defun harness-ui-tree--expansion-text (node)
  "Return the full content of NODE rendered for the expanded view."
  (let ((clip (lambda (s) (harness-truncate-end (or s "") harness-ui-tree-expand-limit))))
    (pcase (harness-ui-tree--kind node)
      ("tool-call" (concat (propertize (or (plist-get node :title) (plist-get node :tool) "") 'face 'harness-tool-title-face)
                           "\n" (propertize (funcall clip (pp-to-string (plist-get node :input))) 'face 'harness-tool-face)))
      ("tool-result" (propertize (funcall clip (plist-get node :output))
                                 'face (if (harness-json-true-p (plist-get node :is-error)) 'harness-tool-error-face 'harness-tool-face)))
      ("thinking" (propertize (funcall clip (plist-get node :content)) 'face 'harness-thinking-face))
      (_ (harness-ui-markdown-render (funcall clip (plist-get node :content)))))))

(defun harness-ui-tree--insert-expansion (row nlanes)
  "Insert the expanded content of ROW under its line.
The rails of the NLANES lanes continue as the line prefix."
  (let* ((prefix (concat (harness-ui-tree--rails nlanes row t) "         "))
         (text (harness-ui-tree--expansion-text (plist-get row :node)))
         (start (point)))
    (insert (if (string-empty-p text) (propertize "(empty)" 'face 'harness-dim-face) text) "\n")
    (add-text-properties start (point)
                         (list 'line-prefix prefix 'wrap-prefix prefix
                               'harness-ui-tree-node (plist-get row :node)
                               'harness-ui-tree-row row
                               'harness-ui-tree-expansion t))))

;;;; Rendering

(defun harness-ui-tree--header ()
  "Return the header line."
  (let ((btn (lambda (label cmd help)
               (concat (propertize label 'face 'harness-label-face 'mouse-face 'mode-line-highlight
                                   'help-echo help 'local-map (harness-ui-mouse-keymap cmd))
                       " "))))
    (list (propertize " Tree " 'face 'harness-label-face)
          (propertize (harness-ui-tree--session-name harness-ui-tree--session-id) 'face 'bold)
          (propertize (format "  %d sessions · %d nodes " (length harness-ui-tree--family) (length harness-ui-tree--rows))
                      'face 'harness-dim-face)
          (cond (harness-ui-tree--loading (propertize "loading… " 'face 'harness-dim-face))
                (harness-ui-tree--error (propertize (format "error: %s " harness-ui-tree--error) 'face 'error))
                (t ""))
          (funcall btn "[RET open]" #'harness-ui-tree-open "Open the session at this node")
          (funcall btn "[c checkout]" #'harness-ui-tree-checkout "Move the session head to this node (time travel)")
          (funcall btn "[f fork]" #'harness-ui-tree-fork "Fork the session at this node")
          (funcall btn "[b btw]" #'harness-ui-tree-btw "Start a BTW side conversation here")
          (funcall btn "[TAB expand]" #'harness-ui-tree-toggle "Show the full node")
          (funcall btn "[n/p lane]" #'harness-ui-tree-next-in-lane "Move within this session's rows")
          (funcall btn "[g]" #'harness-ui-tree-refresh "Refresh")
          (funcall btn "[q]" #'quit-window "Quit"))))

(defun harness-ui-tree--node-position (id)
  "Return the buffer position of the row of node ID, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'harness-ui-tree-node id
                                                 (lambda (v n) (equal v (plist-get n :id))))))
      (prop-match-beginning m))))

(defun harness-ui-tree--render ()
  "Redraw the buffer from `harness-ui-tree--data', keeping point on its node.
Every window showing the buffer keeps its own row too."
  (let* ((inhibit-read-only t)
         (at (harness-ui-tree-node-at-point t))
         (at-id (and at (plist-get at :id)))
         (col (current-column))
         (windows (mapcar (lambda (w)
                            (cons w (plist-get (get-text-property (window-point w) 'harness-ui-tree-node) :id)))
                          (get-buffer-window-list (current-buffer) nil t)))
         (rows (and harness-ui-tree--data (harness-ui-tree--layout harness-ui-tree--data)))
         (nlanes (harness-ui-tree--lane-count rows))
         (win (harness-ui-tree--window))
         (width (if win (window-body-width win) 100)))
    (setq harness-ui-tree--rows rows
          harness-ui-tree--height nil)
    (setq harness-ui-tree--height (harness-ui-tree--line-height))
    (erase-buffer)
    (cond
     ((and (null harness-ui-tree--data) harness-ui-tree--loading)
      (insert (propertize "Loading the conversation tree…\n" 'face 'harness-dim-face)))
     ((and (null harness-ui-tree--data) harness-ui-tree--error)
      (insert (propertize (format "Could not load the tree: %s\n" harness-ui-tree--error) 'face 'error)))
     ((null rows)
      (insert (propertize "This session has no messages yet.\n" 'face 'harness-dim-face)))
     (t (dolist (row rows) (harness-ui-tree--insert-row row nlanes width))))
    (setq header-line-format (harness-ui-tree--header))
    (goto-char (or (and at-id (harness-ui-tree--node-position at-id)) (point-min)))
    (move-to-column col)
    (pcase-dolist (`(,w . ,id) windows)
      (when (window-live-p w)
        (set-window-point w (or (and id (harness-ui-tree--node-position id)) (point-min)))))))

;;;; Data

(defun harness-ui-tree--buffer-name (sid)
  "Return the buffer name for the tree of session SID."
  (format "*harness tree: %s*" (harness-ui-tree--session-name sid)))

(defun harness-ui-tree--buffers ()
  "Return every live tree buffer."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-tree-mode))) (buffer-list)))

(defun harness-ui-tree--load (buffer)
  "Request the tree for BUFFER's session and render it when it arrives."
  (with-current-buffer buffer
    (setq harness-ui-tree--loading t harness-ui-tree--error nil)
    (setq header-line-format (harness-ui-tree--header))
    (let ((sid harness-ui-tree--session-id))
      (harness-ui-call
       "_harness/session/tree" (list :id sid)
       (lambda (data)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-tree--data data
                   harness-ui-tree--family (mapcar (lambda (s) (plist-get s :id)) (plist-get data :sessions))
                   harness-ui-tree--loading nil)
             (let ((name (harness-ui-tree--buffer-name sid)))
               (unless (or (equal name (buffer-name)) (get-buffer name)) (rename-buffer name)))
             (harness-ui-tree--render))))
       (lambda (e)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-tree--loading nil harness-ui-tree--error (harness-error-message e))
             (harness-ui-tree--render))))))))

(defun harness-ui-tree--refresh-buffer (buffer)
  "Reload BUFFER, debounced."
  (harness-debounce (list 'harness-ui-tree buffer) 0.25
                    (lambda () (when (buffer-live-p buffer) (harness-ui-tree--load buffer)))))

(defun harness-ui-tree--on-update (sid update)
  "Refresh trees whose family contains SID for a node or session UPDATE."
  (when (member (plist-get update :sessionUpdate) '("_harness/node" "_harness/session"))
    (dolist (b (harness-ui-tree--buffers))
      (when (member sid (buffer-local-value 'harness-ui-tree--family b))
        (harness-ui-tree--refresh-buffer b)))))

(defun harness-ui-tree--on-event (event _args)
  "Refresh every tree when EVENT may have added a fork."
  (when (member event '("session/created" "session/deleted" "session/forked" "session/head-moved"))
    (mapc #'harness-ui-tree--refresh-buffer (harness-ui-tree--buffers))))

(defun harness-ui-tree--redraw-all ()
  "Rebuild every tree buffer (after a reload or reconnect)."
  (clrhash harness-ui-tree--svg-cache)
  (mapc #'harness-ui-tree--load (harness-ui-tree--buffers)))

;;;; Mode and commands

(defvar harness-ui-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'harness-ui-tree-open)
    (define-key map [mouse-1] #'harness-ui-tree-mouse-open)
    (define-key map (kbd "c") #'harness-ui-tree-checkout)
    (define-key map (kbd "f") #'harness-ui-tree-fork)
    (define-key map (kbd "b") #'harness-ui-tree-btw)
    (define-key map (kbd "TAB") #'harness-ui-tree-toggle)
    (define-key map (kbd "<tab>") #'harness-ui-tree-toggle)
    (define-key map (kbd "n") #'harness-ui-tree-next-in-lane)
    (define-key map (kbd "p") #'harness-ui-tree-previous-in-lane)
    (define-key map (kbd "g") #'harness-ui-tree-refresh)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-tree-mode'.")

(define-derived-mode harness-ui-tree-mode special-mode "Tree"
  "Major mode showing the fork family of a session as a graph."
  (setq truncate-lines t
        buffer-read-only t
        cursor-type 'bar)
  (setq-local harness-ui-session-id nil)
  (add-hook 'window-configuration-change-hook #'harness-ui-tree--on-resize nil t))

;; The tree's keys in the harness menu, behind `.'.
(put 'harness-ui-tree-mode 'harness-menu-group
     '("Conversation tree"
       ["Node at point"
        (". RET" "Open its session" harness-ui-tree-open)
        (". c" "Check out (time travel)" harness-ui-tree-checkout)
        (". f" "Fork here" harness-ui-tree-fork)
        (". b" "BTW from here" harness-ui-tree-btw)
        (". TAB" "Expand or collapse" harness-ui-tree-toggle)]
       ["Move"
        (". n" "Next in lane" harness-ui-tree-next-in-lane)
        (". p" "Previous in lane" harness-ui-tree-previous-in-lane)
        (". g" "Refresh" harness-ui-tree-refresh)]))

(defun harness-ui-tree--on-resize ()
  "Re-render when the window width changed."
  (when harness-ui-tree--data
    (harness-debounce (list 'harness-ui-tree-resize (current-buffer)) 0.2
                      (let ((b (current-buffer)))
                        (lambda () (when (buffer-live-p b) (with-current-buffer b (harness-ui-tree--render))))))))

(defun harness-ui-tree-node-at-point (&optional noerror)
  "Return the node plist of the row at point; signal unless NOERROR."
  (or (get-text-property (point) 'harness-ui-tree-node)
      (and (not noerror) (user-error "No node on this line"))))

(defun harness-ui-tree--row-at-point ()
  "Return the layout row at point."
  (or (get-text-property (point) 'harness-ui-tree-row) (user-error "No node on this line")))

(defun harness-ui-tree--buffer-for (sid)
  "Return the tree buffer showing session SID, creating it if needed."
  (or (cl-find sid (harness-ui-tree--buffers)
               :key (lambda (b) (buffer-local-value 'harness-ui-tree--session-id b)) :test #'equal)
      (with-current-buffer (get-buffer-create (harness-ui-tree--buffer-name sid))
        (harness-ui-tree-mode)
        (setq harness-ui-tree--session-id sid
              harness-ui-tree--family (list sid))
        (current-buffer))))

;;;###autoload
(defun harness-tree (&optional session-id)
  "Show the conversation tree of SESSION-ID (default: the current session)."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (buf (harness-ui-tree--buffer-for sid)))
    (harness-ui-display-view buf)
    (harness-ui-tree--load buf)))

(defun harness-ui-tree-refresh ()
  "Reload the tree."
  (interactive)
  (harness-ui-tree--load (current-buffer)))

(defun harness-ui-tree-open ()
  "Open the session of the node at point, at that node when the chat supports it."
  (interactive)
  (let* ((node (harness-ui-tree-node-at-point))
         (sid (plist-get node :session))
         (open (harness-ui-session-opener)))
    (funcall open sid)
    (when (fboundp 'harness-ui-chat-goto-node)
      (harness-ui-chat-goto-node (plist-get node :id)))))

(defun harness-ui-tree-mouse-open (event)
  "Open the session of the row clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-tree-open))

(defun harness-ui-tree--set-head (sid node-id callback)
  "Move the head of SID to NODE-ID, then call CALLBACK."
  (harness-ui-call "_harness/session/set-head" (list :id sid :node-id node-id) callback))

(defun harness-ui-tree-checkout ()
  "Move the head of the node's session to the node at point (time travel)."
  (interactive)
  (let* ((node (harness-ui-tree-node-at-point))
         (sid (plist-get node :session))
         (id (plist-get node :id)))
    (when (string-prefix-p "session:" id) (user-error "Nothing to check out yet"))
    (when (yes-or-no-p (format "Move the head of %s to %s? " (harness-ui-tree--session-name sid)
                               (substring id (max 0 (- (length id) 6)))))
      (harness-ui-tree--set-head sid id
                                 (lambda (_)
                                   (message "Head of %s is now %s" (harness-ui-tree--session-name sid) id)
                                   (harness-ui-tree--load (current-buffer)))))))

(defun harness-ui-tree--head-of (sid)
  "Return the current head node id of session SID from the tree data."
  (plist-get (cl-find sid (plist-get harness-ui-tree--data :sessions)
                      :key (lambda (s) (plist-get s :id)) :test #'equal)
             :head))

(defun harness-ui-tree--at-node (node fn)
  "Call FN with the session of NODE positioned at NODE.
When NODE is not the head, the head is moved there first and moved back
once FN's request settles.  FN receives (SID DONE) and must call DONE."
  (let* ((sid (plist-get node :session))
         (id (plist-get node :id))
         (head (harness-ui-tree--head-of sid))
         (buffer (current-buffer))
         (restore (lambda ()
                    (when (and head (not (equal head id)))
                      (harness-ui-tree--set-head sid head #'ignore))
                    (when (buffer-live-p buffer) (harness-ui-tree--refresh-buffer buffer)))))
    (when (string-prefix-p "session:" id) (user-error "This fork has no nodes yet"))
    (if (or (null head) (equal head id))
        (funcall fn sid restore)
      (harness-ui-tree--set-head sid id (lambda (_) (funcall fn sid restore))))))

(defun harness-ui-tree-fork ()
  "Fork the node's session at the node at point and open the fork."
  (interactive)
  (let ((open (harness-ui-session-opener)))
    (harness-ui-tree--at-node
     (harness-ui-tree-node-at-point)
     (lambda (sid done)
       (harness-ui-call "_harness/session/fork" (list :id sid :kind "fork")
                        (lambda (child)
                          (funcall done)
                          (harness-ui-refresh-sessions
                           (lambda (_)
                             (message "Forked %s" (substring (plist-get child :id) 0 8))
                             (when harness-ui-open-session-function
                               (funcall open (plist-get child :id))))))
                        (lambda (e) (funcall done) (message "Fork failed: %s" (harness-error-message e))))))))

(defun harness-ui-tree-btw ()
  "Start a BTW side conversation from the node at point.
It opens blank, for a question written in its compose box."
  (interactive)
  (unless (fboundp 'harness-btw) (user-error "The BTW module is not loaded"))
  (let ((tree (current-buffer)))
    (harness-ui-tree--at-node
     (harness-ui-tree-node-at-point)
     (lambda (sid done)
       ;; Opened over the tree; the head moves back once the fork is made.
       (harness-then (if (buffer-live-p tree) (with-current-buffer tree (harness-btw sid)) (harness-btw sid))
                     (lambda (_) (funcall done))
                     (lambda (_) (funcall done)))))))

(defun harness-ui-tree-toggle ()
  "Expand or collapse the node at point."
  (interactive)
  (let ((id (plist-get (harness-ui-tree-node-at-point) :id)))
    (setq harness-ui-tree--expanded
          (if (member id harness-ui-tree--expanded)
              (delete id harness-ui-tree--expanded)
            (cons id harness-ui-tree--expanded)))
    (harness-ui-tree--render)))

(defun harness-ui-tree--move-in-lane (direction)
  "Move DIRECTION (1 or -1) rows to the next node of the same session."
  (let* ((node (harness-ui-tree-node-at-point))
         (sid (plist-get node :session))
         (target nil))
    (save-excursion
      (while (and (not target) (zerop (forward-line direction)) (not (eobp)))
        (let ((n (get-text-property (point) 'harness-ui-tree-node)))
          (when (and n (not (get-text-property (point) 'harness-ui-tree-expansion))
                     (equal (plist-get n :session) sid)
                     (not (equal (plist-get n :id) (plist-get node :id))))
            (setq target (point))))))
    (if target (goto-char target)
      (message "No more rows of %s" (harness-ui-tree--session-name sid)))))

(defun harness-ui-tree-next-in-lane ()
  "Move to the next (older) row of the same session."
  (interactive)
  (harness-ui-tree--move-in-lane 1))

(defun harness-ui-tree-previous-in-lane ()
  "Move to the previous (newer) row of the same session."
  (interactive)
  (harness-ui-tree--move-in-lane -1))

;;;; Module

(defun harness-ui-tree--init ()
  "Wire the tree into the UI."
  (add-hook 'harness-ui-update-functions #'harness-ui-tree--on-update)
  (add-hook 'harness-ui-event-functions #'harness-ui-tree--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-tree--redraw-all)
  (define-key harness-ui-map (kbd "t") #'harness-tree))

(harness-define-module 'ui-tree
  :doc "Conversation tree: the fork family of a session as a git-like graph."
  :requires '(ui)
  :init #'harness-ui-tree--init)

(provide 'harness-ui-tree)
;;; harness-ui-tree.el ends here
