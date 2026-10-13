;;; harness-ui-pet-3d.el --- A small low-poly 3D renderer for the companion pet  -*- lexical-binding: t; -*-

;;; Commentary:

;; The companion pet turns once about its vertical axis as a real
;; low-poly 3D model, drawn at runtime: this file builds the model's
;; meshes, turns and shades them, and writes the result as an SVG image,
;; or as a text map for those who cannot look at images.  It needs
;; nothing of the harness: only the models of `harness-ui-pet-models'.
;;
;;   `harness-ui-pet-3d-model'     the model of a species, or nil
;;   `harness-ui-pet-3d-svg'       an SVG document of a model, with a hat,
;;                                 turned by an angle
;;   `harness-ui-pet-3d-frame'     step N of a turn as an image, cached
;;   `harness-ui-pet-3d-preview'   the same as a text map
;;   `harness-ui-pet-3d-stats'     face counts and the like
;;   `harness-ui-pet-3d-problems'  what is wrong with a model, if anything
;;
;; The format of a model, its parts and its hats is described at the top
;; of harness-ui-pet-models.el.
;;
;; How a frame is drawn:
;;
;;   Meshes    each part is a closed mesh of flat polygons with outward
;;             normals (`ball', `box', `tube', `ring'), built once per
;;             model and hat, with every face that lies wholly inside
;;             another part left out: it can never be seen.  (Only the
;;             faces with all their corners inside go, not those with
;;             just their middle: those would leave holes along the
;;             seams where two parts meet.)
;;   View      the model turns about y by its `:start' plus the angle,
;;             then the camera looks 14 degrees down on it, with no
;;             perspective.  The fit is that of a whole turn, hat
;;             included, so the model never grows, shrinks or slides as
;;             it turns: centred across, its feet near the bottom and
;;             filling about 92% of the box.
;;   Light     from the upper left front: a face is shaded flat at
;;             0.58 to 1.05 times its colour, or not at all when its part
;;             is `:flat'.
;;   Order     a BSP tree, built with the mesh, orders the faces for
;;             any view.  Each node is the plane of a face, and the faces
;;             in front of it and behind it are trees of their own; a face
;;             that crosses the plane is cut along it.  Drawn back to
;;             front (the side of each plane away from the viewer, then
;;             the faces in it, then the side toward the viewer), no face
;;             is drawn before one that hides it, even where two parts
;;             run into each other, as they do at every neck and leg.  A
;;             part's `:detail' faces (eyes, nostrils, spots) are drawn as
;;             if a little nearer the viewer than they are, which does not
;;             move them on the screen: they show over what they sit on
;;             even when sunk into it a little, and never through it from
;;             behind.  Faces that look away are dropped.
;;   Output    one polygon per face, or per piece of a face that was cut,
;;             filled and stroked in its colour so that no seams show.
;;
;; Only the turn, the shading, the details' way down the tree and the
;; walk of it run for each frame, in a few milliseconds; a model and hat
;; are built on first use, in a few tens.
;;
;; To look at a model without an image, a batch Emacs can print it as
;; text: `harness-ui-pet-3d-print-previews' takes the species, the angles
;; and the hats to show, and writes a map of each to standard output.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-ui-pet-models)

(defconst harness-ui-pet-3d-count 24
  "Frames in one turn of the pet.")

(defconst harness-ui-pet-3d-tick 0.09
  "Seconds each frame of a spin shows.")

(defconst harness-ui-pet-3d-shared-colors
  '((eye . "#1d1a21") (shine . "#ffffff") (blush . "#f4a3b4"))
  "Colours any model may name besides those of its palette.")

(defconst harness-ui-pet-3d--tilt 14.0
  "Degrees the camera looks down on the model.")

(defconst harness-ui-pet-3d--fill 0.92
  "The part of the box a model fills, across or down.")

(defconst harness-ui-pet-3d--margin 0.04
  "The part of the box's height left under the model's feet.")

(defconst harness-ui-pet-3d--detail-bias 0.06
  "Model units nearer the viewer than it is that a `:detail' face is drawn.
The view has no perspective, so that does not move it on the screen; it
only changes what it is drawn over.  A detail sunk this much or less into
what it sits on shows over it whole, and one on a part thicker than this
is never seen through it from behind.")

(defconst harness-ui-pet-3d--on-plane 1e-5
  "Model units within which a corner counts as lying in a plane.")

