;;; harness-board-fixture.el --- A realistic freeform board, and the leaf study  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Two fixtures the board's suites and its live demo share.  Neither is a
;; product feature: `harness-board-fixture-board' is the drawing a person
;; arranged by hand -- notes, framed regions, a store drawn as a path, a
;; connector with a label, a named image, a task marker, an intentional
;; overlap and an unknown left visible -- and `harness-board-fixture-leaf'
;; is the explicit leaf construction the grammar's design documents.
;;
;; Both are built only through the ordinary operations a client and an
;; agent use (`harness-board-plan' / `harness-board-plan' with `attach'),
;; so the fixtures prove that the board's own public grammar can make them.
;; Nothing here is a renderer-only primitive, and nothing searches.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-board)
(require 'harness-board-edit)

(defconst harness-board-fixture-image
  "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 240 150'><rect width='240' height='150' fill='%23eceee7'/><rect x='14' y='14' width='212' height='92' fill='none' stroke='%2355545f'/><rect x='14' y='14' width='212' height='14' fill='%23c5ff54'/><text x='24' y='62' font-family='Helvetica' font-size='15' fill='%2325272c'>kinopio · spatial notes</text><text x='24' y='86' font-family='Helvetica' font-size='12' fill='%234d5058'>square corners, bright accents</text></svg>"
  "A picture a board can reference without a file on disk.
The board's image objects name a file; a fixture has no file, so this is
drawn from an inline SVG, which every renderer of the board reads as a
picture.")

(defun harness-board-fixture--ops (diagram)
  "Return the hand-arranged drawing of the fixture, on DIAGRAM."
  (append
   (list
    ;; Framed regions first, so they sit under what they hold.  The tab is
    ;; the frame's own corner, and the name is its tab's words.
    (list :op "create" :id "f-system" :kind "frame" :diagram diagram
          :name "the system" :role "declared" :x 34 :y 155 :z 0
          :shape (list :kind "rect" :w 618 :h 380)
          :style (list :fill "frame" :stroke "edge" :cap "accent" :fontSize 19))
    (list :op "create" :id "f-unknowns" :kind "frame" :diagram diagram
          :name "unknowns" :role "unknown" :x 700 :y 393 :z 0
          :shape (list :kind "rect" :w 280 :h 166)
          :style (list :fill "frame" :stroke "edge" :cap "danger" :fontSize 19))
    ;; A plain note is a sharp square and its words; the accent is loud.
    (list :op "create" :id "n-questions" :kind "note" :diagram diagram
          :name "questions" :role "unknown" :x 60 :y 190 :z 2
          :text "what happens after a\ntimeout?\ncould a retry charge twice?"
          :shape (list :kind "rect" :w 246 :h 122)
          :style (list :fill "note" :stroke "none" :fontSize 18)
          :anchors (list :right (vector 246 61) :left (vector 0 61)))
    (list :op "create" :id "n-retry" :kind "note" :diagram diagram
          :name "retry key" :role "proposed" :x 60 :y 330 :z 2
          :text "reuse the request key\nacross retries"
          :shape (list :kind "rect" :w 232 :h 96)
          :style (list :fill "accent-soft" :stroke "none" :fontSize 17))
    ;; Components: a card with a thick top cap, and one vertical variant.
    (list :op "create" :id "n-api" :kind "component" :diagram diagram
          :name "api" :text "accepts jobs" :role "declared" :x 330 :y 214 :z 3
          :shape (list :kind "rect" :w 164 :h 91)
          :style (list :fill "card" :stroke "edge" :cap "accent" :fontSize 22)
          :anchors (list :right [164 45] :left [0 45] :tip [164 45])
          :resources (list (list :kind "task" :ref "t-board-fixture" :label "task · api")
                           (list :kind "document" :ref "docs/design/freeform-agent-board.md"
                                 :label "design note")))
    (list :op "create" :id "n-workers" :kind "component" :diagram diagram
          :name "worker pool" :text "executes jobs" :role "declared" :x 560 :y 226 :z 3
          :shape (list :kind "rect" :w 183 :h 91)
          :style (list :fill "card" :stroke "edge" :cap "danger" :fontSize 22)
          :anchors (list :left [0 45] :right [183 45]))
    (list :op "create" :id "n-queue" :kind "component" :diagram diagram
          :name "queue" :text "holds jobs" :role "proposed" :x 336 :y 388 :z 3
          :shape (list :kind "rect" :w 150 :h 78)
          :style (list :fill "none" :stroke "violet" :strokeWidth 2
                       :textColor "ink" :fontSize 20 :cap "violet"))
    ;; A store drawn from a path: the grammar's own primitives, not a widget.
    (list :op "create" :id "n-store" :kind "path" :diagram diagram
          :name "event store" :role "observed" :x 540 :y 400 :z 3
          :shape (list :kind "path"
                       :segments (list (list "M" 0 16)
                                       (list "C" 0 0 183 0 183 16)
                                       (list "L" 183 75)
                                       (list "C" 183 93 0 93 0 75)
                                       (list "Z")
                                       (list "M" 0 16)
                                       (list "C" 0 33 183 33 183 16))
                       :closed t)
          :style (list :fill "card" :stroke "edge" :strokeWidth 1.5)
          :resources (list (list :kind "symbol" :ref "atlas@a17c:EventStore.append"
                                 :label "symbol at a17c")))
    ;; The store's own words, above its body.
    (list :op "create" :id "n-store-name" :kind "label" :diagram diagram
          :name "event store" :role "observed" :x 566 :y 438 :z 4
          :text "event store"
          :shape (list :kind "text" :text "event store" :size 20)
          :style (list :fill "ink" :fontSize 20))
    ;; An image: its name above it, no card shell.  It sits clear of the
    ;; worker pool's card, which ends at x 743: a picture whose words are
    ;; covered by a card is a collision nobody asked for.
    (list :op "create" :id "n-reference" :kind "image" :diagram diagram
          :name "reference · kinopio" :role "observed" :x 772 :y 190 :z 2
          :shape (list :kind "image" :w 248 :h 155 :src harness-board-fixture-image)
          :style (list :fontSize 15 :textColor "muted"))
    ;; A task marker, on the node it is actually about.
    (list :op "create" :id "n-marker" :kind "marker" :diagram diagram
          :name "review marker" :role "declared" :x 336 :y 318 :z 5
          :text "review · 2"
          :shape (list :kind "rect" :w 13 :h 13)
          :style (list :fill "danger" :textColor "ink" :fontSize 14)
          :task "t-board-fixture")
    ;; Authentic raw ink: a squiggle a person drew, kept unsmoothed.  It sits
    ;; under the framed region's own edge, clear of the open question's note:
    ;; ink drawn across a note reads as a scribble over its words.
    (list :op "create" :id "n-ink" :kind "ink" :diagram diagram
          :name "ink" :role "declared" :x 736 :y 534 :z 4
          :shape (list :kind "path" :raw t
                       :segments (list (list "M" 0 8) (list "L" 9 3) (list "L" 19 9)
                                       (list "L" 30 4) (list "L" 41 9) (list "L" 54 5)
                                       (list "L" 63 9) (list "L" 78 4)))
          :style (list :stroke "ink" :strokeWidth 2.2 :fill "none"))
    ;; An unknown, still open, in its own framed region.  It overlaps the
    ;; frame on purpose: the design keeps human arrangements.
    (list :op "create" :id "n-open" :kind "note" :diagram diagram
          :name "open question" :role "unknown" :x 716 :y 427 :z 3
          :text "how long should a\nrequest key survive?"
          :shape (list :kind "rect" :w 238 :h 96)
          :style (list :fill "note" :stroke "none" :fontSize 18)
          :resources (list (list :kind "message" :ref "s-fixture/n-1"
                                 :label "exact question")))
    ;; A second diagram: the detail the overview links to.
    (list :op "diagram.add" :id "d-queue" :name "queue detail" :parent "d-overview")
    (list :op "create" :id "n-handler" :kind "component" :diagram "d-queue"
          :name "retry handler" :text "looks up the key" :role "observed"
          :x 120 :y 160 :shape (list :kind "rect" :w 200 :h 91)
          :style (list :fill "card" :stroke "edge" :cap "accent" :fontSize 21))
    (list :op "create" :id "n-record" :kind "component" :diagram "d-queue"
          :name "idempotency record" :text "returns the prior result" :role "proposed"
          :x 420 :y 160 :shape (list :kind "rect" :w 210 :h 91)
          :style (list :fill "card" :stroke "edge" :cap "violet" :fontSize 21))
    ;; The same component, seen again in the detail: one identity, two views.
    (list :op "view.add" :id "n-api" :diagram "d-queue" :x 120 :y 300)
    (list :op "connect" :id "e-handler-record" :kind "flow" :diagram "d-queue"
          :label "lookup key"
          :from (list :object "n-handler" :anchor "right")
          :to (list :object "n-record" :anchor "left")
          :style (list :stroke "ink" :strokeWidth 2.2)))
   ;; Connectors of the overview: an ordinary relationship, with its label.
   (list (list :op "connect" :id "e-jobs" :kind "flow" :diagram diagram
               :label "jobs"
               :from (list :object "n-api" :anchor "right")
               :to (list :object "n-workers" :anchor "left")
               :style (list :stroke "ink" :strokeWidth 2.4))
         (list :op "connect" :id "e-queue" :kind "flow" :diagram diagram
               :label "retry"
               :from (list :object "n-queue" :anchor "right")
               :to (list :object "n-store" :anchor "left")
               :style (list :stroke "violet" :strokeWidth 2.4 :dash "6 5"))
         (list :op "connect" :id "e-question" :kind "association" :diagram diagram
               :label "asked"
               :from (list :object "n-questions" :anchor "right")
               :to (list :object "n-api" :anchor "left")
               :style (list :stroke "danger" :strokeWidth 2.2 :dash "6 5")
               :role "unknown"))))

(defun harness-board-fixture-board (&optional ops)
  "Return the fixture board as a document, its operations applied.
The board is made through `harness-board-plan' and
`harness-board-commit-patch', exactly as a person or an agent would make
it: the fixture cannot hold anything the public grammar could not build.
OPS, when given, are extra operations to apply after the drawing."
  (let* ((board (harness-board-normalise
                 (harness-board-blank "b-fixture" "atlas / fieldnotes" nil)))
         (plan (harness-board-plan
                board (append (harness-board-fixture--ops "d-overview") ops)))
         (committed (harness-board-commit-patch board plan)))
    (plist-put committed :theme "electric-commons")))

(defun harness-board-fixture-leaf-geometry ()
  "Return the leaf's own outline, as the design documents it.
An asymmetric leaf whose base is the local point (0, 0) and whose tip is
(100, 0): its growth axis is x, and its anchors are named for it."
  (list (list "M" 0 0) (list "L" 20 -25) (list "L" 55 -31) (list "L" 100 0)
        (list "L" 55 12) (list "L" 18 8) (list "Z")))

(defun harness-board-fixture-leaf (&optional angle scale mirror)
  "Return (PATCH . BOARD) attaching a leaf to a parent, at ANGLE, SCALE, MIRROR.
This is the design's explicit leaf construction, not a search: a parent
is placed, a child leaf is created, and one `attach' operation puts the
child's base on the parent's tip with a chosen angle, a positive size and
an optional reflection.  The child's base and tip anchors are preserved
exactly, which the suite checks."
  (let* ((board (harness-board-normalise
                 (harness-board-blank "b-leaf" "leaf study" nil)))
         (parent (list :op "create" :id "leaf-parent" :kind "path" :diagram "d-overview"
                       :name "parent" :x 60 :y 220
                       :shape (list :kind "path"
                                    :segments (harness-board-fixture-leaf-geometry))
                       :style (list :fill "accent-soft" :stroke "ink" :strokeWidth 1.5)
                       :anchors (list :base [0 0] :tip [100 0])))
         (child (list :op "create" :id "leaf-child" :kind "path" :diagram "d-overview"
                      :name "child" :x 0 :y 0
                      :shape (list :kind "path"
                                   :segments (harness-board-fixture-leaf-geometry))
                      :style (list :fill "note" :stroke "ink" :strokeWidth 1.5)
                      :anchors (list :base [0 0] :tip [100 0])))
         (attach (list :op "attach" :id "leaf-child" :parent "leaf-parent"
                       :diagram "d-overview"
                       :childAnchor "base" :parentAnchor "tip"
                       :angle (or angle 0) :scale (or scale 1)
                       :mirror (and mirror t)))
         (plan (harness-board-plan board (list parent child attach))))
    (cons plan (harness-board-commit-patch board plan))))

(provide 'harness-board-fixture)
;;; harness-board-fixture.el ends here
