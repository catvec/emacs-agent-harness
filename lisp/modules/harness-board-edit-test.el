;;; harness-board-edit-test.el --- Tests for the board's edit half  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The operations, one at a time and as a batch: what each does to the
;; document, what it refuses, and what a patch keeps so a later undo can
;; take it back.  Every refusal names one of the distinct error kinds,
;; and a soft preference (an object moving far, text likely to overflow,
;; an overlap nobody declared) is a warning the batch still commits.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-board)
(require 'harness-board-edit)
(require 'harness-board-store)

(defun harness-board-edit-test--board ()
  "Return a small board: a frame, two components and a note, in one diagram."
  (harness-board-normalise
   (harness-board-blank "b-edit" "edit" nil)))

(defun harness-board-edit-test--with (&rest ops)
  "Return the board after OPS, from a fresh board of its own."
  (let* ((board (harness-board-edit-test--board))
         (plan (harness-board-plan board ops)))
    (plist-get plan :board)))

(defun harness-board-edit-test--object (board id)
  "Return ID's object in BOARD."
  (harness-board--object! board id))

(defun harness-board-edit-test--refusal (thunk)
  "Return the kind of the board error THUNK raises, or nil."
  (condition-case err
      (progn (funcall thunk) nil)
    (harness-board-error (harness-board-error-kind err))))

(defconst harness-board-edit-test--box
  '(:op "create" :id "n-box" :kind "component" :name "box" :text "does a thing"
    :diagram "d-overview" :x 10 :y 20
    :shape (:kind "rect" :w 120 :h 60)
    :style (:fill "card" :stroke "edge" :cap "accent")
    :anchors (:left [0 30] :right [120 30]))
  "A component, so most operations have something ordinary to work on.")

(defconst harness-board-edit-test--note
  '(:op "create" :id "n-note" :kind "note" :text "an open question"
    :diagram "d-overview" :x 300 :y 20
    :shape (:kind "rect" :w 160 :h 80)
    :style (:fill "note"))
  "A note beside it.")

;;;; Creating

(ert-deftest harness-board-edit-creates-an-object-with-its-first-view ()
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (object (harness-board-edit-test--object board "n-box")))
    (should (eq 'component (plist-get object :kind)))
    (should (equal "box" (plist-get object :name)))
    (should (equal "does a thing" (plist-get object :text)))
    (should (eq 'declared (plist-get object :role)))
    (should (equal '("d-overview")
                   (mapcar #'car (harness-board--object-views object))))
    ;; The placement is its own transform, so a later move is a matrix.
    (should (equal [1 0 0 1 10 20]
                   (plist-get (harness-board--view object "d-overview") :transform)))))

(ert-deftest harness-board-edit-refuses-an-id-that-is-already-here ()
  (should (eq 'invalid-parameter
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with harness-board-edit-test--box
                                                harness-board-edit-test--box))))))

(ert-deftest harness-board-edit-a-create-names-a-kind-the-grammar-has ()
  (should (eq 'unsupported-operation
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     (list :op "create" :kind "kanban-card" :diagram "d-overview"
                           :shape (list :kind "rect" :w 10 :h 10))))))))

(ert-deftest harness-board-edit-a-create-may-name-no-id-and-gets-one ()
  (let* ((board (harness-board-edit-test--with
                    (list :op "create" :kind "note" :diagram "d-overview"
                          :shape (list :kind "rect" :w 10 :h 10))))
         (id (plist-get (car (plist-get board :objects)) :id)))
    (should (string-prefix-p "n-" id))))

;;;; One object, many views

(ert-deftest harness-board-edit-view-add-puts-the-same-object-in-another-diagram ()
  "The object keeps one identity and one history; only its representation is new."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "view.add" :id "n-box" :diagram "d-detail"
                          :transform [1 0 0 1 400 0])))
         (object (harness-board-edit-test--object board "n-box")))
    (should (= 1 (length (plist-get board :objects))))
    (should (equal '("d-overview" "d-detail")
                   (mapcar #'car (harness-board--object-views object))))
    (should (equal [1 0 0 1 400 0]
                   (plist-get (harness-board--view object "d-detail") :transform)))))

(ert-deftest harness-board-edit-view-remove-keeps-the-object ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "view.add" :id "n-box" :diagram "d-detail")
                    (list :op "view.remove" :id "n-box" :diagram "d-detail")))
         (object (harness-board-edit-test--object board "n-box")))
    ;; The representation goes; the meaning stays.
    (should (equal '("d-overview")
                   (mapcar #'car (harness-board--object-views object))))))

(ert-deftest harness-board-edit-view-remove-refuses-the-last-view ()
  "An object with no view would be a meaning with no place: delete it instead."
  (should (eq 'precondition
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "view.remove" :id "n-box" :diagram "d-overview")))))))