(defconst harness-ui-pet-3d--split-tries 8
  "How many faces a node of the order tree tries for its plane.
Of those, the one whose plane runs through parts with the fewest faces
between them wins: those are the faces it might cut.")

(defconst harness-ui-pet-3d--light
  (let* ((x -0.45) (y 0.75) (z 0.5) (n (sqrt (+ (* x x) (* y y) (* z z)))))
    (vector (/ x n) (/ y n) (/ z n)))
  "The direction the light comes from, in view space: upper left front.")

(defconst harness-ui-pet-3d--max-faces 600
  "Faces a species should have at most, before the hidden ones go.")

(defconst harness-ui-pet-3d--fallback-color #x888888
  "The colour of a part whose colour is not known, as 0xRRGGBB.")

;;;; Colours

(defconst harness-ui-pet-3d--hex
  (let ((v (make-vector 256 nil)))
    (dotimes (i 256) (aset v i (format "%02x" i)))
    v)
  "The two hex digits of each byte.")

(defun harness-ui-pet-3d--parse-color (string)
  "The colour of STRING, \"#rrggbb\", as the integer 0xRRGGBB, or nil."
  (when (and (stringp string)
             (string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'"
                           string))
    (logior (ash (string-to-number (match-string 1 string) 16) 16)
            (ash (string-to-number (match-string 2 string) 16) 8)
            (string-to-number (match-string 3 string) 16))))

(defun harness-ui-pet-3d--resolve-color (color palette)
  "The colour COLOR of a part as (LABEL . RGB), through PALETTE.
COLOR is a key of PALETTE, a shared colour's name or \"#rrggbb\".  RGB is
nil when it is none of those."
  (cond ((stringp color) (cons color (harness-ui-pet-3d--parse-color color)))
        ((and color (symbolp color))
         (cons color
               (harness-ui-pet-3d--parse-color
                (or (cdr (assq color palette))
                    (cdr (assq color harness-ui-pet-3d-shared-colors))))))
        (t (cons nil nil))))

;;;; Looking things up

(defun harness-ui-pet-3d--symbol (name)
  "NAME, a symbol or a string naming one, as a symbol; nil when there is none."
  (cond ((symbolp name) name)
        ((stringp name) (intern-soft name))))

(defun harness-ui-pet-3d--model-p (object)
  "Non-nil when OBJECT is a model: a plist."
  (and (consp object) (keywordp (car object))))

(defun harness-ui-pet-3d-model (species)
  "The model of SPECIES, a symbol or a string, or nil when it has none."
  (let ((symbol (harness-ui-pet-3d--symbol species)))
    (and symbol (cdr (assq symbol harness-ui-pet-models)))))

(defun harness-ui-pet-3d--resolve-model (model)
  "MODEL, a species or a model, as a model; nil when there is none."
  (if (harness-ui-pet-3d--model-p model) model (harness-ui-pet-3d-model model)))

(defun harness-ui-pet-3d--resolve-hat (hat)
  "HAT, a hat's name or a hat model, as a hat model; nil when there is none."
  (if (harness-ui-pet-3d--model-p hat)
      hat
    (let ((symbol (harness-ui-pet-3d--symbol hat)))
      (and symbol (cdr (assq symbol harness-ui-pet-hat-models))))))

;;;; Mesh builders
;;
;; Each returns (VERTICES . FACES) in the part's own frame: VERTICES is a
;; list of (X Y Z) and a face a list of indices into it, counter-clockwise
;; seen from outside, so that the normal of a face points away from the
;; part.  Round parts have vertices every 360/N degrees, half a step off
;; the front, so that a flat face looks at the viewer and the parts are
;; as symmetric about x = 0 as the model is.

(defun harness-ui-pet-3d--azimuth (k n)
  "The azimuth in radians of vertex K of N around a circle: half a step in."
  (* (+ k 0.5) (/ (* 2.0 float-pi) n)))

(defun harness-ui-pet-3d--ball-geometry (rx ry rz sides half)
  "The mesh of an ellipsoid of radii RX, RY and RZ, SIDES segments around.
HALF keeps the half above its centre, closed by a flat disk."
  (let* ((n (max 3 sides))
         (rings (max 4 (floor (+ (* 0.6 n) 0.5))))
         (bands (if half (max 2 (floor (+ (/ rings 2.0) 0.5))) rings))
         (span (if half (/ float-pi 2.0) float-pi))
         (last-ring (if half bands (1- bands)))
         (verts (list (list 0.0 (float ry) 0.0)))
         (faces nil))
    (cl-flet ((at (j k) (+ 1 (* (1- j) n) (mod k n))))
      (cl-loop for j from 1 to last-ring
               do (let* ((phi (* span (/ (float j) bands)))
                         (s (sin phi))
                         (y (if (and half (= j bands)) 0.0 (* ry (cos phi)))))
                    (dotimes (k n)
                      (let ((th (harness-ui-pet-3d--azimuth k n)))
                        (push (list (* rx s (sin th)) y (* rz s (cos th))) verts)))))
      (unless half (push (list 0.0 (- (float ry)) 0.0) verts))
      (dotimes (k n)
        (push (list 0 (at 1 k) (at 1 (1+ k))) faces))
      (cl-loop for j from 1 below last-ring
               do (dotimes (k n)
                    (push (list (at j k) (at (1+ j) k) (at (1+ j) (1+ k)) (at j (1+ k))) faces)))
      (if half
          (push (cl-loop for k from (1- n) downto 0 collect (at last-ring k)) faces)
        (let ((pole (+ 1 (* last-ring n))))
          (dotimes (k n)
            (push (list pole (at last-ring (1+ k)) (at last-ring k)) faces)))))
    (cons (nreverse verts) (nreverse faces))))

(defun harness-ui-pet-3d--box-geometry (hx hy hz)
  "The mesh of a box of half extents HX, HY and HZ."
  (cons (cl-loop for i below 8
                 collect (list (if (zerop (logand i 1)) (- hx) hx)
                               (if (zerop (logand i 2)) (- hy) hy)
                               (if (zerop (logand i 4)) (- hz) hz)))
        '((4 5 7 6) (1 0 2 3) (5 1 3 7) (0 4 6 2) (6 7 3 2) (0 1 5 4))))

(defun harness-ui-pet-3d--tube-geometry (radius top height sides)
  "The mesh of a frustum along y, centred on the origin.
RADIUS is that of its bottom, TOP that of its top (0 makes a cone), HEIGHT
its height and SIDES the segments around."
  (let* ((n (max 3 sides))
         (y0 (- (/ height 2.0)))
         (y1 (/ height 2.0))
         (bottom (> radius 1e-9))
         (up (> top 1e-9))
         (verts nil) (faces nil) (base-b 0) (base-t 0))
    (when bottom
      (setq base-b (length verts))
      (dotimes (k n)
        (let ((th (harness-ui-pet-3d--azimuth k n)))
          (setq verts (append verts (list (list (* radius (sin th)) y0 (* radius (cos th)))))))))
    (when up
      (setq base-t (length verts))
      (dotimes (k n)
        (let ((th (harness-ui-pet-3d--azimuth k n)))
          (setq verts (append verts (list (list (* top (sin th)) y1 (* top (cos th)))))))))
    (let ((apex (length verts)))
      (unless (and bottom up) (setq verts (append verts (list (list 0.0 (if up y0 y1) 0.0)))))
      (cond
       ((and bottom up)
        (dotimes (k n)
          (push (list (+ base-t k) (+ base-b k) (+ base-b (mod (1+ k) n)) (+ base-t (mod (1+ k) n))) faces))
        (push (cl-loop for k below n collect (+ base-t k)) faces)
        (push (cl-loop for k from (1- n) downto 0 collect (+ base-b k)) faces))
       (bottom
        (dotimes (k n)
          (push (list apex (+ base-b k) (+ base-b (mod (1+ k) n))) faces))
        (push (cl-loop for k from (1- n) downto 0 collect (+ base-b k)) faces))
       (up
        (dotimes (k n)
          (push (list apex (+ base-t (mod (1+ k) n)) (+ base-t k)) faces))
        (push (cl-loop for k below n collect (+ base-t k)) faces))))
    (cons verts (nreverse faces))))

(defun harness-ui-pet-3d--ring-geometry (radius thickness sides)
  "The mesh of a torus around y, centred on the origin.
RADIUS runs to the middle of the tube, THICKNESS is the tube's radius and
SIDES the segments around the ring."
  (let* ((n (max 6 sides))
         (m (if (>= n 10) 6 4))
         (verts nil) (faces nil))
    (dotimes (i n)
      (let* ((th (harness-ui-pet-3d--azimuth i n))
             (sx (sin th)) (cz (cos th)))
        (dotimes (j m)
          (let* ((psi (harness-ui-pet-3d--azimuth j m))
                 (out (+ radius (* thickness (cos psi)))))
            (push (list (* out sx) (* thickness (sin psi)) (* out cz)) verts)))))
    (cl-flet ((at (i j) (+ (* (mod i n) m) (mod j m))))
      (dotimes (i n)
        (dotimes (j m)
          (push (list (at i j) (at (1+ i) j) (at (1+ i) (1+ j)) (at i (1+ j))) faces))))
    (cons (nreverse verts) (nreverse faces))))

;;;; Parts

(cl-defstruct (harness-ui-pet-3d--piece
               (:constructor harness-ui-pet-3d--piece (kind verts faces center
                                                            rotation shape label rgb flags))
               (:copier nil))
  "One part of a model, built.
KIND is its kind.  VERTS is the flat vector (X Y Z X Y Z ...) of its
vertices in the model's space, FACES a list of lists of indices into
it.  CENTER is its centre (X Y Z) and ROTATION its 3x3 matrix, 9 numbers
by rows.  SHAPE says what its volume is: (BALL RX RY RZ HALF SIDES),
\(BOX HX HY HZ), (TUBE RADIUS TOP HALF-HEIGHT SIDES), or nil for a ring.
LABEL is the colour as the part named it and RGB its value; FLAGS is 1 for
a flat part and 2 for a detail."
  kind verts faces center rotation shape label rgb flags)

(defun harness-ui-pet-3d--triple (value default)
  "VALUE, a number or three, as a list of three floats; DEFAULT when neither."
  (cond ((numberp value) (list (float value) (float value) (float value)))
        ((and (consp value) (numberp (nth 0 value)) (numberp (nth 1 value)) (numberp (nth 2 value)))
         (list (float (nth 0 value)) (float (nth 1 value)) (float (nth 2 value))))
        (t (list (float default) (float default) (float default)))))

(defun harness-ui-pet-3d--number (value default)
  "VALUE as a float when it is a number, else DEFAULT as one."
  (float (if (numberp value) value default)))

(defun harness-ui-pet-3d--matrix* (a b)
  "The product of the 3x3 matrices A and B, 9 numbers each by rows."
  (let ((out (make-vector 9 0.0)))
    (dotimes (r 3)
      (dotimes (c 3)
        (aset out (+ (* r 3) c)
              (+ (* (aref a (* r 3)) (aref b c))
                 (* (aref a (+ (* r 3) 1)) (aref b (+ 3 c)))
                 (* (aref a (+ (* r 3) 2)) (aref b (+ 6 c)))))))
    out))

(defun harness-ui-pet-3d--rotation (rx ry rz)
  "The 3x3 matrix turning RX degrees about x, then RY about y, then RZ about z."
  (let* ((ax (degrees-to-radians rx)) (ay (degrees-to-radians ry)) (az (degrees-to-radians rz))
         (cx (cos ax)) (sx (sin ax)) (cy (cos ay)) (sy (sin ay)) (cz (cos az)) (sz (sin az))
         (mx (vector 1.0 0.0 0.0  0.0 cx (- sx)  0.0 sx cx))
         (my (vector cy 0.0 sy  0.0 1.0 0.0  (- sy) 0.0 cy))
         (mz (vector cz (- sz) 0.0  sz cz 0.0  0.0 0.0 1.0)))
    (harness-ui-pet-3d--matrix* mz (harness-ui-pet-3d--matrix* my mx))))

(defun harness-ui-pet-3d--make-piece (part scale ox oy oz palette)
  "The piece of PART, scaled by SCALE and moved by (OX OY OZ).
PALETTE names the colours of the model.  The result is nil for a part of
a kind that is not known."
  (let* ((kind (car part))
         (plist (cdr part))
         (at (harness-ui-pet-3d--triple (plist-get plist :at) 0.0))
         (turn (harness-ui-pet-3d--triple (plist-get plist :turn) 0.0))
         (sides (let ((s (plist-get plist :sides))) (and (integerp s) s)))
         (flags (logior (if (plist-get plist :flat) 1 0) (if (plist-get plist :detail) 2 0)))
         (color (harness-ui-pet-3d--resolve-color (plist-get plist :color) palette))
         shape geometry)
    (pcase kind
      ('ball
       (let* ((r (harness-ui-pet-3d--triple (plist-get plist :size) 0.5))
              (rx (* scale (nth 0 r))) (ry (* scale (nth 1 r))) (rz (* scale (nth 2 r)))
              (half (and (plist-get plist :half) t))
              (n (or sides 12)))
         (setq shape (list 'ball rx ry rz half n)
               geometry (harness-ui-pet-3d--ball-geometry rx ry rz n half))))
      ('box
       (let* ((h (harness-ui-pet-3d--triple (plist-get plist :size) 0.5))
              (hx (* scale (nth 0 h))) (hy (* scale (nth 1 h))) (hz (* scale (nth 2 h))))
         (setq shape (list 'box hx hy hz)
               geometry (harness-ui-pet-3d--box-geometry hx hy hz))))
      ('tube
       (let* ((radius (harness-ui-pet-3d--number (plist-get plist :radius) 0.2))
              (top (* scale (harness-ui-pet-3d--number (plist-get plist :top) radius)))
              (height (* scale (harness-ui-pet-3d--number (plist-get plist :height) 0.4)))
              (n (or sides 10)))
         (setq radius (* scale radius)
               shape (list 'tube radius top (/ height 2.0) n)
               geometry (harness-ui-pet-3d--tube-geometry radius top height n))))
      ('ring
       (let ((radius (* scale (harness-ui-pet-3d--number (plist-get plist :radius) 0.5)))
             (thickness (* scale (harness-ui-pet-3d--number (plist-get plist :thickness) 0.08))))
         (setq geometry (harness-ui-pet-3d--ring-geometry radius thickness (or sides 12)))))
      (_ nil))
    (when geometry
      (let* ((rot (harness-ui-pet-3d--rotation (nth 0 turn) (nth 1 turn) (nth 2 turn)))
             (cx (+ ox (* scale (nth 0 at))))
             (cy (+ oy (* scale (nth 1 at))))
             (cz (+ oz (* scale (nth 2 at))))
             (verts (apply #'vconcat
                           (mapcar (lambda (v)
                                     (let ((x (nth 0 v)) (y (nth 1 v)) (z (nth 2 v)))
                                       (vector (+ cx (* (aref rot 0) x) (* (aref rot 1) y) (* (aref rot 2) z))
                                               (+ cy (* (aref rot 3) x) (* (aref rot 4) y) (* (aref rot 5) z))
                                               (+ cz (* (aref rot 6) x) (* (aref rot 7) y) (* (aref rot 8) z)))))
                                   (car geometry)))))
        (harness-ui-pet-3d--piece kind verts (cdr geometry) (list cx cy cz) rot shape
                                  (car color) (cdr color) flags)))))

(defun harness-ui-pet-3d--mirrored (part)
  "The copy of PART mirrored across x = 0, turn mirrored to match, or nil.
It is nil when the copy would be the part itself."
  (let* ((plist (copy-sequence (cdr part)))
         (at (harness-ui-pet-3d--triple (plist-get plist :at) 0.0))
         (turn (harness-ui-pet-3d--triple (plist-get plist :turn) 0.0))
         (new-at (list (- (nth 0 at)) (nth 1 at) (nth 2 at)))
         (new-turn (list (nth 0 turn) (- (nth 1 turn)) (- (nth 2 turn)))))
    (unless (and (< (abs (nth 0 at)) 1e-9) (< (abs (nth 1 turn)) 1e-9) (< (abs (nth 2 turn)) 1e-9))
      (setq plist (plist-put plist :at new-at))
      (setq plist (plist-put plist :turn new-turn))
      (setq plist (plist-put plist :mirror nil))
      (cons (car part) plist))))

(defun harness-ui-pet-3d--expand (parts)
  "PARTS with the mirrored copy of every part that asks for one, after it."
  (let (out)
    (dolist (part parts)
      (when (consp part)
        (push part out)
        (when (plist-get (cdr part) :mirror)
          (let ((copy (harness-ui-pet-3d--mirrored part)))
            (when copy (push copy out))))))
    (nreverse out)))

;;;; Volumes, to leave out what cannot be seen

(defun harness-ui-pet-3d--inside-p (piece shrink x y z &optional slack)
  "Non-nil when (X Y Z) lies inside the volume of PIECE.
The volume is a ball, a box or a tube; a ring has none.  SHRINK is how
much of the polygonal solid is certain to be inside the true one, a
factor below 1 for a round shape, and SLACK how far outside the point
may be."
  (let* ((shape (harness-ui-pet-3d--piece-shape piece))
         (c (harness-ui-pet-3d--piece-center piece))
         (m (harness-ui-pet-3d--piece-rotation piece))
         (slack (or slack 0.0))
         (dx (- x (nth 0 c))) (dy (- y (nth 1 c))) (dz (- z (nth 2 c)))
         (px (+ (* (aref m 0) dx) (* (aref m 3) dy) (* (aref m 6) dz)))
         (py (+ (* (aref m 1) dx) (* (aref m 4) dy) (* (aref m 7) dz)))
         (pz (+ (* (aref m 2) dx) (* (aref m 5) dy) (* (aref m 8) dz))))
    (pcase (car shape)
      ('ball
       (let* ((f (* shrink (cos (/ float-pi (max 3 (nth 5 shape))))))
              (a (+ (* f (nth 1 shape)) slack)) (b (+ (* f (nth 2 shape)) slack))
              (cc (+ (* f (nth 3 shape)) slack)))
         (and (< (+ (/ (* px px) (* a a)) (/ (* py py) (* b b)) (/ (* pz pz) (* cc cc))) 1.0)
              (or (not (nth 4 shape)) (> py (- slack))))))
      ('box
       (and (< (abs px) (+ (nth 1 shape) slack))
            (< (abs py) (+ (nth 2 shape) slack))
            (< (abs pz) (+ (nth 3 shape) slack))))
      ('tube
       (let* ((hh (nth 3 shape))
              (f (* shrink (cos (/ float-pi (max 3 (nth 4 shape)))))))
         (and (< (abs py) (+ hh slack))
              (let* ((u (/ (+ py hh) (* 2.0 hh)))
                     (radius (+ (* f (+ (nth 1 shape) (* u (- (nth 2 shape) (nth 1 shape))))) slack)))
                (and (> radius 0.0) (< (+ (* px px) (* pz pz)) (* radius radius)))))))
      (_ nil))))

(defun harness-ui-pet-3d--face-inside-p (container verts face)
  "Non-nil when every corner of FACE, indices into VERTS, is inside CONTAINER.
Such a face lies wholly within the volume of another part and can never be
seen.  One that only has its middle there is kept: the parts that meet at
a seam would take the faces of each other that cover it, and leave a hole."
  (cl-every (lambda (i)
              (harness-ui-pet-3d--inside-p container 0.995 (aref verts (* 3 i)) (aref verts (+ (* 3 i) 1))
                                           (aref verts (+ (* 3 i) 2))))
            face))

;;;; The order to draw faces in
;;
;; Sorting faces by the depth of their middle goes wrong wherever two
;; parts run into each other, or a long face lies by a short one: at a
;; neck, the faces of the body in front of the head's middle were drawn
;; over the head.  A BSP tree has no such case.  Each node takes the
;; plane of one face; what lies in front of that plane (where its normal
;; points) and what lies behind it are each a tree of their own, and a
;; face that crosses the plane is cut in two along it.  Nothing behind a
;; plane can hide what is in front of it from a viewer in front of it,
;; so the tree, walked back to front for the view, draws every face
;; after those it hides.  The view has no perspective, so which side of
;; a plane the viewer is on is the sign of the plane's normal on the way
;; to the viewer; the tree is built once and serves every angle.
;;
;; The tree holds the faces of the parts that are no details.  A
;; detail's faces are drawn as if `harness-ui-pet-3d--detail-bias' nearer
;; the viewer, which does not move them on the screen, as the view has
;; no perspective: for each view they go down the tree so moved, cut
;; where they cross a plane, and are drawn where they land, after what
;; is behind them there and before what is in front.

(defun harness-ui-pet-3d--order-tree (verts faces normals centers owners pieces)
  "The BSP tree that orders the faces of a mesh, and the polygons it draws.
VERTS, FACES, NORMALS and CENTERS are as `harness-ui-pet-3d--mesh' has
them, and OWNERS the index in PIECES of the part each face is of.
The result is (POINTS POLYGONS SOURCES TREE OFFSETS BALLS DETAILS).

POINTS is VERTS and after them the corners where faces were cut.
POLYGONS is a vector of the polygons of the faces that are no detail,
each a vector of indices into POINTS, and SOURCES the face each is (a
piece of).  TREE is nil or a node [FACE IN FRONT BACK]: the plane of
FACE, the list IN of the polygons that lie in it, and the nodes of what
lies in front of it, where its normal points, and behind it, or nil.
OFFSETS holds the plane of each face, the product of its normal and any
point of it.  BALLS holds for each part X, Y, Z and R, a ball it lies
in.  DETAILS lists the faces of the details as (PART . FACES), a part to
a group, in the order the parts are named; see
`harness-ui-pet-3d--draw-order'.

A node's plane is that of the face, of a few it tries
\(`harness-ui-pet-3d--split-tries'), that runs through the fewest parts.
The other faces of a convex part (a ball, a box, a tube) all lie behind
each of its planes, and a part whose ball lies wholly on one side of a
plane is all on that side, so only the parts that a plane runs through
are looked at face by face."
  (let* ((eps harness-ui-pet-3d--on-plane)
         (tries harness-ui-pet-3d--split-tries)
         (nfaces (length faces))
         (npieces (length pieces))
         (convex (make-vector npieces nil))
         (balls (make-vector (* 4 npieces) 0.0))
         (offsets (make-vector nfaces 0.0))
         (points (vconcat verts (make-vector (max 300 (length verts)) 0.0)))
         (used (length verts))
         (polygons nil) (sources nil) (count 0)
         (details nil) (root nil) (stack nil))
    (cl-loop for piece in pieces
             for p from 0
             do (let ((ball (harness-ui-pet-3d--container p piece)))
                  (aset convex p (and (memq (car (harness-ui-pet-3d--piece-shape piece)) '(ball box tube)) t))
                  (aset balls (* 4 p) (float (nth 2 ball)))
                  (aset balls (+ (* 4 p) 1) (float (nth 3 ball)))
                  (aset balls (+ (* 4 p) 2) (float (nth 4 ball)))
                  (aset balls (+ (* 4 p) 3) (sqrt (nth 5 ball)))))
    (dotimes (f nfaces)
      (aset offsets f (+ (* (aref normals (* 3 f)) (aref centers (* 3 f)))
                         (* (aref normals (+ (* 3 f) 1)) (aref centers (+ (* 3 f) 1)))
                         (* (aref normals (+ (* 3 f) 2)) (aref centers (+ (* 3 f) 2))))))
    (cl-labels
        ((add-point (x y z)
           (when (> (+ used 3) (length points))
             (setq points (vconcat points (make-vector (length points) 0.0))))
           (aset points used x)
           (aset points (1+ used) y)
           (aset points (+ used 2) z)
           (prog1 (/ used 3) (setq used (+ used 3))))
         (emit (fragment)
           ;; FRAGMENT, (FACE . CORNERS), is drawn: its index among the polygons.
           (push (vconcat (cdr fragment)) polygons)
           (push (car fragment) sources)
           (prog1 count (setq count (1+ count))))
         (side (p nx ny nz d)
           ;; How far the middle of part P's ball is in front of the plane.
           (- (+ (* nx (aref balls (* 4 p))) (* ny (aref balls (+ (* 4 p) 1))) (* nz (aref balls (+ (* 4 p) 2))))
              d))
         (cost (home fragment groups limit)
           ;; The faces of the parts the plane of FRAGMENT runs through, up to LIMIT.
           ;; (Counting the faces it would cut instead saves a sixth of them,
           ;; for a build three times as long.)
           (let* ((f (car fragment))
                  (nx (aref normals (* 3 f))) (ny (aref normals (+ (* 3 f) 1))) (nz (aref normals (+ (* 3 f) 2)))
                  (d (aref offsets f))
                  (total 0))
             (cl-loop for group in groups
                      until (and limit (>= total limit))
                      do (let ((p (car group)))
                           (unless (and (eq group home) (aref convex p))
                             (when (<= (abs (side p nx ny nz d)) (+ eps (aref balls (+ (* 4 p) 3))))
                               (setq total (+ total (length (cdr group))))))))
             total))
         (choose (groups)
           ;; (GROUP . FRAGMENT): the face whose plane the node takes.
           (let* ((n (cl-loop for group in groups sum (length (cdr group))))
                  (stride (max 1 (/ n tries))) (k 0) (best nil) (best-cost nil))
             (dolist (group groups)
               (dolist (fragment (cdr group))
                 (when (zerop (% k stride))
                   (let ((c (cost group fragment groups best-cost)))
                     (when (or (null best-cost) (< c best-cost))
                       (setq best (cons group fragment) best-cost c))))
                 (setq k (1+ k))))
             best)))
      ;; The faces, a group for each part: (PART . FRAGMENTS), a fragment
      ;; being (FACE . CORNERS).  The details' wait for a view.
      (let ((by-part (make-vector npieces nil)) (groups nil))
        (dotimes (f nfaces)
          (push (cons f (append (aref faces f) nil)) (aref by-part (aref owners f))))
        (dotimes (p npieces)
          (when (aref by-part p)
            (if (zerop (logand 2 (harness-ui-pet-3d--piece-flags (nth p pieces))))
                (push (cons p (nreverse (aref by-part p))) groups)
              (push (cons p (mapcar #'car (nreverse (aref by-part p)))) details))))
        (setq details (nreverse details))
        (when groups (push (list (nreverse groups) nil nil) stack)))
      ;; Each job is (GROUPS PARENT SLOT): the tree of GROUPS goes in SLOT of PARENT.
      (while stack
        (pcase-let* ((`(,groups ,parent ,slot) (pop stack))
                     (`(,home . ,splitter) (choose groups))
                     (f (car splitter))
                     (nx (aref normals (* 3 f)))
                     (ny (aref normals (+ (* 3 f) 1)))
                     (nz (aref normals (+ (* 3 f) 2)))
                     (d (aref offsets f))
                     (in (list (emit splitter)))
                     (front nil) (back nil))
          (dolist (group groups)
            (let ((p (car group))
                  (fragments (if (eq group home) (remq splitter (cdr group)) (cdr group))))
              (cond
               ((null fragments))
               ((and (eq group home) (aref convex p))
                ;; The rest of a convex part is behind the plane, but for
                ;; the other pieces of the face itself, which lie in it.
                (let ((behind nil))
                  (dolist (fragment fragments)
                    (if (= (car fragment) f) (push (emit fragment) in) (push fragment behind)))
                  (when behind (push (cons p (nreverse behind)) back))))
               (t
                (let ((middle (side p nx ny nz d))
                      (reach (+ eps (aref balls (+ (* 4 p) 3)))))
                  (cond
                   ((> middle reach) (push (cons p fragments) front))
                   ((< middle (- reach)) (push (cons p fragments) back))
                   (t
                    (let ((ahead nil) (behind nil))
                      (dolist (fragment fragments)
                        (pcase (harness-ui-pet-3d--cut fragment points nx ny nz d #'add-point)
                          ('front (push fragment ahead))
                          ('back (push fragment behind))
                          ('on (push (emit fragment) in))
                          (`(,a . ,b) (when a (push a ahead)) (when b (push b behind)))))
                      (when ahead (push (cons p (nreverse ahead)) front))
                      (when behind (push (cons p (nreverse behind)) back))))))))))
          (let ((node (vector f (nreverse in) nil nil)))
            (if parent (aset parent slot node) (setq root node))
            (when front (push (list (nreverse front) node 2) stack))
            (when back (push (list (nreverse back) node 3) stack))))))
    (list (substring points 0 used) (vconcat (nreverse polygons)) (vconcat (nreverse sources)) root
          offsets balls details)))

