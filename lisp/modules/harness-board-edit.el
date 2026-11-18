;;; harness-board-edit.el --- Operations, patches, commits and undo for the board  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The edit half of the freeform board (harness-board.el): the operations a
;; person or an agent may apply, the patch validation produces, and the
;; commit that applies it.
;;
;; A PATCH.  `harness-board-plan' takes a board and an ordered array of
;; operations and returns a patch plist without touching anything:
;;
;;   :id          the patch id, a digest of the base revision and the batch
;;   :hash        the content hash a commit must name
;;   :board       the document as the operations would leave it
;;   :revision    the revision the patch was made against
;;   :requested   the operations the caller wrote
;;   :ops         the expanded operations, every one of them ordinary
;;   :created     the ids the patch makes
;;   :changed     the ids whose document entry it replaces
;;   :preimages   (ID ENTRY ...) as each was before the patch
;;   :postimages  (ID ENTRY ...) as each is after it, which undo compares
;;   :diagnostics soft findings: overflow, movement, overlaps nobody declared
;;
;; Every operation is validated against the document as it will be after
;; the operations before it, so a create followed by a transform of that
;; create works, and an operation naming an id that does not exist yet is
;; refused.  A refusal signals `harness-board-error' with one of the kinds
;; in `harness-board-error-kinds'.
;;
;; A COMMIT is the only thing that writes.  It checks the revision the
;; patch was made against, revalidates the patch against the document as it
;; is now, and applies it whole.  A commit carrying an idempotency key that
;; was used before returns its earlier answer.
;;
;; UNDO.  A commit keeps the preimages and postimages of what it replaced,
;; and the board keeps its newest `harness-board-history-limit' commits.
;; Undo builds a compensating batch from them: an object the commit created
;; is deleted, an object it replaced gets its preimage back, an object it
;; deleted is restored -- each only while the document still holds what the
;; commit left there.  An object somebody else changed since is left alone
;; and reported as a conflict, so undo never rewrites another writer's work.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-board)

;;;; Small helpers over the document

(defun harness-board--put-diagram (board diagram)
  "Return BOARD with its diagram whose id is DIAGRAM's replaced."
  (plist-put (copy-sequence board) :diagrams
             (cl-mapcar (lambda (d)
                          (if (equal (plist-get d :id) (plist-get diagram :id)) diagram d))
                        (plist-get board :diagrams))))

(defun harness-board--add-diagram (board diagram)
  "Return BOARD with DIAGRAM added."
  (plist-put (copy-sequence board) :diagrams
             (append (plist-get board :diagrams) (list diagram))))

