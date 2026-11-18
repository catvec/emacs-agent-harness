;;; harness-board-test.el --- Tests for the board's grammar  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The grammar on its own: the primitives a view's geometry may be, the
;; matrices and what they do, the named local anchors, the attachment
;; order the design documents, and the ways a document is refused.
;;
;; Two rules are what the design turns on and are held here exactly:
;; semantic identity is separate from representation (one object, many
;; views, one history), and a transform never mirrors a label.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-board)

;;;; Fixtures

(defun harness-board-test--view (&rest overrides)
  "Return a simple view, with OVERRIDES applied as a plist."
  (append overrides
          (list :shape (list :kind "rect" :w 100 :h 40)
                :transform (vector 1 0 0 1 0 0)
                :style (list :fill "card" :stroke "edge")
                :anchors nil
                :z 0)))

(defun harness-board-test--board (&rest objects)
  "Return a board holding OBJECTS, each ID, KIND and VIEW in turn."
  (harness-board-normalise
   (list :schema harness-board-schema
         :id "b-test" :name "test" :theme "electric-commons"
         :diagrams (list (list :id "d-one" :name "one")
                         (list :id "d-two" :name "two"))
         :objects (cl-loop for (id kind view) on objects by #'cdddr
                           collect (list :id id :kind kind
                                         :views (list :d-one view))))))

(defun harness-board-test--near (a b)
  "Return non-nil when points A and B are the same point, within rounding."
  (and (< (abs (- (car a) (car b))) 1e-9)
       (< (abs (- (cdr a) (cdr b))) 1e-9)))

(defun harness-board-test--refusal (thunk)
  "Return the kind of the board error THUNK raises, or nil when it raises none."
  (condition-case err
      (progn (funcall thunk) nil)
    (harness-board-error (harness-board-error-kind err))))

;;;; The primitives

(ert-deftest harness-board-grammar-has-the-six-primitives-and-no-others ()
  "Every shape kind is one the renderer draws, and the list is closed."
  (should (equal '("rect" "ellipse" "polygon" "path" "text" "image")
                 harness-board-shape-kinds))
  (should (equal '("ellipse" "image" "path" "polygon" "rect" "text")
                 (sort (copy-sequence harness-board-shape-kinds) #'string<))))

(ert-deftest harness-board-grammar-accepts-each-primitive ()
  (dolist (shape (list (list :kind "rect" :w 10 :h 20)
                       (list :kind "ellipse" :rx 10 :ry 20)
                       (list :kind "polygon" :points (list (list 0 0) (list 10 0) (list 5 9)))
                       (list :kind "path" :segments (list (list "M" 0 0) (list "L" 10 0)
                                                          (list "C" 12 2 14 4 16 0)
                                                          (list "Q" 8 6 0 0) (list "Z")))
                       (list :kind "text" :text "words" :size 14)
                       (list :kind "image" :w 40 :h 30 :src "picture.png")))
    (ert-info ((format "%S" (plist-get shape :kind)))
      (should (equal (plist-get shape :kind)
                     (plist-get (harness-board--shape shape) :kind))))))

(ert-deftest harness-board-grammar-refuses-a-shape-it-does-not-have ()
  (should (eq 'unsupported-operation
              (harness-board-test--refusal
               (lambda () (harness-board--shape (list :kind "arc" :r 10))))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--shape (list :kind "rect" :w 0 :h 10)))))))

(ert-deftest harness-board-grammar-a-path-is-finite-and-starts-with-m ()
  "A path is its own segments, never an SVG string to parse."
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--shape
                           (list :kind "path" :segments (list (list "L" 0 0))))))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--shape
                           (list :kind "path" :segments (list (list "M" 0))))))))
  (should (eq 'unsupported-operation
              (harness-board-test--refusal
               (lambda () (harness-board--shape
                           (list :kind "path" :segments (list (list "M" 0 0)
                                                              (list "X" 1 1))))))))
  ;; "M10 10 L20 20" is a string, not a path.
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--shape
                           (list :kind "path" :segments "M10 10 L20 20")))))))

(ert-deftest harness-board-grammar-a-number-must-be-finite-and-bounded ()
  "A coordinate past the limit is refused, and so is a value that is not a number."
  (should (= 12 (harness-board--number "12")))
  (dolist (bad (list "twenty" nil (vector 1) (1+ harness-board-max-coordinate)))
    (ert-info ((format "%S" bad))
      (should (eq 'invalid-parameter
                  (harness-board-test--refusal (lambda () (harness-board--number bad)))))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--positive 0 "scale"))))))