(defun harness-ui-pet-3d--cut (fragment points nx ny nz d add-point)
  "Where FRAGMENT lies against the plane NX NY NZ D: `front', `back' or `on'.
FRAGMENT is (FACE . CORNERS), CORNERS indices into POINTS, a flat vector
of coordinates, or into what ADD-POINT added to it.  One that crosses
the plane is cut along it into (FRONT . BACK), either nil when nothing
of it is left on that side; ADD-POINT, called with X, Y and Z, adds a
point and returns its index.  A corner counts as in the plane within
`harness-ui-pet-3d--on-plane'."
  (let* ((eps harness-ui-pet-3d--on-plane)
         (ahead nil) (behind nil)
         (ds (mapcar (lambda (v)
                       (let* ((i (* 3 v))
                              (dv (- (+ (* nx (aref points i)) (* ny (aref points (1+ i)))
                                        (* nz (aref points (+ i 2))))
                                     d)))
                         (cond ((> dv eps) (setq ahead t))
                               ((< dv (- eps)) (setq behind t)))
                         dv))
                     (cdr fragment))))
    (cond
     ((not (and ahead behind)) (cond (ahead 'front) (behind 'back) (t 'on)))
     (t
      (let ((prev (car (last (cdr fragment))))
            (dp (car (last ds)))
            (front nil) (back nil))
        (cl-mapc
         (lambda (v dv)
           (when (or (and (> dp eps) (< dv (- eps))) (and (< dp (- eps)) (> dv eps)))
             (let* ((k (/ dp (- dp dv)))
                    (i (* 3 prev)) (j (* 3 v))
                    (new (funcall add-point
                                  (+ (aref points i) (* k (- (aref points j) (aref points i))))
                                  (+ (aref points (1+ i)) (* k (- (aref points (1+ j)) (aref points (1+ i)))))
                                  (+ (aref points (+ i 2)) (* k (- (aref points (+ j 2)) (aref points (+ i 2))))))))
               (push new front)
               (push new back)))
           (cond ((> dv eps) (push v front))
                 ((< dv (- eps)) (push v back))
                 (t (push v front) (push v back)))
           (setq prev v dp dv))
         (cdr fragment) ds)
        (cons (and (cddr front) (cons (car fragment) (nreverse front)))
              (and (cddr back) (cons (car fragment) (nreverse back)))))))))

;;;; The mesh of a model

(cl-defstruct (harness-ui-pet-3d--mesh
               (:constructor harness-ui-pet-3d--mesh (verts faces normals centers colors flags
                                                            labels table start radius smin smax
                                                            total pieces points polygons sources
                                                            tree offsets balls details))
               (:copier nil))
  "A model and hat, built.
VERTS is the flat vector of the vertices that faces use, FACES a vector of
vectors of indices into it, NORMALS and CENTERS flat vectors of three
numbers for each face, COLORS the colour of each face as 0xRRGGBB, FLAGS
its flags (1 flat, 2 detail) and LABELS the index of its colour in TABLE,
a list of (LABEL . RGB) in the order the parts name them.  START is the
model's start angle.  RADIUS is the greatest distance of a vertex from the
vertical axis, and SMIN and SMAX the least and greatest height a vertex
reaches on the screen as the model turns, in model units.  TOTAL is the
number of faces the parts have before the hidden ones go, and PIECES the
parts.

POINTS, POLYGONS, SOURCES, TREE, OFFSETS, BALLS and DETAILS are what is
drawn, and in what order, as `harness-ui-pet-3d--order-tree' makes them:
the faces, some of them cut into pieces, the BSP tree that orders them,
and what the details need to find their place in it for a view."
  verts faces normals centers colors flags labels table start radius smin smax total pieces
  points polygons sources tree offsets balls details)

