;;; harness-board-svg-test.el --- Tests for the one board renderer  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The renderer is a reader of the grammar, not a second model of it, so
;; these tests hold it to the geometry the document holds: an object is
;; drawn where its matrix puts it, a theme supplies the palette, and the
;; cleanup the design asks for (a tab on the frame's corner, a note's
;; words inset, an image with its name above it and no card shell) is
;; done here, once.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-board)
(require 'harness-board-store)
(require 'harness-board-svg)
(load (expand-file-name "test/fixtures/harness-board-fixture.el") harness-test-root)

(defun harness-board-svg-test--svg (&optional diagram)
  "Return the fixture board drawn, on DIAGRAM."
  (harness-board-svg (harness-board-fixture-board) (or diagram "d-overview")))

(defun harness-board-svg-test--text (svg)
  "Return the words SVG draws."
  (let ((texts nil) (start 0))
    (while (string-match ">\\([^<>]+\\)</text>" svg start)
      (push (match-string 1 svg) texts)
      (setq start (match-end 0)))
    (nreverse texts)))

(defun harness-board-svg-test--colors (svg)
  "Return every colour SVG paints with."
  (let ((colors nil) (start 0))
    (while (string-match "\\(?:fill\\|stroke\\)=\"\\(#[0-9a-fA-F]\\{6\\}\\)\"" svg start)
      (push (downcase (match-string 1 svg)) colors)
      (setq start (match-end 0)))
    (delete-dups (nreverse colors))))

;;;; A document, not a second model

(ert-deftest harness-board-svg-is-a-document-with-a-view-box ()
  (let ((svg (harness-board-svg-test--svg)))
    (should (string-prefix-p "<?xml" svg))
    (should (string-match-p "<svg [^>]*xmlns=\"http://www.w3.org/2000/svg\"" svg))
    (should (string-match-p "viewBox=\"[-0-9. ]+\"" svg))
    (should (string-match-p "data-board=\"b-fixture\"" svg))
    (should (string-match-p "data-revision=\"1\"" svg))
    (should (string-suffix-p "</svg>" svg))))

(ert-deftest harness-board-svg-draws-every-object-the-diagram-holds ()
  "Everything in the document is drawn; nothing is drawn that is not there."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (here (cl-loop for object in (plist-get board :objects)
                        when (harness-board--view object "d-overview")
                        collect (plist-get object :id))))
    (dolist (id here)
      (ert-info (id)
        (should (string-match-p (format "data-object=\"%s\"" (regexp-quote id)) svg))))
    ;; An object with no view here is not drawn.
    (should-not (string-match-p "data-object=\"n-handler\"" svg))))

(ert-deftest harness-board-svg-places-an-object-by-its-own-matrix ()
  "The placement is the view's, written straight into the group."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (view (harness-board--view (harness-board--object! board "n-api") "d-overview")))
    (should (equal [1 0 0 1 330 214] (plist-get view :transform)))
    (should (string-match-p "<g transform=\"matrix(1 0 0 1 330 214)\">" svg))))

(ert-deftest harness-board-svg-a-rotation-is-drawn-not-flattened ()
  "A turned object keeps its transform, so a client and this picture agree."
  (let* ((board (harness-board-fixture-board))
         (rotated (harness-board-normalise
                   (plist-put (copy-sequence board) :objects
                              (mapcar (lambda (object)
                                        (if (equal (plist-get object :id) "n-queue")
                                            (harness-board--set-view
                                             object "d-overview"
                                             (plist-put (copy-sequence (harness-board--view object "d-overview"))
                                                        :transform (vector 0 1 -1 0 400 300)))
                                          object))
                                      (plist-get board :objects)))))
         (svg (harness-board-svg rotated "d-overview")))
    (should (string-match-p "matrix(0 1 -1 0 400 300)" svg))))

(ert-deftest harness-board-svg-sorts-objects-by-layer ()
  "A frame is drawn under what it holds, a marker over it."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (frame (string-match "data-object=\"f-system\"" svg))
         (note (string-match "data-object=\"n-questions\"" svg))
         (marker (string-match "data-object=\"n-marker\"" svg)))
    (should frame)
    (should note)
    (should marker)
    (should (< frame note))
    (should (< frame marker))))

;;;; Themes are palettes

(ert-deftest harness-board-svg-takes-its-colours-from-the-theme ()
  "The picture is the theme's, not a hard-coded palette."
  (let* ((electric (harness-board-svg (plist-put (harness-board-fixture-board)
                                                 :theme "electric-commons")
                                      "d-overview"))
         (night (harness-board-svg (plist-put (harness-board-fixture-board)
                                              :theme "night-commons")
                                   "d-overview")))
    (should (member "#f5f5f0" (harness-board-svg-test--colors electric)))
    (should (member "#17191d" (harness-board-svg-test--colors night)))
    ;; The same drawing, a different palette: the words are the same.
    (should (equal (harness-board-svg-test--text electric)
                   (harness-board-svg-test--text night)))
    ;; A literal colour a style names is drawn as it is.
    (let* ((board (harness-board-fixture-board))
           (literal (harness-board-normalise
                     (plist-put (copy-sequence board) :objects
                                (mapcar (lambda (object)
                                          (if (equal (plist-get object :id) "n-questions")
                                              (harness-board--set-view
                                               object "d-overview"
                                               (plist-put (copy-sequence (harness-board--view object "d-overview"))
                                                          :style (list :fill "#00ff88")))
                                            object))
                                        (plist-get board :objects))))))
      (should (member "#00ff88"
                      (harness-board-svg-test--colors (harness-board-svg literal "d-overview")))))))

