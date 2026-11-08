;;; harness-ui-pet-3d-test.el --- Tests for the pet's 3D renderer and its models  -*- lexical-binding: t; -*-
;;; Commentary:

;; The low-poly renderer behind the companion pet's spin
;; (`harness-ui-pet-3d') and the models it draws (`harness-ui-pet-models'):
;; the closed meshes of each kind of part, how they turn, mirror and
;; leave out what is buried, the view and its light, the order faces are
;; drawn in (its BSP tree, and what it draws checked cell by cell against
;; the nearest face found by brute force), where details show, the fit of
;; a whole turn in its box, the SVG, the images that are cached, and the
;; models and hats themselves.  The renderer needs nothing of the
;; harness, so none of this needs a UI.

;;; Code:

(require 'harness-test-helpers)
(require 'cl-lib)
(require 'harness)

;; The harness loads its files compiled, and so do the tests: it is the
;; speed they have there, and a file that does not compile fails here.
(dolist (name '("harness-ui-pet-models" "harness-ui-pet-3d"))
  (harness-load-compiled (expand-file-name (format "lisp/ui/%s.el" name) harness-test-root)))

(defvar harness-ui-pet-models)
(defvar harness-ui-pet-hat-models)
(defvar harness-ui-pet-3d-count)
(defvar harness-ui-pet-3d-tick)
(defvar harness-ui-pet-3d--frames)
(defvar harness-ui-pet-3d--detail-bias)
(defvar harness-ui-pet-3d--tilt)
(declare-function harness-ui-pet-3d-model "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-svg "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-frame "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-preview "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-stats "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-problems "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-clear "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d-print-previews "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--ball-geometry "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--box-geometry "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--tube-geometry "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--ring-geometry "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--polygon-normal "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--rotation "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--make-piece "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--pieces "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-of "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-for "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-verts "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-faces "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-flags "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-normals "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-centers "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-total "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--view "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--piece-verts "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--piece-center "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-points "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-polygons "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-sources "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-offsets "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-tree "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-labels "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-table "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--letters "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--point-in-polygon-p "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--mesh-start "harness-ui-pet-3d")
(declare-function harness-ui-pet-3d--cells "harness-ui-pet-3d")

(defconst harness-ui-pet-3d-test--hats
  '(crown tophat propeller halo wizard beanie tinyduck)
  "The hats of the pet, as `harness-ui-pet--hats' names them.")

(defconst harness-ui-pet-3d-test--starts
  '((duck . -90) (snail . -90) (turtle . -90) (goose . 90))
  "The way each species that does not face the viewer faces at rest.")

;;;; Helpers

(defun harness-ui-pet-3d-test--model (&rest parts)
  "A model of PARTS, a grey one with its head at the top of a unit ball."
  (list :palette '((grey . "#808080") (red . "#c03030") (blue . "#3050c0"))
        :head '(0.0 2.0 0.0 1.0) :start 0 :parts parts))

(defun harness-ui-pet-3d-test--ball ()
  "A model that is a ball of radius 1 on y = 1."
  (harness-ui-pet-3d-test--model '(ball :at (0 1 0) :size 1 :color grey)))

(defun harness-ui-pet-3d-test--flat (vertices)
  "The list VERTICES, each (X Y Z), as one vector of numbers."
  (apply #'vconcat (mapcar #'vconcat vertices)))

(defun harness-ui-pet-3d-test--normals (geometry)
  "For each face of GEOMETRY, (NX NY NZ CX CY CZ): its normal and its middle."
  (let ((flat (harness-ui-pet-3d-test--flat (car geometry))))
    (mapcar (lambda (face) (harness-ui-pet-3d--polygon-normal flat face)) (cdr geometry))))

(defun harness-ui-pet-3d-test--dot (n point)
  "The dot product of the normal of N, a face's (NX NY NZ ...), and POINT."
  (+ (* (nth 0 n) (nth 0 point)) (* (nth 1 n) (nth 1 point)) (* (nth 2 n) (nth 2 point))))

(defun harness-ui-pet-3d-test--inward (geometry &optional center)
  "The number of faces of GEOMETRY whose normal does not point away from CENTER."
  (let ((center (or center '(0.0 0.0 0.0))))
    (cl-count-if-not
     (lambda (n)
       (> (harness-ui-pet-3d-test--dot n (list (- (nth 3 n) (nth 0 center))
                                               (- (nth 4 n) (nth 1 center))
                                               (- (nth 5 n) (nth 2 center))))
          1e-9))
     (harness-ui-pet-3d-test--normals geometry))))

(defun harness-ui-pet-3d-test--euler (geometry)
  "The Euler characteristic of GEOMETRY, or nil when it is not closed.
Closed means every edge is shared by two faces, once going each way."
  (let ((edges (make-hash-table :test 'equal)) (closed t) (count 0))
    (dolist (face (cdr geometry))
      (let ((prev (car (last face))))
        (dolist (i face)
          (cl-incf (gethash (cons prev i) edges 0))
          (setq prev i))))
    (maphash (lambda (edge n)
               (cl-incf count)
               (unless (and (= n 1) (eql 1 (gethash (cons (cdr edge) (car edge)) edges)))
                 (setq closed nil)))
             edges)
    (and closed (- (+ (length (car geometry)) (length (cdr geometry))) (/ count 2)))))

(defun harness-ui-pet-3d-test--polygons (svg)
  "The polygons of the SVG document string SVG: a list of (FILL STROKE POINTS).
POINTS is a list of (X . Y)."
  (let ((pos 0) out)
    (while (string-match "<polygon fill=\"#\\([0-9a-f]\\{6\\}\\)\" stroke=\"#\\([0-9a-f]\\{6\\}\\)\" points=\"\\([^\"]*\\)\"/>"
                         svg pos)
      (setq pos (match-end 0))
      (push (list (match-string 1 svg) (match-string 2 svg)
                  (mapcar (lambda (pair)
                            (let ((xy (split-string pair ",")))
                              (cons (string-to-number (car xy)) (string-to-number (cadr xy)))))
                          (split-string (match-string 3 svg) " " t)))
            out))
    (nreverse out)))

(defun harness-ui-pet-3d-test--channels (hex)
  "The three channels of the colour HEX, six hex digits, as a list of numbers."
  (list (string-to-number (substring hex 0 2) 16)
        (string-to-number (substring hex 2 4) 16)
        (string-to-number (substring hex 4 6) 16)))

(defun harness-ui-pet-3d-test--centroid (points)
  "The middle of POINTS, a list of (X . Y)."
  (let ((n (float (length points))))
    (cons (/ (apply #'+ (mapcar #'car points)) n) (/ (apply #'+ (mapcar #'cdr points)) n))))

(defun harness-ui-pet-3d-test--visible (model &optional hat angle)
  "The number of faces of MODEL wearing HAT that look at the viewer at ANGLE."
  (length (car (harness-ui-pet-3d--view (harness-ui-pet-3d--mesh-for model hat) (or angle 0) 150 100))))

(defun harness-ui-pet-3d-test--vertex-set (mesh)
  "The vertices of MESH as a list of (X Y Z), each rounded to 1e-6."
  (let ((verts (harness-ui-pet-3d--mesh-verts mesh)) out)
    (dotimes (i (/ (length verts) 3))
      (push (list (/ (round (* 1e6 (aref verts (* 3 i)))) 1e6)
                  (/ (round (* 1e6 (aref verts (+ (* 3 i) 1)))) 1e6)
                  (/ (round (* 1e6 (aref verts (+ (* 3 i) 2)))) 1e6))
            out))
    out))

(defun harness-ui-pet-3d-test--cells-of (map letter)
  "The number of cells of the text MAP that show LETTER, its legend aside."
  (cl-loop for line in (butlast (split-string map "\n")) sum (cl-count letter line)))

(defun harness-ui-pet-3d-test--segment-distance (px py ax ay bx by)
  "The distance of (PX PY) from the segment from (AX AY) to (BX BY)."
  (let* ((dx (- bx ax)) (dy (- by ay))
         (len2 (+ (* dx dx) (* dy dy)))
         (k (if (> len2 0.0) (max 0.0 (min 1.0 (/ (+ (* (- px ax) dx) (* (- py ay) dy)) len2))) 0.0)))
    (sqrt (+ (expt (- px ax (* k dx)) 2) (expt (- py ay (* k dy)) 2)))))

(defun harness-ui-pet-3d-test--nearest (mesh angle cols rows)
  "The face nearest the viewer over the middle of each cell, by brute force.
MESH is turned ANGLE degrees and fitted to COLS by ROWS cells, as
`harness-ui-pet-3d--cells' draws it.  The result is a vector of ROWS times
COLS: a face, t where no face is, or nil where the middle lies less than
0.15 pixels from an edge of a polygon the renderer draws, where the
rounding of its corners to tenths of a pixel decides.  A face is nearest
by its plane, whatever order the renderer draws faces in; a detail counts
as `harness-ui-pet-3d--detail-bias' nearer."
  (let* ((view (harness-ui-pet-3d--view mesh angle cols (* 2 rows)))
         ;; The same view a thousand times as big: the corners to a ten
         ;; thousandth of a pixel of this one.
         (fine (harness-ui-pet-3d--view mesh angle (* 1000 cols) (* 2000 rows)))
         (verts (harness-ui-pet-3d--mesh-verts mesh))
         (faces (harness-ui-pet-3d--mesh-faces mesh))
         (flags (harness-ui-pet-3d--mesh-flags mesh))
         (th (degrees-to-radians (+ (harness-ui-pet-3d--mesh-start mesh) angle)))
         (ph (degrees-to-radians harness-ui-pet-3d--tilt))
         (ex (- (* (sin th) (cos ph)))) (ey (sin ph)) (ez (* (cos th) (cos ph)))
         (near (make-vector (* cols rows) t))
         (depth (make-vector (* cols rows) -1e9)))
    (cl-flet ((cells (xs ys pad fn)
                ;; Call FN with I, J and the middle of each cell up to PAD outside XS and YS.
                (cl-loop for j from (max 0 (floor (/ (- (apply #'min ys) pad 1.0) 2.0)))
                         to (min (1- rows) (ceiling (/ (- (+ (apply #'max ys) pad) 1.0) 2.0)))
                         do (cl-loop for i from (max 0 (floor (- (apply #'min xs) pad 0.5)))
                                     to (min (1- cols) (ceiling (- (+ (apply #'max xs) pad) 0.5)))
                                     do (funcall fn i j (+ i 0.5) (+ (* 2.0 j) 1.0))))))
      (dolist (f (delete-dups (mapcar #'car (car view))))
        (let* ((corners (append (aref faces f) nil))
               (xs (mapcar (lambda (v) (/ (aref (nth 1 fine) v) 10000.0)) corners))
               (ys (mapcar (lambda (v) (/ (aref (nth 2 fine) v) 10000.0)) corners))
               (zs (mapcar (lambda (v)
                             (+ (* ex (aref verts (* 3 v))) (* ey (aref verts (+ (* 3 v) 1)))
                                (* ez (aref verts (+ (* 3 v) 2)))
                                (if (zerop (logand 2 (aref flags f))) 0.0 harness-ui-pet-3d--detail-bias)))
                           corners))
               ;; The plane of the face, as a depth over the screen.
               (x0 (nth 0 xs)) (y0 (nth 0 ys)) (z0 (nth 0 zs))
               (x1 (nth 1 xs)) (y1 (nth 1 ys)) (z1 (nth 1 zs))
               (x2 (car (last xs))) (y2 (car (last ys))) (z2 (car (last zs)))
               (det (- (* (- x1 x0) (- y2 y0)) (* (- x2 x0) (- y1 y0)))))
          (unless (< (abs det) 1e-9)
            (let ((a (/ (- (* (- z1 z0) (- y2 y0)) (* (- z2 z0) (- y1 y0))) det))
                  (b (/ (- (* (- x1 x0) (- z2 z0)) (* (- x2 x0) (- z1 z0))) det)))
              (cells xs ys 0.0
                     (lambda (i j px py)
                       (when (harness-ui-pet-3d--point-in-polygon-p px py xs ys)
                         (let ((z (+ z0 (* a (- px x0)) (* b (- py y0)))) (k (+ (* j cols) i)))
                           (when (> z (aref depth k))
                             (aset depth k z)
                             (aset near k f))))))))))
      (dolist (polygon (car view))
        (let ((xs (mapcar (lambda (v) (/ (aref (nth 1 view) v) 10.0)) (cdr polygon)))
              (ys (mapcar (lambda (v) (/ (aref (nth 2 view) v) 10.0)) (cdr polygon))))
          (cl-mapc (lambda (ax ay bx by)
                     (cells (list ax bx) (list ay by) 0.15
                            (lambda (i j px py)
                              (when (< (harness-ui-pet-3d-test--segment-distance px py ax ay bx by) 0.15)
                                (aset near (+ (* j cols) i) nil)))))
                   (append (last xs) (butlast xs)) (append (last ys) (butlast ys)) xs ys))))
    near))

;;;; The meshes

(ert-deftest harness-ui-pet-3d-balls-are-closed-with-outward-faces ()
  "A ball, of any sides, is a closed mesh whose faces look away from its centre."
  (dolist (sides '(4 6 8 10 12 14))
    (let ((geometry (harness-ui-pet-3d--ball-geometry 1.0 0.7 0.9 sides nil)))
      (should (= 0 (harness-ui-pet-3d-test--inward geometry)))
      (should (= 2 (harness-ui-pet-3d-test--euler geometry)))))
  ;; Rings: at least four, 0.6 a side; a 12-sided ball has 7 and 84 faces.
  (should (= 84 (length (cdr (harness-ui-pet-3d--ball-geometry 1.0 1.0 1.0 12 nil)))))
  (should (= 24 (length (cdr (harness-ui-pet-3d--ball-geometry 1.0 1.0 1.0 6 nil))))))

(ert-deftest harness-ui-pet-3d-half-balls-are-closed-by-a-flat-disk ()
  "A half ball is the half above its centre, closed by one disk that looks down."
  (dolist (sides '(6 10 12))
    (let* ((geometry (harness-ui-pet-3d--ball-geometry 1.0 0.8 1.0 sides t))
           (normals (harness-ui-pet-3d-test--normals geometry))
           (disks (cl-remove-if-not (lambda (n) (and (< (abs (nth 0 n)) 1e-9) (< (nth 1 n) -0.999))) normals)))
      (should (= 2 (harness-ui-pet-3d-test--euler geometry)))
      (should (= 1 (length disks)))
      (should (< (abs (nth 4 (car disks))) 1e-9))
      ;; Nothing is below the disk, and every other face looks away from the centre.
      (should (cl-every (lambda (v) (>= (nth 1 v) -1e-9)) (car geometry)))
      (should (= 1 (harness-ui-pet-3d-test--inward geometry))))))

(ert-deftest harness-ui-pet-3d-boxes-are-closed-with-outward-faces ()
  "A box is six faces, closed, each looking away from its centre."
  (let ((geometry (harness-ui-pet-3d--box-geometry 1.0 0.5 0.7)))
    (should (= 6 (length (cdr geometry))))
    (should (= 8 (length (car geometry))))
    (should (= 0 (harness-ui-pet-3d-test--inward geometry)))
    (should (= 2 (harness-ui-pet-3d-test--euler geometry)))
    ;; Each face is a flat quad on its own side of the box.
    (let ((sides (mapcar (lambda (n) (list (round (nth 0 n)) (round (nth 1 n)) (round (nth 2 n))))
                         (harness-ui-pet-3d-test--normals geometry))))
      (dolist (axis '((1 0 0) (-1 0 0) (0 1 0) (0 -1 0) (0 0 1) (0 0 -1)))
        (should (member axis sides))))))

(ert-deftest harness-ui-pet-3d-tubes-and-cones-are-closed-with-outward-faces ()
  "A tube is a frustum along y, and a cone when one end is 0; every one is closed."
  (dolist (spec '((0.5 0.5) (0.8 0.4) (0.5 0.0) (0.0 0.5)))
    (let* ((geometry (harness-ui-pet-3d--tube-geometry (car spec) (cadr spec) 1.0 10))
           (normals (harness-ui-pet-3d-test--normals geometry)))
      (should (= 2 (harness-ui-pet-3d-test--euler geometry)))
      ;; The side faces look away from the axis; a cap looks up or down, away from the middle.
      (dolist (n normals)
        (let ((away (+ (* (nth 0 n) (nth 3 n)) (* (nth 2 n) (nth 5 n)))))
          (if (> (abs (nth 1 n)) 0.999)
              (should (> (* (nth 1 n) (nth 4 n)) 0.0))
            (should (> away 1e-9)))))))
  ;; A cone has an apex and no cap there.
  (should (= 9 (length (cdr (harness-ui-pet-3d--tube-geometry 0.5 0.0 1.0 8)))))
  (should (= 12 (length (cdr (harness-ui-pet-3d--tube-geometry 0.5 0.5 1.0 10))))))

(ert-deftest harness-ui-pet-3d-rings-are-closed-tori ()
  "A ring is a torus around y: closed, a hole through it, faces away from its tube."
  (dolist (sides '(8 12 16))
    (let* ((geometry (harness-ui-pet-3d--ring-geometry 1.0 0.2 sides))
           (flat (harness-ui-pet-3d-test--flat (car geometry))))
      (should (= 0 (harness-ui-pet-3d-test--euler geometry)))
      ;; Away from the middle of the tube, a circle of radius 1.
      (dolist (face (cdr geometry))
        (let* ((n (harness-ui-pet-3d--polygon-normal flat face))
               (rho (sqrt (+ (expt (nth 3 n) 2) (expt (nth 5 n) 2)))))
          (should (> (+ (* (nth 0 n) (- (nth 3 n) (/ (nth 3 n) rho)))
                        (* (nth 1 n) (nth 4 n))
                        (* (nth 2 n) (- (nth 5 n) (/ (nth 5 n) rho))))
                     1e-9))))
      ;; The hole: nothing is within 0.75 of the axis, and the ring is 0.4 thick.
      (should (cl-every (lambda (v) (> (sqrt (+ (expt (nth 0 v) 2) (expt (nth 2 v) 2))) 0.75)) (car geometry)))
      (should (cl-every (lambda (v) (<= (abs (nth 1 v)) 0.2001)) (car geometry))))))

(ert-deftest harness-ui-pet-3d-turns-are-about-the-parts-own-centre ()
  "`:turn' goes about x, then y, then z, each right-handed, about the part's centre."
  (cl-flet ((turned (matrix v)
              (list (+ (* (aref matrix 0) (nth 0 v)) (* (aref matrix 1) (nth 1 v)) (* (aref matrix 2) (nth 2 v)))
                    (+ (* (aref matrix 3) (nth 0 v)) (* (aref matrix 4) (nth 1 v)) (* (aref matrix 5) (nth 2 v)))
                    (+ (* (aref matrix 6) (nth 0 v)) (* (aref matrix 7) (nth 1 v)) (* (aref matrix 8) (nth 2 v)))))
            (close-p (a b) (cl-every (lambda (x y) (< (abs (- x y)) 1e-9)) a b)))
    ;; +RX tips the top toward the front, +RY the front toward the right, +RZ the right side up.
    (should (close-p '(0.0 0.0 1.0) (turned (harness-ui-pet-3d--rotation 90 0 0) '(0.0 1.0 0.0))))
    (should (close-p '(1.0 0.0 0.0) (turned (harness-ui-pet-3d--rotation 0 90 0) '(0.0 0.0 1.0))))
    (should (close-p '(0.0 1.0 0.0) (turned (harness-ui-pet-3d--rotation 0 0 90) '(1.0 0.0 0.0))))
    ;; X first, then Z: the top goes to the front, which Z leaves where it is.
    (should (close-p '(0.0 0.0 1.0) (turned (harness-ui-pet-3d--rotation 90 0 90) '(0.0 1.0 0.0)))))
  ;; A box that is long in x, tipped by RZ 90, is long in y instead, about its own centre.
  (let* ((piece (harness-ui-pet-3d--make-piece '(box :at (1 2 3) :size (1.0 0.1 0.1) :turn (0 0 90) :color "#808080")
                                               1.0 0.0 0.0 0.0 nil))
         (verts (harness-ui-pet-3d--piece-verts piece))
         (ys (cl-loop for i from 1 below (length verts) by 3 collect (aref verts i)))
         (xs (cl-loop for i from 0 below (length verts) by 3 collect (aref verts i))))
    (should (equal '(1.0 2.0 3.0) (harness-ui-pet-3d--piece-center piece)))
    (should (< (abs (- (apply #'max ys) 3.0)) 1e-9))
    (should (< (abs (- (apply #'min ys) 1.0)) 1e-9))
    (should (< (abs (- (apply #'max xs) 1.1)) 1e-9))))

(ert-deftest harness-ui-pet-3d-mirror-makes-a-symmetric-copy ()
  "`:mirror' adds a copy across x = 0, its turn mirrored to match."
  (let* ((model (harness-ui-pet-3d-test--model
                 '(ball :at (0.6 0.5 0.2) :size (0.2 0.3 0.1) :turn (10 20 30) :color red :mirror t :sides 8)
                 '(box :at (0.5 1.5 0.0) :size (0.2 0.1 0.3) :turn (0 40 -15) :color blue :mirror t)
                 '(tube :at (0.0 0.5 -0.8) :radius 0.2 :height 0.5 :color grey :mirror t)))
         (mesh (harness-ui-pet-3d--mesh-of model nil))
         (verts (harness-ui-pet-3d-test--vertex-set mesh))
         (normals (harness-ui-pet-3d--mesh-normals mesh))
         (centers (harness-ui-pet-3d--mesh-centers mesh))
         (faces (length (harness-ui-pet-3d--mesh-flags mesh)))
         (found (make-hash-table :test 'equal)))
    ;; The ball and the box have a copy, the tube on the middle none: 40 + 40 + 6 + 6 + 12 faces.
    (should (= (* 2 (+ 40 6)) (- faces 12)))
    ;; Every vertex has its mirror image.
    (dolist (v verts)
      (should (member (list (- (+ (nth 0 v) 0.0)) (nth 1 v) (nth 2 v)) verts)))
    ;; And every face a face looking the mirrored way, in the mirrored place.
    (dotimes (f faces)
      (puthash (list (/ (round (* 1e5 (aref centers (* 3 f)))) 1e5)
                     (/ (round (* 1e5 (aref centers (+ (* 3 f) 1)))) 1e5)
                     (/ (round (* 1e5 (aref centers (+ (* 3 f) 2)))) 1e5)
                     (/ (round (* 1e4 (aref normals (* 3 f)))) 1e4)
                     (/ (round (* 1e4 (aref normals (+ (* 3 f) 1)))) 1e4)
                     (/ (round (* 1e4 (aref normals (+ (* 3 f) 2)))) 1e4))
               t found))
    (dotimes (f faces)
      (should (gethash (list (/ (round (* 1e5 (- (aref centers (* 3 f))))) 1e5)
                             (/ (round (* 1e5 (aref centers (+ (* 3 f) 1)))) 1e5)
                             (/ (round (* 1e5 (aref centers (+ (* 3 f) 2)))) 1e5)
                             (/ (round (* 1e4 (- (aref normals (* 3 f))))) 1e4)
                             (/ (round (* 1e4 (aref normals (+ (* 3 f) 1)))) 1e4)
                             (/ (round (* 1e4 (aref normals (+ (* 3 f) 2)))) 1e4))
                       found)))))

(ert-deftest harness-ui-pet-3d-buried-faces-are-left-out ()
  "A face lying wholly inside another part is never drawn; one that sticks out is."
  (let* ((big '(ball :at (0 1 0) :size 1.0 :color grey))
         (alone (harness-ui-pet-3d-test--model big))
         (buried (harness-ui-pet-3d-test--model big '(ball :at (0.1 1.0 0.1) :size 0.3 :color red)))
         (poking (harness-ui-pet-3d-test--model big '(ball :at (0 1 1.0) :size 0.3 :color red)))
         (as-detail (harness-ui-pet-3d-test--model '(ball :at (0 1 0) :size 1.0 :color grey :detail t)
                                                   '(ball :at (0.1 1.0 0.1) :size 0.3 :color red))))
    (cl-flet ((faces (model) (length (harness-ui-pet-3d--mesh-flags (harness-ui-pet-3d--mesh-of model nil)))))
      (should (= (faces alone) (faces buried)))
      (should (> (faces poking) (faces alone)))
      ;; A detail hides nothing: it is no container.
      (should (> (faces as-detail) (faces alone)))
      ;; What is buried is counted in the total, the faces before the hidden ones go.
      (should (> (harness-ui-pet-3d--mesh-total (harness-ui-pet-3d--mesh-of buried nil))
                 (faces buried))))))

(ert-deftest harness-ui-pet-3d-hats-go-on-the-head-scaled-by-its-radius ()
  "A hat's coordinates are in head radii, from the model's `:head' point."
  (let* ((model (list :palette nil :head '(1.0 2.0 3.0 0.5) :start 0
                      :parts '((ball :at (0 0 0) :size 0.1 :color "#808080"))))
         (hat (list :parts '((ball :at (0 1 0) :size 1.0 :color "#c03030"))))
         (pieces (harness-ui-pet-3d--pieces model hat))
         (worn (cadr pieces))
         (verts (harness-ui-pet-3d--piece-verts worn))
         (ys (cl-loop for i from 1 below (length verts) by 3 collect (aref verts i))))
    (should (= 2 (length pieces)))
    (should (equal '(1.0 2.5 3.0) (harness-ui-pet-3d--piece-center worn)))
    (should (< (abs (- (apply #'max ys) 3.0)) 1e-9))
    (should (< (abs (- (apply #'min ys) 2.0)) 1e-9))
    ;; No hat, or a hat that is not one: only the model's own.
    (should (= 1 (length (harness-ui-pet-3d--pieces model nil))))))

;;;; The view

(ert-deftest harness-ui-pet-3d-a-ball-shows-about-half-its-faces ()
  "The faces that look away are dropped: of a ball's, about half are left."
  (let ((model (harness-ui-pet-3d-test--ball)))
    (dolist (angle '(0 30 90 200))
      (let ((shown (harness-ui-pet-3d-test--visible model nil angle)))
        (should (<= 36 shown 52))))
    ;; Never more than the mesh has, and never none.
    (should (< 0 (harness-ui-pet-3d-test--visible model nil 0)
               (length (harness-ui-pet-3d--mesh-flags (harness-ui-pet-3d--mesh-of model nil)))))))

(ert-deftest harness-ui-pet-3d-angles-turn-from-the-start ()
  "0 faces the viewer, a `:start' of -90 the viewer's left, 90 the right, and ANGLE adds."
  (cl-flet ((cell-of (start angle)
              ;; Where the mark on the front is, left of the middle or right, of a 21 wide map.
              (let* ((model (list :palette '((grey . "#808080") (red . "#c03030"))
                                  :head '(0.0 2.0 0.0 1.0) :start start
                                  :parts '((ball :at (0 1 0) :size 1.0 :color grey)
                                           (ball :at (0 1 1.0) :size 0.3 :color red))))
                     (lines (split-string (harness-ui-pet-3d-preview model nil angle 21 10) "\n"))
                     (sum 0) (n 0))
                (dolist (line (butlast lines))
                  (dotimes (i (length line))
                    (when (eq (aref line i) ?r) (cl-incf sum i) (cl-incf n))))
                (and (> n 0) (- (/ (float sum) n) 10.0)))))
    (should (< (abs (cell-of 0 0)) 0.6))
    (should (< (cell-of -90 0) -3.0))
    (should (> (cell-of 90 0) 3.0))
    (should (> (cell-of 0 90) 3.0))
    (should (< (cell-of 0 -90) -3.0))
    ;; The start and the angle are one sum.
    (should (< (abs (cell-of 90 -90)) 0.6))
    (should (< (abs (- (cell-of 0 90) (cell-of 90 0))) 0.6))
    ;; Turned away, the mark on the front is behind the ball.
    (should-not (cell-of 0 180))))

(ert-deftest harness-ui-pet-3d-the-fit-keeps-every-point-in-the-box ()
  "At every one of the 24 steps, with every hat, every point is in the box."
  (let ((width 150) (height 100))
    (dolist (hat (cons nil harness-ui-pet-3d-test--hats))
      (let ((mesh (harness-ui-pet-3d--mesh-for 'capybara hat))
            (lowest 0) (highest 1e9))
        (dotimes (step harness-ui-pet-3d-count)
          (let ((view (harness-ui-pet-3d--view mesh (* step (/ 360.0 harness-ui-pet-3d-count)) width height)))
            (should (cl-every (lambda (x) (<= 20 x (- (* 10 width) 20))) (nth 1 view)))
            (should (cl-every (lambda (y) (<= 20 y (- (* 10 height) 20))) (nth 2 view)))
            (setq lowest (max lowest (apply #'max (append (nth 2 view) nil)))
                  highest (min highest (apply #'min (append (nth 2 view) nil))))))
        ;; The feet near the bottom, a margin of 4% under them, and the head near the top.
        (should (<= 900 lowest 962))
        (should (<= 30 highest 140))))))

(ert-deftest harness-ui-pet-3d-the-fit-does-not-change-as-it-turns ()
  "The model does not grow, shrink or slide as it turns."
  (let* ((model (harness-ui-pet-3d-test--model '(tube :at (0 1 0) :radius 0.4 :height 2.0 :color grey :sides 24)))
         (mesh (harness-ui-pet-3d--mesh-for model nil))
         (spans nil) (centres nil) (tops nil))
    (dotimes (step 24)
      (let* ((view (harness-ui-pet-3d--view mesh (* step 15.0) 150 100))
             (xs (append (nth 1 view) nil)) (ys (append (nth 2 view) nil)))
        (push (- (apply #'max xs) (apply #'min xs)) spans)
        (push (/ (+ (apply #'max xs) (apply #'min xs)) 2.0) centres)
        (push (- (apply #'max ys) (apply #'min ys)) tops)))
    (cl-flet ((steady (list tolerance)
                (< (- (apply #'max list) (apply #'min list)) tolerance)))
      (should (steady spans 40))
      (should (steady centres 10))
      (should (steady tops 40)))
    (should (< (abs (- (car centres) 750)) 10))))

(ert-deftest harness-ui-pet-3d-light-comes-from-the-upper-left-front ()
  "A face is shaded 0.58 to 1.05 of its colour, the brightest on the upper left."
  (let* ((svg (harness-ui-pet-3d-svg (harness-ui-pet-3d-test--ball) nil 0 150 100))
         (polygons (harness-ui-pet-3d-test--polygons svg))
         (levels (mapcar (lambda (p) (car (harness-ui-pet-3d-test--channels (car p)))) polygons))
         (brightest (cl-find (apply #'max levels) polygons
                             :key (lambda (p) (car (harness-ui-pet-3d-test--channels (car p)))))))
    (should polygons)
    ;; 128 times 0.58 and 1.05.
    (should (<= 74 (apply #'min levels)))
    (should (<= (apply #'max levels) 135))
    (should (> (- (apply #'max levels) (apply #'min levels)) 30))
    ;; Grey stays grey in every light.
    (dolist (p polygons)
      (let ((c (harness-ui-pet-3d-test--channels (car p))))
        (should (= (nth 0 c) (nth 1 c)))
        (should (= (nth 1 c) (nth 2 c)))))
    (let ((middle (harness-ui-pet-3d-test--centroid (apply #'append (mapcar #'caddr polygons))))
          (spot (harness-ui-pet-3d-test--centroid (caddr brightest))))
      (should (< (car spot) (car middle)))
      (should (< (cdr spot) (cdr middle))))))

(ert-deftest harness-ui-pet-3d-flat-parts-are-not-shaded ()
  "A `:flat' part keeps its colour in any light; a shaded one does not."
  (let ((model (harness-ui-pet-3d-test--model '(ball :at (0 1 0) :size 1.0 :color "#ff00ff" :flat t)
                                              '(ball :at (0 3 0) :size 0.5 :color "#00ff00"))))
    (dolist (angle '(0 20 100))
      (let* ((polygons (harness-ui-pet-3d-test--polygons (harness-ui-pet-3d-svg model nil angle 150 100)))
             (flat (cl-remove-if-not (lambda (p) (equal (car p) "ff00ff")) polygons))
             (green (cl-remove-if (lambda (p) (equal (car p) "ff00ff")) polygons))
             (levels (delete-dups (mapcar #'car green))))
        ;; All of the flat ball is one colour, as it was named.
        (should (> (length flat) 20))
        ;; The other is shaded: dark to light, from 0.58 of the colour to all of it, still green.
        (should (>= (length levels) 3))
        (should (member "00ff00" levels))
        (dolist (level levels)
          (let ((c (harness-ui-pet-3d-test--channels level)))
            (should (= 0 (nth 0 c)))
            (should (= 0 (nth 2 c)))
            (should (<= 148 (nth 1 c) 255))))))))

(ert-deftest harness-ui-pet-3d-a-detail-shows-over-what-it-sits-on ()
  "A detail sunk a little into the face it sits on shows whole, as if nearer the viewer.
Without the bias it shows only where it pokes out; from behind, never."
  (let ((model (harness-ui-pet-3d-test--model
                '(box :at (0 1 0) :size (0.5 0.5 0.5) :color grey)
                '(ball :at (0 1 0.48) :size (0.2 0.2 0.04) :color red :detail t :sides 8))))
    (cl-flet ((red (angle bias)
                (let ((harness-ui-pet-3d--detail-bias bias))
                  (harness-ui-pet-3d-test--cells-of (harness-ui-pet-3d-preview model nil angle 40 20) ?r))))
      (dolist (angle '(0 30 60))
        (should (> (red angle 0.0) 0))
        (should (> (red angle 0.06) (* 1.2 (red angle 0.0)))))
      (dolist (angle '(120 180 240))
        (should (= 0 (red angle 0.06)))))))

(ert-deftest harness-ui-pet-3d-a-detail-is-never-seen-through-what-it-sits-on ()
  "The bias brings a detail nearer the viewer, so it never shows through the back of a part."
  (let ((model (harness-ui-pet-3d-test--model
                '(box :at (0 1 0) :size (0.6 0.6 0.1) :color grey)
                '(ball :at (0 1 0.09) :size (0.3 0.3 0.03) :color red :detail t :sides 8))))
    (dolist (angle '(0 30 60))
      (should (> (harness-ui-pet-3d-test--cells-of (harness-ui-pet-3d-preview model nil angle 40 20) ?r) 20)))
    (dolist (angle '(100 150 180 210 260))
      (should (= 0 (harness-ui-pet-3d-test--cells-of (harness-ui-pet-3d-preview model nil angle 40 20) ?r))))))

(ert-deftest harness-ui-pet-3d-a-detail-on-a-big-face-shows-as-it-turns ()
  "Spots near the corners of a big face show as long as the face does.
Sorted by the depth of their middles, the far spot went under the face once it turned."
  (let ((model '(:palette ((a . "#9aa4b2") (b . "#e5484d")) :head (0.0 1.0 0.0 0.5) :start 0
                 :parts ((box :at (0 0.5 0) :size (0.9 0.5 0.7) :color a)
                         (ball :at (0.5 0.55 0.7) :size (0.14 0.14 0.05) :color b :detail t :mirror t)))))
    (cl-flet ((spots (angle) (harness-ui-pet-3d-test--cells-of (harness-ui-pet-3d-preview model nil angle 44 14) ?b)))
      (let ((front (spots 0)))
        (should (>= front 16))
        ;; Both spots, foreshortened as the face turns away.
        (should (>= (spots 20) (* 0.7 front)))
        (should (>= (spots 45) (* 0.6 front)))
        (should (> (spots 70) 0))
        (should (= 0 (spots 120)))
        (should (= 0 (spots 180)))))))

(ert-deftest harness-ui-pet-3d-parts-that-run-into-each-other-are-drawn-as-they-lie ()
  "Where parts run into each other, the face nearest the viewer shows, from every side.
Cell by cell, the face drawn last is the nearest found by brute force:
sorted by the depth of their middles, faces of the legs, the head and the
tail went over or under the body by a few cells at every angle."
  (let ((mesh (harness-ui-pet-3d--mesh-for
               (harness-ui-pet-3d-test--model
                '(ball :at (0 0.8 0) :size (0.8 0.6 0.9) :color grey)
                '(ball :at (0 1.35 0.55) :size 0.5 :color red)
                '(tube :at (0.5 0.35 0.45) :radius 0.16 :height 0.9 :turn (35 0 25) :color blue :mirror t)
                '(box :at (0 1.2 -0.6) :size (0.15 0.5 0.15) :turn (40 0 0) :color red))
               nil)))
    (dotimes (step 12)
      (let* ((angle (* step 30))
             (drawn (car (harness-ui-pet-3d--cells mesh angle 40 20)))
             (nearest (harness-ui-pet-3d-test--nearest mesh angle 40 20))
             (faces 0))
        (dotimes (k (* 40 20))
          (let ((want (aref nearest k)))
            (when want
              (unless (eq want t) (cl-incf faces))
              (should (equal (list angle k want) (list angle k (or (aref drawn k) t)))))))
        ;; Most of the cells the model covers are clear of every edge.
        (should (> faces 150))))))

(ert-deftest harness-ui-pet-3d-the-order-tree-is-a-bsp-tree ()
  "Each polygon under a node's front lies in front of its plane, each under its back behind it.
The pieces a face is cut into make it up, no more and no less."
  (let* ((mesh (harness-ui-pet-3d--mesh-for 'capybara 'tophat))
         (points (harness-ui-pet-3d--mesh-points mesh))
         (polygons (harness-ui-pet-3d--mesh-polygons mesh))
         (sources (harness-ui-pet-3d--mesh-sources mesh))
         (normals (harness-ui-pet-3d--mesh-normals mesh))
         (offsets (harness-ui-pet-3d--mesh-offsets mesh))
         (faces (harness-ui-pet-3d--mesh-faces mesh))
         (flags (harness-ui-pet-3d--mesh-flags mesh))
         (stack (list (cons (harness-ui-pet-3d--mesh-tree mesh) nil)))
         (seen 0) (wrong 0))
    (should (car (car stack)))
    (cl-flet ((dist (f v) (- (+ (* (aref normals (* 3 f)) (aref points (* 3 v)))
                                (* (aref normals (+ (* 3 f) 1)) (aref points (+ (* 3 v) 1)))
                                (* (aref normals (+ (* 3 f) 2)) (aref points (+ (* 3 v) 2))))
                             (aref offsets f))))
      ;; Each job is a node and the sides of the planes above it that it is on.
      (while stack
        (pcase-let ((`(,node . ,sides) (pop stack)))
          (dolist (id (aref node 1))
            (cl-incf seen)
            (dolist (side sides)
              (dolist (v (append (aref polygons id) nil))
                (when (< (* (cdr side) (dist (car side) v)) -1e-4) (cl-incf wrong)))))
          (when (aref node 2) (push (cons (aref node 2) (cons (cons (aref node 0) 1) sides)) stack))
          (when (aref node 3) (push (cons (aref node 3) (cons (cons (aref node 0) -1) sides)) stack)))))
    (should (= 0 wrong))
    ;; Every polygon is in the tree once.
    (should (= seen (length polygons)))
    ;; The pieces of a face add up to it; the details are not in the tree.
    (cl-flet ((area (f corners)
                (let ((ax 0.0) (ay 0.0) (az 0.0) (prev (car (last corners))))
                  (dolist (v corners)
                    (let ((x0 (aref points (* 3 prev))) (y0 (aref points (+ (* 3 prev) 1))) (z0 (aref points (+ (* 3 prev) 2)))
                          (x1 (aref points (* 3 v))) (y1 (aref points (+ (* 3 v) 1))) (z1 (aref points (+ (* 3 v) 2))))
                      (setq ax (+ ax (- (* y0 z1) (* z0 y1)))
                            ay (+ ay (- (* z0 x1) (* x0 z1)))
                            az (+ az (- (* x0 y1) (* y0 x1)))
                            prev v)))
                  (* 0.5 (+ (* ax (aref normals (* 3 f))) (* ay (aref normals (+ (* 3 f) 1)))
                            (* az (aref normals (+ (* 3 f) 2))))))))
      (let ((sums (make-vector (length faces) 0.0)))
        (dotimes (id (length polygons))
          (let ((f (aref sources id)))
            (should (> (area f (append (aref polygons id) nil)) -1e-9))
            (aset sums f (+ (aref sums f) (area f (append (aref polygons id) nil))))))
        (dotimes (f (length faces))
          (let ((whole (area f (append (aref faces f) nil))))
            (if (zerop (logand 2 (aref flags f)))
                (should (< (abs (- whole (aref sums f))) (max 1e-7 (* 1e-5 whole))))
              (should (= 0.0 (aref sums f))))))))
    ;; Cut faces are a few times as many as the faces, no more.
    (should (< (length polygons) (* 3 (length faces))))))

(ert-deftest harness-ui-pet-3d-the-text-map-fills-polygons-as-svg-does ()
  "A point is in a polygon when the polygon winds round it, as SVG's nonzero rule has it.
A polygon whose corners lie on a line covers nothing, not even on the
line; one whose corners rounding turned back on themselves loses
nothing."
  (cl-flet ((in (x y corners)
              (harness-ui-pet-3d--point-in-polygon-p x y (mapcar #'car corners) (mapcar #'cdr corners))))
    (should-not (in 1.0 1.0 '((0.0 . 0.0) (1.0 . 1.0) (2.0 . 2.0))))
    (should-not (in 5.0 1.0 '((0.0 . 0.0) (1.0 . 1.0) (2.0 . 2.0))))
    (dolist (square (list '((0.0 . 0.0) (1.0 . 0.0) (1.0 . 1.0) (0.0 . 1.0))
                          '((0.0 . 1.0) (1.0 . 1.0) (1.0 . 0.0) (0.0 . 0.0))))
      (should (in 0.5 0.5 square))
      (should-not (in 1.5 0.5 square))
      (should-not (in 0.5 -0.5 square)))
    ;; A cut close by a corner, rounded: up a tenth and back down the side.
    (let ((spiked '((24.3 . 21.1) (20.7 . 17.7) (20.7 . 17.6) (20.7 . 18.8) (22.2 . 21.8))))
      (should (in 22.5 21.0 spiked))
      (should (in 21.5 19.0 spiked))
      (should-not (in 20.0 19.0 spiked)))))

(ert-deftest harness-ui-pet-3d-the-fit-fills-the-box-down-or-across ()
  "A tall model fills 92% of the height with its feet 4% from the bottom, a wide one 92% across."
  (cl-flet ((extents (model width height)
              (let* ((view (harness-ui-pet-3d--view (harness-ui-pet-3d--mesh-for model nil) 0 width height))
                     (xs (append (nth 1 view) nil)) (ys (append (nth 2 view) nil)))
                (list (apply #'min xs) (apply #'max xs) (apply #'min ys) (apply #'max ys)))))
    ;; A column, 2 high and 1 across, in a box wider than it is tall: down.
    (let ((e (extents (harness-ui-pet-3d-test--model '(tube :at (0 1 0) :radius 0.5 :height 2.0 :color grey :sides 24))
                      150 100)))
      (should (< (abs (- (- (nth 3 e) (nth 2 e)) 920)) 15))
      (should (< (abs (- (nth 3 e) 960)) 15))
      (should (< (abs (- (/ (+ (nth 0 e) (nth 1 e)) 2.0) 750)) 10)))
    ;; A plate, 4 across and a tenth high: across.
    (let ((e (extents (harness-ui-pet-3d-test--model '(tube :at (0 0.05 0) :radius 2.0 :height 0.1 :color grey :sides 24))
                      150 100)))
      (should (< (abs (- (- (nth 1 e) (nth 0 e)) (* 0.92 1500))) 40))
      (should (< (abs (- (/ (+ (nth 0 e) (nth 1 e)) 2.0) 750)) 10))
      (should (<= (nth 3 e) 960)))
    ;; The size of the box is the box: the same model in another has the same shape.
    (let ((small (extents (harness-ui-pet-3d-test--ball) 75 50))
          (large (extents (harness-ui-pet-3d-test--ball) 150 100)))
      (dotimes (i 4)
        (should (< (abs (- (* 2 (nth i small)) (nth i large))) 6))))))

;;;; The SVG

(ert-deftest harness-ui-pet-3d-svg-is-a-document-of-polygons ()
  "The SVG is WIDTH by HEIGHT, transparent, a polygon a face, in 0.1 pixels."
  (let* ((svg (harness-ui-pet-3d-svg 'capybara 'tophat 30 150 100))
         (polygons (harness-ui-pet-3d-test--polygons svg)))
    (should (string-prefix-p "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"150\" height=\"100\" viewBox=\"0 0 150 100\">" svg))
    (should (string-suffix-p "</g></svg>" svg))
    (should-not (string-match-p "<rect" svg))
    ;; A polygon for every face that looks at the viewer, filled and stroked in one colour.
    (should (= (length polygons) (harness-ui-pet-3d-test--visible 'capybara 'tophat 30)))
    (should (> (length polygons) 150))
    (should (= (length polygons) (cl-count "<polygon " (split-string svg ">") :test (lambda (a b) (string-prefix-p a b)))))
    (dolist (p polygons)
      (should (equal (car p) (cadr p)))
      (should (>= (length (caddr p)) 3)))
    (should (string-match-p "points=\"[0-9]+\\.[0-9],[0-9]+\\.[0-9] " svg))
    ;; All of it in the box.
    (dolist (p polygons)
      (dolist (xy (caddr p))
        (should (<= 0 (car xy) 150))
        (should (<= 0 (cdr xy) 100))))
    ;; The same again, byte for byte, and the size is the size asked for.
    (should (equal svg (harness-ui-pet-3d-svg 'capybara 'tophat 30 150 100)))
    (should (string-match-p "width=\"320\" height=\"200\" viewBox=\"0 0 320 200\"" (harness-ui-pet-3d-svg 'capybara nil 0 320 200)))))

(ert-deftest harness-ui-pet-3d-svg-parses-as-xml ()
  "The document is well formed XML."
  (skip-unless (and (fboundp 'libxml-available-p) (libxml-available-p)))
  (dolist (hat '(nil tophat halo))
    (let* ((svg (harness-ui-pet-3d-svg 'capybara hat 75 150 100))
           (dom (with-temp-buffer (insert svg) (libxml-parse-xml-region (point-min) (point-max)))))
      (should (eq 'svg (car dom)))
      (should (equal "150" (cdr (assq 'width (cadr dom)))))
      (should (> (length (cdr (cdr (car (cddr dom))))) 100)))))

(ert-deftest harness-ui-pet-3d-species-and-hats-are-symbols-or-strings ()
  "A species and a hat may be named by a symbol or a string."
  (should (eq (harness-ui-pet-3d-model 'capybara) (harness-ui-pet-3d-model "capybara")))
  (should (equal (harness-ui-pet-3d-svg 'capybara 'tophat 40 150 100)
                 (harness-ui-pet-3d-svg "capybara" "tophat" 40 150 100)))
  (should (equal (harness-ui-pet-3d-preview 'capybara 'crown 0 30 12)
                 (harness-ui-pet-3d-preview "capybara" "crown" 0 30 12))))

(ert-deftest harness-ui-pet-3d-unknown-species-and-hats-draw-nothing ()
  "No such species has no model; no such hat is no hat; neither is an error."
  (should-not (harness-ui-pet-3d-model 'no-such-pet))
  (should-not (harness-ui-pet-3d-model "no-such-pet-at-all"))
  (should-not (harness-ui-pet-3d-model nil))
  (should-not (harness-ui-pet-3d-model 17))
  (let ((empty (harness-ui-pet-3d-svg 'no-such-pet nil 0 150 100)))
    (should (string-prefix-p "<svg " empty))
    (should-not (string-match-p "<polygon" empty))
    (should (string-match-p "width=\"150\" height=\"100\"" empty)))
  (should (equal (harness-ui-pet-3d-svg 'capybara nil 10 150 100)
                 (harness-ui-pet-3d-svg 'capybara 'no-such-hat 10 150 100)))
  (should (equal (harness-ui-pet-3d-svg 'capybara nil 10 150 100)
                 (harness-ui-pet-3d-svg 'capybara "none" 10 150 100)))
  (should-not (harness-ui-pet-3d-frame 'no-such-pet nil 0 150 100))
  (should-not (harness-ui-pet-3d-frame "no-such-pet-at-all" 'tophat 0 150 100))
  (should-not (harness-ui-pet-3d-stats 'no-such-pet))
  (should (equal "no model" (car (last (split-string (harness-ui-pet-3d-preview 'no-such-pet nil 0 10 4) "\n")))))
  (should (string-match-p "\\`\\(\\.\\{10\\}\n\\)\\{4\\}no model\\'" (harness-ui-pet-3d-preview 'no-such-pet nil 0 10 4)))
  (should (harness-ui-pet-3d-problems 'no-such-pet)))

(ert-deftest harness-ui-pet-3d-every-hat-renders-on-the-capybara ()
  "Each of the seven hats adds to the capybara at every quarter turn."
  (should (equal (sort (copy-sequence harness-ui-pet-3d-test--hats) #'string<)
                 (sort (mapcar #'car harness-ui-pet-hat-models) #'string<)))
  (dolist (angle '(0 90 180 270))
    (let* ((bare (harness-ui-pet-3d-svg 'capybara nil angle 150 100))
           (bare-polygons (harness-ui-pet-3d-test--polygons bare)))
      (dolist (hat harness-ui-pet-3d-test--hats)
        (let* ((svg (harness-ui-pet-3d-svg 'capybara hat angle 150 100))
               (polygons (harness-ui-pet-3d-test--polygons svg)))
          (should-not (equal svg bare))
          ;; A picture of its own, as full as the capybara's alone, every polygon in the box.
          (should (> (length polygons) (* 0.8 (length bare-polygons))))
          (dolist (p polygons)
            (dolist (xy (caddr p))
              (should (<= 0 (car xy) 150))
              (should (<= 0 (cdr xy) 100)))))))))

(ert-deftest harness-ui-pet-3d-hats-sit-on-the-head ()
  "A hat is above the head, in it a little, and floats free only as the halo does."
  (dolist (hat harness-ui-pet-3d-test--hats)
    (let* ((model (harness-ui-pet-3d-model 'capybara))
           (head (plist-get model :head))
           (hat-model (cdr (assq hat harness-ui-pet-hat-models)))
           (pieces (harness-ui-pet-3d--pieces model hat-model))
           (worn (nthcdr (length (harness-ui-pet-3d--pieces model nil)) pieces))
           (ys (cl-loop for piece in worn
                        append (let ((verts (harness-ui-pet-3d--piece-verts piece)))
                                 (cl-loop for i from 1 below (length verts) by 3 collect (aref verts i)))))
           (radius (nth 3 head)))
      (should worn)
      ;; Well above the head's top, and its bottom not deeper than most of a radius.
      (should (>= (- (apply #'max ys) (nth 1 head)) (* 0.3 radius)))
      (should (>= (apply #'min ys) (- (nth 1 head) (* 0.7 radius))))
      (if (eq hat 'halo)
          (should (= 1 (length (harness-ui-pet-3d-problems 'capybara hat))))
        (should-not (harness-ui-pet-3d-problems 'capybara hat))))))

;;;; The frames

(ert-deftest harness-ui-pet-3d-frames-are-cached-images ()
  "A frame is an SVG image of one step of a turn, cached by its arguments."
  (skip-unless (image-type-available-p 'svg))
  (harness-ui-pet-3d-clear)
  (let ((image (harness-ui-pet-3d-frame 'capybara 'tophat 3 150 100)))
    (should (eq 'image (car image)))
    (should (eq 'svg (plist-get (cdr image) :type)))
    (should (eq 'center (plist-get (cdr image) :ascent)))
    (should (eql 1 (plist-get (cdr image) :scale)))
    (should (equal (plist-get (cdr image) :data)
                   (harness-ui-pet-3d-svg 'capybara 'tophat (* 3 (/ 360.0 harness-ui-pet-3d-count)) 150 100)))
    ;; The same arguments, the same image; any other, another.
    (should (eq image (harness-ui-pet-3d-frame 'capybara 'tophat 3 150 100)))
    (should (eq image (harness-ui-pet-3d-frame "capybara" "tophat" 3 150 100)))
    (should-not (eq image (harness-ui-pet-3d-frame 'capybara 'tophat 4 150 100)))
    (should-not (eq image (harness-ui-pet-3d-frame 'capybara 'crown 3 150 100)))
    (should-not (eq image (harness-ui-pet-3d-frame 'capybara 'tophat 3 160 100)))
    (should-not (eq image (harness-ui-pet-3d-frame 'capybara 'tophat 3 150 110)))
    ;; A turn is 24 steps; a step past it is the one it comes round to.
    (should (eq (harness-ui-pet-3d-frame 'capybara nil 0 150 100)
                (harness-ui-pet-3d-frame 'capybara nil harness-ui-pet-3d-count 150 100)))
    ;; Step 0 faces the viewer; the species and hat are the model's own.
    (should (equal (plist-get (cdr (harness-ui-pet-3d-frame 'capybara nil 0 150 100)) :data)
                   (harness-ui-pet-3d-svg 'capybara nil 0 150 100)))))

(ert-deftest harness-ui-pet-3d-frame-cache-is-emptied-past-256 ()
  "The cache of images is emptied once it holds more than 256."
  (skip-unless (image-type-available-p 'svg))
  (harness-ui-pet-3d-clear)
  (dotimes (i 300)
    (harness-ui-pet-3d-frame 'capybara nil 0 (+ 40 i) 30))
  (should (<= (hash-table-count harness-ui-pet-3d--frames) 257))
  (should (> (hash-table-count harness-ui-pet-3d--frames) 0))
  ;; An image cached before is made again, and equal to what it was.
  (let ((image (harness-ui-pet-3d-frame 'capybara nil 0 40 30)))
    (should (equal (plist-get (cdr image) :data) (harness-ui-pet-3d-svg 'capybara nil 0 40 30)))))

(ert-deftest harness-ui-pet-3d-no-svg-no-frame ()
  "Where Emacs cannot show an SVG, a frame is nil."
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) nil)))
    (should-not (harness-ui-pet-3d-frame 'capybara 'tophat 0 150 100)))
  (should (= 24 harness-ui-pet-3d-count))
  (should (= 0.09 harness-ui-pet-3d-tick)))

;;;; The text map

(ert-deftest harness-ui-pet-3d-preview-is-deterministic-text ()
  "The same ball gives the same map, symmetric about the middle, with a legend."
  (let* ((model (harness-ui-pet-3d-test--ball))
         (map (harness-ui-pet-3d-preview model nil 0 20 10))
         (lines (split-string map "\n")))
    (should (equal map (harness-ui-pet-3d-preview model nil 0 20 10)))
    (should (equal map (harness-ui-pet-3d-preview (harness-ui-pet-3d-test--ball) nil 0 20 10)))
    ;; Ten lines of twenty cells, and a legend: the one colour and the cells it has.
    (should (= 11 (length lines)))
    (dolist (line (butlast lines))
      (should (= 20 (length line)))
      (should (string-match-p "\\`[.g]*\\'" line))
      ;; At 0 degrees the ball is as it is mirrored.
      (should (equal line (reverse line))))
    (should (string-match-p "\\`legend: g=grey([0-9]+) \\.=none\\'" (car (last lines))))
    ;; A round ball takes about pi/4 of its box: 0.92 high, 0.92 of 20 wide at best.
    (let ((cells (cl-count ?g map)))
      (should (<= 100 cells 160)))
    ;; The corners are empty, the middle is not.
    (should (eq ?. (aref (car lines) 0)))
    (should (eq ?. (aref (nth 9 lines) 19)))
    (should (eq ?g (aref (nth 5 lines) 10)))))

(ert-deftest harness-ui-pet-3d-print-previews-name-what-they-show ()
  "The batch printer says what each map is."
  (let ((text (with-output-to-string
                (harness-ui-pet-3d-print-previews '(capybara) '(0 90) '(tophat) 30 12))))
    (should (string-match-p "== capybara hat=tophat angle=0 faces=[0-9]+ of [0-9]+\n" text))
    (should (string-match-p "== capybara hat=tophat angle=90 " text))
    (should (string-match-p "legend: " text))))

;;;; The checker

(ert-deftest harness-ui-pet-3d-problems-finds-what-is-wrong ()
  "The checker names what is wrong with a model, and nothing for one that is right."
  (should-not (harness-ui-pet-3d-problems (harness-ui-pet-3d-test--ball)))
  (cl-flet ((problems (&rest parts)
              (harness-ui-pet-3d-problems
               (apply #'harness-ui-pet-3d-test--model '(ball :at (0 1 0) :size 1.0 :color grey) parts)))
            (found (regexp problems) (cl-some (lambda (m) (string-match-p regexp m)) problems)))
    (should-not (problems '(ball :at (0 1 1) :size 0.3 :color red)))
    (should (found "unknown kind" (problems '(cone :at (0 1 1) :color grey))))
    (should (found "unknown key :wiggle" (problems '(ball :at (0 1 1) :size 0.3 :color red :wiggle t))))
    (should (found "colour nope is not known" (problems '(ball :at (0 1 1) :size 0.3 :color nope))))
    (should (found "has no :color" (problems '(ball :at (0 1 1) :size 0.3))))
    (should (found "nearly black" (problems '(ball :at (0 1 1) :size 0.3 :color "#101010"))))
    (should-not (found "nearly black" (problems '(ball :at (0 1 1) :size 0.3 :color eye))))
    (should (found ":at must be" (problems '(ball :size 0.3 :color red))))
    (should (found "floats free" (problems '(ball :at (3 1 0) :size 0.3 :color red))))
    (should (found "more than 600" (problems '(ball :at (0 1 1) :size 0.1 :color red :sides 14 :mirror t)
                                                  '(ball :at (0 1 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (0.3 1 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (-0.3 1 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (0 1.3 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (0 0.7 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (0.3 1.3 -1) :size 0.1 :color red :sides 14)
                                                  '(ball :at (0.3 0.7 -1) :size 0.1 :color red :sides 14)))))
  ;; A model without its head, parts, or with a head that is not numbers.
  (should (cl-some (lambda (m) (string-match-p ":head must be" m))
                   (harness-ui-pet-3d-problems (list :palette '((grey . "#808080")) :start 0
                                                     :parts '((ball :at (0 1 0) :size 1.0 :color grey))))))
  (should (cl-some (lambda (m) (string-match-p "no :parts" m))
                   (harness-ui-pet-3d-problems (list :palette nil :head '(0 1 0 1) :start 0))))
  ;; A hat that floats, as the halo does.
  (should (cl-some (lambda (m) (string-match-p "floats free" m))
                   (harness-ui-pet-3d-problems (harness-ui-pet-3d-test--ball) 'halo))))

(ert-deftest harness-ui-pet-3d-stats-count-faces-and-size ()
  "The statistics of a model are its faces before and after the hidden ones go, and its size."
  (let* ((stats (harness-ui-pet-3d-stats 'capybara))
         (with-hat (harness-ui-pet-3d-stats 'capybara 'tophat)))
    (should (< (plist-get stats :faces) (plist-get stats :total)))
    (should (= (plist-get stats :faces)
               (length (harness-ui-pet-3d--mesh-flags (harness-ui-pet-3d--mesh-for 'capybara nil)))))
    (should (> (plist-get with-hat :faces) (plist-get stats :faces)))
    (should (> (plist-get with-hat :height) (plist-get stats :height)))
    (should (> (plist-get stats :parts) 10))
    (should (<= 1.0 (plist-get stats :radius) 1.6))
    (should (<= 2.0 (plist-get stats :height) 2.6))
    (should-not (harness-ui-pet-3d-stats 'no-such-pet))))

;;;; The models

(ert-deftest harness-ui-pet-3d-models-are-well-formed ()
  "Every model has what the format asks, and none has a problem the numbers can find."
  (should harness-ui-pet-models)
  (dolist (entry harness-ui-pet-models)
    (let* ((species (car entry)) (model (cdr entry)))
      (should (symbolp species))
      (should (eq model (harness-ui-pet-3d-model species)))
      (should (= 4 (length (plist-get model :head))))
      (should (cl-every #'numberp (plist-get model :head)))
      (should (numberp (plist-get model :start)))
      (should (= (or (alist-get species harness-ui-pet-3d-test--starts) 0) (plist-get model :start)))
      (should (plist-get model :palette))
      (should (plist-get model :parts))
      (should-not (harness-ui-pet-3d-problems species))
      (let ((stats (harness-ui-pet-3d-stats species)))
        (should (<= (plist-get stats :total) 600))
        (should (> (plist-get stats :faces) 60))
        (should (<= (plist-get stats :faces) (plist-get stats :total))))))
  (should (assq 'capybara harness-ui-pet-models)))

(ert-deftest harness-ui-pet-3d-every-species-has-a-model ()
  "Each of the 18 species has a model that draws at every quarter turn.
Each draws bare and in every hat."
  (let ((species '(duck goose blob cat dragon octopus owl penguin turtle snail ghost axolotl
                   capybara cactus robot rabbit mushroom chonk)))
    (should (equal (sort (mapcar #'car harness-ui-pet-models) #'string<)
                   (sort (copy-sequence species) #'string<)))
    (dolist (name species)
      (should (harness-ui-pet-3d-model name))
      (dolist (hat (cons nil (mapcar #'car harness-ui-pet-hat-models)))
        (dolist (angle '(0 90 180 270))
          (should (string-match-p "<polygon" (harness-ui-pet-3d-svg name hat angle 150 100))))))))

(ert-deftest harness-ui-pet-3d-the-capybara-faces-the-viewer ()
  "The capybara looks at the viewer at rest, with its eyes, shines and nostrils."
  (let* ((model (harness-ui-pet-3d-model 'capybara))
         (parts (plist-get model :parts))
         (colours (mapcar (lambda (part) (plist-get (cdr part) :color)) parts)))
    (should (= 0 (plist-get model :start)))
    (dolist (colour '(fur light dark eye shine blush))
      (should (memq colour colours)))
    ;; Eyes, shines and blush are details that sit on the face; the shine and blush are flat.
    (dolist (part parts)
      (when (memq (plist-get (cdr part) :color) '(eye shine blush))
        (should (plist-get (cdr part) :detail)))
      (when (memq (plist-get (cdr part) :color) '(shine blush))
        (should (plist-get (cdr part) :flat))))
    ;; Two eyes: the one and its mirror.
    (should (plist-get (cdr (cl-find 'eye parts :key (lambda (p) (plist-get (cdr p) :color)))) :mirror))
    ;; At the front the eyes are the dark of the face and it is the same left and right.
    (let ((map (harness-ui-pet-3d-preview 'capybara nil 0 60 24)))
      (dolist (line (butlast (split-string map "\n")))
        (should (= 60 (length line)))))))

(ert-deftest harness-ui-pet-3d-hats-and-models-draw-quickly ()
  "A frame of the capybara in a tophat is drawn in a blink, the first one included."
  (harness-ui-pet-3d-clear)
  (let ((start (float-time)))
    (harness-ui-pet-3d-svg 'capybara 'tophat 0 150 100)
    (should (< (- (float-time) start) 1.0)))
  (let ((start (float-time)))
    (dotimes (i 24) (harness-ui-pet-3d-svg 'capybara 'tophat (* i 15.0) 150 100))
    (should (< (/ (- (float-time) start) 24) 0.1))))

;;;; The files

(ert-deftest harness-ui-pet-3d-files-compile-without-warnings ()
  "The renderer and the models byte-compile cleanly, leaving nothing in the tree."
  (let ((dir (make-temp-file "pet3d-elc-" t)))
    (unwind-protect
        (dolist (name '("harness-ui-pet-models" "harness-ui-pet-3d"))
          (let* ((source (expand-file-name (format "lisp/ui/%s.el" name) harness-test-root))
                 (target (expand-file-name (concat name ".elc") dir))
                 (byte-compile-error-on-warn t)
                 (byte-compile-dest-file-function (lambda (_file) target))
                 (byte-compile-verbose nil)
                 (inhibit-message t))
            (should (eq t (byte-compile-file source)))
            (should (file-exists-p target))
            (should-not (file-exists-p (expand-file-name (concat name ".elc")
                                                         (file-name-directory source))))))
      (delete-directory dir t))))

(provide 'harness-ui-pet-3d-test)
;;; harness-ui-pet-3d-test.el ends here