(defun harness-ui-pet-3d--head-p (head)
  "Non-nil when HEAD is a model's `:head': four numbers."
  (and (consp head) (cl-every #'numberp head) (>= (length head) 4)))

(defun harness-ui-pet-3d--pieces (model hat)
  "The pieces of MODEL, a plist, and of HAT on its head, a plist or nil."
  (let* ((palette (plist-get model :palette))
         (head (plist-get model :head))
         (own (mapcar (lambda (part) (list part 1.0 0.0 0.0 0.0 palette))
                      (harness-ui-pet-3d--expand (plist-get model :parts))))
         (worn (when (and hat (harness-ui-pet-3d--head-p head))
                 (let ((k (float (nth 3 head))) (hat-palette (plist-get hat :palette)))
                   (mapcar (lambda (part)
                             (list part k (float (nth 0 head)) (float (nth 1 head)) (float (nth 2 head))
                                   hat-palette))
                           (harness-ui-pet-3d--expand (plist-get hat :parts)))))))
    (delq nil (mapcar (lambda (args) (apply #'harness-ui-pet-3d--make-piece args))
                      (append own worn)))))

(defun harness-ui-pet-3d--polygon-normal (verts indices)
  "The unit normal and the middle of the face INDICES of VERTS.
The result is (NX NY NZ CX CY CZ), or nil for a face without an area."
  (let ((nx 0.0) (ny 0.0) (nz 0.0) (cx 0.0) (cy 0.0) (cz 0.0) (count 0)
        (prev (car (last indices))))
    (dolist (i indices)
      (let ((x0 (aref verts (* 3 prev))) (y0 (aref verts (+ (* 3 prev) 1))) (z0 (aref verts (+ (* 3 prev) 2)))
            (x1 (aref verts (* 3 i))) (y1 (aref verts (+ (* 3 i) 1))) (z1 (aref verts (+ (* 3 i) 2))))
        (setq nx (+ nx (* (- y0 y1) (+ z0 z1)))
              ny (+ ny (* (- z0 z1) (+ x0 x1)))
              nz (+ nz (* (- x0 x1) (+ y0 y1)))
              cx (+ cx x1) cy (+ cy y1) cz (+ cz z1)
              count (1+ count)
              prev i)))
    (let ((len (sqrt (+ (* nx nx) (* ny ny) (* nz nz)))))
      (when (> len 1e-9)
        (list (/ nx len) (/ ny len) (/ nz len) (/ cx count) (/ cy count) (/ cz count))))))

(defun harness-ui-pet-3d--container (index piece)
  "The record (INDEX PIECE CX CY CZ R2) of PIECE, which hides what is inside it.
CX, CY and CZ are its middle and R2 the square of the radius of a ball
about it that holds the whole part: a point outside that is not inside it."
  (let* ((c (harness-ui-pet-3d--piece-center piece))
         (verts (harness-ui-pet-3d--piece-verts piece))
         (r2 0.0))
    (dotimes (i (/ (length verts) 3))
      (setq r2 (max r2 (+ (expt (- (aref verts (* 3 i)) (nth 0 c)) 2)
                          (expt (- (aref verts (+ (* 3 i) 1)) (nth 1 c)) 2)
                          (expt (- (aref verts (+ (* 3 i) 2)) (nth 2 c)) 2)))))
    (list index piece (nth 0 c) (nth 1 c) (nth 2 c) (* 1.002 r2))))

(defun harness-ui-pet-3d--buried-p (containers verts face own)
  "Non-nil when FACE, indices into VERTS, lies wholly inside one of CONTAINERS.
CONTAINERS are records of `harness-ui-pet-3d--container'; OWN is the index
of the part FACE belongs to, which cannot bury it."
  (let* ((i (car face))
         (x (aref verts (* 3 i))) (y (aref verts (+ (* 3 i) 1))) (z (aref verts (+ (* 3 i) 2))))
    (cl-loop for c in containers
             thereis (and (/= (car c) own)
                          (<= (+ (expt (- x (nth 2 c)) 2) (expt (- y (nth 3 c)) 2) (expt (- z (nth 4 c)) 2))
                              (nth 5 c))
                          (harness-ui-pet-3d--face-inside-p (nth 1 c) verts face)))))

(defun harness-ui-pet-3d--assemble (pieces start)
  "The mesh of PIECES, a model turned START degrees at rest.
Every face that lies wholly inside the volume of another part that is
not a detail is left out."
  (let* ((containers (cl-loop for piece in pieces
                              for i from 0
                              when (and (memq (car (harness-ui-pet-3d--piece-shape piece)) '(ball box tube))
                                        (zerop (logand 2 (harness-ui-pet-3d--piece-flags piece))))
                              collect (harness-ui-pet-3d--container i piece)))
         (verts nil) (nverts 0) (faces nil) (normals nil) (centers nil)
         (colors nil) (flags nil) (labels nil) (owners nil) (table nil) (total 0))
    (cl-loop
     for piece in pieces
     for i from 0
     do (let* ((pv (harness-ui-pet-3d--piece-verts piece))
               (remap (make-vector (/ (length pv) 3) nil))
               (label (harness-ui-pet-3d--piece-label piece))
               (rgb (or (harness-ui-pet-3d--piece-rgb piece) harness-ui-pet-3d--fallback-color))
               (slot (or (cl-position label table :key #'car :test #'equal)
                         (progn (setq table (append table (list (cons label rgb))))
                                (1- (length table))))))
          (dolist (face (harness-ui-pet-3d--piece-faces piece))
            (cl-incf total)
            (let ((n (harness-ui-pet-3d--polygon-normal pv face)))
              (when (and n (not (harness-ui-pet-3d--buried-p containers pv face i)))
                (push (vconcat
                       (mapcar (lambda (index)
                                 (or (aref remap index)
                                     (prog1 (aset remap index nverts)
                                       (cl-incf nverts)
                                       (push (aref pv (* 3 index)) verts)
                                       (push (aref pv (+ (* 3 index) 1)) verts)
                                       (push (aref pv (+ (* 3 index) 2)) verts))))
                               face))
                      faces)
                (push (nth 0 n) normals) (push (nth 1 n) normals) (push (nth 2 n) normals)
                (push (nth 3 n) centers) (push (nth 4 n) centers) (push (nth 5 n) centers)
                (push rgb colors)
                (push (harness-ui-pet-3d--piece-flags piece) flags)
                (push slot labels)
                (push i owners))))))
    (setq verts (vconcat (nreverse verts))
          faces (vconcat (nreverse faces))
          normals (vconcat (nreverse normals))
          centers (vconcat (nreverse centers)))
    (let ((radius 0.0) (smin 1e9) (smax -1e9)
          (cp (cos (degrees-to-radians harness-ui-pet-3d--tilt)))
          (sp (sin (degrees-to-radians harness-ui-pet-3d--tilt)))
          (order (harness-ui-pet-3d--order-tree verts faces normals centers
                                                (vconcat (nreverse owners)) pieces)))
      (dotimes (i (/ (length verts) 3))
        (let* ((x (aref verts (* 3 i))) (y (aref verts (+ (* 3 i) 1))) (z (aref verts (+ (* 3 i) 2)))
               (r (sqrt (+ (* x x) (* z z)))))
          (setq radius (max radius r)
                smin (min smin (- (* -1.0 y cp) (* r sp)))
                smax (max smax (- (* -1.0 y cp) (- (* r sp)))))))
      (harness-ui-pet-3d--mesh verts faces normals centers (vconcat (nreverse colors))
                               (vconcat (nreverse flags)) (vconcat (nreverse labels)) table
                               (float (if (numberp start) start 0)) radius smin smax total pieces
                               (nth 0 order) (nth 1 order) (nth 2 order) (nth 3 order)
                               (nth 4 order) (nth 5 order) (nth 6 order)))))

(defvar harness-ui-pet-3d--meshes (make-hash-table :test 'eq :weakness 'key)
  "The meshes built, by model and then by hat model, or `none'.")

(defun harness-ui-pet-3d--mesh-of (model hat)
  "The mesh of MODEL wearing HAT, which are plists, built once."
  (let ((per-model (or (gethash model harness-ui-pet-3d--meshes)
                       (puthash model (make-hash-table :test 'eq) harness-ui-pet-3d--meshes)))
        (key (or hat 'none)))
    (or (gethash key per-model)
        (puthash key
                 (harness-ui-pet-3d--assemble (harness-ui-pet-3d--pieces model hat)
                                              (plist-get model :start))
                 per-model))))

(defvar harness-ui-pet-3d--frames (make-hash-table :test 'equal)
  "The images made by `harness-ui-pet-3d-frame'.")

(defun harness-ui-pet-3d-clear ()
  "Forget the meshes and the images built so far."
  (clrhash harness-ui-pet-3d--meshes)
  (clrhash harness-ui-pet-3d--frames))

;;;; Turning, shading and ordering

(defun harness-ui-pet-3d--draw-order (mesh facing ex ey ez)
  "The polygons to draw for a view of MESH, far to near, and their points.
FACING is a bool vector of the faces that look at the viewer and (EX EY
EZ) the way to the viewer in the model's space.  The result is (ORDER .
POINTS): ORDER a list of (FACE . CORNERS), CORNERS a vector of indices
into POINTS, which are the mesh's points and those that cutting the
details for this view added.

The details that look at the viewer go down the tree first, as if
`harness-ui-pet-3d--detail-bias' nearer the viewer, cut where they cross a
plane, and stay where they land: in front of or behind a node that has
nothing there.  Then the tree is walked back to front: at each node
first the side of its plane away from the viewer, then the polygons in
the plane, then the side toward the viewer, a side with no node being
the details that landed there, each part after those named before it."
  (let* ((eps harness-ui-pet-3d--on-plane)
         (bias harness-ui-pet-3d--detail-bias)
         (faces (harness-ui-pet-3d--mesh-faces mesh))
         (normals (harness-ui-pet-3d--mesh-normals mesh))
         (offsets (harness-ui-pet-3d--mesh-offsets mesh))
         (balls (harness-ui-pet-3d--mesh-balls mesh))
         (sources (harness-ui-pet-3d--mesh-sources mesh))
         (polygons (harness-ui-pet-3d--mesh-polygons mesh))
         (root (harness-ui-pet-3d--mesh-tree mesh))
         (static (harness-ui-pet-3d--mesh-points mesh))
         (points static)
         (used (length static))
         (fronts (make-hash-table :test 'eq))
         (backs (make-hash-table :test 'eq))
         (loose nil) (groups nil) (out nil))
    (dolist (group (harness-ui-pet-3d--mesh-details mesh))
      (let ((fragments (cl-loop for f in (cdr group)
                                when (aref facing f)
                                collect (cons f (append (aref faces f) nil)))))
        (when fragments (push (cons (car group) fragments) groups))))
    (setq groups (nreverse groups))
    (cl-flet ((add-point (x y z)
                ;; The mesh's own points are shared by every view: a view's go after them.
                (when (eq points static)
                  (setq points (vconcat static (make-vector 300 0.0))))
                (when (> (+ used 3) (length points))
                  (setq points (vconcat points (make-vector (length points) 0.0))))
                (aset points used x)
                (aset points (1+ used) y)
                (aset points (+ used 2) z)
                (prog1 (/ used 3) (setq used (+ used 3)))))
      ;; The details down the tree.
      (if (null root)
          (setq loose groups)
        (let ((stack (and groups (list (cons root groups)))))
          (while stack
            (pcase-let* ((`(,node . ,groups) (pop stack))
                         (f (aref node 0))
                         (nx (aref normals (* 3 f)))
                         (ny (aref normals (+ (* 3 f) 1)))
                         (nz (aref normals (+ (* 3 f) 2)))
                         ;; A point moved BIAS toward the viewer is BIAS times
                         ;; N.E further in front of the plane.
                         (d (- (aref offsets f) (* bias (+ (* nx ex) (* ny ey) (* nz ez)))))
                         (front nil) (back nil))
              (dolist (group groups)
                (let* ((p (car group))
                       (middle (- (+ (* nx (aref balls (* 4 p))) (* ny (aref balls (+ (* 4 p) 1)))
                                     (* nz (aref balls (+ (* 4 p) 2))))
                                  d))
                       (reach (+ eps (aref balls (+ (* 4 p) 3)))))
                  (cond
                   ((> middle reach) (push group front))
                   ((< middle (- reach)) (push group back))
                   (t
                    (let ((ahead nil) (behind nil))
                      (dolist (fragment (cdr group))
                        (pcase (harness-ui-pet-3d--cut fragment points nx ny nz d #'add-point)
                          ('back (push fragment behind))
                          (`(,a . ,b) (when a (push a ahead)) (when b (push b behind)))
                          (_ (push fragment ahead))))
                      (when ahead (push (cons p (nreverse ahead)) front))
                      (when behind (push (cons p (nreverse behind)) back)))))))
              (when front
                (setq front (nreverse front))
                (if (aref node 2) (push (cons (aref node 2) front) stack) (puthash node front fronts)))
              (when back
                (setq back (nreverse back))
                (if (aref node 3) (push (cons (aref node 3) back) stack) (puthash node back backs))))))))
    ;; The walk, back to front.
    (let ((stack (cond (root (list root)) (loose (list (cons 'details loose))))))
      (while stack
        (let ((item (pop stack)))
          (cond
           ((vectorp item)
            (let* ((i (* 3 (aref item 0)))
                   (front (or (aref item 2)
                              (let ((landed (gethash item fronts))) (and landed (cons 'details landed)))))
                   (back (or (aref item 3)
                             (let ((landed (gethash item backs))) (and landed (cons 'details landed))))))
              (if (> (+ (* ex (aref normals i)) (* ey (aref normals (1+ i))) (* ez (aref normals (+ i 2)))) 0.0)
                  (progn (when front (push front stack))
                         (push (aref item 1) stack)
                         (when back (push back stack)))
                (when back (push back stack))
                (push (aref item 1) stack)
                (when front (push front stack)))))
           ((eq (car-safe item) 'details)
            (dolist (group (cdr item))
              (dolist (fragment (cdr group))
                (push (cons (car fragment) (vconcat (cdr fragment))) out))))
           (t
            (dolist (id item)
              (let ((f (aref sources id)))
                (when (aref facing f)
                  (push (cons f (aref polygons id)) out)))))))))
    (cons (nreverse out) (if (eq points static) static (substring points 0 used)))))

(defun harness-ui-pet-3d--view (mesh angle width height)
  "MESH turned ANGLE degrees past its start, fitted to a WIDTH by HEIGHT box.
The result is (ORDER SX SY SHADE).  ORDER lists the polygons to draw, far
to near, each (FACE . CORNERS) (`harness-ui-pet-3d--draw-order'): those of
the faces that look at the viewer, some of them cut in pieces.  SX and SY
are vectors of the screen coordinates of the corners in tenths of a
pixel.  SHADE holds the light on each face."
  (let* ((th (degrees-to-radians (+ (harness-ui-pet-3d--mesh-start mesh) angle)))
         (c (cos th)) (s (sin th))
         (ph (degrees-to-radians harness-ui-pet-3d--tilt))
         (cp (cos ph)) (sp (sin ph))
         (normals (harness-ui-pet-3d--mesh-normals mesh))
         (flags (harness-ui-pet-3d--mesh-flags mesh))
         (nfaces (length flags))
         (radius (max 1e-6 (harness-ui-pet-3d--mesh-radius mesh)))
         (smin (harness-ui-pet-3d--mesh-smin mesh))
         (smax (harness-ui-pet-3d--mesh-smax mesh))
         (extent (max 1e-6 (- smax smin)))
         (scale (min (/ (* harness-ui-pet-3d--fill width) (* 2.0 radius))
                     (/ (* harness-ui-pet-3d--fill height) extent)))
         (ox (/ width 2.0))
         (oy (- (* (- 1.0 harness-ui-pet-3d--margin) height) (* scale smax)))
         (lx (aref harness-ui-pet-3d--light 0))
         (ly (aref harness-ui-pet-3d--light 1))
         (lz (aref harness-ui-pet-3d--light 2))
         (shade (make-vector nfaces 1.0))
         (facing (make-bool-vector nfaces nil)))
    (dotimes (f nfaces)
      (let* ((nx (aref normals (* 3 f))) (ny (aref normals (+ (* 3 f) 1))) (nz (aref normals (+ (* 3 f) 2)))
             (n1z (- (* nz c) (* nx s)))
             (n2z (+ (* ny sp) (* n1z cp))))
        (when (> n2z 1e-6)
          (let ((n1x (+ (* nx c) (* nz s)))
                (n2y (- (* ny cp) (* n1z sp))))
            (aset facing f t)
            (aset shade f
                  (if (zerop (logand 1 (aref flags f)))
                      (min 1.05 (+ 0.58 (* 0.47 (max 0.0 (+ (* lx n1x) (* ly n2y) (* lz n2z))))))
                    1.0))))))
    ;; The way to the viewer, in the model's space, is what the turn and
    ;; the tilt take to (0 0 1).
    (let* ((drawn (harness-ui-pet-3d--draw-order mesh facing (- (* s cp)) sp (* c cp)))
           (points (cdr drawn))
           (npoints (/ (length points) 3))
           (sx (make-vector npoints 0))
           (sy (make-vector npoints 0)))
      (dotimes (i npoints)
        (let* ((x (aref points (* 3 i))) (y (aref points (+ (* 3 i) 1))) (z (aref points (+ (* 3 i) 2)))
               (x1 (+ (* x c) (* z s)))
               (z1 (- (* z c) (* x s)))
               (y2 (- (* y cp) (* z1 sp))))
          (aset sx i (floor (+ 0.5 (* 10.0 (+ ox (* scale x1))))))
          (aset sy i (floor (+ 0.5 (* 10.0 (- oy (* scale y2))))))))
      (list (car drawn) sx sy shade))))

;;;; Output

(defvar harness-ui-pet-3d--tenths (make-vector 8001 nil)
  "The text of a coordinate in tenths of a pixel, 0.0 to 800.0, made on use.")

(defsubst harness-ui-pet-3d--tenth (n)
  "N tenths of a pixel as text."
  (if (and (>= n 0) (< n 8001))
      (or (aref harness-ui-pet-3d--tenths n)
          (aset harness-ui-pet-3d--tenths n (format "%d.%d" (/ n 10) (% n 10))))
    (format "%.1f" (/ n 10.0))))

(defun harness-ui-pet-3d--face-color (rgb intensity)
  "RGB, a colour as 0xRRGGBB, in the light INTENSITY, as six hex digits."
  (let ((r (min 255 (floor (+ 0.5 (* intensity (ash rgb -16))))))
        (g (min 255 (floor (+ 0.5 (* intensity (logand (ash rgb -8) 255))))))
        (b (min 255 (floor (+ 0.5 (* intensity (logand rgb 255)))))))
    (concat (aref harness-ui-pet-3d--hex r) (aref harness-ui-pet-3d--hex g) (aref harness-ui-pet-3d--hex b))))

(defun harness-ui-pet-3d--svg-header (width height)
  "The start of an SVG document WIDTH by HEIGHT pixels, and of its group."
  (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\""
                  " viewBox=\"0 0 %s %s\"><g stroke-width=\"0.6\" stroke-linejoin=\"round\">")
          width height width height))

(defun harness-ui-pet-3d--svg-of-mesh (mesh angle width height)
  "The SVG document of MESH turned ANGLE degrees, WIDTH by HEIGHT pixels."
  (let* ((view (harness-ui-pet-3d--view mesh angle width height))
         (sx (nth 1 view)) (sy (nth 2 view)) (shade (nth 3 view))
         (colors (harness-ui-pet-3d--mesh-colors mesh))
         (out (list (harness-ui-pet-3d--svg-header width height))))
    (dolist (polygon (car view))
      (let* ((f (car polygon))
             (hex (harness-ui-pet-3d--face-color (aref colors f) (aref shade f))))
        (push (concat "<polygon fill=\"#" hex "\" stroke=\"#" hex "\" points=\"") out)
        (let ((first t))
          (mapc (lambda (v)
                  (unless first (push " " out))
                  (setq first nil)
                  (push (harness-ui-pet-3d--tenth (aref sx v)) out)
                  (push "," out)
                  (push (harness-ui-pet-3d--tenth (aref sy v)) out))
                (cdr polygon)))
        (push "\"/>" out)))
    (push "</g></svg>" out)
    (mapconcat #'identity (nreverse out) "")))

;;;; The API

(defun harness-ui-pet-3d--mesh-for (model hat)
  "The mesh of MODEL, a species or a model, wearing HAT, or nil without a model."
  (let ((m (harness-ui-pet-3d--resolve-model model)))
    (and m (harness-ui-pet-3d--mesh-of m (harness-ui-pet-3d--resolve-hat hat)))))

(defun harness-ui-pet-3d-svg (model hat angle width height)
  "An SVG document of MODEL wearing HAT, turned ANGLE degrees, WIDTH by HEIGHT.
MODEL is a species, a symbol or a string, or a model plist; HAT is the
name of a hat or nil.  ANGLE is added to the model's `:start'.  The
background is transparent.  The fit is that of a whole turn, so the
model does not change size or place as ANGLE does.  A model or a hat that
is not known draws nothing."
  (let ((mesh (harness-ui-pet-3d--mesh-for model hat)))
    (if mesh
        (harness-ui-pet-3d--svg-of-mesh mesh angle width height)
      (concat (harness-ui-pet-3d--svg-header width height) "</g></svg>"))))

(defun harness-ui-pet-3d-frame (species hat step width height)
  "Step STEP of a turn of SPECIES wearing HAT, as an image WIDTH by HEIGHT.
STEP is 0 to `harness-ui-pet-3d-count' minus 1.  The image descriptor is
cached by its arguments.  The result is nil when SPECIES has no model or
this Emacs shows no SVG."
  (let ((model (harness-ui-pet-3d-model species)))
    (when (and model (image-type-available-p 'svg))
      (let* ((hat-model (harness-ui-pet-3d--resolve-hat hat))
             (step (mod step harness-ui-pet-3d-count))
             (key (list model hat-model step width height)))
        (or (gethash key harness-ui-pet-3d--frames)
            (progn
              (when (> (hash-table-count harness-ui-pet-3d--frames) 256)
                (clrhash harness-ui-pet-3d--frames))
              (puthash key
                       (create-image
                        (harness-ui-pet-3d-svg model hat
                                               (* step (/ 360.0 harness-ui-pet-3d-count))
                                               width height)
                        'svg t :ascent 'center :scale 1)
                       harness-ui-pet-3d--frames)))))))

;;;; Text maps

(defun harness-ui-pet-3d--letters (table)
  "A letter for each colour of TABLE, a list of (LABEL . RGB), as a vector.
A named colour takes the first letter of its name that nobody has, any
other the next capital."
  (let ((used nil) (pool (string-to-list "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) (letters nil))
    (dolist (entry table)
      (let* ((label (car entry))
             (name (if (symbolp label) (symbol-name label) ""))
             (letter (or (cl-find-if (lambda (ch) (and (<= ?a ch ?z) (not (memq ch used))))
                                     (downcase name))
                         (progn (while (and pool (memq (car pool) used)) (pop pool))
                                (pop pool))
                         ??)))
        (push letter used)
        (push letter letters)))
    (vconcat (nreverse letters))))

(defun harness-ui-pet-3d--point-in-polygon-p (x y xs ys)
  "Non-nil when (X Y) lies in the polygon of corners XS and YS, lists.
The polygon holds what SVG fills of it, by the nonzero rule: the points
it winds round.  Corners rounded to a tenth of a pixel can turn back on
themselves where a cut ran close by a corner, which leaves a convex
polygon not quite so; that takes nothing away from it.  A polygon with
no area, its corners on a line, holds no point."
  (let ((winding 0) (ax (car (last xs))) (ay (car (last ys))))
    (cl-mapc (lambda (bx by)
               (let ((cross (- (* (- bx ax) (- y ay)) (* (- by ay) (- x ax)))))
                 (cond ((and (<= ay y) (> by y) (> cross 0)) (setq winding (1+ winding)))
                       ((and (> ay y) (<= by y) (< cross 0)) (setq winding (1- winding)))))
               (setq ax bx ay by))
             xs ys)
    (/= winding 0)))

(defun harness-ui-pet-3d--cells (mesh angle cols rows)
  "The face drawn last over the middle of each cell, and the light on each.
MESH is turned ANGLE degrees and fitted to COLS wide cells that are twice as
tall as wide, ROWS of them.  The result is (CELLS . SHADE).  CELLS is a
vector of ROWS times COLS face indices, nil where no face is, and SHADE
a vector of the light on each face."
  (let* ((view (harness-ui-pet-3d--view mesh angle cols (* 2 rows)))
         (sx (nth 1 view)) (sy (nth 2 view))
         (cells (make-vector (* rows cols) nil)))
    (dolist (polygon (car view))
      (let* ((f (car polygon))
             (xs (mapcar (lambda (v) (/ (aref sx v) 10.0)) (cdr polygon)))
             (ys (mapcar (lambda (v) (/ (aref sy v) 10.0)) (cdr polygon)))
             (i0 (max 0 (floor (- (apply #'min xs) 0.5))))
             (i1 (min (1- cols) (ceiling (- (apply #'max xs) 0.5))))
             (j0 (max 0 (floor (- (/ (apply #'min ys) 2.0) 0.5))))
             (j1 (min (1- rows) (ceiling (- (/ (apply #'max ys) 2.0) 0.5)))))
        (cl-loop for j from j0 to j1
                 do (cl-loop for i from i0 to i1
                             when (harness-ui-pet-3d--point-in-polygon-p (+ i 0.5) (+ (* 2.0 j) 1.0) xs ys)
                             do (aset cells (+ (* j cols) i) f)))))
    (cons cells (nth 3 view))))

(defun harness-ui-pet-3d-preview (model hat angle cols rows &optional shade)
  "A text map of MODEL wearing HAT, turned ANGLE degrees, ROWS by COLS cells.
MODEL is a species or a model plist, HAT the name of a hat or nil.  The
cells are twice as tall as wide, as a terminal's are.  Each shows the
letter of the colour of the face drawn last over its middle, or a dot
where there is none.  A legend line under the map says which letter is
which colour and how many cells it has.

With SHADE non-nil each cell shows instead a digit, 0 for the faces the
light reaches least up to 9 for the most, which shows the form."
  (let* ((mesh (harness-ui-pet-3d--mesh-for model hat))
         (table (and mesh (harness-ui-pet-3d--mesh-table mesh)))
         (letters (harness-ui-pet-3d--letters table))
         (drawn (if mesh
                    (harness-ui-pet-3d--cells mesh angle cols rows)
                  (cons (make-vector (* rows cols) nil) (vector))))
         (cells (car drawn))
         (light (cdr drawn))
         (labels (and mesh (harness-ui-pet-3d--mesh-labels mesh)))
         (counts (make-vector (length table) 0))
         (lines nil))
    (dotimes (j rows)
      (let ((line (make-string cols ?.)))
        (dotimes (i cols)
          (let ((f (aref cells (+ (* j cols) i))))
            (when f
              (let ((slot (aref labels f)))
                (aset line i (if shade
                                 (+ ?0 (max 0 (min 9 (floor (* 10.0 (/ (- (aref light f) 0.58) 0.47))))))
                               (aref letters slot)))
                (cl-incf (aref counts slot))))))
        (push line lines)))
    (push (cond ((null mesh) "no model")
                (shade "legend: 0 is the least light, 9 the most; . is nothing")
                (t (concat "legend:"
                           (cl-loop for entry in table
                                    for k from 0
                                    concat (format " %c=%s(%d)" (aref letters k)
                                                   (if (symbolp (car entry)) (symbol-name (car entry)) (car entry))
                                                   (aref counts k)))
                           " .=none")))
          lines)
    (mapconcat #'identity (nreverse lines) "\n")))

(defun harness-ui-pet-3d-print-previews (&optional species angles hats cols rows shade)
  "Print text maps of SPECIES to standard output, for a batch Emacs.
SPECIES is a species, a list of them, or t for all that
`harness-ui-pet-models' has.  Each is drawn at every one of ANGLES, by
default 0, 45, 90, 180 and 270 degrees, and for every one of HATS, a list
of hat names where nil means none, by default just that.  Maps are COLS
wide (default 60) and ROWS tall (30).  A line before each says what it
is, and how many faces it has.  The maps show the colours; with SHADE t
they show the light instead, and with SHADE `both' each map is followed by
that one."
  (let ((species (cond ((eq species t) (mapcar #'car harness-ui-pet-models))
                       ((and species (symbolp species)) (list species))
                       (t species))))
    (dolist (name species)
      (dolist (hat (or hats '(nil)))
        (dolist (angle (or angles '(0 45 90 180 270)))
          (let ((mesh (harness-ui-pet-3d--mesh-for name hat)))
            (princ (format "== %s hat=%s angle=%s faces=%s of %s\n" name (or hat "none") angle
                           (if mesh (length (harness-ui-pet-3d--mesh-flags mesh)) 0)
                           (if mesh (harness-ui-pet-3d--mesh-total mesh) 0)))
            (dolist (mode (pcase shade ('both '(nil t)) ('t '(t)) (_ '(nil))))
              (princ (harness-ui-pet-3d-preview name hat angle (or cols 60) (or rows 30) mode))
              (princ "\n\n"))))))))

;;;; Looking after models

(defun harness-ui-pet-3d-stats (model &optional hat)
  "Numbers about MODEL wearing HAT, a plist, or nil without a model.
It has `:faces' drawn after the hidden ones go, `:total' faces before,
`:polygons' (the faces but the details', as the order tree cut them;
the details are cut for each view), `:vertices', `:parts', `:radius'
\(the greatest distance from the vertical axis) and `:height' (what the
camera sees, as it turns), in model units."
  (let ((mesh (harness-ui-pet-3d--mesh-for model hat)))
    (when mesh
      (list :faces (length (harness-ui-pet-3d--mesh-flags mesh))
            :total (harness-ui-pet-3d--mesh-total mesh)
            :polygons (length (harness-ui-pet-3d--mesh-polygons mesh))
            :vertices (/ (length (harness-ui-pet-3d--mesh-verts mesh)) 3)
            :parts (length (harness-ui-pet-3d--mesh-pieces mesh))
            :radius (harness-ui-pet-3d--mesh-radius mesh)
            :height (- (harness-ui-pet-3d--mesh-smax mesh) (harness-ui-pet-3d--mesh-smin mesh))))))

(defun harness-ui-pet-3d--nearly-black-p (rgb)
  "Non-nil when RGB, a colour as 0xRRGGBB, is nearly black."
  (< (max (ash rgb -16) (logand (ash rgb -8) 255) (logand rgb 255)) #x28))

(defconst harness-ui-pet-3d--part-keys
  '((ball :at :turn :color :mirror :detail :flat :size :half :sides)
    (box :at :turn :color :mirror :detail :flat :size)
    (tube :at :turn :color :mirror :detail :flat :radius :top :height :sides)
    (ring :at :turn :color :mirror :detail :flat :radius :thickness :sides))
  "The keys each kind of part takes.")

(defun harness-ui-pet-3d--touches-p (a b)
  "Non-nil when the pieces A and B overlap or nearly touch."
  (cl-flet ((samples-in (from into)
              (let ((verts (harness-ui-pet-3d--piece-verts from)))
                (cl-loop for i below (/ (length verts) 3)
                         thereis (and (harness-ui-pet-3d--inside-p
                                       into 1.0 (aref verts (* 3 i)) (aref verts (+ (* 3 i) 1))
                                       (aref verts (+ (* 3 i) 2)) 0.08)
                                      t)))))
    (or (and (harness-ui-pet-3d--piece-shape b) (samples-in a b))
        (and (harness-ui-pet-3d--piece-shape a) (samples-in b a))
        (let ((va (harness-ui-pet-3d--piece-verts a)) (vb (harness-ui-pet-3d--piece-verts b)))
          (cl-loop for i below (/ (length va) 3)
                   thereis (cl-loop for j below (/ (length vb) 3)
                                    thereis (< (+ (expt (- (aref va (* 3 i)) (aref vb (* 3 j))) 2)
                                                  (expt (- (aref va (+ (* 3 i) 1)) (aref vb (+ (* 3 j) 1))) 2)
                                                  (expt (- (aref va (+ (* 3 i) 2)) (aref vb (+ (* 3 j) 2))) 2))
                                               0.0064)))))))

(defun harness-ui-pet-3d--near-p (a b)
  "Non-nil when the balls of the records A and B overlap or nearly touch.
The records are those of `harness-ui-pet-3d--container'."
  (let ((reach (+ (sqrt (nth 5 a)) (sqrt (nth 5 b)) 0.1)))
    (<= (+ (expt (- (nth 2 a) (nth 2 b)) 2) (expt (- (nth 3 a) (nth 3 b)) 2) (expt (- (nth 4 a) (nth 4 b)) 2))
        (* reach reach))))

(defun harness-ui-pet-3d--floating-parts (pieces)
  "The indices of PIECES that touch none of the biggest group that touch."
  (let* ((n (length pieces))
         (vec (vconcat pieces))
         (balls (vconcat (cl-loop for piece in pieces for i from 0
                                  collect (harness-ui-pet-3d--container i piece))))
         (group (make-vector n nil))
         (groups 0))
    (dotimes (i n)
      (unless (aref group i)
        (let ((stack (list i)))
          (aset group i groups)
          (while stack
            (let ((a (pop stack)))
              (dotimes (b n)
                (when (and (not (aref group b))
                           (harness-ui-pet-3d--near-p (aref balls a) (aref balls b))
                           (harness-ui-pet-3d--touches-p (aref vec a) (aref vec b)))
                  (aset group b groups)
                  (push b stack)))))
          (cl-incf groups))))
    (let ((best 0) (best-size 0))
      (dotimes (g groups)
        (let ((size (cl-count g group)))
          (when (> size best-size) (setq best g best-size size))))
      (cl-loop for i below n unless (eql (aref group i) best) collect i))))

(defun harness-ui-pet-3d-problems (model &optional hat)
  "What is wrong with MODEL wearing HAT, as a list of messages; nil if nothing.
MODEL is a species or a plist.  It looks for parts of a kind or with keys
that are not known, colours that are not, a `:head' that is not four
numbers, more faces than a species should have, a colour that is black
but for the eyes, and parts that float free of the rest (a hat's too,
which the halo should)."
  (let* ((name (and (not (harness-ui-pet-3d--model-p model)) model))
         (m (harness-ui-pet-3d--resolve-model model))
         (hat-model (harness-ui-pet-3d--resolve-hat hat))
         (problems nil))
    (cl-flet ((note (fmt &rest args) (push (apply #'format fmt args) problems)))
      (cond
       ((null m) (note "%s: no such model" (or name "model")))
       (t
        (unless (harness-ui-pet-3d--head-p (plist-get m :head))
          (note ":head must be (X Y Z RADIUS), numbers"))
        (unless (or (null (plist-get m :start)) (numberp (plist-get m :start)))
          (note ":start must be a number of degrees"))
        (unless (plist-get m :parts) (note "no :parts"))
        (dolist (entry (list (cons "model" m) (cons "hat" hat-model)))
          (when (cdr entry)
            (let ((palette (plist-get (cdr entry) :palette)))
              (dolist (color palette)
                (unless (and (symbolp (car-safe color)) (harness-ui-pet-3d--parse-color (cdr-safe color)))
                  (note "palette entry %S is not (NAME . \"#rrggbb\")" color)))
              (dolist (part (plist-get (cdr entry) :parts))
                (let ((allowed (cdr (assq (car-safe part) harness-ui-pet-3d--part-keys))))
                  (if (null allowed)
                      (note "%s part of unknown kind %S" (car entry) (car-safe part))
                    (let ((plist (cdr part)))
                      (while plist
                        (unless (memq (car plist) allowed)
                          (note "%s %s at %S: unknown key %S" (car entry) (car part)
                                (plist-get (cdr part) :at) (car plist)))
                        (setq plist (cddr plist)))
                      (let* ((color (harness-ui-pet-3d--resolve-color (plist-get (cdr part) :color) palette)))
                        (cond ((null (car color))
                               (note "%s %s at %S has no :color" (car entry) (car part) (plist-get (cdr part) :at)))
                              ((null (cdr color))
                               (note "%s %s at %S: colour %S is not known" (car entry) (car part)
                                     (plist-get (cdr part) :at) (car color)))
                              ((and (harness-ui-pet-3d--nearly-black-p (cdr color)) (not (eq (car color) 'eye)))
                               (note "%s %s at %S: colour %S is nearly black" (car entry) (car part)
                                     (plist-get (cdr part) :at) (car color)))))
                      (unless (and (consp (plist-get (cdr part) :at))
                                   (= (length (plist-get (cdr part) :at)) 3))
                        (note "%s %s: :at must be (X Y Z)" (car entry) (car part)))))))))
          )
        (let ((mesh (harness-ui-pet-3d--mesh-of m hat-model)))
          (when (> (harness-ui-pet-3d--mesh-total (harness-ui-pet-3d--mesh-of m nil))
                   harness-ui-pet-3d--max-faces)
            (note "%d faces before the hidden ones go, more than %d"
                  (harness-ui-pet-3d--mesh-total (harness-ui-pet-3d--mesh-of m nil))
                  harness-ui-pet-3d--max-faces))
          (let ((pieces (harness-ui-pet-3d--mesh-pieces mesh)))
            (dolist (i (harness-ui-pet-3d--floating-parts pieces))
              (let ((piece (nth i pieces)))
                (note "%s at (%s) floats free of the rest"
                      (harness-ui-pet-3d--piece-kind piece)
                      (mapconcat (lambda (v) (format "%.2f" v))
                                 (harness-ui-pet-3d--piece-center piece) " "))))))))
      (nreverse problems))))

(provide 'harness-ui-pet-3d)
;;; harness-ui-pet-3d.el ends here
