;;; board-demo.el --- Draw a board the way an agent and a person do  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A demo of the freeform board, driven the way it is really used:
;;
;;   scripts/board-demo.sh                 # print the transcript
;;   scripts/board-demo.sh --svg DIR       # and write each picture to DIR
;;   scripts/board-demo.sh --png DIR       # render each picture to a PNG
;;
;; Nothing here draws with a private API.  The board is built by calling
;; the six tools an agent has -- scene.read, grammar.describe, scene.edit,
;; patch.preview, patch.commit and history.undo -- and the pictures come
;; from the board's own renderer.  What it shows, in the order a person
;; meets it:
;;
;;   1. an empty board, and the grammar an agent reads before it draws
;;   2. an agent proposes a patch; nothing is written until it commits
;;   3. a person's arrangement is preserved: the overlap it left, the
;;      question nobody answered, the ink it drew
;;   4. the same component appears in a second diagram without a second
;;      meaning, which is what a drill-down is
;;   5. a reflection of a shape, and the refusal to reflect a label
;;   6. undo takes one commit back, and a conflict is reported rather
;;      than somebody else's work being overwritten
;;   7. the three themes, drawn from the same geometry
;;   8. a scene read hands a model the picture and the exact numbers

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-board)
(require 'harness-board-edit)
(require 'harness-board-store)
(require 'harness-board-svg)
(require 'harness-tools-board)
(load (expand-file-name "test/fixtures/harness-board-fixture.el")
      (let ((here (file-name-directory (or load-file-name buffer-file-name))))
        (expand-file-name ".." here)))
;; The harness's own way of loading a module, which starts it as the
;; harness does: a demo runs the modules, not a copy of them.
(load (expand-file-name "test/harness-test-helpers.el")
      (let ((here (file-name-directory (or load-file-name buffer-file-name))))
        (expand-file-name ".." here)))

(defvar board-demo--output nil
  "Directory the pictures go to, or nil for none.")

(defvar board-demo--png nil
  "Non-nil to render each picture to a PNG as well.")

(defvar board-demo--session "s-demo"
  "The session the demo's agent acts as.")

(defvar board-demo--step 0
  "How many places the demo has been to.")

(defun board-demo--call (name input)
  "Call tool NAME with INPUT as the demo's agent, and print what it answered.
Return the result plist."
  (let ((result (funcall (harness-tool-handler (harness-tool-get name))
                         input (list :session-id board-demo--session))))
    (princ (format "\n$ %s %s\n" name
                   (or (plist-get input :board) "")))
    (dolist (line (split-string (string-trim-right (or (plist-get result :content) "")) "\n"))
      (princ (format "  %s\n" line)))
    (when (plist-get result :is-error)
      (princ (format "  (refused: %s)\n" (plist-get (plist-get result :meta) :board-error))))
    result))

(defun board-demo--picture (board diagram caption)
  "Write BOARD's DIAGRAM as a picture, named for the step and CAPTION.
Print where it went, so a reader of the transcript can open it."
  (when board-demo--output
    (cl-incf board-demo--step)
    (let* ((slug (replace-regexp-in-string
                  "[^a-z0-9]+" "-" (downcase caption)))
           (name (format "%02d-%s.svg" board-demo--step
                         (string-trim slug "-" "-")))
           (path (expand-file-name name board-demo--output))
           (svg (harness-board-svg board diagram caption)))
      (make-directory board-demo--output t)
      (with-temp-file path (insert svg))
      (princ (format "\n  picture: %s\n" path))
      (board-demo--render-png path))))

(defun board-demo--render-png (svg-path)
  "Render SVG-PATH to a PNG beside it, when asked to and rsvg-convert is here."
  (when (and board-demo--png (executable-find "rsvg-convert"))
    (let ((png (concat (file-name-sans-extension svg-path) ".png")))
      (when (zerop (call-process "rsvg-convert" nil nil nil
                                 "-w" "1400" svg-path "-o" png))
        (princ (format "  picture: %s\n" png))))))

(defun board-demo--commit (board ops &optional key)
  "Commit OPS on BOARD as the demo's agent, with KEY.  Return the board."
  (let* ((preview (board-demo--call "patch.preview"
                                    (list :board (plist-get board :id) :revision
                                          (plist-get board :revision) :ops ops)))
         (answer (board-demo--call
                  "patch.commit"
                  (list :board (plist-get board :id)
                        :patch (plist-get (plist-get preview :meta) :patch)
                        :hash (plist-get (plist-get preview :meta) :hash)
                        :revision (plist-get board :revision)
                        :idempotencyKey (or key (format "k-demo-%s" board-demo--step))))))
    (if (plist-get answer :is-error)
        board
      (harness-board-load (plist-get board :id)))))

;;;; The demo

(defun board-demo--grammar ()
  "Show the grammar an agent reads before it draws anything."
  (princ "\n=== 1. the grammar, before anything is drawn\n")
  (let ((grammar (harness-call 'board/grammar)))
    (princ (format "  schema %s · %d shapes · %d operations · %d themes\n"
                   (plist-get grammar :schema)
                   (length (append (plist-get grammar :shapes) nil))
                   (length (append (plist-get grammar :operations) nil))
                   (length (append (plist-get grammar :themes) nil))))
    (princ (format "  units: x %s, y %s, angles %s\n"
                   (plist-get (plist-get grammar :units) :x)
                   (plist-get (plist-get grammar :units) :y)
                   (plist-get (plist-get grammar :units) :angle)))
    (princ "  no search, no ranking, no lifecycle: an agent reads, decides and edits\n")))

(defun board-demo--a-person-drew-this (board)
  "Show BOARD, the drawing a person arranged by hand, and its picture."
  (princ "\n=== 2. the drawing a person arranged, read through scene.read\n")
  (board-demo--call "scene.read"
                    (list :board (plist-get board :id) :diagram "d-overview"))
  (board-demo--picture board "d-overview" "the drawing a person arranged"))

(defun board-demo--an-agent-proposes (board)
  "Show a patch an agent makes, and that nothing is written until it commits."
  (princ "\n=== 3. an agent proposes; nothing is written until it commits\n")
  (let* ((before (plist-get board :revision))
         (edit (board-demo--call "scene.edit"
                                 (list :board (plist-get board :id) :diagram "d-overview"
                                       ;; The scope names every object the batch
                                       ;; touches, the ones it makes included.
                                       :scope ["n-api" "n-workers" "n-queue"
                                               "n-replay" "e-replay"]
                                       :ops (list (list :op "create" :id "n-replay" :kind "note"
                                                        :name "replay" :role "proposed"
                                                        :text "replay the backlog\nfrom the last key"
                                                        :diagram "d-overview"
                                                        :x 330 :y 470
                                                        :shape (list :kind "rect" :w 200 :h 84)
                                                        :style (list :fill "note-soft"
                                                                     :fontSize 17))
                                                  (list :op "connect" :id "e-replay"
                                                        :diagram "d-overview"
                                                        :label "proposed"
                                                        :from (list :object "n-queue" :anchor "bottom")
                                                        :to (list :object "n-replay" :anchor "top")
                                                        :role "proposed"
                                                        :style (list :stroke "violet"
                                                                     :strokeWidth 2
                                                                     :dash "6 5")))))))
    (princ (format "\n  the board is still at revision %s: %s\n"
                   (plist-get (harness-board-load (plist-get board :id)) :revision)
                   (if (= before (plist-get (harness-board-load (plist-get board :id)) :revision))
                       "the edit wrote nothing"
                     "the edit wrote something, which it must not")))
    (when (plist-get edit :is-error)
      (princ "  (the demo's proposal was refused; see above)\n"))
    board))

(defun board-demo--commit-the-proposal (board)
  "Commit the proposal, and show the picture of the board it made."
  (princ "\n=== 4. the commit: one atomic revision\n")
  (let* ((committed (board-demo--commit
                     board
                     (list (list :op "create" :id "n-replay" :kind "note"
                                 :name "replay" :role "proposed"
                                 :text "replay the backlog\nfrom the last key"
                                 :diagram "d-overview"
                                 :x 330 :y 470
                                 :shape (list :kind "rect" :w 200 :h 84)
                                 :style (list :fill "note-soft" :fontSize 17))
                           (list :op "connect" :id "e-replay"
                                 :diagram "d-overview"
                                 :label "proposed"
                                 :from (list :object "n-queue" :anchor "bottom")
                                 :to (list :object "n-replay" :anchor "top")
                                 :role "proposed"
                                 :style (list :stroke "violet" :strokeWidth 2 :dash "6 5"))))))
    (princ (format "  revision %s · %d commits in its history\n"
                   (plist-get committed :revision)
                   (length (append (plist-get committed :history) nil))))
    (board-demo--picture committed "d-overview" "the board after one commit")
    committed))

(defun board-demo--one-meaning-two-views (board)
  "Show that n-api is one object in two diagrams, without a second history."
  (princ "\n=== 5. a drill-down: one meaning, two views\n")
  (let ((object (harness-board--object! board "n-api")))
    (princ (format "  n-api appears in: %s\n"
                   (string-join (mapcar #'car (harness-board--object-views object)) ", ")))
    (board-demo--call "scene.read"
                      (list :board (plist-get board :id) :diagram "d-queue"))
    (board-demo--picture board "d-queue" "the queue detail, the same component again"))
  board)

(defun board-demo--a-reflection (board)
  "Show a shape reflected, and a label's reflection refused."
  (princ "\n=== 6. a reflection of a shape, and never of a label\n")
  (board-demo--call "scene.edit"
                    (list :board (plist-get board :id) :diagram "d-overview"
                          :ops (list (list :op "transform" :id "n-store" :diagram "d-overview"
                                           :kind "reflect" :axis "x" :pivot [631 400]))))
  (board-demo--call "scene.edit"
                    (list :board (plist-get board :id) :diagram "d-overview"
                          :ops (list (list :op "transform" :id "n-store-name" :diagram "d-overview"
                                           :kind "reflect" :axis "x" :pivot [629 438]))))
  board)

(defun board-demo--undo (board)
  "Show undo taking back the commit, and keeping what somebody else changed."
  (princ "\n=== 7. undo: a compensating edit, and a conflict reported\n")
  (let ((answer (board-demo--call
                 "history.undo" (list :board (plist-get board :id)))))
    (if (plist-get answer :is-error)
        board
      (harness-board-load (plist-get board :id)))))

(defun board-demo--themes (board)
  "Write the same geometry in each theme, which is a palette and no more."
  (princ "\n=== 8. the three themes, one drawing\n")
  (dolist (theme '("electric-commons" "open-labels" "night-commons"))
    (let ((dressed (harness-board-normalise
                    (plist-put (copy-sequence board) :theme theme))))
      (board-demo--picture dressed "d-overview" (format "the board · %s" theme)))
    (princ (format "  %s\n" theme)))
  board)

(defun board-demo--hand-it-in (board)
  "Pin the revision a task hands in, and show the artifact apart from the board."
  (princ "\n=== 9. the revision a task hands in, pinned as the artifact\n")
  (let ((pinned (board-demo--call
                 "board.pin"
                 (list :board (plist-get board :id)
                       :task "t-demo"
                       :diagram "d-overview"
                       :object "n-api"
                       :title "the system as drawn"))))
    ;; The board goes on after the pin; the artifact does not.
    (let* ((later (harness-board-load (plist-get board :id)))
           (moved (board-demo--commit
                   later
                   (list (list :op "move" :id "n-api" :diagram "d-overview"
                               :dx 12 :dy 8))
                   "k-demo-after-the-pin")))
      (let ((pin (plist-get (plist-get pinned :meta) :pin))
            (kept (harness-call 'board/pins (plist-get board :id)
                                (list :pin (plist-get (plist-get pinned :meta) :pin)))))
        (princ (format "  the pin keeps revision %s; the board is at %s now\n"
                       (plist-get (plist-get kept :pin) :revision)
                       (plist-get moved :revision)))
        (princ (format "  artifact: %s\n  current:  %s\n"
                       (plist-get (plist-get kept :pin) :target)
                       (plist-get (plist-get kept :pin) :current)))
        (when board-demo--output
          (let ((svg (plist-get kept :image)))
            (when svg
              (board-demo--step-svg svg "the artifact, as it was pinned")))))
      moved)))

(defun board-demo--step-svg (svg caption)
  "Write SVG under the next step's name, with CAPTION, as `board-demo--picture' does."
  (cl-incf board-demo--step)
  (let* ((slug (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase caption)))
         (name (format "%02d-%s.svg" board-demo--step (string-trim slug "-" "-")))
         (path (expand-file-name name board-demo--output)))
    (make-directory board-demo--output t)
    (with-temp-file path (insert svg))
    (princ (format "\n  picture: %s\n" path))
    (board-demo--render-png path)))

(defun board-demo--close (board)
  "Show the scene read's picture, which is what a model is handed."
  (princ "\n=== 10. what a model is handed: the exact scene and the picture\n")
  (let ((result (board-demo--call "scene.read"
                                  (list :board (plist-get board :id)
                                        :diagram "d-overview"))))
    (let ((images (append (plist-get result :images) nil)))
      (princ (format "  %d picture%s, %d bytes, drawn from the same geometry a person sees\n"
                     (length images) (if (= 1 (length images)) "" "s")
                     (length (or (car images) ""))))))
  (princ (format "\n%d places shown, %d pictures\n"
                 board-demo--step
                 (if board-demo--output board-demo--step 0)))
  board)

;;;; The world

(defun board-demo--with-world (thunk)
  "Run THUNK with a fresh state, the board's modules loaded and a fixture board."
  (let* ((dir (file-name-as-directory (make-temp-file "board-demo-" t)))
         (harness-state-directory dir))
    (unwind-protect
        (progn
          (harness-test-load-module 'store)
          (harness-test-load-module 'project)
          (harness-test-load-module 'config)
          (harness-test-load-module 'provider)
          (harness-test-load-module 'tools)
          (harness-test-load-module 'session)
          (harness-test-load-module 'agent)
          (harness-test-load-module 'linking)
          (harness-test-load-module 'board)
          (harness-test-load-module 'board-edit)
          (harness-test-load-module 'board-store)
          (harness-test-load-module 'board-svg)
          (harness-test-load-module 'tools-board)
          (let ((board (harness-board-fixture-board)))
            (harness-board-save board)
            (funcall thunk (harness-board-load (plist-get board :id)))))
      (ignore-errors (delete-directory dir t)))))

(defun board-demo-main ()
  "Run the demo: an agent draws, a person's arrangement survives, undo works."
  (let ((args command-line-args-left))
    (while args
      (pcase (pop args)
        ("--svg" (setq board-demo--output (expand-file-name (or (pop args) "."))))
        ("--png" (setq board-demo--png t)
                     (when (and args (not (string-prefix-p "--" (car args))))
                       (setq board-demo--output (expand-file-name (pop args)))))
        ("--out" (setq board-demo--output (expand-file-name (or (pop args) "."))))
        (_ nil)))
    ;; The options are this demo's, not Emacs's: consumed here, so
    ;; `-f board-demo-main' is not followed by an unknown option.
    (setq command-line-args-left nil))

  (princ "\n=== the freeform board, driven through the agent's own tools ===\n")
  (board-demo--with-world
   (lambda (board)
     (board-demo--grammar)
     (board-demo--a-person-drew-this board)
     (board-demo--an-agent-proposes board)
     (let ((committed (board-demo--commit-the-proposal board)))
       (board-demo--one-meaning-two-views committed)
       (board-demo--a-reflection committed)
       (let ((undone (board-demo--undo committed)))
         (board-demo--themes undone)
         (board-demo--close (board-demo--hand-it-in undone))))))
  (princ "\n=== nothing here searched, ranked or re-arranged anything ===\n"))

(provide 'board-demo)
;;; board-demo.el ends here