(ert-deftest harness-board-edit-two-views-move-apart-without-touching-each-other ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "view.add" :id "n-box" :diagram "d-detail"
                          :transform [1 0 0 1 400 400])))
         (object (harness-board-edit-test--object board "n-box")))
    (should (= 2 (length (harness-board--object-views object))))
    (should (equal [1 0 0 1 10 20]
                   (plist-get (harness-board--view object "d-overview") :transform)))
    (should (equal [1 0 0 1 400 400]
                   (plist-get (harness-board--view object "d-detail") :transform)))))

;;;; Moving, turning, styling

(ert-deftest harness-board-edit-a-portal-opens-another-diagram-from-an-object ()
  "A drill-down is authored through the same public operations as everything else."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "diagram.portals" :diagram "d-overview"
                          :portals (vector (list :from "n-box" :diagram "d-detail")))))
         (diagram (harness-board--diagram! board "d-overview")))
    (should (equal '((:from "n-box" :diagram "d-detail"))
                   (mapcar (lambda (portal) (list :from (plist-get portal :from)
                                                  :diagram (plist-get portal :diagram)))
                           (append (plist-get diagram :portals) nil))))))

(ert-deftest harness-board-edit-a-portal-names-an-object-that-is-here ()
  (should (eq 'invalid-reference
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.add" :id "d-detail" :name "detail")
                     (list :op "diagram.portals" :diagram "d-overview"
                           :portals (vector (list :from "n-nowhere" :diagram "d-detail")))))))))

(ert-deftest harness-board-edit-a-portal-opens-a-diagram-that-is-here ()
  (should (eq 'unknown-id
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.portals" :diagram "d-overview"
                           :portals (vector (list :from "n-box" :diagram "d-nowhere")))))))))

(ert-deftest harness-board-edit-a-portal-does-not-open-its-own-diagram ()
  "A portal that opens the diagram it is on is not a drill-down."
  (should (eq 'invalid-parameter
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.portals" :diagram "d-overview"
                           :portals (vector (list :from "n-box" :diagram "d-overview")))))))))

(ert-deftest harness-board-edit-a-portal-list-is-replaced-whole ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "diagram.portals" :diagram "d-overview"
                          :portals (vector (list :from "n-box" :diagram "d-detail")))
                    (list :op "diagram.portals" :diagram "d-overview" :portals [])))
         (diagram (harness-board--diagram! board "d-overview")))
    (should (equal [] (plist-get diagram :portals)))))

(ert-deftest harness-board-edit-a-portal-op-adds-one-and-removes-it ()
  "One drill-down is authored as one operation, and taken away as one."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "diagram.portal" :diagram "d-overview"
                          :from "n-box" :to "d-detail")))
         (diagram (harness-board--diagram! board "d-overview")))
    (should (equal '((:from "n-box" :diagram "d-detail"))
                   (mapcar (lambda (portal)
                             (list :from (plist-get portal :from)
                                   :diagram (plist-get portal :diagram)))
                           (append (plist-get diagram :portals) nil))))
    ;; Adding it twice changes nothing, so a retried edit is harmless.
    (let* ((again (harness-board-plan
                   board (list (list :op "diagram.portal" :diagram "d-overview"
                                     :from "n-box" :to "d-detail"))))
           (removed (harness-board-plan
                     (plist-get again :board)
                     (list (list :op "diagram.portal" :diagram "d-overview"
                                 :from "n-box" :on :false)))))
      (should (= 1 (length (append (plist-get (harness-board--diagram!
                                               (plist-get again :board) "d-overview")
                                           :portals)
                                   nil))))
      (should (equal [] (plist-get (harness-board--diagram!
                                    (plist-get removed :board) "d-overview")
                                   :portals))))))

(ert-deftest harness-board-edit-a-portal-op-refuses-a-place-that-is-not-here ()
  (should (eq 'invalid-reference
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.add" :id "d-detail" :name "detail")
                     (list :op "diagram.portal" :diagram "d-overview"
                           :from "n-nowhere" :to "d-detail"))))))
  (should (eq 'unknown-id
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.portal" :diagram "d-overview"
                           :from "n-box" :to "d-nowhere"))))))
  (should (eq 'invalid-parameter
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "diagram.portal" :diagram "d-overview"
                           :from "n-box" :to "d-overview")))))))

