;;; harness-board.el --- The freeform agent board: a typed spatial graph  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A board is a freeform place to think: notes, authentic ink, geometric
;; shapes, architecture diagrams, connections and linked resources, laid
;; out by people and agents and left however they arranged them.  Nothing
;; here imposes a lifecycle, re-arranges a board, or reads a drawing as a
;; statement about a system.
;;
;; THE GRAMMAR.  A board is a typed, attributed spatial graph.  Its
;; semantic objects -- a component, a question, a task marker, a label --
;; have ids and histories of their own.  Each diagram holds a view of an
;; object: local geometry, a placement matrix, a style and a layer.  One
;; object may appear in several diagrams, which is what a drill-down or a
;; portal is, without a second meaning.  Relationships (connectors) are
;; objects of their own, with endpoints that name an object and a named
;; local anchor.
;;
;; Every shape is a primitive: `rect', `ellipse', `polygon', a finite
;; `path' of line, Bezier and quadratic segments, `text' and `image', plus
;; `raw' ink, which is a path a person drew and the renderer does not
;; smooth.  Compositions -- a sticky note, a title tab, a framed region, a
;; task marker -- are ordinary shapes with ordinary styles.  A theme is a
;; palette that resolves style roles; it adds no drawing power, and no
;; renderer has a primitive the grammar lacks.
;;
;; THE EDITS.  Nothing is implicit.  `board/patch' validates an ordered
;; array of operations against the document as it will be after the
;; operations before it and returns a patch: expanded operations, created
;; and changed ids, the preimages it replaced and diagnostics.  It changes
;; nothing.  `board/preview' renders that exact batch.  `board/commit'
;; applies a validated patch atomically, checking the read set it was made
;; against and revalidating against the current document, with an
;; idempotency key so a retried call after a lost answer commits once.
;; `board/undo' is a compensating edit built from the preimages the commit
;; kept: it preserves what others changed since and reports those objects
;; as conflicts instead of overwriting them.
;;
;; THE NUMBERS.  Coordinates are x right and y down, in canvas units;
;; angles are clockwise degrees.  A placement is the six numbers of an
;; affine matrix [a b c d e f], as SVG writes them.  A matrix whose
;; determinant is (near) zero, a non-finite number, or a number past
;; `harness-board-max-coordinate' is refused (`harness-board--number').
;; Scale is positive; a reflection is an explicit operation.
;;
;; WHAT IS NOT HERE.  No automatic search, candidate ranking, search
;; budget, goal predicate, branch lifecycle or rule engine: agents and
;; people make explicit edits.  No recognition of emergent subshapes in
;; overlapping drawings, and no completeness claim for continuous
;; geometry.  Attachment is explicit anchor matching, in a documented
;; order (`harness-board--attach-matrix').
;;
;; THE STORE.  Boards live in `harness-state-directory/boards/', one JSON
;; document each, written atomically.  Client view state -- the viewport,
;; selection and last focus request -- is a separate document, so
;; navigating a board makes no revision.  Undo history is bounded and kept
;; in the board document, so it survives a restart.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defgroup harness-board nil
  "The freeform agent board."
  :group 'harness)

(defconst harness-board-schema 1
  "Version of the board document schema.
A stored document of another version is refused, never half-read.")

(defconst harness-board-history-limit 200
  "How many commits a board keeps for undo, the newest.")

(defcustom harness-board-max-coordinate 1000000
  "Largest absolute coordinate, size or matrix number an edit may use.
A finite number past it is refused rather than drawn off the canvas."
  :type 'integer :group 'harness)

(defcustom harness-board-movement-budget 4000
  "Default distance, in canvas units, one object may move in one patch.
An op may set a smaller budget of its own."
  :type 'number :group 'harness)

(defconst harness-board-themes
  '((electric-commons
     (paper . "#f5f5f0") (ink . "#25272c") (frame . "#e8e8ef") (edge . "#55545f")
     (card . "#fffef7") (muted . "#4d5058") (accent . "#c5ff54") (accent-soft . "#e8ffb0")
     (note . "#ffc4d2") (note-soft . "#ffe4ea") (violet . "#b3a0ff") (danger . "#ff6589")
     (group . "#eceee7"))
    (open-labels
     (paper . "#fbfbf8") (ink . "#20232a") (frame . "#eeeef2") (edge . "#52525c")
     (card . "#fffef7") (muted . "#5b5e66") (accent . "#c5ff54") (accent-soft . "#eefdc8")
     (note . "#ffd3dc") (note-soft . "#ffe9ee") (violet . "#bcaeff") (danger . "#ff6589")
     (group . "#f0f1eb"))
    (night-commons
     (paper . "#17191d") (ink . "#f0f1e8") (frame . "#25282f") (edge . "#6f7280")
     (card . "#30343c") (muted . "#c8cbd0") (accent . "#c4f46b") (accent-soft . "#3d4f2a")
     (note . "#522d40") (note-soft . "#3c2431") (violet . "#b6a2ff") (danger . "#ff6e8e")
     (group . "#22252b")))
  "The themes a board may wear, as resolved palette roles.
A theme is a palette only: every style role it fills is one `paint'
validates, so a theme can never draw what an edit could not.")

(defconst harness-board-style-roles
  '(fill stroke cap textColor frame)
  "The style keys an object view may set.")

(defconst harness-board-color-roles
  '("none" "paper" "ink" "frame" "edge" "card" "muted" "group"
    "accent" "accent-soft" "note" "note-soft" "violet" "danger")
  "The colours a style role may name, or a literal #rrggbb.")

(defconst harness-board-object-kinds
  '((note . "a sticky note: a rect with a note fill and its text")
    (component . "a box of a system: a rect, a cap and a name")
    (label . "words on their own")
    (frame . "a muted framed region with a small title tab")
    (marker . "a small task marker square with a text label")
    (shape . "geometry of its own: a rect, ellipse, polygon or path")
    (ink . "raw ink: a path drawn by a person, never smoothed")
    (path . "a precise finite path")
    (image . "an image, its name above it, and no card shell")
    (group . "members that move and layer together")
    (connector . "a relationship between two anchors"))
  "The kinds of object a view may hold, and what each is.")

(defconst harness-board-resource-kinds
  '((task . "a harness task") (message . "a message of a session")
    (call . "a tool call of a session") (thread . "a thread of a task's review")
    (diagram . "another diagram of this or another board")
    (board . "another board") (document . "a file or document")
    (symbol . "a code symbol at a revision")
    (screen . "a computer's screen-share moment"))
  "The kinds of resource an object or relationship may link, and what each is.")

(defconst harness-board-evidence-roles
  '((observed . "seen in the code or the system") (declared . "stated intent")
    (proposed . "a proposal, not yet true") (unknown . "nobody knows yet"))
  "The roles an object's or relationship's claim may have.
A drawing distinguishes what was observed from what is only proposed;
proximity alone asserts no architectural meaning.")

(defconst harness-board-op-kinds
  '((create . "a new object with its first view")
    (view.add . "the same object in another diagram")
    (view.remove . "one representation, not the object")
    (set-shape . "control points or a size")
    (set-transform . "a placement matrix")
    (move . "a translation, inside its budget")
    (transform . "rotate, scale, reflect or affine about a pivot")
    (set-style . "paint roles")
    (set-text . "the words of an object")
    (set-name . "the name of an object")
    (set-role . "observed, declared, proposed or unknown")
    (lock . "a hard constraint on an object's geometry")
    (group . "members that move together")
    (ungroup . "members keep their identity")
    (attach . "a child's anchor onto a parent's anchor")
    (connect . "a relationship between anchors")
    (relate . "precise resource links")
    (layer . "the order in a diagram")
    (detach . "one view made an object of its own")
    (delete . "an object, its views and its relationships")
    (set-theme . "the palette the whole board wears")
    (set-board-name . "what the board is called")
    (diagram.add . "another diagram on the board")
    (diagram.parent . "the diagram a diagram is walked into from")
    (diagram.portals . "every portal of a diagram, replaced whole")
    (diagram.portal . "one portal added or taken away: a place to walk into")
    (select . "what a diagram has selected, which changes no drawing")
    (viewport . "where a diagram is looked at from, which changes no drawing"))
  "The operations `scene.edit' accepts, and what each does.
This is what `board/grammar' answers with, so an agent reads the same list
an edit is held to; `restore' is undo's own and is not here, since it
carries the preimage of a commit rather than an edit of its own.")

(defconst harness-board-error-kinds
  '((invalid-parameter . "a number or a field an operation cannot use")
    (unknown-id . "an object, diagram, relationship or patch that is not there")
    (stale-revision . "the document moved since the caller read it")
    (unsupported-operation . "an operation or a shape this grammar lacks")
    (precondition . "an operation that does not fit its object")
    (hard-constraint . "a lock, a scope, a budget or a declared rule")
    (invalid-reference . "a resource or an endpoint that names nothing")
    (permission . "the session may not write this board"))
  "The distinct ways a board operation is refused.")