(ert-deftest harness-board-svg-every-colour-it-paints-is-a-theme-colour ()
  "A palette role that resolved to nothing would paint `()' as a colour."
  (let* ((svg (harness-board-svg-test--svg))
         (colors (harness-board-svg-test--colors svg))
         (palette (mapcar (lambda (pair) (downcase (cdr pair)))
                          (cdr (assoc 'electric-commons harness-board-themes)))))
    (should colors)
    (dolist (colour colors)
      (ert-info (colour)
        (should (member colour palette))))))

;;;; The cleanup the design asks for

(ert-deftest harness-board-svg-a-frame-has-its-tab-on-its-own-corner ()
  "The tab starts where the frame starts, and the title sits on the tab's baseline."
  (let ((svg (harness-board-svg-test--svg)))
    (should (string-match-p "data-object=\"f-system-tab\" x=\"0\" y=\"-" svg))
    (should (string-match-p "data-object=\"f-system-title\" x=\"8\"" svg))
    (should (member "the system" (harness-board-svg-test--text svg)))
    ;; The title is not turned: it is drawn on its own baseline.
    (should-not (string-match-p "rotate(" svg))))

(ert-deftest harness-board-svg-a-frame-title-reads-on-its-tab ()
  "The tab's words are set in whichever of the theme's ink and paper reads.
Night commons fills its tabs with a bright accent, where the theme's own
ink would be a smudge; the two renderers pick the same colour, so the
canvas and this picture agree."
  (let ((board (harness-board-fixture-board)))
    (dolist (theme '("electric-commons" "open-labels" "night-commons"))
      (let* ((dressed (plist-put (copy-sequence board) :theme theme))
             (svg (harness-board-svg dressed "d-overview"))
             (palette (harness-board-theme dressed))
             (cap (cdr (assoc 'accent palette)))
             (ink (cdr (assoc 'ink palette)))
             (paper (cdr (assoc 'paper palette)))
             (chosen (if (< (harness-board-svg--contrast ink cap)
                            (harness-board-svg--contrast paper cap))
                         paper ink)))
        (ert-info ((format "%s" theme))
          ;; The title is drawn in the chosen colour, and it reads.
          (should (string-match-p
                   (format "data-object=\"f-system-title\".*fill=\"%s\""
                           (regexp-quote chosen))
                   svg))
          (should (>= (harness-board-svg--contrast chosen cap) 4.5)))))))

(ert-deftest harness-board-svg-a-note-is-a-sharp-box-with-its-words-inset ()
  "Square corners, no rounding, and the words start inset from the box."
  (let ((svg (harness-board-svg-test--svg)))
    (should (string-match-p "data-object=\"n-questions\" x=\"0\" y=\"0\" width=\"246\"" svg))
    (should (string-match-p "data-object=\"n-questions-text\"" svg))
    (should (string-match-p "<text x=\"14\" y=\"14\"" svg))
    ;; Nothing is rounded anywhere.
    (should-not (string-match-p "rx=\"[1-9]" svg))
    (should-not (string-match-p " ry=\"[1-9]" svg))))

(ert-deftest harness-board-svg-a-note-wraps-its-words-inside-its-box ()
  "A long line is broken at spaces so it fits the box it was given."
  (let ((lines (harness-board-svg--wrap
                "what happens after a timeout? could a retry charge twice?" 208 18)))
    (should (> (length lines) 1))
    ;; No line is wider than the room it has, within the few percent the
    ;; estimate allows so it does not orphan the word that just misses.
    (dolist (line lines)
      (should (<= (* 0.58 18 (length line)) (* 208 1.04))))
    ;; And no line is a lone word the previous one had room for.
    (should (< (length lines) 6))))

(ert-deftest harness-board-svg-a-component-has-a-cap-a-name-and-a-detail ()
  (let ((svg (harness-board-svg-test--svg))
        (texts (harness-board-svg-test--text (harness-board-svg-test--svg))))
    (should (string-match-p "data-object=\"n-api-cap\" x=\"0\" y=\"0\" width=\"164\"" svg))
    (should (member "api" texts))
    (should (member "accepts jobs" texts))
    ;; The name and its detail share one left padding.
    (should (string-match-p "data-object=\"n-api-name\" x=\"12\"" svg))
    (should (string-match-p "data-object=\"n-api-detail\" x=\"12\"" svg))))

(ert-deftest harness-board-svg-an-image-has-its-name-above-it-and-no-card-shell ()
  "No box, no border: the picture and the words that name it."
  (let ((svg (harness-board-svg-test--svg))
        (texts (harness-board-svg-test--text (harness-board-svg-test--svg))))
    (should (member "reference · kinopio" texts))
    ;; The name is above the picture, which starts at the object's own origin.
    (should (string-match-p "data-object=\"n-reference-name\" x=\"0\" y=\"-" svg))
    (should (string-match-p "data-object=\"n-reference\"" svg))
    ;; The image itself is drawn as an image, with the picture it names.
    (should (string-match-p "<image data-object=\"n-reference\" x=\"0\" y=\"0\"" svg))
    (should (string-match-p "href=\"data:image/svg" svg))
    ;; No rect stands in for it.
    (should-not (string-match-p "<rect data-object=\"n-reference\"" svg))))

(ert-deftest harness-board-svg-a-task-marker-shows-the-real-status-beside-it ()
  "A small square and words beside it: never invented activity."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (texts (harness-board-svg-test--text svg)))
    (should (string-match-p "<rect data-object=\"n-marker\" x=\"0\" y=\"0\" width=\"13\"" svg))
    ;; The fixture marker says what it was given, and nothing more.
    (should (member "review · 2" texts))
    (should-not (string-match-p "cursor" (downcase svg)))
    (should-not (string-match-p "editing" (downcase svg)))))

(ert-deftest harness-board-svg-raw-ink-is-a-polyline-with-no-wobble ()
  "Ink is the path a person drew: no smoothing, no simulated pencil."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (ink (harness-board--object! board "n-ink")))
    (should (plist-get (plist-get (harness-board--view ink "d-overview") :shape) :raw))
    (should (string-match-p "data-object=\"n-ink\" d=\"M 0 8 L 9 3 L 19 9" svg))
    ;; It is a path with points, not a curve the renderer invented.
    (should-not (string-match-p "data-object=\"n-ink\" d=\"M 0 8 C" svg))))

;;;; Connectors and the selection

(ert-deftest harness-board-svg-draws-a-connector-between-placed-anchors ()
  "A relationship is a line between two points in the diagram, with its label."
  (let* ((board (harness-board-fixture-board))
         (svg (harness-board-svg board "d-overview"))
         (texts (harness-board-svg-test--text svg)))
    (should (string-match-p "data-relationship=\"e-jobs\"" svg))
    (should (string-match-p "marker-end=\"url(#arrow-e-jobs)\"" svg))
    (should (member "jobs" texts))
    ;; The line starts where the api's right anchor is and ends at the
    ;; workers' left anchor: the two are 66 units apart.
    (should (string-match-p "d=\"M 494 259 Q" svg))
    (should (string-match-p " 560 271\"" svg))))

(ert-deftest harness-board-svg-a-selection-is-an-outline-not-a-recolour ()
  "The selected object is still drawn as it is; a dashed outline marks it."
  (let* ((board (harness-board-fixture-board))
         (selected (harness-board-normalise
                    (plist-put (copy-sequence board) :diagrams
                               (list (list :id "d-overview" :name "overview"
                                           :selection ["n-api"])
                                     (list :id "d-queue" :name "queue detail"
                                           :parent "d-overview")))))
         (svg (harness-board-svg selected "d-overview")))
    (should (string-match-p "data-selected=\"n-api\"" svg))
    (should (string-match-p "stroke-dasharray=\"6 4\"" svg))
    ;; And with nothing selected there is no outline at all.
    (should-not (string-match-p "data-selected=" (harness-board-svg-test--svg)))))

(ert-deftest harness-board-svg-an-empty-board-is-still-a-picture ()
  (let* ((board (harness-board-normalise (harness-board-blank "b-empty" "empty" nil)))
         (svg (harness-board-svg board)))
    (should (string-prefix-p "<?xml" svg))
    (should (string-match-p "viewBox=\"0 0 " svg))
    (should-not (string-match-p "data-object=" svg))))

;;;; Honest text

(ert-deftest harness-board-svg-escapes-what-would-break-the-document ()
  "Words with markup in them are text, not markup."
  (let ((svg (harness-board-svg--xml "a & b <c> \"d\"")))
    (should (equal "a &amp; b &lt;c&gt; &quot;d&quot;" svg))))

(ert-deftest harness-board-svg-never-turns-text ()
  "Vertical text is drawn on baselines, never rotated: the design's cleanup."
  (let* ((board (harness-board-fixture-board))
         (notes (harness-board-normalise
                 (plist-put (copy-sequence board) :objects
                            (mapcar (lambda (object)
                                      (if (equal (plist-get object :id) "n-questions")
                                          (harness-board--set-view
                                           object "d-overview"
                                           (plist-put (copy-sequence (harness-board--view object "d-overview"))
                                                      :transform (vector 1 0 0 1 60 190)))
                                        object))
                                    (plist-get board :objects))))))
    (should-not (string-match-p "rotate(" (harness-board-svg notes "d-overview")))))

(provide 'harness-board-svg-test)
;;; harness-board-svg-test.el ends here