(ert-deftest harness-board-edit-deleting-the-object-a-portal-starts-from-removes-the-portal ()
  "A portal from an object that is gone would name nothing."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    harness-board-edit-test--note
                    (list :op "diagram.add" :id "d-detail" :name "detail")
                    (list :op "diagram.portals" :diagram "d-overview"
                          :portals (vector (list :from "n-box" :diagram "d-detail")))
                    (list :op "delete" :id "n-box")))
         (diagram (harness-board--diagram! board "d-overview")))
    (should (equal [] (plist-get diagram :portals)))))


(ert-deftest harness-board-edit-move-translates-the-view ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "move" :id "n-box" :diagram "d-overview" :dx 30 :dy -5)))
         (view (harness-board--view (harness-board-edit-test--object board "n-box") "d-overview")))
    (should (equal [1 0 0 1 40 15] (plist-get view :transform)))))

(ert-deftest harness-board-edit-move-refuses-to-go-past-its-budget ()
  "A hard constraint, named as one: the whole batch is refused."
  (should (eq 'hard-constraint
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "move" :id "n-box" :diagram "d-overview"
                           :dx 0 :dy 40 :budget 10))))))
  ;; And a budget of its own lets it.
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "move" :id "n-box" :diagram "d-overview"
                          :dx 0 :dy 40 :budget 100))))
    (should (harness-board-edit-test--object board "n-box"))))

(ert-deftest harness-board-edit-a-locked-object-is-a-hard-constraint ()
  (let ((board (harness-board-edit-test--with
                   harness-board-edit-test--box
                   (list :op "lock" :id "n-box" :on t))))
    (should (plist-get (harness-board-edit-test--object board "n-box") :locked))
    ;; And unlocking is allowed, so the lock is not a trap.
    (should-not (plist-get (harness-board-edit-test--object
                            (harness-board-edit-test--with
                                harness-board-edit-test--box
                                (list :op "lock" :id "n-box" :on t)
                                (list :op "lock" :id "n-box" :on :false))
                            "n-box")
                           :locked))))

(ert-deftest harness-board-edit-a-locked-object-refuses-a-move ()
  (should (eq 'hard-constraint
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "lock" :id "n-box" :on t)
                     (list :op "move" :id "n-box" :diagram "d-overview" :dx 1 :dy 1)))))))

(ert-deftest harness-board-edit-transform-rotates-about-an-explicit-pivot ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "transform" :id "n-box" :diagram "d-overview"
                          :kind "rotate" :angle 90 :pivot [10 20])))
         (view (harness-board--view (harness-board-edit-test--object board "n-box") "d-overview"))
         (matrix (plist-get view :transform)))
    ;; About the object's own origin, so the shape turns where it stands.
    (should (< (abs (- (aref matrix 0) 0)) 1e-9))
    (should (< (abs (- (aref matrix 1) 1)) 1e-9))))

(ert-deftest harness-board-edit-transform-refuses-a-zero-scale ()
  (dolist (op (list (list :op "transform" :id "n-box" :diagram "d-overview"
                          :kind "scale" :sx 0 :sy 1 :pivot [0 0])
                    (list :op "transform" :id "n-box" :diagram "d-overview"
                          :kind "scale" :sx -1 :sy 1 :pivot [0 0])
                    (list :op "transform" :id "n-box" :diagram "d-overview"
                          :kind "affine" :matrix [0 0 0 1 0 0] :pivot [0 0])))
    (ert-info ((format "%S" (plist-get op :kind)))
      (should (eq 'invalid-parameter
                  (harness-board-edit-test--refusal
                   (lambda () (harness-board-edit-test--with harness-board-edit-test--box op))))))))

(ert-deftest harness-board-edit-transform-refuses-a-kind-it-does-not-have ()
  (should (eq 'unsupported-operation
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "transform" :id "n-box" :diagram "d-overview"
                           :kind "shear" :pivot [0 0])))))))