;;;; Matrices

(ert-deftest harness-board-matrix-composition-is-svg-order ()
  "A matrix applies as SVG writes it: [a b c d e f] is x' = ax + cy + e."
  (let ((m (vector 2 0 0 3 10 20)))
    (should (harness-board-test--near (cons 14 26) (harness-board-matrix-apply m 2 2)))))

(ert-deftest harness-board-matrix-multiply-composes-left-to-right ()
  (let* ((translate (harness-board-matrix-translation 10 0))
         (scale (harness-board-matrix-scale 2 2))
         (both (harness-board-matrix-multiply translate scale)))
    ;; First scale, then translate: (1,1) -> (2,2) -> (12,2).
    (should (harness-board-test--near (cons 12 2) (harness-board-matrix-apply both 1 1)))))

(ert-deftest harness-board-matrix-rotation-is-clockwise-in-a-y-down-plane ()
  "Angles are clockwise, and y grows down, so 90 degrees turns x into y."
  (let ((point (harness-board-matrix-apply (harness-board-matrix-rotation 90) 1 0)))
    (should (< (abs (- (car point) 0)) 1e-9))
    (should (< (abs (- (cdr point) 1)) 1e-9))))

(ert-deftest harness-board-matrix-about-turns-around-the-pivot ()
  (let* ((pivot (cons 5 5))
         (m (harness-board-matrix-about (harness-board-matrix-rotation 180) pivot))
         (point (harness-board-matrix-apply m 5 5)))
    (should (< (abs (- (car point) 5)) 1e-9))
    (should (< (abs (- (cdr point) 5)) 1e-9))))

(ert-deftest harness-board-matrix-inverse-undoes-it ()
  (let* ((m (harness-board-matrix-multiply
             (harness-board-matrix-translation 40 -12)
             (harness-board-matrix-multiply (harness-board-matrix-rotation 33)
                                            (harness-board-matrix-scale 2 0.5))))
         (back (harness-board-matrix-multiply m (harness-board-matrix-inverse m)))
         (point (harness-board-matrix-apply back 7 -3)))
    (should (< (abs (- (car point) 7)) 1e-9))
    (should (< (abs (- (cdr point) -3)) 1e-9))))

(ert-deftest harness-board-matrix-a-collapsed-plane-is-refused ()
  "Zero scale has no inverse and no human reading, so a document cannot hold one."
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--matrix (vector 0 0 0 1 0 0) "transform")))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--matrix (vector 0 0 0 0 0 0) "transform")))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--matrix (vector 1 0 0) "transform"))))))

