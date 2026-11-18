;;; harness-tools-board-test.el --- Tests for the board tools  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The six tools an agent works the board with.  Each is one bus method
;; of the board module, so what is tried here is what the tool sends,
;; what it says of the answer, and that it refuses with the board's own
;; error kinds rather than an opaque failure.
;;
;; The tools are not a second model of the board: they are named the way
;; the design names them, they carry the calling session as the writer,
;; and they never search, rank or commit without being told to.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-tools)
(require 'harness-tools-board)
(require 'harness-board-store)
(require 'harness-acp)
(load (expand-file-name "test/fixtures/harness-board-fixture.el") harness-test-root)

(defmacro harness-tools-board-test--with (&rest body)
  "Run BODY with the board modules loaded and the fixture board saved."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (require 'harness-board-svg)
     (let ((board (harness-board-fixture-board)))
       (harness-board-save board)
       (harness-board-set-views "b-fixture"
                                (list :focus (list :board "b-fixture" :diagram "d-overview")))
       ,@body)))

(defun harness-tools-board-test--call (name input &optional ctx)
  "Execute tool NAME with INPUT and CTX, answering the result plist."
  (let ((tool (harness-tool-get name)))
    (unless tool (error "No tool %s" name))
    (funcall (harness-tool-handler tool) input ctx)))

(defun harness-tools-board-test--ctx (&optional session)
  "Return a tool context for SESSION."
  (list :session-id (or session "s-test")))

;;;; The six are registered, under the names the design gives them

(ert-deftest harness-tools-board-the-board-tools-are-registered ()
  "The six the design names, and the two a task's artifact and a discussion need."
  (dolist (name '("board.pin" "board.discuss"))
    (ert-info (name)
      (let ((tool (harness-tool-get name)))
        (should tool)
        (should (stringp (harness-tool-label tool)))
        (should-not (string-match-p "[.!?]\\'" (harness-tool-label tool)))
        (should (> (length (harness-tool-description tool)) 80))
        (should (eq 'write (harness-tool-kind tool)))))))

(ert-deftest harness-tools-board-the-six-tools-are-registered ()
  "scene.read, grammar.describe, scene.edit, patch.preview, patch.commit and history.undo."
  (dolist (name '("scene.read" "grammar.describe" "scene.edit"
                  "patch.preview" "patch.commit" "history.undo"))
    (ert-info (name)
      (let ((tool (harness-tool-get name)))
        (should tool)
        ;; Each names the thing people read, in a noun phrase.
        (should (harness-tool-label tool))
        (should (stringp (harness-tool-label tool)))
        (should-not (string-match-p "[.!?]\\'" (harness-tool-label tool)))
        ;; And says what the model needs to know to use it.
        (should (> (length (harness-tool-description tool)) 80))
        (should (equal "object" (plist-get (harness-tool-schema tool) :type)))))))

(ert-deftest harness-tools-board-there-is-no-search-tool ()
  "The design leaves search out: no tool generates, ranks or searches candidates."
  (dolist (name '("branch.search" "branch.search_tool" "board.search" "scene.search"))
    (should-not (harness-tool-get name))))

(ert-deftest harness-tools-board-the-kinds-are-the-permission-classes-they-need ()
  "Reading is read; an edit, a commit and an undo are writes; a preview changes nothing."
  (should (eq 'read (harness-tool-kind (harness-tool-get "scene.read"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "grammar.describe"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "patch.preview"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "scene.edit"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "patch.commit"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "history.undo")))))

;;;; scene.read

(ert-deftest harness-tools-board-scene-read-reads-a-scene ()
  "The revision, the diagram, every object with its geometry and text, its anchors and its resources."
  (harness-tools-board-test--with
    (let* ((result (harness-tools-board-test--call
                    "scene.read" (list :board "b-fixture" :diagram "d-overview")
                    (harness-tools-board-test--ctx)))
           (content (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (should (equal "b-fixture" (plist-get (plist-get result :meta) :board)))
      (should (= 1 (plist-get (plist-get result :meta) :revision)))
      ;; The words a model reads say where things are and what they claim.
      (should (string-match-p "revision 1" content))
      (should (string-match-p "d-overview" content))
      (should (string-match-p "n-api" content))
      (should (string-match-p "accepts jobs" content))
      (should (string-match-p "declared" content))
      (should (string-match-p "observed" content))
      ;; And the geometry, exactly, not an impression of it.
      (should (string-match-p "330" content))
      (should (string-match-p "214" content)))))

(ert-deftest harness-tools-board-scene-read-hands-over-the-picture ()
  "A model given a picture and a person shown one are given the same drawing."
  (harness-tools-board-test--with
    (require 'harness-board-svg)
    (let* ((result (harness-tools-board-test--call
                    "scene.read" (list :board "b-fixture" :diagram "d-overview")
                    (harness-tools-board-test--ctx)))
           (images (append (plist-get result :images) nil)))
      (should (= 1 (length images)))
      (should (string-prefix-p "<?xml" (car images)))
      (should (string-match-p "data-board=\"b-fixture\"" (car images))))))

(ert-deftest harness-tools-board-scene-read-says-what-a-link-resolved-to ()
  "A resource is reported with its state, never as a generic page."
  (harness-tools-board-test--with
    (let* ((result (harness-tools-board-test--call
                    "scene.read" (list :board "b-fixture" :diagram "d-overview")
                    (harness-tools-board-test--ctx)))
           (content (plist-get result :content)))
      ;; The link keeps the words its author gave it, names what it is,
      ;; and says where it resolved.
      (should (string-match-p "links: 1" content))
      (should (string-match-p "symbol atlas@a17c:EventStore.append · declared" content))
      ;; A symbol is declared evidence at a revision, and the tool says so.
      (should (string-match-p "static evidence at a revision" content))
      ;; A precise target that cannot be resolved says that, rather than
      ;; standing in a generic page for it.
      (should (string-match-p "message s-fixture/n-1 · unsupported" content)))))

(ert-deftest harness-tools-board-scene-read-refuses-a-board-that-is-not-there ()
  (harness-tools-board-test--with
    (let ((result (harness-tools-board-test--call
                   "scene.read" (list :board "b-nowhere") (harness-tools-board-test--ctx))))
      (should (plist-get result :is-error))
      (should (string-match-p "unknown-id" (plist-get result :content)))
      (should (eq 'unknown-id (plist-get (plist-get result :meta) :board-error))))))

(ert-deftest harness-tools-board-scene-read-needs-a-board ()
  (harness-tools-board-test--with
    (should-error (harness-tools-board-test--call
                   "scene.read" nil (harness-tools-board-test--ctx)))))

;;;; grammar.describe

(ert-deftest harness-tools-board-grammar-describe-lists-what-can-be-built ()
  "The shapes, the operations, the styles, the themes, the units and the limits."
  (harness-tools-board-test--with
    (let* ((result (harness-tools-board-test--call
                    "grammar.describe" nil (harness-tools-board-test--ctx)))
           (content (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (dolist (kind '("rect" "ellipse" "polygon" "path" "text" "image"))
        (ert-info (kind)
          (should (string-match-p kind content))))
      (dolist (op '("create" "view.add" "move" "transform" "set-style" "attach"
                    "connect" "delete"))
        (ert-info (op)
          (should (string-match-p (regexp-quote op) content))))
      ;; The units a caller places something with.
      (should (string-match-p "x right" content))
      (should (string-match-p "y down" content))
      (should (string-match-p "clockwise" content))
      ;; The themes, by name.
      (dolist (theme '("electric-commons" "open-labels" "night-commons"))
        (should (string-match-p theme content)))
      ;; And the ways an operation is refused.
      (dolist (kind '("invalid-parameter" "stale-revision" "hard-constraint"))
        (should (string-match-p kind content))))))

(ert-deftest harness-tools-board-grammar-describe-says-what-is-not-there ()
  "No tool offers search, ranking or a lifecycle, and the grammar does not pretend otherwise."
  (harness-tools-board-test--with
    (let ((content (plist-get (harness-tools-board-test--call
                               "grammar.describe" nil (harness-tools-board-test--ctx))
                              :content)))
      (should-not (string-match-p "\\bsearch\\b" (downcase content)))
      (should-not (string-match-p "\\brank" (downcase content)))
      (should-not (string-match-p "\\bkanban\\b" (downcase content))))))

;;;; scene.edit

(ert-deftest harness-tools-board-scene-edit-returns-a-validated-patch ()
  "An edit is a proposal: the patch, what it creates and changes, and what it would replace."
  (harness-tools-board-test--with
    (let* ((result (harness-tools-board-test--call
                    "scene.edit"
                    (list :board "b-fixture" :diagram "d-overview"
                          :ops (list (list :op "move" :id "n-api" :dx 20 :dy 0)))
                    (harness-tools-board-test--ctx)))
           (content (plist-get result :content))
           (meta (plist-get result :meta)))
      (should-not (plist-get result :is-error))
      (should (plist-get meta :patch))
      (should (plist-get meta :hash))
      (should (string-match-p "Not committed" content))
      (should (string-match-p "n-api" content))
      ;; Nothing was written.
      (should (= 1 (plist-get (harness-board-load "b-fixture") :revision))))))

(ert-deftest harness-tools-board-scene-edit-is-held-to-its-scope ()
  "The batch may touch only the objects the caller named."
  (harness-tools-board-test--with
    (let ((result (harness-tools-board-test--call
                   "scene.edit"
                   (list :board "b-fixture" :diagram "d-overview" :scope ["n-api"]
                         :ops (list (list :op "move" :id "n-workers" :dx 20 :dy 0)))
                   (harness-tools-board-test--ctx))))
      (should (plist-get result :is-error))
      (should (string-match-p "hard-constraint" (plist-get result :content))))))

(ert-deftest harness-tools-board-scene-edit-says-which-kind-refused-it ()
  "A refusal names one of the grammar's distinct kinds, not a bare failure."
  (harness-tools-board-test--with
    (dolist (case '(((:op "transform" :id "n-store-name" :kind "reflect" :axis "x" :pivot [0 0])
                     . "precondition")
                    ((:op "move" :id "n-nowhere" :dx 1 :dy 0) . "unknown-id")
                    ((:op "transform" :id "n-api" :kind "scale" :sx 0 :sy 1 :pivot [0 0])
                     . "invalid-parameter")
                    ((:op "paint" :id "n-api") . "unsupported-operation")))
      (ert-info ((format "%S" (car case)))
        (let ((result (harness-tools-board-test--call
                       "scene.edit"
                       (list :board "b-fixture" :diagram "d-overview" :ops (list (car case)))
                       (harness-tools-board-test--ctx))))
          (should (plist-get result :is-error))
          (should (string-match-p (cdr case) (plist-get result :content)))
          (should (eq (intern (cdr case))
                      (plist-get (plist-get result :meta) :board-error))))))))

;;;; patch.preview

(ert-deftest harness-tools-board-patch-preview-names-the-batch-it-renders ()
  "The preview and the patch name the same batch, so a commit applies exactly it."
  (harness-tools-board-test--with
    (let* ((ops (list (list :op "move" :id "n-api" :dx 20 :dy 0)))
           (edit (harness-tools-board-test--call
                  "scene.edit" (list :board "b-fixture" :diagram "d-overview" :ops ops)
                  (harness-tools-board-test--ctx)))
           (preview (harness-tools-board-test--call
                     "patch.preview" (list :board "b-fixture" :diagram "d-overview" :ops ops)
                     (harness-tools-board-test--ctx))))
      (should-not (plist-get preview :is-error))
      (should (equal (plist-get (plist-get edit :meta) :patch)
                     (plist-get (plist-get preview :meta) :patch)))
      (should (equal (plist-get (plist-get edit :meta) :hash)
                     (plist-get (plist-get preview :meta) :hash)))
      ;; A preview draws the batch, so it hands over a picture of it.
      (should (append (plist-get preview :images) nil)))))

(ert-deftest harness-tools-board-patch-preview-reports-warnings-and-still-stands ()
  "Overflow and a far movement are warnings; the batch is not refused."
  (harness-tools-board-test--with
    (let* ((result (harness-tools-board-test--call
                    "patch.preview"
                    (list :board "b-fixture" :diagram "d-overview"
                          :ops (list (list :op "move" :id "n-api" :dx 0 :dy 900)))
                    (harness-tools-board-test--ctx)))
           (content (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "movement" content))
      (should (string-match-p "warning" content)))))

;;;; patch.commit

(ert-deftest harness-tools-board-patch-commit-applies-the-previewed-batch ()
  "The commit takes the patch id and hash, the revision read, and a key."
  (harness-tools-board-test--with
    (let* ((ops (list (list :op "move" :id "n-api" :dx 20 :dy 0)))
           (preview (harness-tools-board-test--call
                     "patch.preview" (list :board "b-fixture" :diagram "d-overview" :ops ops)
                     (harness-tools-board-test--ctx)))
           (commit (harness-tools-board-test--call
                    "patch.commit"
                    (list :board "b-fixture"
                          :patch (plist-get (plist-get preview :meta) :patch)
                          :hash (plist-get (plist-get preview :meta) :hash)
                          :revision 1
                          :idempotencyKey "k-tool-1")
                    (harness-tools-board-test--ctx))))
      (should-not (plist-get commit :is-error))
      (should (string-match-p "committed at revision 2" (plist-get commit :content)))
      (should (= 2 (plist-get (harness-board-load "b-fixture") :revision))))))

(ert-deftest harness-tools-board-patch-commit-is-idempotent-by-its-key ()
  "A retried call after a lost answer commits once and says so."
  (harness-tools-board-test--with
    (let* ((ops (list (list :op "move" :id "n-api" :dx 20 :dy 0)))
           (first (harness-tools-board-test--call
                   "patch.commit" (list :board "b-fixture" :ops ops :revision 1
                                        :idempotencyKey "k-once")
                   (harness-tools-board-test--ctx)))
           (second (harness-tools-board-test--call
                    "patch.commit" (list :board "b-fixture" :ops ops :revision 2
                                         :idempotencyKey "k-once")
                    (harness-tools-board-test--ctx))))
      (should-not (plist-get first :is-error))
      (should-not (plist-get second :is-error))
      (should (plist-get (plist-get second :meta) :idempotent))
      (should (string-match-p "Already committed" (plist-get second :content)))
      (should (= 2 (plist-get (harness-board-load "b-fixture") :revision))))))

(ert-deftest harness-tools-board-patch-commit-refuses-a-moved-read-set ()
  "stale-revision, named as such, and the board is left as it is."
  (harness-tools-board-test--with
    (let* ((ops (list (list :op "move" :id "n-api" :dx 20 :dy 0)))
           (preview (harness-tools-board-test--call
                     "patch.preview" (list :board "b-fixture" :diagram "d-overview" :ops ops)
                     (harness-tools-board-test--ctx))))
      ;; Somebody else commits first.
      (harness-tools-board-test--call
       "patch.commit" (list :board "b-fixture" :revision 1
                            :ops (list (list :op "move" :id "n-workers" :dx 5 :dy 0))
                            :idempotencyKey "k-theirs")
       (harness-tools-board-test--ctx))
      (let ((ours (harness-tools-board-test--call
                   "patch.commit"
                   (list :board "b-fixture"
                         :patch (plist-get (plist-get preview :meta) :patch)
                         :hash (plist-get (plist-get preview :meta) :hash)
                         :revision 1)
                   (harness-tools-board-test--ctx))))
        (should (plist-get ours :is-error))
        (should (string-match-p "stale-revision" (plist-get ours :content)))))))

;;;; history.undo

(ert-deftest harness-tools-board-history-undo-takes-back-the-newest-commit ()
  (harness-tools-board-test--with
    (harness-tools-board-test--call
     "patch.commit" (list :board "b-fixture" :revision 1
                          :ops (list (list :op "move" :id "n-api" :dx 40 :dy 0))
                          :idempotencyKey "k-move")
     (harness-tools-board-test--ctx))
    (let* ((result (harness-tools-board-test--call
                    "history.undo" (list :board "b-fixture")
                    (harness-tools-board-test--ctx)))
           (content (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "Applied 1 operation" content))
      (should (string-match-p "n-api" content))
      (should (string-match-p "No conflicts" content))
      (should (= 3 (plist-get (plist-get result :meta) :revision))))))

(ert-deftest harness-tools-board-history-undo-dry-run-commits-nothing ()
  (harness-tools-board-test--with
    (harness-tools-board-test--call
     "patch.commit" (list :board "b-fixture" :revision 1
                          :ops (list (list :op "move" :id "n-api" :dx 40 :dy 0))
                          :idempotencyKey "k-move")
     (harness-tools-board-test--ctx))
    (let ((result (harness-tools-board-test--call
                   "history.undo" (list :board "b-fixture" :dryRun t)
                   (harness-tools-board-test--ctx))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "Would apply" (plist-get result :content)))
      (should (= 2 (plist-get (harness-board-load "b-fixture") :revision))))))

(ert-deftest harness-tools-board-history-undo-says-when-there-is-nothing-to-take-back ()
  (harness-tools-board-test--with
    (harness-call 'board/create "b-blank" "blank" nil)
    (let ((result (harness-tools-board-test--call
                   "history.undo" (list :board "b-blank")
                   (harness-tools-board-test--ctx))))
      (should (plist-get result :is-error))
      (should (string-match-p "precondition" (plist-get result :content))))))

;;;; What the tools never do

(ert-deftest harness-tools-board-editing-never-creates-a-task ()
  "A drawing is a drawing: a task is made only when a person asks for one."
  (harness-tools-board-test--with
    (let ((before (length (append (harness-call 'board/list nil) nil))))
      (harness-tools-board-test--call
       "patch.commit" (list :board "b-fixture" :revision 1
                            :ops (list (list :op "create" :id "n-drawn" :kind "note"
                                             :text "a new note" :diagram "d-overview"
                                             :x 0 :y 0
                                             :shape (list :kind "rect" :w 60 :h 30)))
                            :idempotencyKey "k-draw")
       (harness-tools-board-test--ctx))
      ;; The board grew, and nothing else did.
      (should (= before (length (append (harness-call 'board/list nil) nil))))
      (should (harness-board--object (harness-board-load "b-fixture") "n-drawn")))))

(ert-deftest harness-tools-board-editing-never-approves-code ()
  "No board tool reaches a review verdict."
  (harness-tools-board-test--with
    (dolist (name '("scene.edit" "patch.commit" "history.undo"))
      (let ((schema (harness-tool-schema (harness-tool-get name))))
        (should-not (string-match-p "verdict" (format "%S" schema)))
        (should-not (string-match-p "approve" (format "%S" schema)))))))

(ert-deftest harness-tools-board-is-known-to-a-ui ()
  "A UI may call the board's methods and hears what changes it."
  (should (member "board/" harness-acp-extension-prefixes))
  (dolist (event '(board/created board/deleted board/changed board/focused))
    (should (memq event harness-acp--forwarded-events)))
  (dolist (method '(board/list board/get board/grammar board/patch board/preview
                                board/commit board/undo board/focus board/views
                                board/delete board/link/describe))
    (should (harness-method-exists-p method))))

;;;; board.pin and board.discuss

(ert-deftest harness-tools-board-a-pin-says-the-artifact-and-the-board-apart ()
  "The tool pins the revision and names both links: the artifact and the board."
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.pin"
                   (list :board "b-fixture" :task "t-1" :title "the plan")
                   (harness-tools-board-test--ctx))))
      (should-not (plist-get answer :is-error))
      (let ((meta (plist-get answer :meta)))
        (should (stringp (plist-get meta :pin)))
        (should (= 1 (plist-get meta :revision)))
        (should (string-match-p "/revision/1\\'" (plist-get meta :target)))
        (should (equal (harness-links-board-url "b-fixture" "d-overview")
                       (plist-get meta :current))))
      (should (string-match-p "Pinned revision 1" (plist-get answer :content))))))

(ert-deftest harness-tools-board-a-pin-refuses-a-place-that-is-not-here ()
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.pin"
                   (list :board "b-fixture" :diagram "d-nowhere")
                   (harness-tools-board-test--ctx))))
      (should (plist-get answer :is-error))
      (should (string-match-p "unknown-id" (plist-get answer :content))))))

(ert-deftest harness-tools-board-a-discussion-needs-a-review-to-hold-it ()
  "With no review module there is nowhere to discuss a board, and it says so."
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.discuss"
                   (list :board "b-fixture" :object "n-api" :task "t-1" :text "why?")
                   (harness-tools-board-test--ctx))))
      (should (plist-get answer :is-error))
      (should (string-match-p "unsupported-operation" (plist-get answer :content))))))

(provide 'harness-tools-board-test)
;;; harness-tools-board-test.el ends here