(ert-deftest harness-board-edit-a-reflection-never-mirrors-a-label ()
  "The design's rule, held to the letter: a label turns only if the op says so in words."
  (dolist (kind '("label" "component" "note" "marker" "frame"))
    (ert-info (kind)
      (should (eq 'precondition
                  (harness-board-edit-test--refusal
                   (lambda ()
                     (harness-board-edit-test--with
                         (list :op "create" :id "n-words" :kind kind :name "words"
                               :text "words" :diagram "d-overview" :x 0 :y 0
                               :shape (list :kind "rect" :w 40 :h 20))
                         (list :op "set-transform" :id "n-words" :diagram "d-overview"
                               :transform [-1 0 0 1 400 0]))))))))
  ;; An explicit request is a different intent, and goes through.
  (let* ((board (harness-board-edit-test--with
                    (list :op "create" :id "n-words" :kind "label" :text "words"
                          :diagram "d-overview" :x 0 :y 0
                          :shape (list :kind "text" :text "words" :size 16))
                    (list :op "set-transform" :id "n-words" :diagram "d-overview"
                          :transform [-1 0 0 1 400 0] :text t))))
    (should (harness-board-edit-test--object board "n-words")))
  ;; Raw geometry has no label to mirror, so a reflection of it is ordinary.
  (let ((board (harness-board-edit-test--with
                   (list :op "create" :id "n-shape" :kind "shape" :diagram "d-overview" :x 0 :y 0
                         :shape (list :kind "polygon" :points '([0 0] [40 0] [20 30])))
                   (list :op "transform" :id "n-shape" :diagram "d-overview"
                         :kind "reflect" :axis "y" :pivot [20 0]))))
    (should (harness-board-matrix-reflects-p
             (plist-get (harness-board--view (harness-board-edit-test--object board "n-shape")
                                             "d-overview")
                        :transform)))))

(ert-deftest harness-board-edit-a-move-is-not-a-reflection ()
  "Moving an object never mirrors it, whatever it holds."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "move" :id "n-box" :diagram "d-overview" :dx -200 :dy 0)))
         (matrix (plist-get (harness-board--view (harness-board-edit-test--object board "n-box")
                                                 "d-overview")
                            :transform)))
    (should-not (harness-board-matrix-reflects-p matrix))))

(ert-deftest harness-board-edit-set-style-merges-one-key ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "set-style" :id "n-box" :diagram "d-overview"
                          :style (list :fill "accent-soft"))))
         (style (plist-get (harness-board--view (harness-board-edit-test--object board "n-box")
                                                "d-overview")
                           :style)))
    (should (equal "accent-soft" (plist-get style :fill)))
    ;; The keys it did not name are still there.
    (should (equal "edge" (plist-get style :stroke)))
    (should (equal "accent" (plist-get style :cap)))))

(ert-deftest harness-board-edit-set-style-refuses-a-key-the-grammar-lacks ()
  (should (eq 'invalid-parameter
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "set-style" :id "n-box" :diagram "d-overview"
                           :style (list :dropShadow "5"))))))))

(ert-deftest harness-board-edit-set-text-and-name-change-the-words ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--note
                    (list :op "set-text" :id "n-note" :text "still open?")
                    (list :op "set-name" :id "n-note" :name "open question")))
         (object (harness-board-edit-test--object board "n-note")))
    (should (equal "still open?" (plist-get object :text)))
    (should (equal "open question" (plist-get object :name)))))

(ert-deftest harness-board-edit-a-role-says-what-the-drawing-claims ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "set-role" :id "n-box" :role "observed")))
         (object (harness-board-edit-test--object board "n-box")))
    (should (equal 'observed (plist-get object :role)))
    (should (eq 'invalid-parameter
                (harness-board-edit-test--refusal
                 (lambda ()
                   (harness-board-edit-test--with
                       harness-board-edit-test--box
                       (list :op "set-role" :id "n-box" :role "certain"))))))))

;;;; Grouping, layering, deleting

(ert-deftest harness-board-edit-a-group-holds-members-and-keeps-their-ids ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    harness-board-edit-test--note
                    (list :op "group" :id "g-1" :members ["n-box" "n-note"]
                          :diagram "d-overview" :name "the pair")))
         (group (harness-board-edit-test--object board "g-1")))
    (should (eq 'group (plist-get group :kind)))
    (should (equal "the pair" (plist-get group :name)))
    (dolist (id '("n-box" "n-note"))
      (should (equal "g-1" (plist-get (harness-board-edit-test--object board id) :group))))
    ;; Ungrouping dissolves it; the members keep their own identity.
    (let ((after (harness-board-edit-test--with
                     harness-board-edit-test--box
                     harness-board-edit-test--note
                     (list :op "group" :id "g-1" :members ["n-box" "n-note"]
                           :diagram "d-overview")
                     (list :op "ungroup" :id "g-1"))))
      (should-not (harness-board--object after "g-1"))
      (should-not (plist-get (harness-board-edit-test--object after "n-box") :group))
      (should (harness-board--object after "n-box")))))

(ert-deftest harness-board-edit-a-group-needs-two-members ()
  (should (eq 'invalid-parameter
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "group" :id "g-1" :members ["n-box"] :diagram "d-overview")))))))

(ert-deftest harness-board-edit-a-layer-is-a-number-the-renderer-sorts-by ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "layer" :id "n-box" :diagram "d-overview" :z 9)))
         (view (harness-board--view (harness-board-edit-test--object board "n-box") "d-overview")))
    (should (= 9 (plist-get view :z)))))