(define-error 'harness-board-error "Board error")

(defun harness-board--fail (kind fmt &rest args)
  "Signal a board error of KIND with FMT and ARGS.
KIND is one of `harness-board-error-kinds'."
  (signal 'harness-board-error
          (list (cons kind (apply #'format fmt args)))))

(defun harness-board--error-payload (err)
  "Return (KIND . MESSAGE) of ERR, a caught board error, or nil.
`harness-board--fail' signals the pair as the error's one datum, so the
condition `condition-case' hands back is (harness-board-error (KIND .
MESSAGE)); a caller that re-signals the data gives (harness-board-error
KIND MESSAGE), which reads the same here."
  (when (and (consp err) (eq (car err) 'harness-board-error))
    (let ((data (cdr err)))
      (cond
       ((and (consp data) (consp (car data)) (symbolp (caar data)))
        (car data))
       ((and (consp data) (symbolp (car data)))
        (cons (car data) (and (stringp (cadr data)) (cadr data))))))))

(defun harness-board-error-kind (err)
  "Return the kind of ERR, a caught board error, or nil."
  (car (harness-board--error-payload err)))

(defun harness-board-error-message (err)
  "Return the message of ERR, a caught board error."
  (or (cdr (harness-board--error-payload err))
      (harness-error-message err)))

(defun harness-board-error-plist (err)
  "Return ERR, a caught board error, as a plist for a tool result."
  (list :error (or (harness-board-error-kind err) 'unknown)
        :message (harness-board-error-message err)))

;;;; Numbers, matrices and geometry

(defun harness-board--number (value &optional what)
  "Return VALUE as a finite bounded number, or refuse it.
WHAT names the value in the refusal.  A string that reads as a number is
taken as one, since JSON carries both."
  (let ((n (cond ((numberp value) value)
                 ((and (stringp value)
                       (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\(?:[eE][-+]?[0-9]+\\)?\\'" value))
                  (string-to-number value))
                 (t nil))))
    (unless (numberp n)
      (harness-board--fail 'invalid-parameter "%s is not a number: %S" (or what "value") value))
    (unless (and (numberp n)
                 (not (and (floatp n) (not (= n n))))
                 (not (and (floatp n) (>= (abs n) 1e308))))
      (harness-board--fail 'invalid-parameter "%s is not finite: %S" (or what "value") value))
    (when (> (abs n) harness-board-max-coordinate)
      (harness-board--fail 'invalid-parameter "%s is past the limit of %s: %S"
                           (or what "value") harness-board-max-coordinate value))
    n))

(defun harness-board--positive (value &optional what)
  "Return VALUE as a positive finite number, or refuse it."
  (let ((n (harness-board--number value what)))
    (unless (> n 0)
      (harness-board--fail 'invalid-parameter "%s must be positive: %S" (or what "value") value))
    n))

(defconst harness-board-identity (vector 1 0 0 1 0 0)
  "The matrix that places a shape at its own origin.")

(defun harness-board--matrix (value &optional what)
  "Return VALUE as an affine matrix (a vector of six numbers), or refuse it.
A matrix whose determinant is (nearly) zero collapses the plane and is
refused: a zero scale has no inverse and no human reading."
  (let* ((list (cond ((vectorp value) (append value nil))
                     ((listp value) value)
                     (t nil)))
         (what (or what "transform")))
    (unless (and list (= (length list) 6))
      (harness-board--fail 'invalid-parameter "%s must be six numbers [a b c d e f]: %S" what value))
    (let ((m (vconcat (cl-loop for v in list for i from 0
                               collect (harness-board--number v (format "%s[%d]" what i))))))
      (let ((det (- (* (aref m 0) (aref m 3)) (* (aref m 1) (aref m 2)))))
        (unless (> (abs det) 1e-9)
          (harness-board--fail 'invalid-parameter
                               "%s is singular (determinant %s): a zero or collapsed scale is refused"
                               what det)))
      m)))


(defun harness-board-matrix-multiply (m n)
  "Return the matrix of applying N and then M, both six-number vectors."
  (vector (+ (* (aref m 0) (aref n 0)) (* (aref m 2) (aref n 1)))
          (+ (* (aref m 1) (aref n 0)) (* (aref m 3) (aref n 1)))
          (+ (* (aref m 0) (aref n 2)) (* (aref m 2) (aref n 3)))
          (+ (* (aref m 1) (aref n 2)) (* (aref m 3) (aref n 3)))
          (+ (* (aref m 0) (aref n 4)) (* (aref m 2) (aref n 5)) (aref m 4))
          (+ (* (aref m 1) (aref n 4)) (* (aref m 3) (aref n 5)) (aref m 5))))

(defun harness-board-matrix-apply (m x y)
  "Return the point (X, Y) in the frame of a shape placed by M."
  (cons (+ (* (aref m 0) x) (* (aref m 2) y) (aref m 4))
        (+ (* (aref m 1) x) (* (aref m 3) y) (aref m 5))))

(defun harness-board-matrix-translation (dx dy)
  "Return the matrix translating by DX and DY."
  (vector 1 0 0 1 dx dy))

(defun harness-board-matrix-rotation (degrees)
  "Return the matrix rotating DEGREES clockwise about the origin.
Y points down, so a positive angle turns as a clock's hands do."
  (let* ((radians (* degrees (/ float-pi 180)))
         (c (cos radians)) (s (sin radians)))
    (vector c s (- s) c 0 0)))

(defun harness-board-matrix-scale (sx sy)
  "Return the matrix scaling by SX and SY, both positive."
  (vector sx 0 0 sy 0 0))

(defun harness-board-matrix-reflection (axis)
  "Return the matrix reflecting across AXIS, `x', `y' or a direction (UX . UY).
Y points down, so reflecting across `x' turns a shape over as a mirror
in water does."
  (pcase axis
    ('x (vector 1 0 0 -1 0 0))
    ('y (vector -1 0 0 1 0 0))
    (`(,ux . ,uy)
     (let* ((len (sqrt (+ (* ux ux) (* uy uy))))
            (nx (if (> len 0) (/ ux len) 1.0))
            (ny (if (> len 0) (/ uy len) 0.0)))
       (vector (- (* 2 nx nx) 1) (* 2 nx ny) (* 2 nx ny) (- (* 2 ny ny) 1) 0 0)))
    (_ (harness-board--fail 'invalid-parameter "a reflection axis is x, y or a direction: %S" axis))))

(defun harness-board-matrix-about (m pivot)
  "Return M applied about PIVOT (X . Y) rather than about the origin."
  (let ((px (car pivot)) (py (cdr pivot)))
    (harness-board-matrix-multiply
     (harness-board-matrix-multiply (harness-board-matrix-translation px py) m)
     (harness-board-matrix-translation (- px) (- py)))))

(defun harness-board-matrix-inverse (m)
  "Return the inverse of M, or nil when M is singular."
  (let* ((a (aref m 0)) (b (aref m 1)) (c (aref m 2)) (d (aref m 3))
         (e (aref m 4)) (f (aref m 5))
         (det (- (* a d) (* b c))))
    (when (> (abs det) 1e-12)
      (let ((ia (/ d det)) (ib (/ (- b) det)) (ic (/ (- c) det)) (id (/ a det)))
        (vector ia ib ic id
                (- (+ (* ia e) (* ic f)))
                (- (+ (* ib e) (* id f))))))))

(defun harness-board-matrix-reflects-p (m)
  "Non-nil when M turns a shape over: its determinant is negative."
  (< (- (* (aref m 0) (aref m 3)) (* (aref m 1) (aref m 2))) 0))

(defun harness-board-matrix-scale-of (m)
  "Return the (SX . SY) scale M applies to the axes."
  (cons (sqrt (+ (* (aref m 0) (aref m 0)) (* (aref m 1) (aref m 1))))
        (sqrt (+ (* (aref m 2) (aref m 2)) (* (aref m 3) (aref m 3))))))

(defun harness-board--point (value &optional what)
  "Return VALUE, a two-number point, as (X . Y), or refuse it.
A point arrives as a JSON array ([x y]), a two-element list or a cons
\(x . y), since a caller that computed one of the board's own anchors
passes the cons it read."
  (let* ((list (cond ((vectorp value) (append value nil))
                     ((and (consp value) (not (listp (cdr value))))
                      (list (car value) (cdr value)))
                     ((listp value) value)
                     (t nil)))
         (what (or what "point")))
    (unless (and list (= (length list) 2))
      (harness-board--fail 'invalid-parameter "%s must be two numbers [x y]: %S" what value))
    (cons (harness-board--number (nth 0 list) (format "%s[0]" what))
          (harness-board--number (nth 1 list) (format "%s[1]" what)))))

;;;; Shape validation

(defconst harness-board-shape-kinds
  '("rect" "ellipse" "polygon" "path" "text" "image")
  "The primitive shapes a view's geometry may be.")

(defconst harness-board-path-commands
  '("M" "L" "C" "Q" "Z")
  "The segments a finite path may hold, with the numbers each takes.
M and L take a point, C two control points and a point, Q one control
point and a point, Z nothing.")

(defun harness-board--path-commands ()
  "Return the arity of each path command."
  '(("M" . 2) ("L" . 2) ("C" . 6) ("Q" . 4) ("Z" . 0)))

(defun harness-board--segments (value)
  "Return VALUE, a list of path segments, validated and normalised."
  (unless (and (listp value) value)
    (harness-board--fail 'invalid-parameter "a path needs at least one segment: %S" value))
  (let ((arity (harness-board--path-commands))
        (out nil)
        (first t))
    (dolist (segment value)
      (unless (and (listp segment) (stringp (car segment)))
        (harness-board--fail 'invalid-parameter "a path segment is [\"M\", x, y]: %S" segment))
      (let* ((command (upcase (car segment)))
             (count (cdr (assoc command arity))))
        (unless count
          (harness-board--fail 'unsupported-operation
                               "a path segment is M, L, C, Q or Z, not %s" (car segment)))
        (unless (= (length (cdr segment)) count)
          (harness-board--fail 'invalid-parameter
                               "a %s segment takes %d numbers, not %d: %S"
                               command count (length (cdr segment)) segment))
        (when (and first (not (equal command "M")))
          (harness-board--fail 'invalid-parameter "a path starts with M: %S" segment))
        (setq first nil)
        (push (cons command
                    (cl-loop for v in (cdr segment)
                             collect (harness-board--number v (format "path %s" command))))
              out)))
    (nreverse out)))

(defun harness-board--shape (shape)
  "Return SHAPE, a primitive geometry, validated and normalised."
  (unless (listp shape)
    (harness-board--fail 'invalid-parameter "a shape is an object with a kind: %S" shape))
  (let ((kind (harness-board--string (plist-get shape :kind) "shape kind")))
    (unless (member kind harness-board-shape-kinds)
      (harness-board--fail 'unsupported-operation
                           "shape kind %s is not one of %s" kind
                           (string-join harness-board-shape-kinds ", ")))
    (let ((out (list :kind kind)))
      (pcase kind
        ("rect" (setq out (append out (list :w (harness-board--positive (plist-get shape :w) "rect w")
                                            :h (harness-board--positive (plist-get shape :h) "rect h")))))
        ("image" (setq out (append out (list :w (harness-board--positive (plist-get shape :w) "image w")
                                             :h (harness-board--positive (plist-get shape :h) "image h")
                                             :src (harness-board--string (plist-get shape :src) "image src")))))
        ("ellipse" (setq out (append out (list :rx (harness-board--positive (plist-get shape :rx) "ellipse rx")
                                               :ry (harness-board--positive (plist-get shape :ry) "ellipse ry")))))
        ("polygon"
         (let ((points (plist-get shape :points)))
           (unless (and (listp points) (>= (length points) 3))
             (harness-board--fail 'invalid-parameter "a polygon needs three points or more: %S" points))
           (setq out (append out (list :points
                                       (vconcat (mapcar (lambda (p)
                                                          (let ((pt (harness-board--point p "polygon point")))
                                                            (vector (car pt) (cdr pt))))
                                                        points)))))))
        ("path" (setq out (append out (list :segments (harness-board--segments (plist-get shape :segments))
                                            :raw (and (harness-board--truthy (plist-get shape :raw)) t)
                                            :closed (and (harness-board--truthy (plist-get shape :closed)) t)))))
        ("text" (setq out (append out (list :text (or (harness-board--string (plist-get shape :text) "text") "")
                                            :size (harness-board--positive (or (plist-get shape :size) 18)
                                                                           "text size"))))))
      out)))

(defun harness-board--truthy (value)
  "Return non-nil when VALUE is a JSON or Lisp truth."
  (and value (not (eq value :false)) (not (equal value "false"))))

(defun harness-board--string (value &optional what)
  "Return VALUE as a string, or nil when it is nothing.
Refuse a value that is neither.  A keyword reads as its name, so that a
plist key and a JSON key mean the same thing."
  (cond ((null value) nil)
        ((stringp value) value)
        ((eq value :false) nil)
        ((keywordp value) (substring (symbol-name value) 1))
        ((or (numberp value) (symbolp value)) (format "%s" value))
        (t (harness-board--fail 'invalid-parameter "%s must be text: %S" (or what "value") value))))

;;;; Styles

(defun harness-board--color (value &optional what)
  "Return VALUE as a colour role or a literal #rrggbb, or refuse it."
  (let ((text (harness-board--string value)))
    (cond ((null text) nil)
          ((member text harness-board-color-roles) text)
          ((string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\(?:[0-9a-fA-F]\\{2\\}\\)?\\'" text) text)
          (t (harness-board--fail 'invalid-parameter
                                  "%s is not a colour role (%s) or #rrggbb: %S"
                                  (or what "colour")
                                  (string-join harness-board-color-roles ", ")
                                  value)))))

(defun harness-board--style (style)
  "Return STYLE, a view's paint, validated.
An unknown style key is refused: `grammar.describe' is the only list of
styles there is, and a theme cannot smuggle in another one."
  (let (out)
    (cl-loop for (key value) on style by #'cddr
             do (pcase key
                  ((or :fill :stroke :cap :frame)
                   (setq out (plist-put out key (harness-board--color value (format "%s" key)))))
                  (:textColor
                   (setq out (plist-put out :textColor (harness-board--color value "textColor"))))
                  (:strokeWidth
                   (setq out (plist-put out :strokeWidth (harness-board--number value "strokeWidth"))))
                  (:fontSize
                   (setq out (plist-put out :fontSize (harness-board--positive value "fontSize"))))
                  (:dash
                   (setq out (plist-put out :dash
                                        (and value
                                             (if (stringp value)
                                                 (unless (string-match-p "\\`[0-9 .]+\\(?:[0-9.]\\)\\'" value)
                                                   (harness-board--fail
                                                    'invalid-parameter "a dash is numbers: %S" value))
                                               (mapconcat (lambda (v)
                                                            (format "%s" (harness-board--positive v "dash")))
                                                          (if (listp value) value (list value)) " "))))))
                  (:fontWeight
                   (setq out (plist-put out :fontWeight
                                        (let ((n (harness-board--number value "fontWeight")))
                                          (unless (memq n '(300 400 500 600 700))
                                            (harness-board--fail 'invalid-parameter
                                                                 "fontWeight is 300 to 700, not %s" n))
                                          n))))
                  (_ (harness-board--fail 'invalid-parameter
                                          "unknown style key %s; the style keys are %s"
                                          key (string-join (mapcar #'symbol-name
                                                                   harness-board-style-roles)
                                                           ", ")))))
    out))

(defun harness-board--anchors (anchors)
  "Return ANCHORS, named local points, validated."
  (let (out)
    (cl-loop for (name point) on anchors by #'cddr
             do (let ((key (harness-board--string name "anchor name"))
                      (pt (harness-board--point point (format "anchor %s" name))))
                  (unless (and key (string-match-p "\\`[A-Za-z][A-Za-z0-9_.-]*\\'" key))
                    (harness-board--fail 'invalid-parameter
                                         "an anchor name is letters, digits, dots and dashes: %S" name))
                  (setq out (plist-put out (intern (concat ":" key)) (vector (car pt) (cdr pt))))))
    out))

;;;; Ids and diagrams

(defun harness-board--id (value &optional what)
  "Return VALUE as an id, or refuse it."
  (let ((text (harness-board--string value (or what "id"))))
    (unless (and text (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.:-]*\\'" text))
      (harness-board--fail 'invalid-parameter
                           "%s is letters, digits and .:- : %S" (or what "id") value))
    text))

(defun harness-board-new-id (prefix)
  "Return a fresh id that starts with PREFIX."
  (format "%s-%s" prefix (harness-short-id 8)))

(defun harness-board--diagram (board diagram)
  "Return the diagram of BOARD named DIAGRAM, or nil."
  (cl-find (harness-board--string diagram) (plist-get board :diagrams)
           :key (lambda (d) (plist-get d :id)) :test #'equal))

(defun harness-board--diagram! (board diagram)
  "Return the diagram of BOARD named DIAGRAM, or refuse it.
A caller that needs the diagram to exist says so; a caller that adds one
asks for it with `harness-board--diagram' and refuses a duplicate."
  (or (harness-board--diagram board diagram)
      (harness-board--fail 'unknown-id "no diagram %s in this board" diagram)))

(defun harness-board--diagram-ids (board)
  "Return the ids of the diagrams of BOARD."
  (mapcar (lambda (d) (plist-get d :id)) (plist-get board :diagrams)))

(defun harness-board--object (board id)
  "Return the object of BOARD named ID, or nil."
  (cl-find id (plist-get board :objects) :key (lambda (o) (plist-get o :id)) :test #'equal))

(defun harness-board--object! (board id)
  "Return the object of BOARD named ID, or refuse it."
  (or (harness-board--object board id)
      (harness-board--fail 'unknown-id "no object %s in this board" id)))

(defun harness-board--relationship (board id)
  "Return the relationship of BOARD named ID, or nil."
  (cl-find id (plist-get board :relationships) :key (lambda (r) (plist-get r :id)) :test #'equal))

(defun harness-board--relationship! (board id)
  "Return the relationship of BOARD named ID, or refuse it."
  (or (harness-board--relationship board id)
      (harness-board--fail 'unknown-id "no relationship %s in this board" id)))

(defun harness-board--view (object diagram)
  "Return the view of OBJECT in DIAGRAM, or nil."
  (let ((views (plist-get object :views)))
    (cond ((null views) nil)
          ((and (consp views) (keywordp (car views))) (plist-get views (intern (concat ":" diagram))))
          (t (cdr (assoc diagram views))))))

(defun harness-board--set-view (object diagram view)
  "Return OBJECT with its view in DIAGRAM set to VIEW."
  (let ((views (copy-sequence (plist-get object :views))))
    (setq views (plist-put views (intern (concat ":" diagram)) view))
    (plist-put (copy-sequence object) :views views)))

(defun harness-board--object-views (object)
  "Return (DIAGRAM . VIEW) for every view of OBJECT.
A document keeps the views as a plist keyed by diagram; an operation may
hand an object whose views are still the (DIAGRAM . VIEW) alist it read,
so both shapes are read here."
  (let ((views (plist-get object :views)))
    (cond
     ((null views) nil)
     ((and (consp views) (keywordp (car views)))
      (cl-loop for (k v) on views by #'cddr
               collect (cons (substring (symbol-name k) 1) v)))
     ((stringp (car-safe (car views))) views)
     (t nil))))

;;;; A board, from the wire

(defun harness-board-blank (id name &optional project)
  "Return a new empty board named NAME with id ID.
PROJECT groups it with a project's other boards, or is nil."
  (list :schema harness-board-schema
        :id (harness-board--id id "board id")
        :name (or (harness-board--string name) id)
        :project (and project (harness-board--string project))
        :theme "electric-commons"
        :revision 0
        :created (harness-now)
        :updated (harness-now)
        :diagrams (list (list :id "d-overview" :name "overview" :parent nil
                              :viewport (list :x 0 :y 0 :zoom 1)
                              :selection nil :portals nil))
        :objects nil
        :relationships nil
        :history nil))

(defun harness-board--normalise-diagram (diagram)
  "Return DIAGRAM, validated, as the document keeps it."
  (unless (listp diagram)
    (harness-board--fail 'invalid-parameter "a diagram is an object: %S" diagram))
  (let* ((viewport (plist-get diagram :viewport))
         (x (harness-board--number (or (plist-get viewport :x) 0) "viewport x"))
         (y (harness-board--number (or (plist-get viewport :y) 0) "viewport y"))
         (zoom (harness-board--positive (or (plist-get viewport :zoom) 1) "viewport zoom")))
    (when (> zoom 16)
      (harness-board--fail 'invalid-parameter "viewport zoom is 16 or less: %S" zoom))
    (list :id (harness-board--id (plist-get diagram :id) "diagram id")
          :name (or (harness-board--string (plist-get diagram :name)) "diagram")
          :parent (and (plist-get diagram :parent)
                       (harness-board--id (plist-get diagram :parent) "diagram parent"))
          :viewport (list :x x :y y :zoom zoom)
          :selection (vconcat (mapcar (lambda (id) (harness-board--id id "selection"))
                                      (if (listp (plist-get diagram :selection))
                                          (plist-get diagram :selection)
                                        (append (plist-get diagram :selection) nil))))
          :portals (vconcat
                    (mapcar (lambda (portal)
                              (list :from (harness-board--id (plist-get portal :from) "portal from")
                                    :diagram (harness-board--id (plist-get portal :diagram) "portal diagram")))
                            (if (listp (plist-get diagram :portals))
                                (plist-get diagram :portals)
                              (append (plist-get diagram :portals) nil)))))))

(defun harness-board-normalise (board)
  "Return BOARD, a document from the wire or the store, validated.
A document of another schema version is refused."
  (unless (listp board)
    (harness-board--fail 'invalid-parameter "a board is an object: %S" board))
  (let ((schema (or (plist-get board :schema) harness-board-schema)))
    (unless (equal schema harness-board-schema)
      (harness-board--fail 'unsupported-operation
                           "board schema %s; this harness reads schema %s"
                           schema harness-board-schema)))
  (let* ((theme (or (harness-board--string (plist-get board :theme)) "electric-commons"))
         (diagrams (mapcar #'harness-board--normalise-diagram
                           (or (plist-get board :diagrams) nil)))
         (pages (plist-get board :pages)))
    (unless (assoc (intern theme) harness-board-themes)
      (harness-board--fail 'invalid-parameter
                           "theme %s is not one of %s"
                           theme (string-join (mapcar #'symbol-name (mapcar #'car harness-board-themes)) ", ")))
    (unless diagrams
      (harness-board--fail 'invalid-parameter "a board has at least one diagram"))
    (list :schema harness-board-schema
          :id (harness-board--id (plist-get board :id) "board id")
          :name (or (harness-board--string (plist-get board :name)) "board")
          :project (harness-board--string (plist-get board :project))
          :theme theme
          :revision (let ((r (or (plist-get board :revision) 0)))
                      (unless (and (integerp r) (>= r 0))
                        (harness-board--fail 'invalid-parameter "revision is a whole number: %S" r))
                      r)
          :created (or (plist-get board :created) (harness-now))
          :updated (or (plist-get board :updated) (harness-now))
          :diagrams diagrams
          :objects (mapcar #'harness-board--normalise-object
                           (if (listp (plist-get board :objects))
                               (plist-get board :objects)
                             (append (plist-get board :objects) nil)))
          :relationships (mapcar #'harness-board--normalise-relationship
                                 (if (listp (plist-get board :relationships))
                                     (plist-get board :relationships)
                                   (append (plist-get board :relationships) nil)))
          :history (harness-board--normalise-history (plist-get board :history))
          :keys (harness-board--normalise-keys (plist-get board :keys))
          :writers (when-let* ((writers (plist-get board :writers)))
                     (vconcat (mapcar (lambda (one) (harness-board--string one "writer"))
                                      (if (listp writers) writers (append writers nil)))))
          :pages (when (listp pages) pages))))

(defun harness-board-normalise-document (board)
  "Return BOARD, normalised as `harness-board-normalise' does, and checked.
Every view, portal, relationship endpoint and selection the document
holds names something the document has: a stored board cannot keep a
reference to an object somebody deleted, and a document from the wire is
held to the same rule before anything is written."
  (let ((document (harness-board-normalise board)))
    (harness-board--check-references document)
    document))

(defun harness-board--normalise-history (history)
  "Return HISTORY, the commits a board remembers, validated.
A commit keeps the preimages and postimages undo compares, so those
entries are normalised like the document's own: what a commit left in
memory and what a later process reads back from the file are then the
same value, and undo compares like with like."
  (vconcat
   (cl-loop for entry in (if (listp history) history (append history nil))
            when (listp entry)
            collect (list :revision (plist-get entry :revision)
                          :patch (harness-board--string (plist-get entry :patch))
                          :time (plist-get entry :time)
                          :preimages (harness-board--normalise-image
                                      (plist-get entry :preimages))
                          :postimages (harness-board--normalise-image
                                       (plist-get entry :postimages))
                          :created (vconcat (mapcar (lambda (id)
                                                      (harness-board--id id "created id"))
                                                    (append (plist-get entry :created) nil)))
                          :changed (vconcat (mapcar (lambda (id)
                                                      (harness-board--id id "changed id"))
                                                    (append (plist-get entry :changed) nil)))))))

(defun harness-board--normalise-image (image)
  "Return IMAGE, a commit's (ID ENTRY ...) record, normalised."
  (if (null image)
      nil
    (cl-loop for (key entry) on (if (listp image) image (append image nil)) by #'cddr
             append (list key (harness-board--normalise-entry entry)))))

(defun harness-board--normalise-entry (entry)
  "Return ENTRY of a history image, normalised, or as it is when it names none."
  (cond
   ((null entry) nil)
   ((not (listp entry)) entry)
   ((plist-member entry :absent) entry)
   ((plist-get entry :views)
    (condition-case nil (harness-board--normalise-object entry) (error entry)))
   ((plist-member entry :from)
    (condition-case nil (harness-board--normalise-relationship entry) (error entry)))
   (t entry)))

(defun harness-board--normalise-keys (keys)
  "Return KEYS, the idempotency keys a board remembers, as a plist."
  (when (and (listp keys) (keywordp (car keys)))
    (cl-loop for (key entry) on keys by #'cddr
             append (list key (list :patch (plist-get entry :patch)
                                    :hash (plist-get entry :hash)
                                    :revision (plist-get entry :revision)
                                    :created (vconcat (append (plist-get entry :created) nil))
                                    :changed (vconcat (append (plist-get entry :changed) nil))
                                    :time (plist-get entry :time))))))

(defun harness-board--normalise-resources (resources)
  "Return RESOURCES, typed links, validated."
  (let ((out nil))
    (dolist (resource (if (listp resources) resources (append resources nil)))
      (unless (listp resource)
        (harness-board--fail 'invalid-reference "a resource is an object: %S" resource))
      (let ((kind (intern (or (harness-board--string (plist-get resource :kind)) "")))
            (ref (harness-board--string (plist-get resource :ref))))
        (unless (assoc kind harness-board-resource-kinds)
          (harness-board--fail 'invalid-reference
                               "resource kind %s is not one of %s"
                               (plist-get resource :kind)
                               (string-join (mapcar #'symbol-name
                                                    (mapcar #'car harness-board-resource-kinds)) ", ")))
        (unless (and ref (not (string-empty-p ref)))
          (harness-board--fail 'invalid-reference "a %s resource needs a ref" kind))
        (push (list :kind kind :ref ref
                    :label (harness-board--string (plist-get resource :label))
                    :role (let ((role (harness-board--symbol (plist-get resource :role))))
                            (and role (assoc role harness-board-evidence-roles) role)))
              out)))
    (nreverse out)))

(defun harness-board--symbol (value)
  "Return VALUE as a lowercase symbol, or nil."
  (let ((text (harness-board--string (if (keywordp value) (substring (symbol-name value) 1) value))))
    (and text (intern (downcase text)))))

(defun harness-board--anchor-ref (value &optional what)
  "Return VALUE, an endpoint, as (:object ID :anchor NAME)."
  (let ((object (plist-get value :object))
        (anchor (plist-get value :anchor)))
    (list :object (harness-board--id object (format "%s object" (or what "endpoint")))
          :anchor (when anchor (harness-board--string anchor "anchor")))))

(defun harness-board--normalise-relationship (relationship)
  "Return RELATIONSHIP, validated, as the document keeps it."
  (unless (listp relationship)
    (harness-board--fail 'invalid-parameter "a relationship is an object: %S" relationship))
  (let ((kind (or (harness-board--symbol (plist-get relationship :kind)) 'flow)))
    (unless (memq kind '(flow association boundary portal))
      (harness-board--fail 'invalid-parameter "relationship kind is flow, association, boundary or portal: %S" kind))
    (list :id (harness-board--id (plist-get relationship :id) "relationship id")
          :kind kind
          :diagram (harness-board--id (plist-get relationship :diagram) "relationship diagram")
          :label (harness-board--string (plist-get relationship :label))
          :from (harness-board--anchor-ref (plist-get relationship :from) "from")
          :to (harness-board--anchor-ref (plist-get relationship :to) "to")
          :style (harness-board--style (or (plist-get relationship :style) nil))
          :resources (harness-board--normalise-resources (plist-get relationship :resources))
          :role (or (let ((role (harness-board--symbol (plist-get relationship :role))))
                      (and role (assoc role harness-board-evidence-roles) role))
                    'declared))))

(defun harness-board--normalise-view (view)
  "Return VIEW, validated, as the document keeps it."
  (unless (listp view)
    (harness-board--fail 'invalid-parameter "a view is an object: %S" view))
  (list :shape (and (plist-get view :shape) (harness-board--shape (plist-get view :shape)))
        :transform (harness-board--matrix (or (plist-get view :transform) harness-board-identity)
                                          "view transform")
        :style (harness-board--style (or (plist-get view :style) nil))
        :anchors (harness-board--anchors (or (plist-get view :anchors) nil))
        :z (let ((z (or (plist-get view :z) 0)))
             (unless (numberp z)
               (harness-board--fail 'invalid-parameter "a layer is a number: %S" z))
             z)))

(defun harness-board--normalise-object (object)
  "Return OBJECT, validated, as the document keeps it."
  (unless (listp object)
    (harness-board--fail 'invalid-parameter "an object is an object: %S" object))
  (let* ((kind (harness-board--symbol (plist-get object :kind)))
         (views (plist-get object :views))
         (pairs (if (and (consp views) (keywordp (car views)))
                    (cl-loop for (k v) on views by #'cddr
                             collect (cons (substring (symbol-name k) 1) v))
                  views)))
    (unless (assoc kind harness-board-object-kinds)
      (harness-board--fail 'unsupported-operation
                           "object kind %s is not one of %s"
                           (plist-get object :kind)
                           (string-join (mapcar #'symbol-name
                                                (mapcar #'car harness-board-object-kinds))
                                        ", ")))
    (let* ((normalised (mapcar (lambda (pair)
                                 (cons (harness-board--id (car pair) "view diagram")
                                       (harness-board--normalise-view (cdr pair))))
                               pairs))
           (views-plist (harness-board--views-plist normalised)))
      (unless normalised
        (harness-board--fail 'invalid-parameter "object %s has no view in any diagram"
                             (plist-get object :id)))
      (list :id (harness-board--id (plist-get object :id) "object id")
            :kind kind
            :name (harness-board--string (plist-get object :name))
            :text (harness-board--string (plist-get object :text))
            :role (or (let ((role (harness-board--symbol (plist-get object :role))))
                        (and role (assoc role harness-board-evidence-roles) role))
                      'declared)
            :locked (and (harness-board--truthy (plist-get object :locked)) t)
            :group (when (plist-get object :group)
                     (harness-board--id (plist-get object :group) "group id"))
            :resources (harness-board--normalise-resources (plist-get object :resources))
            :task (when (plist-get object :task)
                    (harness-board--string (plist-get object :task) "task"))
            :views views-plist))))

(defun harness-board--views-plist (pairs)
  "Return PAIRS, (DIAGRAM . VIEW) as they are kept, as a plist.
The keys are the diagrams' ids as keywords, which is how a document and
a patch carry them; `harness-board--object-views' reads them back."
  (let (out)
    (dolist (pair pairs)
      (setq out (plist-put out (intern (concat ":" (car pair))) (cdr pair))))
    out))

;;;; Geometry of a shape

(defun harness-board-shape-box (shape)
  "Return (X Y W H), the untransformed box of SHAPE."
  (pcase (plist-get shape :kind)
    ((or "rect" "image") (list 0 0 (plist-get shape :w) (plist-get shape :h)))
    ("ellipse" (let ((rx (plist-get shape :rx)) (ry (plist-get shape :ry)))
                 (list (- rx) (- ry) (* 2 rx) (* 2 ry))))
    ("text" (let ((size (plist-get shape :size))
                  (text (or (plist-get shape :text) "")))
              (let* ((lines (split-string text "\n"))
                     (width (cl-loop for line in lines maximize (* 0.58 size (length line))))
                     (height (* size 1.25 (max 1 (length lines)))))
                (list 0 0 (max width 1) height))))
    ((or "polygon" "path")
     (let ((points (harness-board--shape-flat-points shape)))
       (if (null points)
           (list 0 0 0 0)
         (let ((xs (mapcar #'car points)) (ys (mapcar #'cdr points)))
           (list (apply #'min xs) (apply #'min ys)
                 (- (apply #'max xs) (apply #'min xs))
                 (- (apply #'max ys) (apply #'min ys)))))))
    (_ (list 0 0 0 0))))

(defun harness-board--shape-flat-points (shape)
  "Return the points SHAPE is drawn through, as (X . Y) list."
  (pcase (plist-get shape :kind)
    ("polygon" (cl-loop for p in (append (plist-get shape :points) nil)
                        collect (if (vectorp p) (cons (aref p 0) (aref p 1))
                                  (cons (car p) (cadr p)))))
    ("path" (let (out)
              (dolist (segment (plist-get shape :segments))
                (pcase (car segment)
                  ("M" (push (cons (nth 1 segment) (nth 2 segment)) out))
                  ("L" (push (cons (nth 1 segment) (nth 2 segment)) out))
                  ("C" (push (cons (nth 1 segment) (nth 2 segment)) out)
                       (push (cons (nth 3 segment) (nth 4 segment)) out)
                       (push (cons (nth 5 segment) (nth 6 segment)) out))
                  ("Q" (push (cons (nth 1 segment) (nth 2 segment)) out)
                       (push (cons (nth 3 segment) (nth 4 segment)) out))
                  ("Z" nil)))
              (nreverse out)))
    (_ nil)))

(defun harness-board-view-box (view)
  "Return (X . Y . W . H) of VIEW in its diagram's coordinates.
The box is the transformed shape's axis-aligned bounds, which is what a
renderer clips, a person drags and an agent's overflow check measures."
  (let* ((shape (plist-get view :shape))
         (m (plist-get view :transform))
         (box (harness-board-shape-box shape)))
    (if (null shape)
        (let ((origin (harness-board-matrix-apply m 0 0)))
          (list (car origin) (cdr origin) 0 0))
      (let* ((x (car box)) (y (cadr box)) (w (nth 2 box)) (h (nth 3 box))
             (corners (mapcar (lambda (p) (harness-board-matrix-apply m (car p) (cdr p)))
                              (list (cons x y) (cons (+ x w) y)
                                    (cons (+ x w) (+ y h)) (cons x (+ y h)))))
             (xs (mapcar #'car corners)) (ys (mapcar #'cdr corners)))
        (list (apply #'min xs) (apply #'min ys)
              (- (apply #'max xs) (apply #'min xs))
              (- (apply #'max ys) (apply #'min ys)))))))

(defun harness-board-anchor-local (view anchor)
  "Return the local point of ANCHOR in VIEW's own frame, or nil.
A view's named anchors are local points.  Every shape also has the six
implicit ones -- left, right, top, bottom, center, and tip and base at
the growth end -- which are its box's edge midpoints, so a shape with no
declared anchors can still be connected."
  (let* ((anchors (plist-get view :anchors))
         (named (and anchors (plist-get anchors (intern (concat ":" anchor))))))
    (cond
     (named (cons (aref named 0) (aref named 1)))
     ((member anchor '("left" "right" "top" "bottom" "center" "base" "tip"))
      (let* ((shape (plist-get view :shape))
             (box (harness-board-shape-box shape))
             (x (car box)) (y (cadr box)) (w (nth 2 box)) (h (nth 3 box)))
        (pcase anchor
          ("left" (cons x (+ y (/ h 2))))
          ("base" (cons x (+ y (/ h 2))))
          ("right" (cons (+ x w) (+ y (/ h 2))))
          ("tip" (cons (+ x w) (+ y (/ h 2))))
          ("top" (cons (+ x (/ w 2)) y))
          ("bottom" (cons (+ x (/ w 2)) (+ y h)))
          (_ (cons (+ x (/ w 2)) (+ y (/ h 2)))))))
     (t nil))))

(defun harness-board-anchor-point (view anchor)
  "Return the point in the diagram where ANCHOR of VIEW is, or nil."
  (let ((local (harness-board-anchor-local view anchor)))
    (and local (harness-board-matrix-apply (plist-get view :transform)
                                           (car local) (cdr local)))))

(defun harness-board-view-anchor-origin (view)
  "Return the point VIEW's own frame has at its origin."
  (harness-board-matrix-apply (plist-get view :transform) 0 0))

;;;; Attachment

(defun harness-board--attach-matrix (child-anchor parent-point angle scale mirror)
  "Return the matrix placing a child so CHILD-ANCHOR meets PARENT-POINT.
The order is documented and tested: reflect across the child's growth
axis when MIRROR is set, then scale by SCALE, then rotate clockwise by
ANGLE degrees, then translate to PARENT-POINT.  So
CHILD = T(PARENT) . R(ANGLE) . S(SCALE) . F(MIRROR), and the child's
anchor is preserved exactly."
  (let* ((scale (harness-board--positive scale "attach scale"))
         (angle (harness-board--number angle "attach angle"))
         (point (harness-board--point parent-point "attach point"))
         (parts (list (harness-board-matrix-translation (car point) (cdr point))
                      (harness-board-matrix-rotation angle)
                      (harness-board-matrix-scale scale scale)))
         (matrix harness-board-identity))
    (when (harness-board--truthy mirror)
      (setq parts (append parts (list (harness-board-matrix-reflection 'x)))))
    (dolist (part parts)
      (setq matrix (harness-board-matrix-multiply matrix part)))
    ;; Place the child so its own anchor lands on the point: the anchor is
    ;; a local point, so translate by -anchor in the child's frame first.
    (let ((anchor (harness-board--point child-anchor "child anchor")))
      (harness-board-matrix-multiply matrix
                                     (harness-board-matrix-translation
                                      (- (car anchor)) (- (cdr anchor)))))))

;;;; Validation of a whole document's references

(defun harness-board--check-references (board)
  "Refuse BOARD when a view, portal or relationship names nothing."
  (let ((diagrams (harness-board--diagram-ids board))
        (objects (mapcar (lambda (o) (plist-get o :id)) (plist-get board :objects))))
    (dolist (object (plist-get board :objects))
      (dolist (pair (harness-board--object-views object))
        (unless (member (car pair) diagrams)
          (harness-board--fail 'invalid-reference
                               "object %s has a view in diagram %s, which the board does not have"
                               (plist-get object :id) (car pair))))
      (when-let* ((group (plist-get object :group)))
        (let ((parent (harness-board--object board group)))
          (unless (and parent (eq (plist-get parent :kind) 'group))
            (harness-board--fail 'invalid-reference
                                 "object %s is a member of %s, which is not a group here"
                                 (plist-get object :id) group)))))
    (dolist (diagram (plist-get board :diagrams))
      (dolist (portal (append (plist-get diagram :portals) nil))
        (unless (member (plist-get portal :diagram) diagrams)
          (harness-board--fail 'invalid-reference
                               "diagram %s has a portal to %s, which the board does not have"
                               (plist-get diagram :id) (plist-get portal :diagram)))
        (unless (member (plist-get portal :from) objects)
          (harness-board--fail 'invalid-reference
                               "diagram %s has a portal from %s, which is not an object here"
                               (plist-get diagram :id) (plist-get portal :from))))
      (dolist (id (append (plist-get diagram :selection) nil))
        (unless (member id objects)
          (harness-board--fail 'invalid-reference
                               "the selection of diagram %s names %s, which is not an object here"
                               (plist-get diagram :id) id))))
    (dolist (relationship (plist-get board :relationships))
      (dolist (endpoint (list (plist-get relationship :from) (plist-get relationship :to)))
        (let ((object (harness-board--object board (plist-get endpoint :object))))
          (unless object
            (harness-board--fail 'invalid-reference
                                 "relationship %s names object %s, which is not here"
                                 (plist-get relationship :id) (plist-get endpoint :object)))
          (let ((view (harness-board--view object (plist-get relationship :diagram))))
            (unless view
              (harness-board--fail 'invalid-reference
                                   "relationship %s is in %s, where %s has no view"
                                   (plist-get relationship :id)
                                   (plist-get relationship :diagram)
                                   (plist-get endpoint :object)))
            (when-let* ((anchor (plist-get endpoint :anchor)))
              (unless (harness-board-anchor-point view anchor)
                (harness-board--fail 'invalid-reference
                                     "object %s has no anchor %s in %s"
                                     (plist-get endpoint :object) anchor
                                     (plist-get relationship :diagram))))))))
    board))

(harness-define-module 'board
  :doc "The freeform board's grammar: the typed, attributed spatial graph a person and an agent draw on -- the primitives, the matrices, the named local anchors, the attachment order, the themes as palettes and the distinct ways a document is refused.  No lifecycle, no re-layout, no search."
  :requires nil)

(provide 'harness-board)
;;; harness-board.el ends here