(ert-deftest harness-board-matrix-says-when-it-reflects ()
  (should (harness-board-matrix-reflects-p (harness-board-matrix-reflection 'x)))
  (should (harness-board-matrix-reflects-p (vector -1 0 0 1 0 0)))
  (should-not (harness-board-matrix-reflects-p harness-board-identity))
  (should-not (harness-board-matrix-reflects-p (harness-board-matrix-rotation 45)))
  ;; Two reflections are a rotation.
  (should-not (harness-board-matrix-reflects-p
               (harness-board-matrix-multiply (harness-board-matrix-reflection 'x)
                                              (harness-board-matrix-reflection 'y))))
  (let ((scale (harness-board-matrix-scale-of (harness-board-matrix-scale 2 3))))
    (should (harness-board-test--near (cons 2 3) scale))))

;;;; Anchors

(ert-deftest harness-board-anchors-are-local-points ()
  "A named anchor is a point in the object's own frame, and the implicit ones are the box's edges."
  (let* ((view (harness-board-test--view :anchors (list :tip (vector 100 20))))
         (object (harness-board-test--board "n-1" 'note view))
         (found (harness-board--object! object "n-1"))
         (the-view (harness-board--view found "d-one")))
    (should (equal (cons 100 20) (harness-board-anchor-local the-view "tip")))
    (should (equal (cons 0 20) (harness-board-anchor-local the-view "left")))
    (should (equal (cons 100 20) (harness-board-anchor-local the-view "right")))
    (should (equal (cons 50 0) (harness-board-anchor-local the-view "top")))
    (should (equal (cons 50 40) (harness-board-anchor-local the-view "bottom")))
    (should (equal (cons 50 20) (harness-board-anchor-local the-view "center")))
    (should-not (harness-board-anchor-local the-view "nonesuch"))))

(ert-deftest harness-board-anchors-follow-the-place-the-view-is-put ()
  "The same local anchor is a different diagram point once the view moves."
  (let* ((view (harness-board-test--view :anchors (list :tip (vector 100 20))
                                         :transform (vector 1 0 0 1 30 7))))
    (should (harness-board-test--near (cons 130 27) (harness-board-anchor-point view "tip")))))

(ert-deftest harness-board-anchors-refuse-a-name-that-is-not-one ()
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--anchors (list "1bad" (vector 0 0)))))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--anchors (list "tip" (vector 0))))))))

;;;; Attachment: the documented order

(ert-deftest harness-board-attach-puts-the-childs-base-on-the-parents-tip ()
  "The leaf study: the child's base lands exactly on the parent's tip."
  (dolist (case '((0 1 nil) (30 1.5 t) (-45 0.75 nil) (180 2 t)))
    (let* ((angle (nth 0 case)) (scale (nth 1 case)) (mirror (nth 2 case))
           (parent-anchor (cons 100 0))
           (matrix (harness-board--attach-matrix (cons 0 0) parent-anchor angle scale mirror))
           (placed (harness-board-matrix-apply matrix 0 0)))
      (ert-info ((format "angle %s scale %s mirror %S" angle scale mirror))
        (should (< (abs (- (car placed) 100)) 1e-9))
        (should (< (abs (- (cdr placed) 0)) 1e-9))))))

(ert-deftest harness-board-attach-order-is-reflect-then-scale-then-rotate-then-translate ()
  "The order is the design's: T(parent) . R(angle) . S(scale) . F(mirror) . T(-child)."
  (let* ((angle 30) (scale 2)
         (child-anchor (cons 0 0))
         (parent-point (cons 160 220))
         (built (harness-board--attach-matrix child-anchor parent-point angle scale t))
         (expected (harness-board-matrix-multiply
                    (harness-board-matrix-translation (car parent-point) (cdr parent-point))
                    (harness-board-matrix-multiply
                     (harness-board-matrix-rotation angle)
                     (harness-board-matrix-multiply
                      (harness-board-matrix-scale scale scale)
                      (harness-board-matrix-reflection 'x))))))
    (should (equal built expected))
    ;; The reflection is across the child's growth axis (x), so a tip
    ;; above the axis lands below it, and the other way round.
    (let* ((up (harness-board-matrix-apply built 100 -30))
           (down (harness-board-matrix-apply built 100 30))
           (mid (harness-board-matrix-apply built 50 0)))
      (should (< (* (- (cdr up) (cdr mid)) (- (cdr down) (cdr mid))) 0)))
    ;; The reflection is a reflection of the shape, not of its words: a
    ;; mirrored placement is a negative determinant, which is what a
    ;; renderer reads to keep a label upright.
    (should (harness-board-matrix-reflects-p built))))

(ert-deftest harness-board-attach-refuses-a-zero-scale ()
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--attach-matrix (cons 0 0) (cons 0 0) 0 0 nil)))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board--attach-matrix (cons 0 0) (cons 0 0) 0 -1 nil))))))

;;;; Identity apart from representation

(ert-deftest harness-board-one-object-may-have-a-view-in-several-diagrams ()
  "The same semantic object appears in more than one view, with one history."
  (let* ((board (harness-board-test--board "n-api" 'component (harness-board-test--view)))
         (object (harness-board--object! board "n-api"))
         (second (harness-board--set-view object "d-two"
                                          (harness-board-test--view :transform (vector 1 0 0 1 300 0))))
         (board (harness-board-normalise
                 (plist-put (copy-sequence board) :objects (list second)))))
    (should (equal '("d-one" "d-two")
                   (mapcar #'car (harness-board--object-views (harness-board--object! board "n-api")))))
    ;; One object, so one line in the document, whatever it is drawn in.
    (should (= 1 (length (plist-get board :objects))))
    ;; The geometry is the diagram's, the meaning is the object's.
    (should (harness-board-test--near
             (cons 0 0)
             (harness-board-view-anchor-origin
              (harness-board--view (harness-board--object! board "n-api") "d-one"))))
    (should (harness-board-test--near
             (cons 300 0)
             (harness-board-view-anchor-origin
              (harness-board--view (harness-board--object! board "n-api") "d-two"))))))

(ert-deftest harness-board-a-document-of-another-schema-is-refused ()
  "A board of a schema this harness does not read is refused, never half-read."
  (should (eq 'unsupported-operation
              (harness-board-test--refusal
               (lambda () (harness-board-normalise-document
                           (list :schema 99 :id "b" :name "b"
                                 :diagrams (list (list :id "d"))))))))
  (should (eq 'invalid-parameter
              (harness-board-test--refusal
               (lambda () (harness-board-normalise-document
                           (list :schema 1 :id "b" :name "b"
                                 :diagrams nil)))))))

(ert-deftest harness-board-a-document-refuses-what-names-nothing ()
  "A view on a diagram that is not there, a group that is not one, a selection of nothing."
  (let ((board (harness-board-test--board "n-1" 'note (harness-board-test--view))))
    (should (eq 'invalid-reference
                (harness-board-test--refusal
                 (lambda ()
                   (harness-board-normalise-document
                    (plist-put (copy-sequence board) :objects
                               (list (list :id "n-1" :kind 'note
                                           :views (list :d-nowhere (harness-board-test--view))))))))))
    (should (eq 'invalid-reference
                (harness-board-test--refusal
                 (lambda ()
                   (harness-board-normalise-document
                    (plist-put (copy-sequence board) :objects
                               (list (list :id "n-1" :kind 'note :group "n-2"
                                           :views (list :d-one (harness-board-test--view))))))))))
    (should (eq 'invalid-reference
                (harness-board-test--refusal
                 (lambda ()
                   (harness-board-normalise-document
                    (plist-put (copy-sequence board) :diagrams
                               (list (list :id "d-one" :selection (vector "n-nowhere"))
                                     (list :id "d-two"))))))))))

(ert-deftest harness-board-a-document-refuses-a-kind-it-does-not-have ()
  (should (eq 'unsupported-operation
              (harness-board-test--refusal
               (lambda ()
                 (harness-board-test--board "n-1" 'kanban-card (harness-board-test--view)))))))

;;;; Boxes

(ert-deftest harness-board-a-box-is-the-placed-bounds ()
  "The box is what a renderer clips and a person drags: the transformed shape's bounds."
  (let ((view (harness-board-test--view :transform (vector 1 0 0 1 20 30))))
    (should (equal (list 20 30 100 40) (harness-board-view-box view))))
  ;; A rotation grows the axis-aligned box of a wide rectangle.
  (let* ((view (harness-board-test--view :transform (harness-board-matrix-rotation 90)))
         (box (harness-board-view-box view)))
    (should (< (abs (- (nth 2 box) 40)) 1e-9))
    (should (< (abs (- (nth 3 box) 100)) 1e-9))))

(ert-deftest harness-board-a-views-geometry-can-be-a-path-or-a-polygon ()
  "A path's box is the box of its control points; a polygon's is its points'."
  (let ((box (harness-board-shape-box
              (list :kind "polygon"
                    :points (list (list 10 10) (list 30 10) (list 20 50))))))
    (should (equal (list 10 10 20 40) box)))
  (let ((box (harness-board-shape-box
              (list :kind "path" :segments (list (list "M" 0 0) (list "L" 50 25))))))
    (should (equal (list 0 0 50 25) box))))

;;;; Themes

(ert-deftest harness-board-themes-are-palettes-not-new-capabilities ()
  "Every colour a theme names is one a style may use, so a theme draws nothing an edit could not."
  (dolist (theme harness-board-themes)
    (ert-info ((format "%s" (car theme)))
      (dolist (pair (cdr theme))
        (should (member (format "%s" (cdr pair))
                        (mapcar (lambda (role)
                                  (cdr (assoc (intern role) (cdr theme))))
                                harness-board-color-roles))))))
  ;; The three the design asks for are there, by name.
  (should (equal '("electric-commons" "open-labels" "night-commons")
                 (mapcar (lambda (theme) (symbol-name (car theme))) harness-board-themes))))

(ert-deftest harness-board-a-theme-names-every-role-the-styles-use ()
  "A style may name any colour role, in any theme, and it resolves."
  (dolist (theme harness-board-themes)
    (dolist (role '("paper" "ink" "frame" "edge" "card" "muted" "group"
                    "accent" "accent-soft" "note" "note-soft" "violet" "danger"))
      (ert-info ((format "%s %s" (car theme) role))
        (should (cdr (assoc (intern role) (cdr theme))))))))

(provide 'harness-board-test)
;;; harness-board-test.el ends here
