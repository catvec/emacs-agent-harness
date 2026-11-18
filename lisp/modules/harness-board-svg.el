;;; harness-board-svg.el --- A board drawn as SVG, from its own geometry  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; One renderer for the board, written once and used everywhere the board
;; is shown rather than drawn again by each client: the Emacs page shows
;; this SVG, `scene.read' hands it to a model as a picture, and the Flutter
;; client can show the same snapshot beside its live canvas.  A picture a
;; model is given and one a person sees are then the same drawing, which is
;; what an evidence claim needs.
;;
;; The renderer is a reader of the grammar, not a second model of it: it
;; draws the primitives harness-board.el validates -- rect, ellipse,
;; polygon, path, text and image -- with the style roles the theme resolves.
;; Nothing here has a shape the grammar lacks.  A theme supplies the
;; palette; the geometry arrives already placed by each view's matrix, which
;; is written straight into the SVG group.
;;
;; The cleanup the design asks for is done here, in one place: a framed
;; region's small title tab sits on the frame's top-left corner with its
;; text on the tab's baseline; a note's text is inset from its box; an
;; image has its name above it and no card shell; a task marker is a small
;; square with its label beside it, at the same baseline.  Vertical text is
;; never drawn rotated.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-board)
(require 'harness-board-store)

(defgroup harness-board-svg nil
  "Drawing a board as a picture." :group 'harness)

(defcustom harness-board-svg-scale 1.0
  "Pixels per canvas unit when a board is drawn."
  :type 'number :group 'harness-board-svg)

(defun harness-board-theme (board)
  "Return BOARD's theme as an alist of roles and colours."
  (let ((theme (or (plist-get board :theme) "electric-commons")))
    (or (cdr (assoc (intern theme) harness-board-themes))
        (cdr (assoc "electric-commons" harness-board-themes)))))

(defun harness-board-svg--luminance (colour)
  "Return the relative luminance of COLOUR, a #rrggbb string."
  (let ((rgb (and (stringp colour)
                  (string-match "\\`#\\([0-9a-fA-F]\\{6\\}\\)\\'" colour)
                  (cl-loop for at in '(1 3 5)
                           collect (/ (string-to-number
                                       (substring colour at (+ at 2))
                                       16)
                                      255.0)))))
    (if (null rgb)
        1.0
      (cl-destructuring-bind (r g b)
          (mapcar (lambda (value)
                    (if (<= value 0.03928)
                        (/ value 12.92)
                      (expt (/ (+ value 0.055) 1.055) 2.4)))
                  rgb)
        (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))))

(defun harness-board-svg--contrast (one two)
  "Return the contrast ratio of colours ONE and TWO, as WCAG writes it."
  (let* ((a (harness-board-svg--luminance one))
         (b (harness-board-svg--luminance two))
         (light (max a b))
         (dark (min a b)))
    (/ (+ light 0.05) (+ dark 0.05))))

(defun harness-board-svg--on-cap (board cap)
  "Return the colour words on CAP are drawn in, on BOARD.
A tab is filled with a theme's accent, and its words are whichever of the
theme's ink and paper reads on that accent: night commons fills its tabs
with a bright accent, where the theme's own ink would vanish."
  (let ((ink (harness-board-svg--color board "ink"))
        (paper (harness-board-svg--color board "paper")))
    (if (and ink paper cap
             (< (harness-board-svg--contrast ink cap)
                (harness-board-svg--contrast paper cap)))
        paper
      ink)))

(defun harness-board-svg--color (board role)
  "Return the colour ROLE means on BOARD, or nil."
  (let ((theme (harness-board-theme board)))
    (cond ((null role) nil)
          ((equal role "none") nil)
          ((string-prefix-p "#" role) role)
          (t (cdr (assoc (intern role) theme))))))

(defun harness-board-svg--xml (text)
  "Return TEXT escaped for XML, and valid."
  (let ((text (harness-valid-text (or text ""))))
    (replace-regexp-in-string
     "[&<>\"]"
     (lambda (char) (pcase char ("&" "&amp;") ("<" "&lt;") (">" "&gt;") (_ "&quot;")))
     text t t)))

(defun harness-board-svg--number (n)
  "Return N written for an SVG attribute."
  (let ((n (float n)))
    (if (= n (truncate n))
        (format "%d" (truncate n))
      (format "%.2f" n))))