(ert-deftest harness-board-edit-delete-takes-the-object-its-views-and-its-lines ()
  "A relationship to a deleted object cannot outlive it."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    harness-board-edit-test--note
                    (list :op "connect" :id "e-1" :diagram "d-overview"
                          :from (list :object "n-box" :anchor "right")
                          :to (list :object "n-note" :anchor "left"))
                    (list :op "delete" :id "n-note"))))
    (should-not (harness-board--object board "n-note"))
    (should-not (harness-board--relationship board "e-1"))))

(ert-deftest harness-board-edit-connect-makes-a-relationship-between-placed-anchors ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    harness-board-edit-test--note
                    (list :op "connect" :id "e-1" :diagram "d-overview" :label "asks"
                          :from (list :object "n-box" :anchor "right")
                          :to (list :object "n-note" :anchor "left"))))
         (relationship (harness-board--relationship! board "e-1")))
    (should (equal "e-1" (plist-get relationship :id)))
    (should (equal "asks" (plist-get relationship :label)))
    (should (eq 'flow (plist-get relationship :kind)))))

(ert-deftest harness-board-edit-connect-refuses-an-endpoint-that-names-nothing ()
  "A line to nothing is a lie about the drawing, so it is refused."
  (should (eq 'unknown-id
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     (list :op "connect" :id "e-1" :diagram "d-overview"
                           :from (list :object "n-box" :anchor "right")
                           :to (list :object "n-nowhere" :anchor "left")))))))
  (should (eq 'invalid-reference
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     harness-board-edit-test--box
                     harness-board-edit-test--note
                     (list :op "connect" :id "e-1" :diagram "d-overview"
                           :from (list :object "n-box" :anchor "sideways")
                           :to (list :object "n-note" :anchor "left"))))))))

;;;; Attachment: the leaf study, through the ordinary operations

(ert-deftest harness-board-edit-attach-puts-a-childs-base-on-its-parents-tip ()
  "The design's construction, made of ordinary operations only."
  (let* ((geometry (list (list "M" 0 0) (list "L" 20 -25) (list "L" 55 -31)
                         (list "L" 100 0) (list "L" 55 12) (list "L" 18 8) (list "Z")))
         (board (harness-board-edit-test--with
                    (list :op "create" :id "leaf-parent" :kind "path" :name "parent"
                          :diagram "d-overview" :x 60 :y 220
                          :shape (list :kind "path" :segments geometry)
                          :anchors '(:base [0 0] :tip [100 0]))
                    (list :op "create" :id "leaf-child" :kind "path" :name "child"
                          :diagram "d-overview" :x 0 :y 0
                          :shape (list :kind "path" :segments geometry)
                          :anchors '(:base [0 0] :tip [100 0]))
                    (list :op "attach" :id "leaf-child" :parent "leaf-parent"
                          :diagram "d-overview"
                          :childAnchor "base" :parentAnchor "tip"
                          :angle 30 :scale 1.5)))
         (child (harness-board--view (harness-board-edit-test--object board "leaf-child")
                                     "d-overview"))
         (parent (harness-board--view (harness-board-edit-test--object board "leaf-parent")
                                      "d-overview"))
         (base (harness-board-anchor-point child "base"))
         (tip (harness-board-anchor-point parent "tip")))
    (should (< (abs (- (car base) (car tip))) 1e-9))
    (should (< (abs (- (cdr base) (cdr tip))) 1e-9))
    ;; The child's own shape is unchanged: only its placement is new.
    (should (equal geometry (plist-get (plist-get child :shape) :segments)))))

(ert-deftest harness-board-edit-attach-can-mirror-a-shape-but-not-its-words ()
  (let* ((geometry (list (list "M" 0 0) (list "L" 100 0) (list "L" 100 20)))
         (board (harness-board-edit-test--with
                    (list :op "create" :id "p" :kind "path" :diagram "d-overview" :x 0 :y 0
                          :shape (list :kind "path" :segments geometry)
                          :anchors '(:base [0 0] :tip [100 0]))
                    (list :op "create" :id "c" :kind "path" :diagram "d-overview" :x 0 :y 0
                          :shape (list :kind "path" :segments geometry)
                          :anchors '(:base [0 0] :tip [100 0]))
                    (list :op "attach" :id "c" :parent "p" :diagram "d-overview"
                          :childAnchor "base" :parentAnchor "tip" :mirror t))))
    (should (harness-board-matrix-reflects-p
             (plist-get (harness-board--view (harness-board-edit-test--object board "c")
                                             "d-overview")
                        :transform))))
  ;; A note attached mirrored is refused, because its words would mirror.
  (should (eq 'precondition
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     (list :op "create" :id "p" :kind "path" :diagram "d-overview" :x 0 :y 0
                           :shape (list :kind "path" :segments '(("M" 0 0) ("L" 100 0)))
                           :anchors '(:tip [100 0]))
                     (list :op "create" :id "c" :kind "note" :text "words"
                           :diagram "d-overview" :x 0 :y 0
                           :shape (list :kind "rect" :w 40 :h 20))
                     (list :op "attach" :id "c" :parent "p" :diagram "d-overview"
                           :childAnchor "left" :parentAnchor "tip" :mirror t)))))))

(ert-deftest harness-board-edit-detach-makes-an-instance-independent ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "detach" :id "n-box" :diagram "d-overview" :newId "n-copy")))
         (original (harness-board-edit-test--object board "n-box"))
         (copy (harness-board-edit-test--object board "n-copy")))
    (should (and original copy))
    (should-not (equal (plist-get original :id) (plist-get copy :id)))
    (should (equal (plist-get original :name) (plist-get copy :name)))))

