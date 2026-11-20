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
  "Every board tool the design names, with a label and a description of its own."
  (dolist (name '("board.list" "board.create" "scene.read" "grammar.describe"
                  "scene.edit" "patch.preview" "patch.commit" "history.undo"
                  "board.pin" "board.pins" "board.discuss" "board.discussions"
                  "board.delete"))
    (ert-info (name)
      (let ((tool (harness-tool-get name)))
        (should tool)
        (should (stringp (harness-tool-label tool)))
        (should-not (string-match-p "[.!?]\\'" (harness-tool-label tool)))
        (should (> (length (harness-tool-description tool)) 80))
        (should (equal "object" (plist-get (harness-tool-schema tool) :type)))))))

(ert-deftest harness-tools-board-the-kinds-are-the-permission-classes-they-need ()
  "Reading is read; an edit, a commit and an undo are writes; a preview changes nothing."
  (should (eq 'read (harness-tool-kind (harness-tool-get "scene.read"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "grammar.describe"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "patch.preview"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "board.list"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "board.pins"))))
  (should (eq 'read (harness-tool-kind (harness-tool-get "board.discussions"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "scene.edit"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "patch.commit"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "history.undo"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "board.create"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "board.pin"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "board.discuss"))))
  (should (eq 'write (harness-tool-kind (harness-tool-get "board.delete")))))

(ert-deftest harness-tools-board-every-schema-declares-what-its-handler-reads ()
  "A model can only send what the schema declares: no tool reads an undeclared field."
  (dolist (name '("board.list" "board.create" "scene.read" "scene.edit"
                  "patch.preview" "patch.commit" "history.undo"
                  "board.pin" "board.pins" "board.discuss" "board.discussions"
                  "board.delete"))
    (ert-info (name)
      (let* ((schema (harness-tool-schema (harness-tool-get name)))
             (properties (plist-get schema :properties)))
        ;; The required fields are declared ones, not just named.
        (dolist (required (append (plist-get schema :required) nil))
          (should (plist-member properties (intern (concat ":" required)))))
        ;; And the fields an operation of an edit takes are all there.
        (when (equal name "scene.edit")
          (let ((op-properties (plist-get (plist-get (plist-get properties :ops)
                                                     :items)
                                          :properties)))
            (dolist (field '(:op :id :diagram :kind :parent :child-anchor
                             :parent-anchor :angle :scale :mirror :text :name :role
                             :locked :x :y :dx :dy :budget :pivot :sx :sy :axis
                             :matrix :transform :shape :style :anchors :resources
                             :task :members :selection :portals :viewport :theme
                             :new-id :from :to :label :z :on))
              (ert-info ((format "%s" field))
                (should (plist-member op-properties field))))))))))

(ert-deftest harness-tools-board-the-schema-of-an-edit-names-every-operation ()
  "The grammar's operations are what the tool's own description says they are."
  (harness-tools-board-test--with
    (let ((content (plist-get (harness-tools-board-test--call
                               "grammar.describe" nil (harness-tools-board-test--ctx))
                              :content)))
      ;; Every operation a patch accepts is in the grammar an agent reads,
      ;; but for `restore', which is undo's own and carries a preimage.
      (dolist (entry harness-board--op-table)
        (unless (equal "restore" (car entry))
          (ert-info ((car entry))
            (should (string-match-p (regexp-quote (car entry)) content)))))
      (should-not (string-match-p "restore" content)))))

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

;;;; board.list

(ert-deftest harness-tools-board-board-list-names-the-boards-there-are ()
  "The id every other tool names, with what a list shows and nothing it guesses."
  (harness-tools-board-test--with
    (let* ((answer (harness-tools-board-test--call
                    "board.list" nil (harness-tools-board-test--ctx)))
           (content (plist-get answer :content))
           (meta (plist-get answer :meta)))
      (should-not (plist-get answer :is-error))
      (should (= 1 (plist-get meta :boards)))
      (should (string-match-p "b-fixture" content))
      (should (string-match-p "revision 1" content))
      (should (string-match-p "electric-commons" content))
      (should (string-match-p "Read one with scene.read" content))
      ;; A project's boards are what is listed; another project's are not.
      (let ((other (harness-tools-board-test--call
                    "board.list" (list :project "/tmp/elsewhere")
                    (harness-tools-board-test--ctx))))
        (should (string-match-p "No boards in /tmp/elsewhere" (plist-get other :content)))
        ;; And it says how a board is made, since there is none to read.
        (should (string-match-p "board.create" (plist-get other :content))))
      ;; Every board, whatever its project.
      (harness-call 'board/create "b-other" "another" (list :project "/tmp/elsewhere"))
      (let ((all (harness-tools-board-test--call
                  "board.list" (list :all t) (harness-tools-board-test--ctx))))
        (should (= 2 (plist-get (plist-get all :meta) :boards)))
        (should (string-match-p "b-other" (plist-get all :content)))))))

(ert-deftest harness-tools-board-board-list-says-when-there-are-no-boards ()
  "An empty answer names what it left out rather than reading as an empty harness."
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.list" (list :project (harness-test-temp-dir))
                   (harness-tools-board-test--ctx))))
      (should (string-match-p "No boards" (plist-get answer :content)))
      (should (= 0 (plist-get (plist-get answer :meta) :boards))))))

;;;; board.create

(ert-deftest harness-tools-board-board-create-makes-an-empty-board ()
  "A name makes a board with one empty diagram, and its id is what to read it by."
  (harness-tools-board-test--with
    (let* ((answer (harness-tools-board-test--call
                    "board.create" (list :name "the plan" :project "/tmp/atlas")
                    (harness-tools-board-test--ctx)))
           (meta (plist-get answer :meta))
           (board (plist-get meta :board)))
      (should-not (plist-get answer :is-error))
      ;; The answer names the board, its diagram, its project and its link.
      (should (stringp board))
      (should (string-match-p "\\`b-[a-z0-9]+\\'" board))
      (should (equal "the plan" (plist-get meta :name)))
      (should (equal "/tmp/atlas/" (plist-get meta :project)))
      (should (equal 0 (plist-get meta :revision)))
      (should (stringp (plist-get meta :diagram)))
      (should (string-match-p (format "harness:board/%s" (regexp-quote board))
                              (plist-get meta :link)))
      (should (string-match-p "Made board" (plist-get answer :content)))
      ;; It is there to read, empty but for its diagram.
      (let ((document (harness-call 'board/get board)))
        (should (equal 0 (plist-get document :revision)))
        (should (= 0 (length (plist-get document :objects))))
        (should (= 1 (length (plist-get document :diagrams)))))
      ;; And it is in the list it was made in.
      (let ((listed (harness-tools-board-test--call
                     "board.list" (list :project "/tmp/atlas")
                     (harness-tools-board-test--ctx))))
        (should (string-match-p (regexp-quote board) (plist-get listed :content)))))))

(ert-deftest harness-tools-board-board-create-takes-an-id-and-a-theme ()
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.create" (list :name "night" :id "b-night" :theme "night-commons")
                   (harness-tools-board-test--ctx))))
      (should-not (plist-get answer :is-error))
      (should (equal "b-night" (plist-get (plist-get answer :meta) :board)))
      (should (equal "night-commons" (plist-get (harness-call 'board/get "b-night") :theme)))
      ;; A board that is already here is refused, never emptied.
      (let ((again (harness-tools-board-test--call
                    "board.create" (list :name "again" :id "b-night")
                    (harness-tools-board-test--ctx))))
        (should (plist-get again :is-error))
        (should (string-match-p "invalid-parameter" (plist-get again :content)))
        (should (equal "night" (plist-get (harness-call 'board/get "b-night") :name))))
      ;; A theme the grammar does not have is refused, and says which it has.
      (let ((bad (harness-tools-board-test--call
                  "board.create" (list :name "bad" :theme "no-such-theme")
                  (harness-tools-board-test--ctx))))
        (should (plist-get bad :is-error))
        (should (string-match-p "invalid-parameter" (plist-get bad :content)))))))

(ert-deftest harness-tools-board-board-create-needs-a-name ()
  (harness-tools-board-test--with
    (should-error (harness-tools-board-test--call
                   "board.create" nil (harness-tools-board-test--ctx)))))

;;;; board.pins and board.discussions

(ert-deftest harness-tools-board-board-pins-reads-what-a-board-delivered ()
  "The list of artifacts, and one pin as the document it kept."
  (harness-tools-board-test--with
    ;; Nothing delivered yet: the answer says how one is made.
    (let ((empty (harness-tools-board-test--call
                  "board.pins" (list :board "b-fixture")
                  (harness-tools-board-test--ctx))))
      (should (string-match-p "No pinned revision" (plist-get empty :content)))
      (should (string-match-p "board.pin" (plist-get empty :content))))
    (let ((pin (harness-tools-board-test--call
                "board.pin" (list :board "b-fixture" :task "t-1" :title "the plan")
                (harness-tools-board-test--ctx))))
      (let* ((answer (harness-tools-board-test--call
                      "board.pins" (list :board "b-fixture")
                      (harness-tools-board-test--ctx)))
             (content (plist-get answer :content)))
        (should-not (plist-get answer :is-error))
        (should (= 1 (plist-get (plist-get answer :meta) :pins)))
        (should (string-match-p "the plan" content))
        (should (string-match-p "task t-1" content))
        (should (string-match-p "revision 1" content)))
      ;; One pin reads as the document it kept, with its picture.
      (let* ((one (harness-tools-board-test--call
                   "board.pins" (list :board "b-fixture"
                                      :pin (plist-get (plist-get pin :meta) :pin))
                   (harness-tools-board-test--ctx)))
             (content (plist-get one :content)))
        (should-not (plist-get one :is-error))
        (should (string-match-p "n-api" content))
        (should (string-match-p "Artifact:" content))
        (should (= 1 (length (append (plist-get one :images) nil))))))))

(ert-deftest harness-tools-board-board-pins-lines-read-cleanly ()
  "A pin's line counts one object as one, and never leaves an empty separator."
  (let ((line (harness-tools-board--pin-line
               (list :id "pin-1" :title "the plan" :revision 1 :diagram "d-overview"
                     :objects 1 :task "t-1" :created (harness-now)
                     :target "artifact" :current "board"))))
    (should (string-match-p "1 object\\b" line))
    (should (string-match-p "task t-1" line))
    (should (string-match-p "just now" line))
    (should-not (string-match-p " ·  · " line))
    (should-not (string-match-p " · \n" line)))
  (let ((line (harness-tools-board--pin-line
               (list :id "pin-2" :title "the plan" :revision 1 :diagram "d-overview"
                     :objects 3 :created (harness-now)
                     :target "artifact" :current "board"))))
    (should (string-match-p "3 objects" line))
    (should (string-match-p "no task" line))
    (should-not (string-match-p " ·  · " line))))

(ert-deftest harness-tools-board-board-pins-keeps-the-artifact-of-a-task ()
  "Naming a task keeps the pins it delivered."
  (harness-tools-board-test--with
    (dolist (task '("t-1" "t-2"))
      (harness-tools-board-test--call
       "board.pin" (list :board "b-fixture" :task task)
       (harness-tools-board-test--ctx)))
    (let ((answer (harness-tools-board-test--call
                   "board.pins" (list :board "b-fixture" :task "t-2")
                   (harness-tools-board-test--ctx))))
      (should (= 1 (plist-get (plist-get answer :meta) :pins)))
      (should (string-match-p "task t-2" (plist-get answer :content)))
      (should-not (string-match-p "task t-1" (plist-get answer :content))))))

(ert-deftest harness-tools-board-board-pins-refuses-a-pin-that-is-not-here ()
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.pins" (list :board "b-fixture" :pin "pin-nowhere")
                   (harness-tools-board-test--ctx))))
      (should (plist-get answer :is-error))
      (should (string-match-p "unknown-id" (plist-get answer :content))))))

(ert-deftest harness-tools-board-board-discussions-says-when-there-is-none ()
  "A board no review has discussed says so, and names the tool that starts one."
  (harness-tools-board-test--with
    (let ((answer (harness-tools-board-test--call
                   "board.discussions" (list :board "b-fixture")
                   (harness-tools-board-test--ctx))))
      (should-not (plist-get answer :is-error))
      (should (string-match-p "No discussion" (plist-get answer :content)))
      (should (string-match-p "board.discuss" (plist-get answer :content)))
      (should (= 0 (plist-get (plist-get answer :meta) :threads))))))

(ert-deftest harness-tools-board-board-discussions-needs-a-board ()
  (harness-tools-board-test--with
    (dolist (name '("board.pins" "board.discussions" "board.delete"))
      (ert-info (name)
        (should-error (harness-tools-board-test--call
                       name nil (harness-tools-board-test--ctx)))))))

;;;; board.delete

(ert-deftest harness-tools-board-board-delete-removes-a-board-made-by-mistake ()
  (harness-tools-board-test--with
    (let ((made (harness-tools-board-test--call
                 "board.create" (list :name "mistake" :id "b-mistake")
                 (harness-tools-board-test--ctx))))
      (should-not (plist-get made :is-error))
      (let ((answer (harness-tools-board-test--call
                     "board.delete" (list :board "b-mistake")
                     (harness-tools-board-test--ctx))))
        (should-not (plist-get answer :is-error))
        (should (plist-get (plist-get answer :meta) :deleted))
        (should (string-match-p "Deleted board b-mistake" (plist-get answer :content)))
        (should-not (harness-board-load "b-mistake"))))))

(ert-deftest harness-tools-board-board-delete-keeps-what-a-task-delivered ()
  "A delivered artifact is refused, and force says what goes with the board."
  (harness-tools-board-test--with
    (harness-tools-board-test--call
     "board.pin" (list :board "b-fixture" :task "t-1")
     (harness-tools-board-test--ctx))
    (let ((refused (harness-tools-board-test--call
                    "board.delete" (list :board "b-fixture")
                    (harness-tools-board-test--ctx))))
      (should (plist-get refused :is-error))
      (should (string-match-p "precondition" (plist-get refused :content)))
      (should (harness-board-load "b-fixture")))
    (let ((forced (harness-tools-board-test--call
                   "board.delete" (list :board "b-fixture" :force t)
                   (harness-tools-board-test--ctx))))
      (should-not (plist-get forced :is-error))
      (should (= 1 (plist-get (plist-get forced :meta) :pins)))
      (should (string-match-p "pinned revision went with it" (plist-get forced :content)))
      (should-not (harness-board-load "b-fixture")))))
(ert-deftest harness-tools-board-the-module-brings-a-skill-that-names-every-tool ()
  "The skill is listed while the tools module is ready, and it covers what it explains."
  (harness-test-with-temp-state
    (unwind-protect
        (progn
          (harness-test-reset-bus)
          (dolist (name '(store project config provider tools session agent linking
                          board board-edit board-store board-svg skills tools-board))
            (harness-test-load-module name))
          (should (harness-module-ready-p 'tools-board))
          (let* ((cwd (harness-test-temp-dir))
                 (skill (cl-find "freeform-board" (harness-call 'skills/list cwd)
                                 :key (lambda (s) (plist-get s :name))
                                 :test #'string=)))
            (unwind-protect
                (progn
                  (should skill)
                  (should (eq 'global (plist-get skill :source)))
                  (should (equal "harness" (plist-get skill :origin)))
                  (let ((content (plist-get (harness-call 'skills/load "freeform-board" cwd)
                                            :content)))
                    ;; It names every tool, so a model that follows it
                    ;; reaches the ones this module registers.
                    (dolist (name '("board.list" "board.create" "scene.read"
                                    "grammar.describe" "scene.edit" "patch.preview"
                                    "patch.commit" "history.undo" "board.pin"
                                    "board.pins" "board.discuss" "board.discussions"
                                    "board.delete"))
                      (ert-info (name)
                        (should (string-match-p (regexp-quote name) content))))
                    ;; And the rules a caller would otherwise get wrong.
                    (should (string-match-p "stale-revision" content))
                    (should (string-match-p "idempotencyKey" content))
                    (should (string-match-p "scope" content)))
                  ;; A module that is not ready brings no skill.
                  (harness-module-disable 'tools-board)
                  (should-not (cl-find "freeform-board" (harness-call 'skills/list)
                                       :key (lambda (s) (plist-get s :name))
                                       :test #'string=)))
              (ignore-errors (delete-directory cwd t)))))
      (harness-skills-remove-module-directory 'tools-board)
      (harness-test-reset-bus)
      (dolist (name '(store project config provider tools session agent linking
                      board board-edit board-store board-svg tools-board))
        (harness-test-load-module name)))))

(provide 'harness-tools-board-test)
;;; harness-tools-board-test.el ends here