(defun harness-board-svg--matrix (m)
  "Return the SVG transform for matrix M, or nil for an identity."
  (if (equal m harness-board-identity)
      nil
    (format "matrix(%s)"
            (mapconcat #'harness-board-svg--number (append m nil) " "))))

(defun harness-board-svg--style (board style &rest overrides)
  "Return SVG paint attributes for STYLE on BOARD.
OVERRIDES are (KEY . VALUE) pairs applied over it."
  (let* ((style (copy-sequence style))
         (fill (or (cdr (assoc :fill overrides))
                   (harness-board-svg--color board (plist-get style :fill))))
         (stroke (or (cdr (assoc :stroke overrides))
                     (harness-board-svg--color board (plist-get style :stroke))))
         (width (or (cdr (assoc :strokeWidth overrides)) (plist-get style :strokeWidth)))
         (dash (plist-get style :dash))
         (opacity (cdr (assoc :opacity overrides))))
    (concat
     (format " fill=\"%s\"" (or fill "none"))
     (format " stroke=\"%s\"" (or stroke "none"))
     (when width (format " stroke-width=\"%s\"" (harness-board-svg--number width)))
     (when (and width (> width 0.1)) " stroke-linejoin=\"miter\"")
     (when dash (format " stroke-dasharray=\"%s\"" (harness-board-svg--xml dash)))
     (when opacity (format " opacity=\"%s\"" (harness-board-svg--number opacity))))))

(defun harness-board-svg--text-style (board style &optional overrides)
  "Return SVG text attributes for STYLE on BOARD."
  (let ((ink (harness-board-svg--color board (or (cdr (assoc :fill overrides))
                                                 (plist-get style :textColor)
                                                 "ink")))
        (size (or (cdr (assoc :size overrides)) (plist-get style :fontSize) 18))
        (weight (or (plist-get style :fontWeight) 400)))
    (format " fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"%s\""
            (or ink "currentColor") (harness-board-svg--number size) weight)))

(defun harness-board-svg--points (points)
  "Return POINTS, a vector of [x y], as an SVG points attribute."
  (mapconcat (lambda (p)
               (format "%s,%s" (harness-board-svg--number (aref p 0))
                       (harness-board-svg--number (aref p 1))))
             (append points nil) " "))

(defun harness-board-svg--path-data (segments)
  "Return SEGMENTS, a path's own segments, as SVG path data."
  (mapconcat (lambda (segment)
               (concat (car segment)
                       (when (cdr segment)
                         (concat " "
                                 (mapconcat #'harness-board-svg--number
                                            (cdr segment) " ")))))
             segments " "))

(defun harness-board-svg--shape (board id shape style)
  "Return the SVG element for SHAPE, the primitive of object ID.
STYLE is the view's paint.  ID names the element for a click."
  (let* ((attributes (harness-board-svg--style board style))
         (tag (lambda (name rest) (format "<%s data-object=\"%s\"%s%s/>"
                                         name (harness-board-svg--xml id) attributes rest))))
    (pcase (plist-get shape :kind)
      ("rect" (funcall tag "rect"
                       (format " x=\"0\" y=\"0\" width=\"%s\" height=\"%s\""
                               (harness-board-svg--number (plist-get shape :w))
                               (harness-board-svg--number (plist-get shape :h)))))
      ("image" (format "<image data-object=\"%s\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" href=\"%s\" preserveAspectRatio=\"xMidYMid meet\"/>"
                       (harness-board-svg--xml id)
                       (harness-board-svg--number (plist-get shape :w))
                       (harness-board-svg--number (plist-get shape :h))
                       (harness-board-svg--xml (plist-get shape :src))))
      ("ellipse" (funcall tag "ellipse"
                          (format " cx=\"0\" cy=\"0\" rx=\"%s\" ry=\"%s\""
                                  (harness-board-svg--number (plist-get shape :rx))
                                  (harness-board-svg--number (plist-get shape :ry)))))
      ("polygon" (funcall tag "polygon"
                          (format " points=\"%s\""
                                  (harness-board-svg--points (plist-get shape :points)))))
      ("path" (let ((stroke-style (if (plist-get shape :raw)
                                      (list :fill "none" :stroke (or (plist-get style :stroke) "ink")
                                            :strokeWidth (or (plist-get style :strokeWidth) 2.4))
                                    style)))
                (format "<path data-object=\"%s\" d=\"%s\"%s%s%s/>"
                        (harness-board-svg--xml id)
                        (harness-board-svg--path-data (plist-get shape :segments))
                        (harness-board-svg--style board stroke-style)
                        (if (plist-get shape :raw)
                            " stroke-linecap=\"round\""
                          " stroke-linecap=\"butt\"")
                        (if (plist-get shape :closed) " data-closed=\"true\"" ""))))
      ("text" "")
      (_ ""))))

(defun harness-board-svg--text (board id text style &optional size)
  "Return the SVG for TEXT of object ID in STYLE.
TEXT is written on its own baselines, never rotated, and its lines keep
even spacing: the design's fix for the awkward vertical spacing of the
sketch."
  (let* ((size (or size (plist-get style :fontSize) 18))
         (lines (split-string (or text "") "\n"))
         (spacing (* size 1.3))
         (index 0))
    (format "<g data-object=\"%s\"%s>%s</g>"
            (harness-board-svg--xml id)
            (harness-board-svg--text-style board style (list (cons :size size)))
            (mapconcat (lambda (line)
                         (prog1
                             (format "<text x=\"0\" y=\"%s\" dominant-baseline=\"text-before-edge\">%s</text>"
                                     (harness-board-svg--number (* spacing index))
                                     (harness-board-svg--xml line))
                           (cl-incf index)))
                       lines ""))))

(defun harness-board-svg--note (board object view)
  "Return the SVG for a note OBJECT in VIEW: a sharp box with its words.
The words are inset from the box on every side, wrapped at the box's
width, and start on one baseline so a note of three lines reads as one
block."
  (let* ((id (plist-get object :id))
         (shape (plist-get view :shape))
         (style (plist-get view :style))
         (w (plist-get shape :w))
         (fill (harness-board-svg--color board (or (plist-get style :fill) "note")))
         (ink (harness-board-svg--color board (or (plist-get style :textColor) "ink")))
         (size (or (plist-get style :fontSize) 18))
         (border (harness-board-svg--color board (or (plist-get style :stroke) "edge")))
         (inset 14)
         (lines (harness-board-svg--wrap (or (plist-get object :text) "") (- w (* 2 inset)) size))
         (spacing (* size 1.3))
         (index 0))
    (concat
     (format "<rect data-object=\"%s\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" fill=\"%s\"%s/>"
             (harness-board-svg--xml id) (harness-board-svg--number w)
             (harness-board-svg--number (plist-get shape :h))
             (or fill "none")
             (if border (format " stroke=\"%s\" stroke-width=\"1\"" border) ""))
     (format "<g data-object=\"%s\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"400\">"
             (harness-board-svg--xml (format "%s-text" id)) (or ink "currentColor")
             (harness-board-svg--number size))
     (mapconcat (lambda (line)
                  (prog1
                      (format "<text x=\"%s\" y=\"%s\" dominant-baseline=\"text-before-edge\">%s</text>"
                              (harness-board-svg--number inset)
                              (harness-board-svg--number (+ inset (* spacing index)))
                              (harness-board-svg--xml line))
                    (cl-incf index)))
                lines "")
     "</g>")))

(defun harness-board-svg--wrap (text width size)
  "Return TEXT split into lines that fit WIDTH at SIZE, breaking at spaces.
The width of a line is estimated from its characters, which is what a
renderer without a font can know; a line is allowed a few percent over
the estimate rather than orphaning the word that just misses, which is
what made the sketch's notes read badly.  Words longer than a line are
kept whole: clipping is the person's call, and an estimate that silently
truncates would be a lie about the text."
  (let ((per-char (* 0.58 size))
        (room (* width 1.04))
        (lines nil))
    (dolist (paragraph (split-string (or text "") "\n"))
      (let ((current ""))
        (dolist (word (split-string paragraph " +"))
          (if (string-empty-p current)
              (setq current word)
            (if (<= (* per-char (+ (length current) 1 (length word))) room)
                (setq current (concat current " " word))
              (push current lines)
              (setq current word))))
        (push current lines)))
    (nreverse lines)))

(defconst harness-board-svg--tab-height 30
  "Units a framed region's title tab takes above the frame's own top line.")

(defun harness-board-svg--frame (board object view)
  "Return the SVG for a framed region OBJECT in VIEW: a muted frame, a title tab.
The tab sits on the frame's own top-left corner, its text on the tab's
baseline, and the title is aligned with the frame's left line: the
design's cleanup of the sketch's floating label."
  (let* ((id (plist-get object :id))
         (shape (plist-get view :shape))
         (style (plist-get view :style))
         (w (plist-get shape :w))
         (h (plist-get shape :h))
         (fill (harness-board-svg--color board (or (plist-get style :fill) "frame")))
         (stroke (harness-board-svg--color board (or (plist-get style :stroke) "edge")))
         (cap (harness-board-svg--color board (or (plist-get style :cap) "accent")))
         (ink (harness-board-svg--color board (or (plist-get style :textColor) "ink")))
         (title (or (plist-get object :name) ""))
         ;; The words on the tab are read on the accent, not on the ink the
         ;; rest of the drawing is set in.
         (tab-ink (or (harness-board-svg--on-cap board cap) ink))
         (size (or (plist-get style :fontSize) 19))
         (tab-width (max 24 (* 0.62 size (length title))))
         (tab-height (* size 1.7)))
    (concat
     (format "<rect data-object=\"%s\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/>"
             (harness-board-svg--xml id) (harness-board-svg--number w)
             (harness-board-svg--number h) (or fill "none") (or stroke "none"))
     ;; The tab is the frame's own corner: it starts where the frame starts.
     (format "<rect data-object=\"%s-tab\" x=\"0\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1\"/>"
             (harness-board-svg--xml id)
             (harness-board-svg--number (- tab-height))
             (harness-board-svg--number tab-width)
             (harness-board-svg--number tab-height)
             (or cap "none") (or tab-ink "none"))
     (format "<text data-object=\"%s-title\" x=\"%s\" y=\"%s\" dominant-baseline=\"text-before-edge\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"500\">%s</text>"
             (harness-board-svg--xml id)
             (harness-board-svg--number 8)
             (harness-board-svg--number (- (* tab-height 0.68)))
             (or tab-ink "currentColor") (harness-board-svg--number size)
             (harness-board-svg--xml title)))))

(defun harness-board-svg--component (board object view)
  "Return the SVG for a component OBJECT in VIEW: a box, a cap and a name.
The box is a plain square-cornered card with a thick top cap, which is
the treatment the themes share; the name and its detail share one left
padding and one baseline grid."
  (let* ((id (plist-get object :id))
         (shape (plist-get view :shape))
         (style (plist-get view :style))
         (w (plist-get shape :w))
         (h (plist-get shape :h))
         (card (harness-board-svg--color board (or (plist-get style :fill) "card")))
         (stroke (harness-board-svg--color board (or (plist-get style :stroke) "edge")))
         (cap (harness-board-svg--color board (or (plist-get style :cap) "accent")))
         (ink (harness-board-svg--color board (or (plist-get style :textColor) "ink")))
         (muted (harness-board-svg--color board "muted"))
         (size (or (plist-get style :fontSize) 22))
         (cap-height (or (plist-get style :capHeight) 9)))
    (concat
     (format "<rect data-object=\"%s\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1\"/>"
             (harness-board-svg--xml id) (harness-board-svg--number w)
             (harness-board-svg--number h) (or card "none") (or stroke "none"))
     (format "<rect data-object=\"%s-cap\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" fill=\"%s\"/>"
             (harness-board-svg--xml id) (harness-board-svg--number w)
             (harness-board-svg--number cap-height) (or cap "none"))
     (format "<text data-object=\"%s-name\" x=\"12\" y=\"%s\" dominant-baseline=\"text-before-edge\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"500\">%s</text>"
             (harness-board-svg--xml id)
             (harness-board-svg--number (+ cap-height 12))
             (or ink "currentColor") (harness-board-svg--number size)
             (harness-board-svg--xml (or (plist-get object :name) "")))
     (when (plist-get object :text)
       (format "<text data-object=\"%s-detail\" x=\"12\" y=\"%s\" dominant-baseline=\"text-before-edge\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"400\">%s</text>"
               (harness-board-svg--xml id)
               (harness-board-svg--number (+ cap-height 12 size 12))
               (or muted "currentColor") (harness-board-svg--number (max 13 (- size 4)))
               (harness-board-svg--xml (plist-get object :text))))
     ;; A locked object says so; a mirrored one does not, since a reflection
     ;; of a box is a box.
     (when (plist-get object :locked)
       (format "<text x=\"%s\" y=\"%s\" text-anchor=\"end\" fill=\"%s\" font-size=\"11\" font-family=\"Inter, sans-serif\">locked</text>"
               (harness-board-svg--number (- w 8)) (harness-board-svg--number 18)
               (or muted "currentColor"))))))

(defun harness-board-svg--marker (board object view)
  "Return the SVG for a task marker OBJECT in VIEW: a square and a label.
The label is beside the square on the same baseline, and says what the
source says now: a real status, never invented activity."
  (let* ((id (plist-get object :id))
         (style (plist-get view :style))
         (fill (harness-board-svg--color board (or (plist-get style :fill) "accent")))
         (ink (harness-board-svg--color board (or (plist-get style :textColor) "ink")))
         (status (plist-get object :source-status))
         (label (or (plist-get object :text)
                    (and status (plist-get status :label))
                    (plist-get object :name) "task"))
         (size (or (plist-get style :fontSize) 14)))
    (concat
     (format "<rect data-object=\"%s\" x=\"0\" y=\"0\" width=\"13\" height=\"13\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1\"/>"
             (harness-board-svg--xml id) (or fill "none") (or ink "none"))
     (format "<text data-object=\"%s-label\" x=\"20\" y=\"%s\" dominant-baseline=\"text-before-edge\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"500\">%s</text>"
             (harness-board-svg--xml id)
             (harness-board-svg--number (* (- 13 (* size 1.15)) 0.5))
             (or ink "currentColor") (harness-board-svg--number size)
             (harness-board-svg--xml label)))))

(defun harness-board-svg--image (board object view)
  "Return the SVG for an image OBJECT in VIEW: its name above it, no card shell."
  (let* ((id (plist-get object :id))
         (shape (plist-get view :shape))
         (style (plist-get view :style))
         (ink (harness-board-svg--color board (or (plist-get style :textColor) "muted")))
         (name (or (plist-get object :name) (plist-get shape :src) "image"))
         (size (or (plist-get style :fontSize) 15)))
    (concat
     (format "<text data-object=\"%s-name\" x=\"0\" y=\"%s\" dominant-baseline=\"text-before-edge\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"%s\" font-weight=\"500\">%s</text>"
             (harness-board-svg--xml id) (harness-board-svg--number (- (* size 1.5)))
             (or ink "currentColor") (harness-board-svg--number size)
             (harness-board-svg--xml name))
     (format "<image data-object=\"%s\" x=\"0\" y=\"0\" width=\"%s\" height=\"%s\" href=\"%s\" preserveAspectRatio=\"xMidYMid meet\"/>"
             (harness-board-svg--xml id)
             (harness-board-svg--number (plist-get shape :w))
             (harness-board-svg--number (plist-get shape :h))
             (harness-board-svg--xml (plist-get shape :src))))))

(defun harness-board-svg--object (board object view)
  "Return the SVG for OBJECT, drawn in VIEW."
  (let* ((kind (plist-get object :kind))
         (shape (plist-get view :shape))
         (style (plist-get view :style))
         (transform (harness-board-svg--matrix (plist-get view :transform))))
    (format "<g%s>%s</g>"
            (if transform (format " transform=\"%s\"" transform) "")
            (pcase kind
              ('note (if shape (harness-board-svg--note board object view) ""))
              ('frame (if shape (harness-board-svg--frame board object view) ""))
              ('component (if shape (harness-board-svg--component board object view) ""))
              ('marker (harness-board-svg--marker board object view))
              ('image (if shape (harness-board-svg--image board object view) ""))
              ('label (concat (when shape (harness-board-svg--shape board (plist-get object :id) shape style))
                              (harness-board-svg--text board (plist-get object :id) (plist-get object :text) style)))
              ('group "")
              (_ (concat (when shape (harness-board-svg--shape board (plist-get object :id) shape style))
                         (when (and (equal (plist-get shape :kind) "rect")
                                    (or (plist-get object :text)))
                           (harness-board-svg--text board (plist-get object :id) (plist-get object :text)
                                                    style))))))))

(defun harness-board-svg--connector (board relationship)
  "Return the SVG for RELATIONSHIP, a connector between two placed anchors.
The line is a straight segment when it can be, and a gentle curve when
the endpoints face away from each other; its arrow and its label follow
the theme, and the label sits above the midpoint so it never crosses a
node's text."
  (let* ((from (plist-get relationship :from-point))
         (to (plist-get relationship :to-point))
         (style (plist-get relationship :style))
         (stroke (harness-board-svg--color board (or (plist-get style :stroke) "ink")))
         (width (or (plist-get style :strokeWidth) 2))
         (dash (plist-get style :dash))
         (label (plist-get relationship :label)))
    (if (not (and from to))
        ""
      (let* ((x1 (car from)) (y1 (cdr from)) (x2 (car to)) (y2 (cdr to))
             (mid-x (/ (+ x1 x2) 2.0))
             (mid-y (/ (+ y1 y2) 2.0))
             (curve-y (- mid-y (min 40 (/ (abs (- x2 x1)) 8.0))))
             (marker (format "arrow-%s" (harness-board-svg--xml (plist-get relationship :id)))))
        (concat
         (format "<path data-relationship=\"%s\" d=\"M %s %s Q %s %s %s %s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"%s marker-end=\"url(#%s)\"/>"
                 (harness-board-svg--xml (plist-get relationship :id))
                 (harness-board-svg--number x1) (harness-board-svg--number y1)
                 (harness-board-svg--number mid-x) (harness-board-svg--number curve-y)
                 (harness-board-svg--number x2) (harness-board-svg--number y2)
                 (or stroke "currentColor") (harness-board-svg--number width)
                 (if dash (format " stroke-dasharray=\"%s\"" (harness-board-svg--xml dash)) "")
                 marker)
         (when label
           ;; The label sits above the curve's own apex, where the line
           ;; has room, in the line's colour: a label is the line's, so a
           ;; theme's ink carries both.
           (format "<text data-relationship-label=\"%s\" x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"%s\" font-family=\"Inter, Helvetica, Arial, sans-serif\" font-size=\"13\" font-weight=\"500\">%s</text>"
                   (harness-board-svg--xml (plist-get relationship :id))
                   (harness-board-svg--number mid-x)
                   (harness-board-svg--number (- curve-y 8))
                   (or stroke "currentColor")
                   (harness-board-svg--xml label))))))))

(defun harness-board-svg-defs (board relationships)
  "Return the arrow markers RELATIONSHIPS need on BOARD."
  (concat
   "<defs>"
   (mapconcat (lambda (relationship)
                (let* ((style (plist-get relationship :style))
                       (stroke (or (harness-board-svg--color board (or (plist-get style :stroke) "ink"))
                                   "currentColor")))
                  (format "<marker id=\"arrow-%s\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\"><path d=\"M1 1 L7 4 L1 7\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"/></marker>"
                          (harness-board-svg--xml (plist-get relationship :id)) stroke)))
              relationships "")
   "</defs>"))

(defun harness-board-svg--bounds (board diagram)
  "Return (X Y W H) of everything BOARD draws in DIAGRAM, with a margin."
  (let ((boxes (cl-loop for object in (plist-get board :objects)
                        for view = (harness-board--view object diagram)
                        when view
                        collect (harness-board-view-box view))))
    (if (null boxes)
        (list 0 0 1000 640)
      (let* ((xs (mapcar (lambda (b) (nth 0 b)) boxes))
             (ys (mapcar (lambda (b) (nth 1 b)) boxes))
             (rights (mapcar (lambda (b) (+ (nth 0 b) (nth 2 b))) boxes))
             (bottoms (mapcar (lambda (b) (+ (nth 1 b) (nth 3 b))) boxes))
             ;; Room for a stroke, and above a frame for its tab.
             (margin 56)
             (tab (* harness-board-svg--tab-height 2))
             (x (- (apply #'min xs) margin))
             (y (- (apply #'min ys) (+ (* 2 margin) tab)))
             (w (+ (- (apply #'max rights) (apply #'min xs)) (* 2 margin)))
             (h (+ (- (apply #'max bottoms) (apply #'min ys)) (* 2 margin) tab)))
        (list x y (max w 320) (max h 240))))))

(defun harness-board-svg (board &optional diagram title)
  "Return BOARD drawn as an SVG document, for DIAGRAM.
This is the board's own geometry rendered, not a second model of it: the
same objects, the same theme and the same placements a client draws.
TITLE is the picture's accessible name."
  (let* ((diagram (or diagram (plist-get (car (plist-get board :diagrams)) :id)))
         (place (harness-board--diagram board diagram))
         (bounds (harness-board-svg--bounds board diagram))
         (paper (or (harness-board-svg--color board "paper") "#f5f5f0"))
         (relationships (cl-loop for relationship in (plist-get board :relationships)
                                 when (equal (plist-get relationship :diagram) diagram)
                                 collect relationship))
         (placed (sort (cl-loop for object in (plist-get board :objects)
                                for view = (harness-board--view object diagram)
                                when view collect (cons object view))
                       (lambda (a b) (< (or (plist-get (cdr a) :z) 0)
                                        (or (plist-get (cdr b) :z) 0)))))
         (document (harness-board-document board diagram)))
    (format (concat "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                    "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\""
                    " viewBox=\"%s %s %s %s\" width=\"%s\" height=\"%s\" role=\"img\""
                    " aria-label=\"%s\" data-board=\"%s\" data-revision=\"%s\">"
                    "%s"
                    "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\"/>"
                    "%s"
                    "%s"
                    "<g data-layer=\"connectors\">%s</g>"
                    "</svg>")
            (harness-board-svg--number (nth 0 bounds))
            (harness-board-svg--number (nth 1 bounds))
            (harness-board-svg--number (nth 2 bounds))
            (harness-board-svg--number (nth 3 bounds))
            (harness-board-svg--number (* (nth 2 bounds) harness-board-svg-scale))
            (harness-board-svg--number (* (nth 3 bounds) harness-board-svg-scale))
            (harness-board-svg--xml (or title
                                       (format "%s · %s" (plist-get board :name)
                                               (or (plist-get place :name) diagram))))
            (harness-board-svg--xml (plist-get board :id))
            (plist-get board :revision)
            (harness-board-svg-defs board relationships)
            (harness-board-svg--number (nth 0 bounds))
            (harness-board-svg--number (nth 1 bounds))
            (harness-board-svg--number (nth 2 bounds))
            (harness-board-svg--number (nth 3 bounds))
            paper
            (mapconcat (lambda (pair)
                         (harness-board-svg--object board (car pair) (cdr pair)))
                       placed "")
            (if (plist-get (plist-get document :diagram) :selection)
                (harness-board-svg--selection document)
              "")
            (mapconcat (lambda (relationship)
                         (harness-board-svg--connector
                          board (harness-board--relationship-view board relationship)))
                       relationships ""))))

(defun harness-board-svg--selection (document)
  "Return the selection outline of DOCUMENT's diagram, or an empty string."
  (let ((selected (append (plist-get (plist-get document :diagram) :selection) nil))
        (objects (append (plist-get document :objects) nil))
        (accent (or (harness-board-svg--color document "accent") "currentColor")))
    (mapconcat
     (lambda (object)
       (when (member (plist-get object :id) selected)
         (let ((box (plist-get object :box)))
           (format "<rect data-selected=\"%s\" x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"2\" stroke-dasharray=\"6 4\"/>"
                   (harness-board-svg--xml (plist-get object :id))
                   (harness-board-svg--number (- (nth 0 box) 4))
                   (harness-board-svg--number (- (nth 1 box) 4))
                   (harness-board-svg--number (+ (nth 2 box) 8))
                   (harness-board-svg--number (+ (nth 3 box) 8))
                   accent))))
     objects "")))

(harness-define-module 'board-svg
  :doc "One renderer for a board, from its own geometry: the SVG a person sees on the Emacs page, a model is handed as a picture, and a client can show beside its live canvas."
  :requires '(board board-store))

(provide 'harness-board-svg)
;;; harness-board-svg.el ends here