;;;; Resources and evidence

(ert-deftest harness-board-edit-resources-are-typed-links ()
  (let* ((board (harness-board-edit-test--with
                    (list :op "create" :id "n-box" :kind "component" :diagram "d-overview"
                          :x 0 :y 0 :shape (list :kind "rect" :w 40 :h 20)
                          :resources (list (list :kind "task" :ref "t-1" :label "task")
                                           (list :kind "message" :ref "s-1/n-2")))))
         (resources (plist-get (harness-board-edit-test--object board "n-box") :resources)))
    (should (= 2 (length resources)))
    (should (equal '(task message) (mapcar (lambda (r) (plist-get r :kind)) resources)))
    (should (eq 'invalid-reference
                (harness-board-edit-test--refusal
                 (lambda ()
                   (harness-board-edit-test--with
                       (list :op "create" :id "n-box" :kind "component" :diagram "d-overview"
                             :x 0 :y 0 :shape (list :kind "rect" :w 40 :h 20)
                             :resources (list (list :kind "wish" :ref "w-1"))))))))))

(ert-deftest harness-board-edit-a-resource-needs-a-ref ()
  (should (eq 'invalid-reference
              (harness-board-edit-test--refusal
               (lambda ()
                 (harness-board-edit-test--with
                     (list :op "create" :id "n-box" :kind "component" :diagram "d-overview"
                           :x 0 :y 0 :shape (list :kind "rect" :w 40 :h 20)
                           :resources (list (list :kind "task" :ref "")))))))))

(ert-deftest harness-board-edit-relate-replaces-the-links ()
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "relate" :id "n-box"
                          :resources (list (list :kind "task" :ref "t-2")))))
         (resources (plist-get (harness-board-edit-test--object board "n-box") :resources)))
    (should (= 1 (length resources)))
    (should (equal "t-2" (plist-get (car resources) :ref)))))

;;;; Scope: an agent is held to the selection it was given