(defun harness-board--put-object (board object)
  "Return BOARD with OBJECT replacing the object of its id, or added."
  (let* ((objects (plist-get board :objects))
         (old (cl-find (plist-get object :id) objects
                       :key (lambda (o) (plist-get o :id)) :test #'equal)))
    (plist-put (copy-sequence board) :objects
               (if old
                   (cl-mapcar (lambda (o) (if (eq o old) object o)) objects)
                 (append objects (list object))))))

(defun harness-board--remove-object (board id)
  "Return BOARD without the object ID."
  (plist-put (copy-sequence board) :objects
             (cl-remove-if (lambda (o) (equal (plist-get o :id) id))
                           (plist-get board :objects))))

(defun harness-board--put-relationship (board relationship)
  "Return BOARD with RELATIONSHIP replacing the one of its id, or added."
  (let ((old (harness-board--relationship board (plist-get relationship :id))))
    (plist-put (copy-sequence board) :relationships
               (if old
                   (cl-mapcar (lambda (r) (if (eq r old) relationship r))
                              (plist-get board :relationships))
                 (append (plist-get board :relationships) (list relationship))))))

(defun harness-board--remove-relationship (board id)
  "Return BOARD without the relationship ID."
  (plist-put (copy-sequence board) :relationships
             (cl-remove-if (lambda (r) (equal (plist-get r :id) id))
                           (plist-get board :relationships))))

(defun harness-board--restore-entry (board _id entry)
  "Return BOARD with the document entry ENTRY put back.
ENTRY is an object, a relationship or a diagram; what it holds says
which: a diagram has a viewport, an object views, a relationship ends."
  (cond
   ((plist-member entry :viewport)
    (let ((checked (harness-board--normalise-diagram entry)))
      (if (harness-board--diagram board (plist-get checked :id))
          (harness-board--put-diagram board checked)
        (harness-board--add-diagram board checked))))
   ((plist-get entry :views) (harness-board--put-object board entry))
   ((plist-member entry :from) (harness-board--put-relationship board entry))
   (t (harness-board--put-relationship board entry))))

(defun harness-board--require-view (_board object diagram)
  "Return the view of OBJECT in DIAGRAM, or refuse it."
  (or (harness-board--view object diagram)
      (harness-board--fail 'precondition
                           "object %s has no view in diagram %s; its diagrams are %s"
                           (plist-get object :id) diagram
                           (string-join (mapcar #'car (harness-board--object-views object)) ", "))))

(defun harness-board--check-scope! (scope id what)
  "Refuse an operation outside SCOPE (nil for none) that names ID."
  (when (and scope (not (member id scope)))
    (harness-board--fail 'hard-constraint
                         "%s %s is outside the scope of this edit (%s)"
                         what id (string-join scope ", "))))

(defun harness-board--map-view (board id diagram function)
  "Return BOARD with FUNCTION applied to the view of object ID in DIAGRAM."
  (let* ((object (harness-board--object! board id))
         (view (harness-board--require-view board object diagram)))
    (harness-board--put-object board
                               (harness-board--set-view object diagram (funcall function view)))))

(defun harness-board--diagram-ids-of (object)
  "Return the diagrams OBJECT has a view in."
  (mapcar #'car (harness-board--object-views object)))

;;;; Diagnostics

(defun harness-board--diagnostic (kind level message &rest args)
  "Return a diagnostic of KIND and LEVEL, its MESSAGE written with ARGS.
MESSAGE is a `format' string: a diagnostic a person reads says which
objects and how much, not the placeholders it was written with."
  (append (list :kind kind :level level :message (apply #'format message args))
          args))

(defun harness-board-diagnostics (board-old board-new)
  "Return the soft findings a patch from BOARD-OLD to BOARD-NEW raises.
These are warnings, never refusals: a person may mean to clip a note, to
move something far, or to overlap two objects on purpose.  Each is a
plist with `:kind', `:level', `:message' and the ids it is about."
  (let ((diagnostics nil))
    (dolist (diagram (harness-board--diagram-ids board-new))
      (let ((placed (cl-loop for object in (plist-get board-new :objects)
                             for view = (harness-board--view object diagram)
                             when view
                             collect (cons object view))))
        ;; Words in a box too small for them, and two objects that share a
        ;; place: both are observations, not refusals.
        (dolist (pair placed)
          (when-let* ((overflow (harness-board--overflow (car pair) diagram (cdr pair))))
            (push overflow diagnostics)))
        (dolist (a placed)
          (dolist (b placed)
            (when (string< (plist-get (car a) :id) (plist-get (car b) :id))
              (let* ((view-a (cdr a)) (view-b (cdr b))
                     (shape-a (plist-get view-a :shape))
                     (shape-b (plist-get view-b :shape)))
                ;; A frame is a region, not a card: what stands on it is
                ;; meant to be there, so it is not the overlap a person
                ;; would want to hear about.
                (when (and shape-a shape-b
                           (not (eq (plist-get (car a) :kind) 'frame))
                           (not (eq (plist-get (car b) :kind) 'frame)))
                  (let* ((box-a (harness-board-view-box view-a))
                         (box-b (harness-board-view-box view-b))
                         (overlap (harness-board-box-overlap box-a box-b)))
                    (when (> overlap 0.5)
                      (push (harness-board--diagnostic
                             'overlap 'warning
                             "%s and %s overlap in %s"
                             (plist-get (car a) :id) (plist-get (car b) :id) diagram)
                            diagnostics))))))))
        (dolist (pair placed)
          (let* ((object (car pair)) (view (cdr pair))
                 (old (harness-board--object board-old (plist-get object :id)))
                 (before (and old (harness-board--view old diagram))))
            (when (and before
                       (not (equal (plist-get view :transform) (plist-get before :transform))))
              (when-let* ((far (harness-board--movement (plist-get object :id) before view)))
                (push far diagnostics)))))))
    (nreverse diagnostics)))

(defun harness-board-box-contains-p (outer inner &optional tolerance)
  "Return non-nil when box OUTER holds INNER, within TOLERANCE units.
Both are (X Y W H), as `harness-board-view-box' reads one."
  (let ((tolerance (or tolerance 1))
        (ox (nth 0 outer)) (oy (nth 1 outer))
        (ow (nth 2 outer)) (oh (nth 3 outer))
        (ix (nth 0 inner)) (iy (nth 1 inner))
        (iw (nth 2 inner)) (ih (nth 3 inner)))
    (and (<= (- ox tolerance) ix)
         (<= (- oy tolerance) iy)
         (>= (+ ox ow tolerance) (+ ix iw))
         (>= (+ oy oh tolerance) (+ iy ih)))))

(defun harness-board-box-overlap (a b)
  "Return the fraction of the smaller of boxes A and B that they share."
  (let* ((ax (nth 0 a)) (ay (nth 1 a)) (aw (nth 2 a)) (ah (nth 3 a))
         (bx (nth 0 b)) (by (nth 1 b)) (bw (nth 2 b)) (bh (nth 3 b))
         (w (max 0 (- (min (+ ax aw) (+ bx bw)) (max ax bx))))
         (h (max 0 (- (min (+ ay ah) (+ by bh)) (max ay by))))
         (area-a (* aw ah)) (area-b (* bw bh))
         (smaller (min area-a area-b)))
    (if (> smaller 0) (/ (* w h) smaller) 0)))

(defconst harness-board--text-padding 14
  "Units of room the words of a shaped object keep from its box's edges.
The renderer insets a note's words by this, so the estimate measures the
same room the drawing gives them.")

(defun harness-board--overflow (object _diagram view)
  "Return an overflow diagnostic for VIEW of OBJECT, or nil.
An estimate: the words wrapped at the room the box gives them, against
the room it has for lines.  It is a warning, never a refusal -- a person
may mean to clip a note, and a label or a marker lays its words out
beside its shape rather than inside it, so only a kind that draws its
words in its box is measured."
  (let* ((shape (plist-get view :shape))
         (kind (plist-get object :kind))
         (text (or (plist-get object :text) (plist-get shape :text))))
    (when (and (memq kind '(note component))
               (equal (plist-get shape :kind) "rect")
               (stringp text) (not (string-empty-p text)))
      (let* ((size (or (plist-get (plist-get view :style) :fontSize) 18))
             (padding harness-board--text-padding)
             (have-w (- (plist-get shape :w) (* 2 padding)))
             (have-h (- (plist-get shape :h) (* 2 padding)))
             (lines (harness-board-edit--wrap text have-w size))
             (needed-h (* size 1.3 (length lines))))
        (when (> needed-h have-h)
          (harness-board--diagnostic
           'overflow 'warning
           "the words of %s need about %d lines; its box holds %d"
           (plist-get object :id) (length lines)
           (max 0 (floor (/ have-h (* size 1.3))))))))))

(defun harness-board-edit--wrap (text width size)
  "Return TEXT split into the lines WIDTH holds at SIZE.
The width of a line is estimated from its characters, which is what a
caller without a font can know; it is the same estimate the renderer
wraps by, so the two agree about what fits."
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

(defun harness-board--movement (id from to)
  "Return a diagnostic when the move of ID from FROM to TO is far."
  (let* ((a (harness-board-matrix-apply (plist-get from :transform) 0 0))
         (b (harness-board-matrix-apply (plist-get to :transform) 0 0))
         (distance (sqrt (+ (expt (- (car a) (car b)) 2)
                            (expt (- (cdr a) (cdr b)) 2)))))
    (when (> distance 800)
      (harness-board--diagnostic 'movement 'warning
                                 "%s moves %d units" id (round distance)))))

;;;; The operations

(defun harness-board--new-object (op diagram)
  "Return (ID . OBJECT) for the create OP in DIAGRAM."
  (let* ((id (or (and (plist-get op :id) (harness-board--id (plist-get op :id) "object id"))
                 (harness-board-new-id "n")))
         (kind (harness-board--symbol (plist-get op :kind)))
         (view (list :shape (when (plist-get op :shape)
                              (harness-board--shape (plist-get op :shape)))
                     :transform (if (plist-get op :transform)
                                    (harness-board--matrix (plist-get op :transform))
                                  (harness-board-matrix-translation
                                   (harness-board--number (or (plist-get op :x) 0) "x")
                                   (harness-board--number (or (plist-get op :y) 0) "y")))
                     :style (harness-board--style (or (plist-get op :style) nil))
                     :anchors (harness-board--anchors (or (plist-get op :anchors) nil))
                     :z (harness-board--number (or (plist-get op :z) 0) "z"))))
    (unless (assoc kind harness-board-object-kinds)
      (harness-board--fail 'unsupported-operation
                           "object kind %s is not one of %s"
                           (plist-get op :kind)
                           (string-join (mapcar #'symbol-name (mapcar #'car harness-board-object-kinds))
                                        ", ")))
    (cons id (list :id id :kind kind
                   :name (harness-board--string (plist-get op :name))
                   :text (harness-board--string (plist-get op :text))
                   :role (or (let ((role (harness-board--symbol (plist-get op :role))))
                               (and (assoc role harness-board-evidence-roles) role))
                             'declared)
                   :locked (and (harness-board--truthy (plist-get op :locked)) t)
                   :group nil
                   :resources (harness-board--normalise-resources (plist-get op :resources))
                   :task (harness-board--string (plist-get op :task))
                   :views (list (intern (concat ":" diagram)) view)))))

(defun harness-board--create (board op)
  "Return (BOARD . CREATED-IDS) for the create OP."
  (let* ((diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (pair (harness-board--new-object op diagram))
         (id (car pair)) (object (cdr pair)))
    (harness-board--diagram! board diagram)
    (when (harness-board--object board id)
      (harness-board--fail 'invalid-parameter "object %s is already here" id))
    (list :board (harness-board--put-object board object) :ops nil :created (list id))))

(defun harness-board--view-add (board op)
  "Return BOARD with OP's object represented in another diagram."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (object (harness-board--object! board id)))
    (harness-board--diagram! board diagram)
    (when (harness-board--view object diagram)
      (harness-board--fail 'invalid-parameter "object %s already has a view in %s" id diagram))
    (let* ((source (harness-board--require-view
                    board object
                    ;; The view it is copied from: the one OP names as
                    ;; `from', else the object's first.
                    (or (and (plist-get op :from)
                             (harness-board--id (plist-get op :from) "source diagram"))
                        (car (harness-board--diagram-ids-of object)))))
           (view (list :shape (if (plist-get op :shape)
                                  (harness-board--shape (plist-get op :shape))
                                (plist-get source :shape))
                       :transform (if (plist-get op :transform)
                                      (harness-board--matrix (plist-get op :transform))
                                    (plist-get source :transform))
                       :style (harness-board--style
                               (or (plist-get op :style) (plist-get source :style)))
                       :anchors (harness-board--anchors
                                 (or (plist-get op :anchors) (plist-get source :anchors)))
                       :z (harness-board--number (or (plist-get op :z) (plist-get source :z) 0)
                                                 "z"))))
      (harness-board--put-object board (harness-board--set-view object diagram view)))))

(defun harness-board--view-remove (board op)
  "Return BOARD without OP's object view, keeping the object itself."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (object (harness-board--object! board id)))
    (harness-board--require-view board object diagram)
    (when (= 1 (length (harness-board--object-views object)))
      (harness-board--fail 'precondition
                           "the view of %s in %s is its last; delete the object instead"
                           id diagram))
    (let ((views nil))
      (dolist (pair (harness-board--object-views object))
        (unless (equal (car pair) diagram)
          (setq views (plist-put views (intern (concat ":" (car pair))) (cdr pair)))))
      (harness-board--put-object
       board (plist-put (copy-sequence object) :views views)))))

(defun harness-board--set-shape (board op)
  "Return BOARD with OP's shape replaced."
  (harness-board--map-view board (harness-board--id (plist-get op :id) "object id")
                           (harness-board--id (plist-get op :diagram) "diagram")
                           (lambda (view)
                             (plist-put (copy-sequence view) :shape
                                        (harness-board--shape (plist-get op :shape))))))

(defun harness-board--refuse-mirrored-label (object op matrix)
  "Refuse a reflection of OBJECT's label unless OP asks for it.
Geometry turns; a label does not, unless the caller says so: that is a
different intent, and the op spells it out."
  (when (and (harness-board-matrix-reflects-p matrix)
             (not (harness-board--truthy (plist-get op :text))))
    (when (memq (plist-get object :kind) '(label text component note marker frame))
      (harness-board--fail 'precondition
                           "reflecting %s would mirror its label; pass \"text\": true to mean it"
                           (plist-get object :id)))))

(defun harness-board--set-transform (board op)
  "Return BOARD with OP's placement matrix replaced."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (object (harness-board--object! board id))
         (matrix (harness-board--matrix (plist-get op :transform))))
    (harness-board--require-view board object diagram)
    (harness-board--refuse-mirrored-label object op matrix)
    (harness-board--map-view board id diagram
                             (lambda (view)
                               (plist-put (copy-sequence view) :transform matrix)))))

(defun harness-board--move (board op)
  "Return BOARD with OP's object translated, inside its budget."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (object (harness-board--object! board id))
         (view (harness-board--require-view board object diagram))
         (dx (harness-board--number (or (plist-get op :dx) 0) "dx"))
         (dy (harness-board--number (or (plist-get op :dy) 0) "dy"))
         (distance (sqrt (+ (* dx dx) (* dy dy))))
         (budget (if (plist-get op :budget)
                     (harness-board--number (plist-get op :budget) "budget")
                   harness-board-movement-budget)))
    (when (plist-get object :locked)
      (harness-board--fail 'hard-constraint "%s is locked" id))
    (when (> distance budget)
      (harness-board--fail 'hard-constraint
                           "%s would move %d units, past its budget of %s"
                           id (round distance) budget))
    (let ((moved (harness-board-matrix-multiply
                  (harness-board-matrix-translation dx dy)
                  (plist-get view :transform))))
      (harness-board--map-view board id diagram
                               (lambda (view)
                                 (plist-put (copy-sequence view) :transform moved))))))

(defun harness-board--transform (board op)
  "Return BOARD with OP's rotate, scale, reflect or affine applied."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (object (harness-board--object! board id))
         (view (harness-board--require-view board object diagram))
         (kind (harness-board--symbol (plist-get op :kind)))
         (pivot (harness-board--point (or (plist-get op :pivot) [0 0]) "pivot"))
         (matrix
          (pcase kind
            ('rotate
             (harness-board-matrix-about
              (harness-board-matrix-rotation
               (harness-board--number (or (plist-get op :angle) 0) "angle"))
              pivot))
            ('scale
             (let ((sx (harness-board--positive (or (plist-get op :sx) (plist-get op :scale) 1) "sx"))
                   (sy (harness-board--positive (or (plist-get op :sy) (plist-get op :scale) 1) "sy")))
               (harness-board-matrix-about (harness-board-matrix-scale sx sy) pivot)))
            ('reflect
             (harness-board-matrix-about
              (harness-board-matrix-reflection
               (let ((axis (plist-get op :axis)))
                 (cond ((or (null axis) (equal axis "x")) 'x)
                       ((equal axis "y") 'y)
                       ((stringp axis)
                        (harness-board--fail 'invalid-parameter
                                             "a reflection axis is x, y or a direction: %S" axis))
                       (t (let ((point (harness-board--point axis "reflection axis")))
                            (cons (car point) (cdr point)))))))
              pivot))
            ('affine
             (harness-board-matrix-about
              (harness-board--matrix (plist-get op :matrix) "transform matrix") pivot))
            (_ (harness-board--fail 'unsupported-operation
                                    "a transform is rotate, scale, reflect or affine, not %s"
                                    (plist-get op :kind))))))
    (when (plist-get object :locked)
      (harness-board--fail 'hard-constraint "%s is locked" id))
    (harness-board--refuse-mirrored-label object op matrix)
    (let ((placed (harness-board-matrix-multiply matrix (plist-get view :transform))))
      (harness-board--map-view board id diagram
                               (lambda (view)
                                 (plist-put (copy-sequence view) :transform placed))))))

(defun harness-board--set-style (board op)
  "Return BOARD with OP's style merged into the view's."
  (harness-board--map-view
   board (harness-board--id (plist-get op :id) "object id")
   (harness-board--id (plist-get op :diagram) "diagram")
   (lambda (view)
     (let ((current (copy-sequence (plist-get view :style)))
           (added (harness-board--style (or (plist-get op :style) nil))))
       (while added
         (setq current (plist-put current (car added) (cadr added))
               added (cddr added)))
       (plist-put (copy-sequence view) :style current)))))

(defun harness-board--set-field (board op field)
  "Return BOARD with OP's FIELD set on its object."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (object (harness-board--object! board id))
         (value (pcase field
                  (:text (harness-board--string (plist-get op :text)))
                  (:name (harness-board--string (plist-get op :name)))
                  (:role (let ((role (harness-board--symbol (plist-get op :role))))
                           (unless (assoc role harness-board-evidence-roles)
                             (harness-board--fail
                              'invalid-parameter
                              "a role is observed, declared, proposed or unknown: %S"
                              (plist-get op :role)))
                           role)))))
    (harness-board--put-object board (plist-put (copy-sequence object) field value))))

(defun harness-board--set-text (board op)
  "Return BOARD with OP's object's text set."
  (harness-board--set-field board op :text))

(defun harness-board--set-name (board op)
  "Return BOARD with OP's object's name set."
  (harness-board--set-field board op :name))

(defun harness-board--set-role (board op)
  "Return BOARD with OP's object's evidence role set.
The role says what the drawing claims: observed, declared, proposed or
unknown.  It is the object's, not the view's, so every view agrees."
  (harness-board--set-field board op :role))

(defun harness-board--lock (board op)
  "Return BOARD with OP's object locked or unlocked."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (object (harness-board--object! board id)))
    (harness-board--put-object board
                               (plist-put (copy-sequence object) :locked
                                          (and (harness-board--truthy (plist-get op :on)) t)))))

(defun harness-board--group (board op)
  "Return (:board BOARD :created (ID)) with a group made of OP's members."
  (let* ((diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (members (mapcar (lambda (id) (harness-board--id id "member"))
                          (append (plist-get op :members) nil)))
         (requested (and (plist-get op :id) (harness-board--id (plist-get op :id) "group id")))
         (id (or requested (harness-board-new-id "g")))
         (view (list :shape nil
                     :transform harness-board-identity
                     :style (harness-board--style (or (plist-get op :style) nil))
                     :anchors nil
                     :z (harness-board--number (or (plist-get op :z) 0) "z")))
         (group nil))
    (harness-board--diagram! board diagram)
    (unless (>= (length members) 2)
      (harness-board--fail 'invalid-parameter "a group needs two members or more: %S" members))
    (when (harness-board--object board id)
      (harness-board--fail 'invalid-parameter "object %s is already here" id))
    (dolist (member members)
      (let ((object (harness-board--object! board member)))
        (when (plist-get object :group)
          (harness-board--fail 'precondition "%s already belongs to a group" member))
        (harness-board--require-view board object diagram)))
    (setq group (list :id id :kind 'group
                      :name (harness-board--string (plist-get op :name))
                      :text nil :role 'declared :locked nil :group nil
                      :resources nil :task nil
                      :views (list (intern (concat ":" diagram)) view)))
    (setq board (harness-board--put-object board group))
    (dolist (member members)
      (let ((object (harness-board--object! board member)))
        (setq board (harness-board--put-object
                     board (plist-put (copy-sequence object) :group id)))))
    (list :board board :ops nil :created (list id))))

(defun harness-board--ungroup (board op)
  "Return BOARD with OP's group dissolved; members keep their ids."
  (let* ((id (harness-board--id (plist-get op :id) "group id"))
         (group (harness-board--object! board id)))
    (unless (eq (plist-get group :kind) 'group)
      (harness-board--fail 'precondition "%s is not a group" id))
    (let ((board (harness-board--remove-object board id)))
      (dolist (object (plist-get board :objects))
        (when (equal (plist-get object :group) id)
          (setq board (harness-board--put-object
                       board (plist-put (copy-sequence object) :group nil)))))
      board)))

(defun harness-board--detach (board op)
  "Return (:board BOARD :created (ID)) with OP's view made an object of its own."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (new-id (or (and (plist-get op :newId)
                          (harness-board--id (plist-get op :newId) "new id"))
                     (harness-board-new-id "n")))
         (object (harness-board--object! board id))
         (view (harness-board--require-view board object diagram)))
    (when (harness-board--object board new-id)
      (harness-board--fail 'invalid-parameter "object %s is already here" new-id))
    (let ((copy (plist-put (copy-sequence object) :id new-id)))
      (setq copy (plist-put copy :group nil))
      (setq copy (plist-put copy :views
                            (list (intern (concat ":" diagram)) (copy-sequence view))))
      (list :board (harness-board--put-object board copy)
            :ops nil :created (list new-id)))))

(defun harness-board--connect (board op)
  "Return (BOARD . CREATED-IDS) with a relationship for OP."
  (let* ((id (or (and (plist-get op :id) (harness-board--id (plist-get op :id) "relationship id"))
                 (harness-board-new-id "e")))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (relationship (harness-board--normalise-relationship
                        (list :id id :kind (or (plist-get op :kind) 'flow)
                              :diagram diagram
                              :label (plist-get op :label)
                              :from (plist-get op :from) :to (plist-get op :to)
                              :style (plist-get op :style)
                              :resources (plist-get op :resources)
                              :role (plist-get op :role)))))
    (when (harness-board--relationship board id)
      (harness-board--fail 'invalid-parameter "relationship %s is already here" id))
    (harness-board--diagram! board diagram)
    (dolist (endpoint (list (plist-get relationship :from) (plist-get relationship :to)))
      (let* ((endpoint-id (plist-get endpoint :object))
             (object (or (harness-board--object board endpoint-id)
                         (harness-board--fail 'unknown-id "no object %s in this board" endpoint-id)))
             (view (or (harness-board--view object diagram)
                       (harness-board--fail 'invalid-reference
                                            "%s has no view in %s" endpoint-id diagram))))
        (when-let* ((anchor (plist-get endpoint :anchor)))
          (unless (harness-board-anchor-point view anchor)
            (harness-board--fail 'invalid-reference "%s has no anchor %s" endpoint-id anchor)))))
    (list :board (harness-board--put-relationship board relationship) :ops nil :created (list id))))

(defun harness-board--attach (board op)
  "Return (BOARD . EXPANDED-OPS) placing OP's child anchor on the parent's."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (diagram (harness-board--id (plist-get op :diagram) "diagram"))
         (child (harness-board--object! board id))
         (parent-id (harness-board--id (or (plist-get op :parent) (plist-get op :to)) "parent id"))
         (parent (harness-board--object! board parent-id))
         (child-view (harness-board--require-view board child diagram))
         (parent-view (harness-board--require-view board parent diagram))
         (child-anchor (or (harness-board--string (or (plist-get op :childAnchor)
                                                      (plist-get op :child-anchor)))
                           "base"))
         (parent-anchor (or (harness-board--string (or (plist-get op :parentAnchor)
                                                       (plist-get op :parent-anchor)))
                            "tip"))
         (local (harness-board-anchor-local child-view child-anchor))
         (point (harness-board-anchor-point parent-view parent-anchor)))
    (unless local
      (harness-board--fail 'invalid-reference "%s has no anchor %s" id child-anchor))
    (unless point
      (harness-board--fail 'invalid-reference "%s has no anchor %s" parent-id parent-anchor))
    (when (and (plist-get child :locked))
      (harness-board--fail 'hard-constraint "%s is locked" id))
    (let* ((matrix (harness-board--attach-matrix
                    local (cons (car point) (cdr point))
                    (or (plist-get op :angle) 0)
                    (or (plist-get op :scale) 1)
                    (plist-get op :mirror)))
           (expanded (list (list :op "set-transform" :id id :diagram diagram
                                 :transform matrix
                                 :text (and (harness-board--truthy (plist-get op :text)) t))))
           (board (harness-board--set-transform board (car expanded))))
      (list :board board :ops expanded :created nil))))

(defun harness-board--relate (board op)
  "Return BOARD with OP's object's resources replaced."
  (let* ((id (harness-board--id (plist-get op :id) "object id"))
         (resources (harness-board--normalise-resources (plist-get op :resources))))
    (cond
     ((harness-board--object board id)
      (harness-board--put-object board
                                 (plist-put (copy-sequence (harness-board--object board id))
                                            :resources resources)))
     ((harness-board--relationship board id)
      (harness-board--put-relationship board
                                       (plist-put (copy-sequence (harness-board--relationship board id))
                                                  :resources resources)))
     (t (harness-board--fail 'unknown-id "no object or relationship %s" id)))))

(defun harness-board--layer (board op)
  "Return BOARD with OP's view laid at its z."
  (harness-board--map-view board (harness-board--id (plist-get op :id) "object id")
                           (harness-board--id (plist-get op :diagram) "diagram")
                           (lambda (view)
                             (plist-put (copy-sequence view) :z
                                        (harness-board--number (plist-get op :z) "z")))))

(defun harness-board--delete (board op)
  "Return BOARD without OP's object, its views and its relationships.
An id that names a diagram removes the diagram, unless it is the board's
last: a board with no diagram has nowhere to put anything."
  (let* ((id (harness-board--id (plist-get op :id) "object id")))
    (cond
     ((harness-board--relationship board id)
      (harness-board--remove-relationship board id))
     ((and (harness-board--diagram board id)
           (not (harness-board--object board id)))
      (when (= 1 (length (plist-get board :diagrams)))
        (harness-board--fail 'precondition
                             "%s is the board's last diagram; a board keeps one" id))
      (when (cl-find-if (lambda (object) (harness-board--view object id))
                        (plist-get board :objects))
        (harness-board--fail 'hard-constraint
                             "%s still holds objects; remove their views first" id))
      (plist-put (copy-sequence board) :diagrams
                 (cl-remove-if (lambda (diagram) (equal (plist-get diagram :id) id))
                               (plist-get board :diagrams))))
     ((let ((object (harness-board--object board id)))
        (when (plist-get object :locked)
          (harness-board--fail 'hard-constraint "%s is locked" id))
        (let ((board (harness-board--remove-object board id)))
          (dolist (other (plist-get board :objects))
            (when (equal (plist-get other :group) id)
              (setq board (harness-board--put-object
                           board (plist-put (copy-sequence other) :group nil)))))
          (plist-put
           (plist-put (copy-sequence board) :relationships
                      (cl-remove-if (lambda (r)
                                      (or (equal (plist-get (plist-get r :from) :object) id)
                                          (equal (plist-get (plist-get r :to) :object) id)))
                                    (plist-get board :relationships)))
           :diagrams
           (mapcar (lambda (diagram)
                     (list :id (plist-get diagram :id)
                           :name (plist-get diagram :name)
                           :parent (plist-get diagram :parent)
                           :viewport (plist-get diagram :viewport)
                           :selection (vconcat (cl-remove id (append (plist-get diagram :selection)
                                                                     nil)))
                           :portals (vconcat (cl-remove-if
                                              (lambda (portal) (equal (plist-get portal :from) id))
                                              (append (plist-get diagram :portals) nil)))))
                   (plist-get board :diagrams))))))
     (t (harness-board--fail 'unknown-id "no object or relationship %s" id)))))

(defun harness-board--board-field (board op field)
  "Return BOARD with a document FIELD set from OP."
  (pcase field
    (:theme
     (let ((theme (harness-board--string (plist-get op :theme))))
       (unless (assoc (intern theme) harness-board-themes)
         (harness-board--fail 'invalid-parameter
                              "theme %s is not one of %s" theme
                              (string-join (mapcar #'symbol-name (mapcar #'car harness-board-themes))
                                           ", ")))
       (plist-put (copy-sequence board) :theme theme)))
    (:name (plist-put (copy-sequence board) :name
                      (or (harness-board--string (plist-get op :name)) "board")))
    (:diagram.add
     (let* ((id (harness-board--id (or (plist-get op :id) (plist-get op :diagram))
                                   "diagram id"))
            (existing (harness-board--diagram board id))
            (diagram (harness-board--normalise-diagram
                      (list :id id :name (or (plist-get op :name) id)
                            :parent (plist-get op :parent)))))
       (when existing
         (harness-board--fail 'invalid-parameter "diagram %s is already here" id))
       (when-let* ((parent (plist-get diagram :parent)))
         (harness-board--diagram! board parent))
       (harness-board--add-diagram board diagram)))
    (:diagram.parent
     (let* ((id (harness-board--id (or (plist-get op :id) (plist-get op :diagram))
                                   "diagram id"))
            (diagram (harness-board--diagram! board id))
            (parent (and (plist-get op :parent)
                         (harness-board--id (plist-get op :parent) "diagram parent"))))
       (when (and parent (equal parent id))
         (harness-board--fail 'invalid-parameter "a diagram cannot be its own parent"))
       (when parent (harness-board--diagram! board parent))
       (harness-board--put-diagram board (plist-put (copy-sequence diagram) :parent parent))))
    (:selection
     (let* ((id (harness-board--id (or (plist-get op :diagram) (plist-get op :id)) "diagram id"))
            (diagram (harness-board--diagram! board id))
            (selection (append (plist-get op :selection) nil)))
       (dolist (object selection)
         (unless (and (harness-board--object board object)
                      (harness-board--view (harness-board--object board object) id))
           (harness-board--fail 'invalid-reference "%s has no view in %s" object id)))
       (harness-board--put-diagram
        board (plist-put (copy-sequence diagram) :selection (vconcat selection)))))
    (:viewport
     (let* ((id (harness-board--id (or (plist-get op :diagram) (plist-get op :id)) "diagram id"))
            (diagram (harness-board--diagram! board id))
            (checked (harness-board--normalise-diagram
                      (list :id id :name (plist-get diagram :name)
                            :parent (plist-get diagram :parent)
                            :selection (plist-get diagram :selection)
                            :portals (plist-get diagram :portals)
                            :viewport (plist-get op :viewport)))))
       (harness-board--put-diagram board
                                   (plist-put (copy-sequence diagram) :viewport
                                              (plist-get checked :viewport)))))
    (:portals
     ;; A portal is a drill-down: the object it starts from, and the diagram
     ;; it opens.  The whole list is replaced, so an op can add one, remove
     ;; one or reorder them; each entry is checked here rather than left for
     ;; the document's own reference pass, because the refusal names the
     ;; operation the caller wrote.
     (let* ((id (harness-board--id (or (plist-get op :diagram) (plist-get op :id)) "diagram id"))
            (diagram (harness-board--diagram! board id))
            (checked (harness-board--normalise-diagram
                      (list :id id :name (plist-get diagram :name)
                            :parent (plist-get diagram :parent)
                            :selection (plist-get diagram :selection)
                            :portals (plist-get op :portals)
                            :viewport (plist-get diagram :viewport)))))
       (dolist (portal (append (plist-get checked :portals) nil))
         (let ((from (plist-get portal :from))
               (to (plist-get portal :diagram)))
           (unless (harness-board--object board from)
             (harness-board--fail 'invalid-reference
                                  "a portal starts from %s, which is not an object here" from))
           (harness-board--diagram! board to)
           (when (equal to id)
             (harness-board--fail 'invalid-parameter
                                  "a portal opens another diagram, not %s itself" id))))
       (harness-board--put-diagram
        board (plist-put (copy-sequence diagram) :portals
                         (plist-get checked :portals)))))
    (_ (harness-board--fail 'unsupported-operation "no document field %s" field))))

(defun harness-board--diagram-portal (board op)
  "Return BOARD with one portal of OP's diagram added, or taken away.
OP `:diagram' is the diagram the portal is on, `:from' the object it
starts from and `:to' the diagram it opens; with `:on' false the portal
from that object is removed.  A portal is a place to walk into, not a
relationship: the object keeps its one identity and its one history, and
the diagram it opens is where it is drawn again.  Adding the same portal
twice changes nothing, so a retried edit is harmless."
  (let* ((id (harness-board--id (or (plist-get op :diagram) (plist-get op :id))
                                "diagram id"))
         (diagram (harness-board--diagram! board id))
         (from (harness-board--id (plist-get op :from) "object id"))
         (to (and (plist-get op :to)
                  (harness-board--id (plist-get op :to) "diagram")))
         (on (if (plist-member op :on)
                 (and (harness-board--truthy (plist-get op :on)) t)
               t))
         (portals (append (plist-get diagram :portals) nil)))
    (unless (harness-board--object board from)
      (harness-board--fail 'invalid-reference
                           "a portal starts from %s, which is not an object here" from))
    (when (and on to)
      (harness-board--diagram! board to)
      (when (equal to id)
        (harness-board--fail 'invalid-parameter
                             "a portal opens another diagram, not %s itself" id)))
    (setq portals
          (if on
              (if (cl-find from portals :key (lambda (p) (plist-get p :from)) :test #'equal)
                  (cl-mapcar (lambda (p)
                               (if (equal (plist-get p :from) from)
                                   (list :from from :diagram to)
                                 p))
                             portals)
                (append portals (list (list :from from :diagram to))))
            (cl-remove-if (lambda (p) (equal (plist-get p :from) from)) portals)))
    (harness-board--put-diagram
     board (plist-put (copy-sequence diagram) :portals
                      (plist-get (harness-board--normalise-diagram
                                  (list :id id :name (plist-get diagram :name)
                                        :parent (plist-get diagram :parent)
                                        :selection (plist-get diagram :selection)
                                        :portals (vconcat portals)
                                        :viewport (plist-get diagram :viewport)))
                                 :portals)))))

;;;; Applying one operation

(defconst harness-board--op-table
  '(("create" . harness-board--create)
    ("view.add" . harness-board--view-add)
    ("view.remove" . harness-board--view-remove)
    ("set-shape" . harness-board--set-shape)
    ("set-transform" . harness-board--set-transform)
    ("move" . harness-board--move)
    ("transform" . harness-board--transform)
    ("set-style" . harness-board--set-style)
    ("set-text" . harness-board--set-text)
    ("set-name" . harness-board--set-name)
    ("set-role" . harness-board--set-role)
    ("lock" . harness-board--lock)
    ("group" . harness-board--group)
    ("ungroup" . harness-board--ungroup)
    ("attach" . harness-board--attach)
    ("connect" . harness-board--connect)
    ("relate" . harness-board--relate)
    ("layer" . harness-board--layer)
    ("detach" . harness-board--detach)
    ("delete" . harness-board--delete)
    ("set-theme" . theme)
    ("set-board-name" . board-name)
    ("diagram.add" . diagram-add)
    ("diagram.parent" . diagram-parent)
    ("diagram.portals" . portals)
    ("diagram.portal" . harness-board--diagram-portal)
    ("select" . select)
    ("viewport" . viewport)
    ("restore" . harness-board--restore-op))
  "The operations a patch accepts, and the function that applies each.
A function name is called with (BOARD OP).  `create', `group', `detach',
`connect' and `attach' answer a (:board/:ops/:created) plist; the others
answer the document the operation leaves.  A keyword names one of the
document and view fields in `harness-board--field-ops'.  The first twenty
are the grammar's own (`harness-board-op-kinds'); the rest are what a
client and undo need, so that neither writes a board document directly.")

(defconst harness-board--field-ops
  '((theme . :theme) (board-name . :name) (diagram-add . :diagram.add)
    (diagram-parent . :diagram.parent) (select . :selection)
    (viewport . :viewport) (portals . :portals))
  "The operations that set one field of the document, and which field.
An object's own words and role are set by `harness-board--set-text',
`harness-board--set-name' and `harness-board--set-role', which change the
object rather than the board.")

(defun harness-board--op-name (op)
  "Return the operation name of OP, a plist, as a string."
  (let ((name (or (plist-get op :op) (plist-get op :operation))))
    (or (harness-board--string name)
        (harness-board--fail 'invalid-parameter "an operation needs an op: %S" op))))

(defun harness-board--apply-one (board op)
  "Return (:board NEW :ops EXPANDED :created IDS) applying OP to BOARD.
EXPANDED holds the ordinary operations a convenience operation resolves
to, such as the transform an `attach' places the child with."
  (let* ((name (harness-board--op-name op))
         (entry (cdr (assoc name harness-board--op-table))))
    (unless entry
      (harness-board--fail 'unsupported-operation
                           "operation %s is not one of %s" name
                           (string-join (mapcar #'car harness-board--op-table) ", ")))
    (cond
     ((assq entry harness-board--field-ops)
      (let ((field (cdr (assq entry harness-board--field-ops))))
        (list :board (harness-board--board-field board op field)
              :ops nil :created nil)))
     ((memq entry '(harness-board--create harness-board--group
                                          harness-board--detach harness-board--connect))
      (let ((result (funcall entry board op)))
        (list :board (plist-get result :board)
              :ops nil
              :created (plist-get result :created))))
     ((eq entry 'harness-board--attach)
      (let ((result (harness-board--attach board op)))
        (list :board (plist-get result :board)
              :ops (plist-get result :ops)
              :created nil)))
     (t (list :board (funcall entry board op) :ops nil :created nil)))))

(defun harness-board--restore-op (board op)
  "Return BOARD with OP's preimage put back, for undo."
  (harness-board--restore-entry board (harness-board--id (plist-get op :id) "id")
                                (plist-get op :entry)))

(defun harness-board--snapshot-entry (board id)
  "Return the document entry of BOARD named ID, or nil.
That is an object, a relationship or a diagram."
  (or (harness-board--object board id)
      (harness-board--relationship board id)
      (harness-board--diagram board id)))

;;;; Planning a patch

(defun harness-board--images (board ids)
  "Return (ID ENTRY ...) for each of IDS in BOARD, ENTRY as it is there now.
An id BOARD does not hold is (:absent ID), which is what undo reads to
know that a commit made it."
  (let (out)
    (dolist (id ids)
      (push (intern (concat ":" id)) out)
      (push (or (harness-board--snapshot-entry board id) (list :absent id)) out))
    (nreverse out)))

(defun harness-board--payload (board ops scope)
  "Return the text a patch's hash covers: BOARD's revision, OPS and SCOPE."
  (harness-json-encode-text
   (list :schema harness-board-schema
         :board (plist-get board :id)
         :revision (plist-get board :revision)
         :scope (vconcat scope)
         :ops (vconcat ops))))

(defun harness-board--op-names (op)
  "Return the ids OP names, as the scope check reads them."
  (let (out)
    (dolist (key '(:id :parent :to :member :group))
      (when-let* ((value (plist-get op key)))
        (when (stringp value) (push value out))))
    (dolist (key '(:members :selection))
      (dolist (value (append (plist-get op key) nil))
        (when (stringp value) (push value out))))
    (dolist (key '(:from :to))
      (when-let* ((endpoint (plist-get op key)))
        (when (listp endpoint)
          (when-let* ((object (plist-get endpoint :object)))
            (when (stringp object) (push object out))))))
    out))

(cl-defun harness-board-plan (board ops &key scope)
  "Return the patch applying OPS to BOARD, or signal a board error.
BOARD is a document as `harness-board-normalise' returns it.  OPS is a
list of operation plists.  SCOPE, when given, is the list of object ids
the patch may touch: an operation naming anything else is refused as a
hard constraint before it applies.  Nothing is written; the patch names
the document the operations would leave, and `harness-board-commit-patch'
is what applies it."
  (unless (and (listp ops) ops)
    (harness-board--fail 'invalid-parameter "a patch needs at least one operation"))
  (let ((working board)
        (expanded nil)
        (created nil)
        (touched nil)
        (position 0))
    (dolist (op ops)
      (cl-incf position)
      (unless (listp op)
        (harness-board--fail 'invalid-parameter "operation %d is not an object: %S" position op))
      (when scope
        (dolist (named (harness-board--op-names op))
          (harness-board--check-scope! scope named "object")))
      (let* ((result (harness-board--apply-one working op))
             (extra (plist-get result :ops))
             (new-ids (plist-get result :created)))
        (setq working (plist-get result :board))
        (when extra (setq expanded (append expanded extra)))
        (when new-ids (setq created (append created new-ids)))
        (dolist (named (harness-board--op-names op)) (push named touched))
        (dolist (one extra)
          (when-let* ((id (plist-get one :id))) (push id touched)))))
    (harness-board--check-references working)
    (let* ((base (plist-get board :revision))
           (hash (secure-hash 'sha256 (harness-board--payload board ops (or scope []))))
           (id (format "p-%s" (substring (secure-hash 'sha256
                                                      (format "%s/%s/%s"
                                                              (plist-get board :id) base hash))
                                          0 12)))
           (all (delete-dups (append created touched)))
           (changed (cl-remove-if (lambda (one) (member one created)) all)))
      (list :id id :hash hash
            :boardId (plist-get board :id)
            :revision base
            :board (plist-put (plist-put (copy-sequence working)
                                         :revision (1+ base))
                              :updated (harness-now))
            :requested (vconcat ops)
            :ops (or expanded [])
            :created (vconcat (delete-dups created))
            :changed (vconcat changed)
            :preimages (harness-board--images board all)
            :postimages (harness-board--images working all)
            :diagnostics (or (harness-board-diagnostics board working) [])))))

;;;; Committing

(defvar harness-board--commit-hook nil
  "Functions called with (BOARD PATCH) after a board commit.
The store binds this to write the document and to announce the change.")

(defun harness-board-commit-patch (board patch)
  "Return BOARD with PATCH applied as one new revision.
PATCH is what `harness-board-plan' returned for this board.  The
document's revision becomes the patch's, its history keeps the patch's
preimages and postimages, and `harness-board--commit-hook' hears of it."
  (let* ((next (copy-sequence (plist-get patch :board)))
         (entry (list :revision (plist-get next :revision)
                      :patch (plist-get patch :id)
                      :time (harness-now)
                      :preimages (plist-get patch :preimages)
                      :postimages (plist-get patch :postimages)
                      :created (plist-get patch :created)
                      :changed (plist-get patch :changed)))
         (history (cons entry (append (plist-get board :history) nil)))
         (bounded (cl-subseq history 0 (min (length history) harness-board-history-limit))))
    (cl-incf (plist-get next :revision) 0)
    (setq next (plist-put next :history (vconcat bounded)))
    (run-hook-with-args 'harness-board--commit-hook next patch)
    next))

(defun harness-board-undo-ops (board &optional revision)
  "Return (OPS . CONFLICTS) taking back a commit of BOARD.
The commit is REVISION, or the newest one when it is nil.  An object the
commit created is deleted, one it replaced gets its preimage back, and
one it deleted is restored -- each only while the document still holds
what the commit left there.  An object somebody else changed since is
left alone and reported in CONFLICTS as (:id ID :reason TEXT)."
  (let* ((history (append (plist-get board :history) nil))
         (entry (if revision
                    (cl-find revision history :key (lambda (e) (plist-get e :revision)))
                  (car history))))
    (unless entry
      ;; A board with no commits has nothing to take back, which is a
      ;; precondition; a revision named that is not in the history is an
      ;; id that is not there.
      (if revision
          (harness-board--fail 'unknown-id "no commit at revision %s" revision)
        (harness-board--fail 'precondition "nothing to take back: the board has no commits")))
    (unless (= (plist-get entry :revision) (plist-get board :revision))
      (harness-board--fail 'stale-revision
                           "revision %s is not the newest (%s); undo a commit of the newest"
                           (plist-get entry :revision) (plist-get board :revision)))
    (let ((preimages (plist-get entry :preimages))
          (postimages (plist-get entry :postimages))
          (created (append (plist-get entry :created) nil))
          (ops nil) (conflicts nil))
      (cl-loop for (key before) on preimages by #'cddr
               for id = (substring (symbol-name key) 1)
               for after = (plist-get postimages key)
               for now = (harness-board--snapshot-entry board id)
               do (cond
                   ((not (equal now after))
                    (push (list :id id
                                :reason (if (and (consp after) (plist-get after :absent))
                                            "deleted since the commit"
                                          "changed since the commit"))
                          conflicts))
                   ((member id created)
                    (push (list :op "delete" :id id) ops))
                   ((and (consp before) (plist-get before :absent))
                    nil)
                   ((consp before)
                    (push (list :op "restore" :id id :entry before) ops))))
      (cons (nreverse ops) (nreverse conflicts)))))

(defun harness-board-restore-plan (board ops)
  "Return the patch that restores BOARD's entries by OPS.
The operations are `delete' and `restore', the compensating edit undo
proposes; they are ordinary document operations, validated like any
other, so undo cannot write a document a normal edit could not."
  (let ((working board))
    (dolist (op ops)
      (setq working
            (pcase (plist-get op :op)
              ("delete" (harness-board--delete working op))
              ("restore" (harness-board--restore-op working op))
              (other (harness-board--fail 'unsupported-operation
                                          "an undo op is delete or restore, not %s" other)))))
    (harness-board--check-references working)
    working))

(harness-define-module 'board-edit
  :doc "The board's edit half: the operations a patch may apply, validation against the document as each operation leaves it, the patch a commit names, and the compensating edit undo proposes from the preimages a commit kept."
  :requires '(board))

(provide 'harness-board-edit)
;;; harness-board-edit.el ends here