(ert-deftest harness-board-edit-a-scope-refuses-an-object-outside-it ()
  "The whole batch is refused before anything is written."
  (let ((board (harness-board-edit-test--with
                   harness-board-edit-test--box
                   harness-board-edit-test--note)))
    (should (eq 'hard-constraint
                (harness-board-edit-test--refusal
                 (lambda ()
                   (harness-board-plan board
                                       (list (list :op "move" :id "n-box" :diagram "d-overview"
                                                   :dx 5 :dy 0)
                                             (list :op "move" :id "n-note" :diagram "d-overview"
                                                   :dx 5 :dy 0))
                                       :scope '("n-box"))))))
    ;; The objects inside it are fine.
    (should (harness-board-plan board
                                (list (list :op "move" :id "n-box" :diagram "d-overview"
                                            :dx 5 :dy 0))
                                :scope '("n-box")))))

;;;; Patches

(ert-deftest harness-board-edit-a-patch-names-its-read-set-and-its-operations ()
  (let* ((board (harness-board-edit-test--board))
         (plan (harness-board-plan board (list harness-board-edit-test--box))))
    (should (string-prefix-p "p-" (plist-get plan :id)))
    (should (= (length (plist-get plan :hash)) 64))
    (should (= 0 (plist-get plan :revision)))
    (should (= 1 (plist-get (plist-get plan :board) :revision)))
    (should (equal '("n-box") (append (plist-get plan :created) nil)))
    ;; A created object is not also reported as changed.
    (should-not (member "n-box" (append (plist-get plan :changed) nil))))

(ert-deftest harness-board-edit-a-patch-does-not-change-the-document-it-came-from ()
  "`scene.edit' is a proposal: the board it read is as it was."
  (let* ((board (harness-board-edit-test--board))
         (plan (harness-board-plan board (list harness-board-edit-test--box))))
    (should-not (harness-board--object board "n-box"))
    (should (harness-board--object (plist-get plan :board) "n-box"))
    (should (= 0 (plist-get board :revision)))))

(ert-deftest harness-board-edit-the-same-operations-make-the-same-patch ()
  "A hash covers the board, its revision, the scope and the operations."
  (let* ((board (harness-board-edit-test--board))
         (ops (list harness-board-edit-test--box))
         (one (harness-board-plan board ops))
         (two (harness-board-plan board ops)))
    (should (equal (plist-get one :id) (plist-get two :id)))
    (should (equal (plist-get one :hash) (plist-get two :hash)))
    ;; Another operation is another hash.
    (should-not (equal (plist-get one :hash)
                       (plist-get (harness-board-plan
                                   board (list (list :op "create" :id "n-other"
                                                     :kind "note" :diagram "d-overview"
                                                     :x 0 :y 0
                                                     :shape (list :kind "rect" :w 1 :h 1))))
                                  :hash)))))

(ert-deftest harness-board-edit-a-commit-keeps-the-preimages-and-postimages ()
  "Undo reads them: it says what was there and what the commit left."
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (plan (harness-board-plan board
                                   (list (list :op "move" :id "n-box" :diagram "d-overview"
                                               :dx 9 :dy 0))))
         (committed (harness-board-commit-patch board plan))
         (entry (car (append (plist-get committed :history) nil))))
    (should (= (1+ (plist-get board :revision)) (plist-get committed :revision)))
    (should (= (plist-get committed :revision) (plist-get entry :revision)))
    (should (equal "p-" (substring (plist-get entry :patch) 0 2)))
    (should (plist-get (plist-get entry :preimages) :n-box))
    (should (plist-get (plist-get entry :postimages) :n-box))))

(ert-deftest harness-board-edit-history-is-bounded ()
  "The newest `harness-board-history-limit' commits are kept; the oldest fall away."
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (limit harness-board-history-limit))
    (let ((harness-board-history-limit 3))
      (dotimes (i 5)
        (setq board (harness-board-commit-patch
                     board
                     (harness-board-plan
                      board
                      (list (list :op "move" :id "n-box" :diagram "d-overview"
                                  :dx 1 :dy 0))))))
      (should (= 3 (length (append (plist-get board :history) nil)))))
    (ignore limit)))

;;;; Diagnostics: soft preferences never refuse

(ert-deftest harness-board-edit-overflow-is-a-warning-not-a-refusal ()
  "A note whose words need more room than its box has is reported and still commits."
  (let* ((board (harness-board-edit-test--board))
         (plan (harness-board-plan
                board
                (list (list :op "create" :id "n-tight" :kind "note" :diagram "d-overview"
                            :x 0 :y 0
                            :text "a long sentence that a small box cannot possibly hold in one piece"
                            :shape (list :kind "rect" :w 60 :h 20)
                            :style (list :fontSize 18)))))
         (diagnostics (append (plist-get plan :diagnostics) nil)))
    (should (cl-find 'overflow diagnostics
                     :key (lambda (d) (plist-get d :kind))
                     :test (lambda (a b) (equal (format "%s" a) (format "%s" b)))))
    (should (cl-every (lambda (d) (equal "warning" (plist-get d :level))) diagnostics))))

(ert-deftest harness-board-edit-an-intentional-overlap-is-allowed ()
  "Two objects on top of each other are the person's arrangement, not an error."
  (let* ((board (harness-board-edit-test--with
                    harness-board-edit-test--box
                    (list :op "create" :id "n-on-top" :kind "note" :diagram "d-overview"
                          :x 20 :y 30 :shape (list :kind "rect" :w 120 :h 60))))
         (diagnostics (append (harness-board-plan
                               board
                               (list (list :op "move" :id "n-on-top" :diagram "d-overview"
                                           :dx 0 :dy 0)))
                              :diagnostics)))
    ;; Whatever is reported, it is a warning: the arrangement stands.
    (should (cl-every (lambda (d) (equal "warning" (plist-get d :level))) diagnostics))))

(ert-deftest harness-board-edit-an-object-that-moves-far-is-reported ()
  "A movement is a preference, and the report says how far, in units."
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (plan (harness-board-plan board
                                   (list (list :op "move" :id "n-box" :diagram "d-overview"
                                               :dx 0 :dy 900))))
         (diagnostics (append (plist-get plan :diagnostics) nil)))
    (should (cl-find-if (lambda (d) (equal "movement" (plist-get d :kind))) diagnostics))
    (should (cl-every (lambda (d) (equal "warning" (plist-get d :level))) diagnostics))))

;;;; Undo

(ert-deftest harness-board-edit-undo-takes-back-the-newest-commit ()
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (before (plist-get (harness-board--view (harness-board-edit-test--object board "n-box")
                                                 "d-overview")
                            :transform))
         (committed (harness-board-commit-patch
                     board
                     (harness-board-plan
                      board
                      (list (list :op "move" :id "n-box" :diagram "d-overview"
                                  :dx 100 :dy 0)))))
         (result (harness-board-undo-ops committed))
         (restored (harness-board-restore-plan committed (car result))))
    (should (equal '("n-box") (mapcar (lambda (op) (plist-get op :id)) (car result))))
    (should-not (cdr result))
    (should (equal before
                   (plist-get (harness-board--view
                               (harness-board-edit-test--object restored "n-box")
                               "d-overview")
                              :transform)))))

(ert-deftest harness-board-edit-undo-deletes-what-the-commit-created ()
  (let* ((board (harness-board-edit-test--board))
         (committed (harness-board-commit-patch
                     board (harness-board-plan board (list harness-board-edit-test--box))))
         (result (harness-board-undo-ops committed)))
    (should (equal '("delete") (mapcar (lambda (op) (plist-get op :op)) (car result))))
    (should (equal '("n-box") (mapcar (lambda (op) (plist-get op :id)) (car result))))))

(ert-deftest harness-board-edit-undo-keeps-anothers-work-and-reports-it ()
  "An object somebody else changed since the commit is left alone, as a conflict."
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (committed (harness-board-commit-patch
                     board
                     (harness-board-plan
                      board
                      (list (list :op "move" :id "n-box" :diagram "d-overview"
                                  :dx 100 :dy 0)))))
         ;; Somebody else moves it again.
         (theirs (harness-board-commit-patch
                  committed
                  (harness-board-plan
                   committed
                   (list (list :op "move" :id "n-box" :diagram "d-overview"
                               :dx 0 :dy 40)))))
         (result (harness-board-undo-ops theirs)))
    ;; Undo takes back the newest commit, which is theirs, and leaves it.
    (should (equal 2 (plist-get (car (append (plist-get theirs :history) nil)) :revision)))
    (should (harness-board-undo-ops theirs))
    ;; And when the object moved since the commit whose preimage undo
    ;; wants, undo says so rather than restoring over their work.
    (let* ((mine (harness-board-commit-patch
                  board
                  (harness-board-plan
                   board
                   (list (list :op "move" :id "n-box" :diagram "d-overview" :dx 5 :dy 0)))))
           (newer (harness-board-commit-patch
                   mine
                   (harness-board-plan
                    mine
                    (list (list :op "move" :id "n-box" :diagram "d-overview" :dx 0 :dy 5))))))
      ;; Take back the newer one first, then the older against what is left:
      ;; the older commit's postimage no longer matches, so it is a conflict.
      (let* ((back (harness-board-restore-plan
                    newer (car (harness-board-undo-ops newer))))
             (result (harness-board-undo-ops (harness-board-commit-patch
                                              newer
                                              (harness-board-plan
                                               newer
                                               (list (list :op "move" :id "n-box"
                                                           :diagram "d-overview"
                                                           :dx 0 :dy -5)))))))
        (should back)
        (should result))))))

(ert-deftest harness-board-edit-undo-refuses-a-revision-that-is-not-the-newest ()
  (let* ((board (harness-board-edit-test--with harness-board-edit-test--box))
         (one (harness-board-commit-patch
               board
               (harness-board-plan
                board (list (list :op "move" :id "n-box" :diagram "d-overview" :dx 1 :dy 0)))))
         (two (harness-board-commit-patch
               one
               (harness-board-plan
                one (list (list :op "move" :id "n-box" :diagram "d-overview" :dx 1 :dy 0))))))
    (should (eq 'stale-revision
                (harness-board-edit-test--refusal
                 (lambda () (harness-board-undo-ops
                             two (plist-get (nth 1 (append (plist-get two :history) nil))
                                            :revision))))))))

(ert-deftest harness-board-edit-undo-names-a-commit-that-is-not-there ()
  (let ((board (harness-board-edit-test--with harness-board-edit-test--box)))
    (should (eq 'unknown-id
                (harness-board-edit-test--refusal
                 (lambda () (harness-board-undo-ops board 99)))))))

(provide 'harness-board-edit-test)
;;; harness-board-edit-test.el ends here
